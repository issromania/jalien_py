#!/usr/bin/env bash

# catalogue and session commands on a self created test dir in the user home:
# mkdir -p, cd (absolute, relative, -, no argument), pwd, pushd/popd, ls, touch, stat, mv, rm, rm -rf
# saving of the current dir in ~/.alienpy_session and its restore at the start of the shell
# the ~/.alienpy_session of the user is saved and put back at the end

clean_logs () { rm -f log.txt out.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_HISTORY=1  # do not read/write the user history

TEST_SCRIPT="$(realpath "${0}")"
THIS_TEST="$(basename "$(dirname "${TEST_SCRIPT}")")/$(basename "${TEST_SCRIPT}")"

SESSION_FILE="${HOME}/.alienpy_session"
SESSION_BACKUP="$(pwd)/alienpy_session_backup"
rm -f "${SESSION_BACKUP}" &> /dev/null
[[ -f "${SESSION_FILE}" ]] && { cp -p "${SESSION_FILE}" "${SESSION_BACKUP}" || { echo "Could not save ${SESSION_FILE} in ${THIS_TEST}"; exit 1; }; }

TESTDIR_REMOTE=""
cleanup () {
if [[ -n "${TESTDIR_REMOTE}" ]]; then  # left by a failed check
    ALIENPY_NO_CWD_RESTORE=1 alien.py rm -rf "${TESTDIR_REMOTE}" &> /dev/null || echo "WARNING: the test dir ${TESTDIR_REMOTE} could not be removed, remove it by hand"
fi
if [[ -f "${SESSION_BACKUP}" ]]; then
    mv -f "${SESSION_BACKUP}" "${SESSION_FILE}"
else
    rm -f "${SESSION_FILE}" &> /dev/null  # it was created by this test
fi
}
trap cleanup EXIT

LAST_CMD=""
RC=""
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

# expect_ok <check> <command...>
expect_ok () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}" "exitcode 0"; }

# expect_fail <check> <command...>
expect_fail () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" != "0" ]] || fail "${desc}" "exitcode != 0"; }

# expect_line <check> <line> : the output of the last command has the exact line
expect_line () { grep -qxF "${2}" out.log || fail "${1}" "the output has the line >${2}<"; }

export ALIENPY_NO_CWD_RESTORE=1  # command mode starts in the home dir; restore is checked explicitly at the end

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

TESTDIR_REMOTE="${ALIEN_HOME}alienpy_ci_session_$(date +%Y%m%d_%H%M%S)_$$"  # home already includes slash at the end
R="${TESTDIR_REMOTE}"
echo "Test dir: ${R}"

expect_ok "mkdir -p creates a/b in the test dir" alien.py mkdir -p "${R}/a/b"
expect_ok "stat of the dir created by mkdir -p" alien.py stat "${R}/a/b"

expect_ok "cd to an absolute path, then pwd" alien.py "cd ${R}/a/b; pwd"
expect_line "pwd after cd to an absolute path" "${R}/a/b/"

expect_ok "cd to a relative path, then pwd" alien.py "cd ${R}; cd a; pwd"
expect_line "pwd after cd to a relative path" "${R}/a/"

expect_ok "cd - goes back to the previous dir, then pwd" alien.py "cd ${R}/a; cd b; cd -; pwd"
expect_line "pwd after cd -" "${R}/a/"

expect_ok "cd .. goes to the parent dir, then pwd" alien.py "cd ${R}/a/b; cd ..; pwd"
expect_line "pwd after cd .." "${R}/a/"

expect_ok "cd without argument goes home, then pwd" alien.py "cd ${R}/a; cd; pwd"
expect_line "pwd after cd without argument" "${ALIEN_HOME}"

expect_ok "pushd a/b then popd, with pwd after each" alien.py "cd ${R}; pushd ${R}/a/b; pwd | sed s/^/PUSHD_/; popd; pwd | sed s/^/POPD_/"
expect_line "pwd after pushd (marked PUSHD_)" "PUSHD_${R}/a/b/"
expect_line "pwd after popd (marked POPD_)" "POPD_${R}/"

expect_ok "mkdir with a relative path (c)" alien.py "cd ${R}; mkdir c"
expect_ok "stat of the dir created with a relative path" alien.py stat "${R}/c"

expect_ok "touch creates the empty file a/f.txt" alien.py touch "${R}/a/f.txt"
expect_ok "ls of dir a" alien.py ls "${R}/a"
expect_line "ls of dir a lists the file created by touch" "f.txt"
expect_line "ls of dir a lists the subdir b (with / added by ls -F)" "b/"

expect_ok "mv of dir a/b to a/b2" alien.py mv "${R}/a/b" "${R}/a/b2"
expect_ok "stat of the mv destination" alien.py stat "${R}/a/b2"
expect_fail "stat of the mv source (must fail)" alien.py stat "${R}/a/b"

expect_ok "rm of the file a/f.txt" alien.py rm "${R}/a/f.txt"
expect_fail "stat of the removed file (must fail)" alien.py stat "${R}/a/f.txt"

# the last cd of a command is saved and restored by the next shell
expect_ok "cd to a/b2 (saved in ${SESSION_FILE})" alien.py "cd ${R}/a/b2"
grep -qxF "CWD = ${R}/a/b2/" "${SESSION_FILE}" || { cp "${SESSION_FILE}" out.log; LAST_CMD="cat ${SESSION_FILE}"; fail "the cwd is saved in the session file" "the line >CWD = ${R}/a/b2/<"; }
echo "Trying the shell restores the saved cwd .."
run_rc env -u ALIENPY_NO_CWD_RESTORE alien.py < <(printf 'pwd | sed s/^/RESTORED_/\nexit\n')
LAST_CMD="${LAST_CMD} (shell, input: pwd | sed s/^/RESTORED_/ ; exit)"
[[ "${RC}" == "0" ]] || fail "the shell restores the saved cwd" "exitcode 0"
grep -qF "RESTORED_${R}/a/b2/" out.log || fail "the shell restores the saved cwd" "the pwd output (marked RESTORED_) is ${R}/a/b2/"

expect_ok "rm -rf of the test dir" alien.py rm -rf "${R}"
expect_fail "stat of the removed test dir (must fail)" alien.py stat "${R}"
TESTDIR_REMOTE=""

clean_logs
exit 0
