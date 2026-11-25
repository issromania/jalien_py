#!/usr/bin/env bash

clean_logs () { rm -f log.txt out.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1

TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

# offline: no connection to JAliEn; uses the python3 (and alienpy) of the active environment
# each group of checks is printed, each failed check with got/expected; the output is also kept in out.log
python3 ./offline_functions.py 2>&1 | tee out.log
EXITCODE="${PIPESTATUS[0]}"
[[ "${EXITCODE}" == "0" ]] && { clean_logs; } || { echo "Failed offline checks in ${THIS_TEST} : ${EXITCODE} failed"; exit ${EXITCODE}; }
