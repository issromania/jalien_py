#!/usr/bin/env bash

clean_logs () { rm -rf xrdlog_*.txt xrdlog.txt log.txt cmdout.txt ci_test_dir out.log &> /dev/null ; }
clean_logs

export XRD_LOGLEVEL='Dump' XRD_LOGFILE=xrdlog.txt ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

ALIEN_HOME="$(ALIENPY_NO_CWD_RESTORE=yes alien.py home)"
EXITCODE="${?}"
[[ -z ${ALIEN_HOME} ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

NOW="$(date +%Y%m%d_%H%M%S)"
TESTDIR_REMOTE="${ALIEN_HOME}alienpy_ci_test_dir_${NOW}" # home already includes slash at the end
TESTDIR_LOCAL="ci_test_dir"

alienpy_clean_testdir () {
local TESTDIR_R TESTDIR_L
TESTDIR_R="${1}"
TESTDIR_L="${2}"
alien.py rm -rf "${TESTDIR_R}" &> /dev/null # let's try to clean up, does not matter if missing
[[ -d "${TESTDIR_L}" ]] && { rm -rf "${TESTDIR_L}" &> /dev/null; } # clean up also the local dir if prezent
}

alienpy_clean_testdir "${TESTDIR_REMOTE}" "${TESTDIR_LOCAL}"

# get the files for upload test
echo -ne "Download reference files in ${TESTDIR_LOCAL} .. "
export XRD_LOGFILE=xrdlog_download.txt
alien.py cp -retry 3 "/alice/cern.ch/user/a/admin/referenceData/*.log" "file:${TESTDIR_LOCAL}/" &> out.log || { EXITCODE="${?}"; echo "Could not download reference files in ${THIS_TEST}"; cat out.log; exit "${EXITCODE}"; }
echo "OK"

# do the upload
# use 2 + CERN for the safety of the test, we do not want a fail test due to oveloaded server
echo -ne "Uploading the ci_test_dir to GRID .. "
export XRD_LOGFILE=xrdlog_upload.txt
alien.py cp "file:${TESTDIR_LOCAL}/" "${TESTDIR_REMOTE}/@disk:2,ALICE::CERN::EOS" &> out.log || { EXITCODE="${?}"; echo "Could not upload reference files in ${THIS_TEST}"; cat out.log; exit "${EXITCODE}"; }
echo "OK"

# the downloaded reference files (the upload source)
shopt -s globstar nullglob
LOCAL_FILES=( "${TESTDIR_LOCAL}"/**/*.log )
GOOD_RESULT="4"
echo -ne "Checking the number of downloaded reference files .. "
[[ "${#LOCAL_FILES[@]}" -eq "${GOOD_RESULT}" ]] || { echo "Wrong count of downloaded files in ${THIS_TEST}: expected ${GOOD_RESULT}, found ${#LOCAL_FILES[@]} : ${LOCAL_FILES[*]}"; exit 1; }
echo "OK"

# each uploaded file must exist in the grid dir, at the same relative path
for f in "${LOCAL_FILES[@]}"; do
    REMOTE_FILE="${TESTDIR_REMOTE}/${f#"${TESTDIR_LOCAL}"/}"
    echo -ne "Checking with stat the uploaded ${REMOTE_FILE} .. "
    alien.py stat "${REMOTE_FILE}" &> out.log || { EXITCODE="${?}"; echo "FAIL: stat exitcode ${EXITCODE} in ${THIS_TEST} (upload reported success)"; cat out.log; alienpy_clean_testdir "${TESTDIR_REMOTE}" "${TESTDIR_LOCAL}"; exit 1; }
    echo "OK"
done

# clean ci dir
alienpy_clean_testdir "${TESTDIR_REMOTE}" "${TESTDIR_LOCAL}"
clean_logs
exit 0
