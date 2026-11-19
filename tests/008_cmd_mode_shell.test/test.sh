#!/usr/bin/env bash

# command mode: chaining with ; , pipe to a shell command, batch file, -json output
# shell mode with commands from stdin: survival after failed/invalid commands, exit code propagation
# no grid data is created or modified

clean_logs () { rm -f log.txt out.log cmds_ok.txt cmds_fail.txt &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_HISTORY=1 ALIENPY_NO_CWD_RESTORE=1  # do not read/write the user history and saved session

TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

fail () { echo "FAIL in ${THIS_TEST} :: ${1}"; cat out.log; exit 1; }

# run_rc <command...> : run with output in out.log, set RC
run_rc () { "$@" &> out.log; RC="${?}"; }

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }
INVALID_DIR="/alice/cern.ch/alienpy_ci_does_not_exist_$(date +%s)"

run_rc alien.py ls "${INVALID_DIR}"
LS_FAIL_RC="${RC}"
[[ "${LS_FAIL_RC}" != "0" ]] || fail "ls of invalid dir: expected exitcode != 0"

# chain: the exitcode is the one of the last command
run_rc alien.py "ls ${INVALID_DIR}; pwd"
[[ "${RC}" == "0" ]] || fail "chain with last command valid: expected exitcode 0 got ${RC}"
grep -qxF "${ALIEN_HOME}" out.log || fail "chain: pwd output (${ALIEN_HOME}) not found"

run_rc alien.py "pwd; ls ${INVALID_DIR}"
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "chain with last command failed: expected exitcode ${LS_FAIL_RC} got ${RC}"

# pipe of the output to a shell command; the exitcode is the one of the shell command
run_rc alien.py "pwd | grep -c alice"
[[ "${RC}" == "0" && "$(< out.log)" == "1" ]] || fail "pipe to grep -c : expected exitcode 0 and output 1, got ${RC}"

run_rc alien.py "pwd | grep -q alienpy_ci_no_such_string"
[[ "${RC}" == "1" ]] || fail "pipe to grep without match: expected exitcode 1 got ${RC}"

# batch file: one command per line, the exitcode is the one of the last command
printf 'ls %s\npwd\n' "${INVALID_DIR}" > cmds_ok.txt
printf 'pwd\nls %s\n' "${INVALID_DIR}" > cmds_fail.txt
run_rc alien.py ./cmds_ok.txt
[[ "${RC}" == "0" ]] || fail "batch file with last command valid: expected exitcode 0 got ${RC}"
grep -qxF "${ALIEN_HOME}" out.log || fail "batch file: pwd output not found"
run_rc alien.py ./cmds_fail.txt
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "batch file with last command failed: expected exitcode ${LS_FAIL_RC} got ${RC}"

# unknown command is refused client side
run_rc alien.py alienpy_ci_no_such_command
[[ "${RC}" == "1" ]] || fail "unknown command: expected exitcode 1 got ${RC}"

# exit command with explicit code
run_rc alien.py "exit 3"
[[ "${RC}" == "3" ]] || fail "exit 3 in command mode: expected exitcode 3 got ${RC}"

# a bare exit before any other command
run_rc alien.py exit
[[ "${RC}" == "0" ]] || fail "bare exit in command mode: expected exitcode 0 got ${RC}"

# -json : the output is the JSON answer of the server
run_rc alien.py -json pwd
[[ "${RC}" == "0" ]] || fail "-json pwd: expected exitcode 0 got ${RC}"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if "metadata" in d and "results" in d else 1)' out.log || fail "-json pwd: output is not a JSON server answer"

# shell mode with commands from stdin: failed and invalid commands do not terminate the shell
# (the prompt contains the current dir, so the pwd output is marked to be found)
run_rc alien.py < <(printf 'ls %s\nls "unbalanced_quote\npwd | sed s/^/MARK_/\nexit 7\n' "${INVALID_DIR}")
[[ "${RC}" == "7" ]] || fail "shell: expected exitcode 7 (from exit 7) got ${RC}"
grep -qF "MARK_${ALIEN_HOME}" out.log || fail "shell: pwd output after the failed commands not found"

# shell mode: a bare exit as the first command
run_rc alien.py < <(printf 'exit\n')
[[ "${RC}" == "0" ]] || fail "shell: bare exit as first command: expected exitcode 0 got ${RC}"

# shell mode: exit without code returns the exitcode of the last command
run_rc alien.py < <(printf 'ls %s\nexit\n' "${INVALID_DIR}")
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "shell: exit after failed command: expected exitcode ${LS_FAIL_RC} got ${RC}"

clean_logs
exit 0
