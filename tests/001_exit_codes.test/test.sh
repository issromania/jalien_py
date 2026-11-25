#!/usr/bin/env bash

clean_logs () { rm -f log.txt output.txt &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1

echo "Trying ls .."
alien.py ls &>> output.txt || { REZ="${?}"; echo "ls:: expected exitcode 0 but got ${REZ}"; exit "${REZ}"; }

echo "Trying ls on not existing directory .."
alien.py ls /doesnotexist &>> output.txt && { REZ="${?}"; echo "ls invalid dir:: expected exitcode !=0 but got ${REZ}"; exit 1; }

TESTDIR="test_$(date +%s)"
echo "Trying mkdir .."
alien.py mkdir "${TESTDIR}" &>> output.txt || { REZ="${?}"; echo "mkdir:: expected exitcode 0 but got ${REZ}"; exit "${REZ}"; }

echo "Trying rm -rf .."
alien.py rm -rf "${TESTDIR}" &>> output.txt || { REZ="${?}"; echo "rm -rf:: expected exitcode 0 but got ${REZ}"; exit "${REZ}"; }

echo "Trying mkdir in an not permitted directory .."
alien.py mkdir "/alice/cern.ch/${TESTDIR}" &>> output.txt && { REZ="${?}"; echo "mkdir invalid dir:: expected exitcode !=0 but got ${REZ}"; exit 1; }

echo "Trying stat .."
alien.py "stat /alice/cern.ch/user/a/admin/referenceData" &>> output.txt || { REZ="${?}"; echo "stat reference dir:: expected exitcode 0 but got ${REZ}"; exit "${REZ}"; }

echo "Trying stat of invalid directory .."
alien.py "stat /fail/no/valid" &>> output.txt && { REZ="${?}"; echo "stat invalid dir:: expected exitcode !=0 but got ${REZ}"; exit 1; }

clean_logs
exit 0
