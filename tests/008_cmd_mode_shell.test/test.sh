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

LAST_CMD=""
RC=""
# trying <check> : print the check that is done
trying () { echo "Trying ${1} .."; }

# fail <check> <expected> : report the check, the command run, what was expected, what was got
fail () {
echo "FAIL in ${THIS_TEST}"
echo "  check    : ${1}"
echo "  command  : ${LAST_CMD}"
echo "  expected : ${2}"
echo "  exitcode : ${RC}"
echo "  output   :"
sed 's/^/    | /' out.log
exit 1
}

# run_rc <command...> : run with output in out.log, set RC; the command is kept for the failure report
run_rc () { LAST_CMD="$*"; "$@" &> out.log; RC="${?}"; }

# run_shell <printf format> [args] : run the alien.py shell with these commands on stdin
run_shell () { local input; input="$(printf "$@")"; LAST_CMD="alien.py (shell) with input: ${input//$'\n'/ ; }"; alien.py < <(printf '%s\n' "${input}") &> out.log; RC="${?}"; }

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }
INVALID_DIR="/alice/cern.ch/alienpy_ci_does_not_exist_$(date +%s)"

trying "ls of a dir that does not exist (must fail)"
run_rc alien.py ls "${INVALID_DIR}"
LS_FAIL_RC="${RC}"
[[ "${LS_FAIL_RC}" != "0" ]] || fail "ls of a dir that does not exist" "exitcode != 0"

# chain: the exitcode is the one of the last command
trying "chain 'failing ls; pwd': exitcode of the last command (0)"
run_rc alien.py "ls ${INVALID_DIR}; pwd"
[[ "${RC}" == "0" ]] || fail "chain with the last command valid" "exitcode 0"
grep -qxF "${ALIEN_HOME}" out.log || fail "chain with the last command valid" "the pwd output >${ALIEN_HOME}<"

trying "chain 'pwd; failing ls': exitcode of the last command (${LS_FAIL_RC})"
run_rc alien.py "pwd; ls ${INVALID_DIR}"
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "chain with the last command failed" "exitcode ${LS_FAIL_RC} (of the failing ls)"

# pipe of the output to a shell command; the exitcode is the one of the shell command
trying "pipe of pwd to 'grep -c alice': output 1, exitcode 0"
run_rc alien.py "pwd | grep -c alice"
[[ "${RC}" == "0" && "$(< out.log)" == "1" ]] || fail "pipe of the output to a shell command" "exitcode 0 and the output 1"

trying "pipe of pwd to grep without match: exitcode 1 of grep"
run_rc alien.py "pwd | grep -q alienpy_ci_no_such_string"
[[ "${RC}" == "1" ]] || fail "pipe to a shell command that fails" "exitcode 1 (of grep)"

# batch file: one command per line, the exitcode is the one of the last command
printf 'ls %s\npwd\n' "${INVALID_DIR}" > cmds_ok.txt
printf 'pwd\nls %s\n' "${INVALID_DIR}" > cmds_fail.txt
trying "batch file 'failing ls, pwd': exitcode of the last command (0)"
run_rc alien.py ./cmds_ok.txt
[[ "${RC}" == "0" ]] || fail "batch file with the last command valid" "exitcode 0"
grep -qxF "${ALIEN_HOME}" out.log || fail "batch file with the last command valid" "the pwd output >${ALIEN_HOME}<"

trying "batch file 'pwd, failing ls': exitcode of the last command (${LS_FAIL_RC})"
run_rc alien.py ./cmds_fail.txt
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "batch file with the last command failed" "exitcode ${LS_FAIL_RC} (of the failing ls)"

# unknown command is refused client side
trying "unknown command: refused with exitcode 1"
run_rc alien.py alienpy_ci_no_such_command
[[ "${RC}" == "1" ]] || fail "unknown command" "exitcode 1"

trying "exit 3 in command mode: exitcode 3"
run_rc alien.py "exit 3"
[[ "${RC}" == "3" ]] || fail "exit with explicit code in command mode" "exitcode 3"

trying "bare exit in command mode: exitcode 0"
run_rc alien.py exit
[[ "${RC}" == "0" ]] || fail "bare exit before any other command" "exitcode 0"

# -json : the output is the JSON answer of the server
trying "-json pwd: the output is the JSON answer of the server"
run_rc alien.py -json pwd
[[ "${RC}" == "0" ]] || fail "-json pwd" "exitcode 0"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if "metadata" in d and "results" in d else 1)' out.log || fail "-json pwd" "a JSON object with metadata and results"

# shell mode with commands from stdin: failed and invalid commands do not terminate the shell
# (the prompt contains the current dir, so the pwd output is marked to be found)
trying "shell: failing ls and invalid quoting do not stop it, then exit 7"
run_shell 'ls %s\nls "unbalanced_quote\npwd | sed s/^/MARK_/\nexit 7' "${INVALID_DIR}"
[[ "${RC}" == "7" ]] || fail "shell continues after failed commands and exits with exit 7" "exitcode 7"
grep -qF "MARK_${ALIEN_HOME}" out.log || fail "shell continues after failed commands" "the pwd output marked MARK_${ALIEN_HOME}"

trying "shell: bare exit as the first command: exitcode 0"
run_shell 'exit'
[[ "${RC}" == "0" ]] || fail "shell: bare exit as the first command" "exitcode 0"

trying "shell: bare exit after a failing ls: exitcode of the ls (${LS_FAIL_RC})"
run_shell 'ls %s\nexit' "${INVALID_DIR}"
[[ "${RC}" == "${LS_FAIL_RC}" ]] || fail "shell: bare exit after a failed command" "exitcode ${LS_FAIL_RC} (of the failing ls)"

clean_logs
exit 0
