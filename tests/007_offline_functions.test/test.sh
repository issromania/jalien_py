#!/usr/bin/env bash

clean_logs () { rm -f log.txt out.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1

TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

# offline: no connection to JAliEn; uses the python3 (and alienpy) of the active environment
python3 ./offline_functions.py &> out.log && { clean_logs; } || { EXITCODE="${?}"; echo "Failed offline checks in ${THIS_TEST} : ${EXITCODE} failed"; cat out.log; exit ${EXITCODE}; }
