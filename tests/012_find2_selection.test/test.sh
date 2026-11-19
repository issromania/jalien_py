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

cleanup () { alien.py rm -rf "${R}" &> /dev/null; }  # does not matter if missing
trap cleanup EXIT

fail () { echo "FAIL in ${THIS_TEST} :: ${1}"; cat out.log; exit 1; }

# run_rc <command...> : run with output in out.log, set RC
run_rc () { "$@" &> out.log; RC="${?}"; }

# expect_count <expected number of lfns> <description> <find2 arguments...> ; the search dir is added as last argument
expect_count () {
local exp="${1}" desc="${2}"; shift 2
run_rc alien.py find2 "$@" "${R}/"
[[ "${RC}" == "0" ]] || fail "${desc}: expected exitcode 0 got ${RC}"
local found; found="$(grep -cF "${R}/" out.log)"
[[ "${found}" == "${exp}" ]] || fail "${desc}: expected ${exp} files, found ${found}"
}

# expect_rc <expected exitcode> <description> <find2 arguments...>
expect_rc () { local exp="${1}" desc="${2}"; shift 2; run_rc alien.py find2 "$@" "${R}/"; [[ "${RC}" == "${exp}" ]] || fail "${desc}: expected exitcode ${exp} got ${RC}"; }

run_rc alien.py mkdir -p "${R}/a" "${R}/b"
[[ "${RC}" == "0" ]] || fail "mkdir of test dirs: expected exitcode 0 got ${RC}"
for f in a/stdout.log a/stderr.log a/x_stdout.log.gz b/AO2D_001.root b/AO2D_xx.root b/other.root; do
    run_rc alien.py touch "${R}/${f}"
    [[ "${RC}" == "0" ]] || fail "touch ${f}: expected exitcode 0 got ${RC}"
done

expect_count 6 "all files"
expect_count 2 "-name ext_log" -name ext_log
expect_count 2 "-name begin_std" -name begin_std
expect_count 2 "-name contain_stdout" -name contain_stdout
expect_count 1 "-name contain_err_contain_std (any order)" -name contain_err_contain_std
expect_count 1 "-name begin_x_ends_out_ext_gz" -name begin_x_ends_out.log_ext_gz
expect_count 1 "-name plain regex" -name 'AO2D_[0-9]+\.root$'
expect_count 3 "-glob" -glob '*.root'
expect_count 1 "-glob with -exclude_re" -glob '*.root' -exclude_re 'AO2D'
expect_count 4 "-exclude" -exclude b/AO2D
expect_count 1 "-select" -select '.*\.gz$'

expect_rc 22 "invalid -exclude_re" -exclude_re 'a('
expect_rc 22 "invalid -name plain regex" -name 'a('
expect_rc 22 "-name verb repeated" -name begin_a_begin_b
expect_rc 22 "-name and -glob together" -name ext_log -glob '*.log'

run_rc alien.py rm -rf "${R}"
[[ "${RC}" == "0" ]] || fail "rm -rf of test dir: expected exitcode 0 got ${RC}"
trap - EXIT
clean_logs
exit 0
