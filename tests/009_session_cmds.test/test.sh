#!/usr/bin/env bash

# catalogue and session commands on a self created test dir in the user home:
# mkdir -p, cd (absolute, relative, -, no argument), pwd, pushd/popd, ls, touch, stat, mv, rm, rm -rf
# saving of the current dir in ~/.alienpy_session and its restore at the start of the shell
# the ~/.alienpy_session of the user is saved and put back at the end

clean_logs () { rm -f log.txt out.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_HISTORY=1  # do not read/write the user history

TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

SESSION_FILE="${HOME}/.alienpy_session"
SESSION_BACKUP="$(pwd)/alienpy_session_backup"
rm -f "${SESSION_BACKUP}" &> /dev/null
[[ -f "${SESSION_FILE}" ]] && { cp -p "${SESSION_FILE}" "${SESSION_BACKUP}" || { echo "Could not save ${SESSION_FILE} in ${THIS_TEST}"; exit 1; }; }

TESTDIR_REMOTE=""
cleanup () {
[[ -n "${TESTDIR_REMOTE}" ]] && ALIENPY_NO_CWD_RESTORE=1 alien.py rm -rf "${TESTDIR_REMOTE}" &> /dev/null  # does not matter if missing
if [[ -f "${SESSION_BACKUP}" ]]; then
    mv -f "${SESSION_BACKUP}" "${SESSION_FILE}"
else
    rm -f "${SESSION_FILE}" &> /dev/null  # it was created by this test
fi
}
trap cleanup EXIT

fail () { echo "FAIL in ${THIS_TEST} :: ${1}"; cat out.log; exit 1; }

# run_rc <command...> : run with output in out.log, set RC
run_rc () { "$@" &> out.log; RC="${?}"; }

# expect_ok <description> <command...>
expect_ok () { local desc="${1}"; shift; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}: expected exitcode 0 got ${RC}"; }

# expect_fail <description> <command...>
expect_fail () { local desc="${1}"; shift; run_rc "$@"; [[ "${RC}" != "0" ]] || fail "${desc}: expected exitcode != 0 got 0"; }

# expect_line <description> <line> : out.log has the exact line
expect_line () { grep -qxF "${2}" out.log || fail "${1}: line >${2}< not found"; }

export ALIENPY_NO_CWD_RESTORE=1  # command mode starts in the home dir; restore is checked explicitly at the end

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

TESTDIR_REMOTE="${ALIEN_HOME}alienpy_ci_session_$(date +%Y%m%d_%H%M%S)_$$"  # home already includes slash at the end
R="${TESTDIR_REMOTE}"

expect_ok "mkdir -p" alien.py mkdir -p "${R}/a/b"
expect_ok "stat of created dir" alien.py stat "${R}/a/b"

expect_ok "cd absolute" alien.py "cd ${R}/a/b; pwd"
expect_line "cd absolute" "${R}/a/b/"

expect_ok "cd relative" alien.py "cd ${R}; cd a; pwd"
expect_line "cd relative" "${R}/a/"

expect_ok "cd -" alien.py "cd ${R}/a; cd b; cd -; pwd"
expect_line "cd -" "${R}/a/"

expect_ok "cd .." alien.py "cd ${R}/a/b; cd ..; pwd"
expect_line "cd .." "${R}/a/"

expect_ok "cd without argument" alien.py "cd ${R}/a; cd; pwd"
expect_line "cd without argument" "${ALIEN_HOME}"

expect_ok "pushd/popd" alien.py "cd ${R}; pushd ${R}/a/b; pwd | sed s/^/PUSHD_/; popd; pwd | sed s/^/POPD_/"
expect_line "pushd" "PUSHD_${R}/a/b/"
expect_line "popd" "POPD_${R}/"

expect_ok "mkdir relative" alien.py "cd ${R}; mkdir c"
expect_ok "stat of relative mkdir" alien.py stat "${R}/c"

expect_ok "touch" alien.py touch "${R}/a/f.txt"
expect_ok "ls" alien.py ls "${R}/a"
expect_line "ls file" "f.txt"
expect_line "ls dir" "b/"

expect_ok "mv dir" alien.py mv "${R}/a/b" "${R}/a/b2"
expect_ok "stat of moved dir" alien.py stat "${R}/a/b2"
expect_fail "stat of mv source" alien.py stat "${R}/a/b"

expect_ok "rm file" alien.py rm "${R}/a/f.txt"
expect_fail "stat of removed file" alien.py stat "${R}/a/f.txt"

# the last cd of a command is saved and restored by the next shell
expect_ok "cd for session save" alien.py "cd ${R}/a/b2"
grep -qxF "CWD = ${R}/a/b2/" "${SESSION_FILE}" || { cp "${SESSION_FILE}" out.log; fail "session file does not have the cwd ${R}/a/b2/"; }
run_rc env -u ALIENPY_NO_CWD_RESTORE alien.py < <(printf 'pwd | sed s/^/RESTORED_/\nexit\n')
[[ "${RC}" == "0" ]] || fail "shell with restore: expected exitcode 0 got ${RC}"
grep -qF "RESTORED_${R}/a/b2/" out.log || fail "shell did not restore the cwd ${R}/a/b2/"

expect_ok "rm -rf" alien.py rm -rf "${R}"
expect_fail "stat of removed dir" alien.py stat "${R}"
TESTDIR_REMOTE=""

clean_logs
exit 0
