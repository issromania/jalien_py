#!/usr/bin/env bash

# token-init with a present and valid token: kept (no re-creation), -q/-quiet, token given as env content, token-destroy;token-init,
# token arguments when the user certificate is not usable; the token files of the user are never removed or re-created by this test
# the token of the environment is used: JALIEN_TOKEN_{CERT,KEY} (file names or content) or the default token files;
# no user certificate is needed if the token is valid (CI tests have only a token)

clean_logs () { rm -f log.txt out.log err.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_HISTORY=1  # do not read/write the user history

TEST_SCRIPT="$(realpath "${0}")"
THIS_TEST="$(basename "$(dirname "${TEST_SCRIPT}")")/$(basename "${TEST_SCRIPT}")"

LAST_CMD=""
RC=""
# fail <check> <expected> : report the check, the command run, what was expected, what was got
fail () {
echo "FAIL in ${THIS_TEST}"
echo "  check    : ${1}"
echo "  command  : ${LAST_CMD}"
echo "  expected : ${2}"
echo "  exitcode : ${RC}"
echo "  stdout   :"
sed 's/^/    | /' out.log
echo "  stderr   :"
sed 's/^/    | /' err.log
exit 1
}

# run_rc <command...> : run with stdout in out.log and stderr in err.log, set RC; the command is kept for the failure report
run_rc () { LAST_CMD="$*"; "$@" > out.log 2> err.log; RC="${?}"; }

# expect_ok <check> <command...>
expect_ok () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}" "exitcode 0"; }

# expect_fail <check> <command...>
expect_fail () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" != "0" ]] || fail "${desc}" "exitcode != 0"; }

# expect_line <check> <line> : the stdout of the last command has the exact line
expect_line () { grep -qxF "${2}" out.log || fail "${1}" "the stdout has the line >${2}<"; }

# expect_no_stdout <check> : the last command printed nothing on stdout
expect_no_stdout () { [[ -s out.log ]] && fail "${1}" "nothing on stdout"; return 0; }

# expect_err <check> <text> : the stderr of the last command contains the text
expect_err () { grep -qF "${2}" err.log || fail "${1}" "the stderr contains >${2}<"; }

PRESENT='Token present; use token-destroy to recreate the token'
PRESENT_ENV='Token is present in environment; unset JALIEN_TOKEN_CERT/JALIEN_TOKEN_KEY to (re)create the token with user certificates'
TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "${TMPDIR}/alienpy_ci_token_XXXXXX")" || { echo "Could not create a temporary directory in ${THIS_TEST}"; exit 1; }
trap 'rm -rf "${WORKDIR}" &> /dev/null' EXIT

# a valid token is needed: it is created only if missing or not valid (that needs a user certificate)
expect_ok "token-init (prerequisite: a valid token)" alien.py token-init

# token_file <env value> <default file> <file for the content> : the file of the token cert/key; the env content is saved in a file of WORKDIR
token_file () {
if [[ "${1}" == -----BEGIN* ]]; then
    (umask 077; printf '%s\n' "${1}" > "${3}")
    echo "${3}"
elif [[ -n "${1}" ]]; then
    echo "${1}"
else
    echo "${2}"
fi
}
FILECERT="$(token_file "${JALIEN_TOKEN_CERT}" "${TMPDIR}/tokencert_$(id -u).pem" "${WORKDIR}/tokencert.pem")"
FILEKEY="$(token_file "${JALIEN_TOKEN_KEY}" "${TMPDIR}/tokenkey_$(id -u).pem" "${WORKDIR}/tokenkey.pem")"
[[ -f "${FILECERT}" && -f "${FILEKEY}" ]] || fail "token-init (prerequisite: a valid token)" "the token files ${FILECERT} ${FILEKEY}"

# token given as file names
export JALIEN_TOKEN_CERT="${FILECERT}"
export JALIEN_TOKEN_KEY="${FILEKEY}"

expect_ok "token-init with a valid token" alien.py token-init
expect_line "token-init with a valid token" "${PRESENT}"

expect_ok "token-init -q with a valid token" alien.py token-init -q
expect_no_stdout "token-init -q with a valid token"

expect_ok "token-init -quiet with a valid token" alien.py token-init -quiet
expect_no_stdout "token-init -quiet with a valid token"

expect_ok "token-init with token arguments and no usable user certificate" env X509_USER_CERT=/nonexistent X509_USER_KEY=/nonexistent alien.py token-init -v 1
expect_err "token-init with token arguments and no usable user certificate" "WARNING: the token was not re-created"

# token given as content of the env variables
export JALIEN_TOKEN_CERT="$(< "${FILECERT}")"
export JALIEN_TOKEN_KEY="$(< "${FILEKEY}")"

expect_ok "token-init with the token as env content" alien.py token-init
expect_line "token-init with the token as env content" "${PRESENT_ENV}"

expect_ok "token-init -q with the token as env content" alien.py token-init -q
expect_no_stdout "token-init -q with the token as env content"

expect_fail "token-destroy with the token as env content" alien.py token-destroy

expect_ok "token-destroy;token-init with the token as env content" alien.py "token-destroy;token-init"
expect_line "token-destroy;token-init with the token as env content" "${PRESENT_ENV}"

expect_ok "token-init with token arguments and the token as env content" alien.py token-init -v 1
expect_err "token-init with token arguments and the token as env content" "it is not re-created"

[[ -f "${FILECERT}" && -f "${FILEKEY}" ]] || fail "token files kept" "the token files ${FILECERT} ${FILEKEY}"

clean_logs
exit 0
