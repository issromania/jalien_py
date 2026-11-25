#!/usr/bin/env bash

# find2 selections (-name verbs, -name plain regex, -glob, -select, -exclude_re) on empty lfns created with touch
# in a self created test dir in the user home; invalid selections must give exitcode 22 (EINVAL)
# the same selections are used by cp for the download of directories

clean_logs () { rm -f log.txt out.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_CWD_RESTORE=1 ALIENPY_NO_HISTORY=1

TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

R="${ALIEN_HOME}alienpy_ci_find2_$(date +%Y%m%d_%H%M%S)_$$"  # home already includes slash at the end

cleanup () { alien.py rm -rf "${R}" &> /dev/null || echo "WARNING: the test dir ${R} could not be removed, remove it by hand"; }
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

# expect_count <expected number of lfns> <check> <find2 arguments...> ; the search dir is added as last argument
expect_count () {
local exp="${1}" desc="${2}"; shift 2
echo "Trying find2 ${desc}: ${exp} files .."
run_rc alien.py find2 "$@" "${R}/"
[[ "${RC}" == "0" ]] || fail "find2 ${desc}" "exitcode 0 and ${exp} files"
local found; found="$(grep -cF "${R}/" out.log)"
[[ "${found}" == "${exp}" ]] || fail "find2 ${desc}" "${exp} files (found ${found})"
}

# expect_rc <expected exitcode> <check> <find2 arguments...>
expect_rc () {
local exp="${1}" desc="${2}"; shift 2
echo "Trying find2 ${desc}: exitcode ${exp} .."
run_rc alien.py find2 "$@" "${R}/"
[[ "${RC}" == "${exp}" ]] || fail "find2 ${desc}" "exitcode ${exp}"
}

echo "Test dir: ${R}"
echo "Trying mkdir -p of the test dirs a and b .."
run_rc alien.py mkdir -p "${R}/a" "${R}/b"
[[ "${RC}" == "0" ]] || fail "mkdir -p of the test dirs a and b" "exitcode 0"
echo "Trying touch of the empty test files .."
for f in a/stdout.log a/stderr.log a/x_stdout.log.gz b/AO2D_001.root b/AO2D_xx.root b/other.root; do
    run_rc alien.py touch "${R}/${f}"
    [[ "${RC}" == "0" ]] || fail "touch of the test file ${f}" "exitcode 0"
done

expect_count 6 "without selection (all files)"
expect_count 2 "-name ext_log (extension log)" -name ext_log
expect_count 2 "-name begin_std (name begins with std)" -name begin_std
expect_count 2 "-name contain_stdout (name contains stdout)" -name contain_stdout
expect_count 1 "-name contain_err_contain_std (contains both, any order)" -name contain_err_contain_std
expect_count 1 "-name begin_x_ends_out.log_ext_gz (begin + ends + extension)" -name begin_x_ends_out.log_ext_gz
expect_count 1 "-name with a plain regex AO2D_[0-9]+\.root\$" -name 'AO2D_[0-9]+\.root$'
expect_count 3 "-glob *.root" -glob '*.root'
expect_count 1 "-glob *.root with -exclude_re AO2D" -glob '*.root' -exclude_re 'AO2D'
expect_count 4 "-exclude b/AO2D (path relative to the searched dir)" -exclude b/AO2D
expect_count 1 "-select .*\.gz\$ (regex)" -select '.*\.gz$'

expect_rc 22 "with an invalid -exclude_re regex" -exclude_re 'a('
expect_rc 22 "with an invalid -name regex" -name 'a('
expect_rc 22 "-name with a repeated verb (begin_a_begin_b)" -name begin_a_begin_b
expect_rc 22 "with both -name and -glob" -name ext_log -glob '*.log'

echo "Trying rm -rf of the test dir .."
run_rc alien.py rm -rf "${R}"
[[ "${RC}" == "0" ]] || fail "rm -rf of the test dir" "exitcode 0"
trap - EXIT
clean_logs
exit 0
