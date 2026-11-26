#!/usr/bin/env bash

# cert-info, token-info as validity checks: exitcode, -q/-quiet (nothing on stdout)
# certkey-match, tokenkey-match: only the match is checked, a warning for a not valid certificate
# offline (no connection): self signed certificates are created by this test (valid, expired, less than 10 min left, a not matching key)
# the certificates and tokens of the user are not used

clean_logs () { rm -f log.txt out.log err.log &> /dev/null; }

clean_logs
export ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE="$(pwd)/log.txt" ALIENPY_DEBUG_APPEND=1

TEST_SCRIPT="$(realpath "${0}")"
THIS_TEST="$(basename "$(dirname "${TEST_SCRIPT}")")/$(basename "${TEST_SCRIPT}")"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/alienpy_ci_certs_XXXXXX")" || { echo "Could not create a temporary directory in ${THIS_TEST}"; exit 1; }
cleanup () { rm -rf "${WORKDIR}" &> /dev/null; }
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
echo "  stdout   :"
sed 's/^/    | /' out.log
echo "  stderr   :"
sed 's/^/    | /' err.log
exit 1
}

# run_rc <command...> : run with stdout in out.log and stderr in err.log, set RC; the command is kept for the failure report
run_rc () { LAST_CMD="$*"; "$@" > out.log 2> err.log; RC="${?}"; }

# expect_ok <check> <command...> : exitcode 0 and something on stdout
expect_ok () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}" "exitcode 0"; [[ -s out.log ]] || fail "${desc}" "the information on stdout"; }

# expect_ok_quiet <check> <command...> : exitcode 0 and nothing on stdout
expect_ok_quiet () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}" "exitcode 0"; [[ -s out.log ]] && fail "${desc}" "nothing on stdout"; return 0; }

# expect_ok_warn <check> <command...> : exitcode 0, nothing on stdout (used with -q) and a warning on stderr
expect_ok_warn () { expect_ok_quiet "$@"; grep -qF "WARNING:" err.log || fail "${1}" "a warning on stderr"; }

# expect_fail <check> <command...> : exitcode != 0 and nothing on stdout
expect_fail () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" != "0" ]] || fail "${desc}" "exitcode != 0"; [[ -s out.log ]] && fail "${desc}" "nothing on stdout"; return 0; }

# certificates and keys: ok (1 day), exp (expired), short (5 min left), other (another key)
LAST_CMD="python3 (cryptography): create the test certificates in ${WORKDIR}"
python3 - "${WORKDIR}" > out.log 2> err.log <<'PYEOF'
import datetime, os, sys
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
now = datetime.datetime.now(datetime.timezone.utc)
d = datetime.timedelta
for name, nb, na in (('ok', now - d(hours=1), now + d(days=1)), ('exp', now - d(days=2), now - d(days=1)),
                     ('short', now - d(hours=1), now + d(minutes=5)), ('other', now - d(hours=1), now + d(days=1))):
    k = rsa.generate_private_key(public_exponent = 65537, key_size = 2048)
    n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f'alienpy test {name}')])
    c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(nb).not_valid_after(na).sign(k, hashes.SHA256()))
    with open(os.path.join(sys.argv[1], f'{name}cert.pem'), 'wb') as f: f.write(c.public_bytes(serialization.Encoding.PEM))
    with open(os.open(os.path.join(sys.argv[1], f'{name}key.pem'), os.O_WRONLY | os.O_CREAT, 0o600), 'wb') as f:
        f.write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
PYEOF
RC="${?}"
[[ "${RC}" == "0" ]] || fail "create the test certificates" "exitcode 0"

W="${WORKDIR}"
export TMPDIR="${WORKDIR}"  # the temporary copies of the env content tokens are made here
unset JALIEN_TOKEN_CERT JALIEN_TOKEN_KEY

for q in -q -quiet; do
    expect_ok       "cert-info, valid certificate"                  env X509_USER_CERT="${W}/okcert.pem" X509_USER_KEY="${W}/okkey.pem" alien.py cert-info
    expect_ok_quiet "cert-info ${q}, valid certificate"             env X509_USER_CERT="${W}/okcert.pem" X509_USER_KEY="${W}/okkey.pem" alien.py cert-info "${q}"
    expect_fail     "cert-info ${q}, expired certificate"           env X509_USER_CERT="${W}/expcert.pem" X509_USER_KEY="${W}/expkey.pem" alien.py cert-info "${q}"
    expect_fail     "cert-info ${q}, less than 10 min left"         env X509_USER_CERT="${W}/shortcert.pem" X509_USER_KEY="${W}/shortkey.pem" alien.py cert-info "${q}"
    expect_fail     "cert-info ${q}, missing certificate"           env X509_USER_CERT="${W}/nonexistent.pem" X509_USER_KEY="${W}/nonexistent.pem" alien.py cert-info "${q}"
    expect_ok       "certkey-match, valid certificate"              env X509_USER_CERT="${W}/okcert.pem" X509_USER_KEY="${W}/okkey.pem" alien.py certkey-match
    expect_ok_quiet "certkey-match ${q}, valid certificate"         env X509_USER_CERT="${W}/okcert.pem" X509_USER_KEY="${W}/okkey.pem" alien.py certkey-match "${q}"
    expect_ok_warn  "certkey-match ${q}, expired certificate"       env X509_USER_CERT="${W}/expcert.pem" X509_USER_KEY="${W}/expkey.pem" alien.py certkey-match "${q}"
    expect_fail     "certkey-match ${q}, key does not match"        env X509_USER_CERT="${W}/okcert.pem" X509_USER_KEY="${W}/otherkey.pem" alien.py certkey-match "${q}"

    expect_ok       "token-info, valid token file"                  env JALIEN_TOKEN_CERT="${W}/okcert.pem" JALIEN_TOKEN_KEY="${W}/okkey.pem" alien.py token-info
    expect_ok_quiet "token-info ${q}, valid token file"             env JALIEN_TOKEN_CERT="${W}/okcert.pem" JALIEN_TOKEN_KEY="${W}/okkey.pem" alien.py token-info "${q}"
    expect_fail     "token-info ${q}, expired token file"           env JALIEN_TOKEN_CERT="${W}/expcert.pem" JALIEN_TOKEN_KEY="${W}/expkey.pem" alien.py token-info "${q}"
    expect_fail     "token-info ${q}, missing token file"           env JALIEN_TOKEN_CERT="${W}/nonexistent.pem" JALIEN_TOKEN_KEY="${W}/nonexistent.pem" alien.py token-info "${q}"
    expect_ok_quiet "token-info ${q}, valid token as env content"   env JALIEN_TOKEN_CERT="$(< "${W}/okcert.pem")" JALIEN_TOKEN_KEY="$(< "${W}/okkey.pem")" alien.py token-info "${q}"
    expect_fail     "token-info ${q}, expired token as env content" env JALIEN_TOKEN_CERT="$(< "${W}/expcert.pem")" JALIEN_TOKEN_KEY="$(< "${W}/expkey.pem")" alien.py token-info "${q}"
    grep -qF -- "-----BEGIN CERTIFICATE-----" err.log && fail "token-info ${q}, expired token as env content" "the reason for the temporary copy, not the content used as file name"
    expect_ok_quiet "tokenkey-match ${q}, valid token file"         env JALIEN_TOKEN_CERT="${W}/okcert.pem" JALIEN_TOKEN_KEY="${W}/okkey.pem" alien.py tokenkey-match "${q}"
    expect_ok_warn  "tokenkey-match ${q}, expired token file"       env JALIEN_TOKEN_CERT="${W}/expcert.pem" JALIEN_TOKEN_KEY="${W}/expkey.pem" alien.py tokenkey-match "${q}"
    expect_fail     "tokenkey-match ${q}, key does not match"       env JALIEN_TOKEN_CERT="${W}/okcert.pem" JALIEN_TOKEN_KEY="${W}/otherkey.pem" alien.py tokenkey-match "${q}"
    expect_ok_warn  "tokenkey-match ${q}, expired token as env content" env JALIEN_TOKEN_CERT="$(< "${W}/expcert.pem")" JALIEN_TOKEN_KEY="$(< "${W}/expkey.pem")" alien.py tokenkey-match "${q}"
    grep -qF -- "-----BEGIN CERTIFICATE-----" err.log && fail "tokenkey-match ${q}, expired token as env content" "the reason for the temporary copy, not the content used as file name"
done

LAST_CMD="ls ${WORKDIR}/tokencert_* ${WORKDIR}/tokenkey_*"
compgen -G "${WORKDIR}/token*_*.pem" > out.log && fail "temporary copies of the env content tokens removed at exit" "no ${WORKDIR}/token*_*.pem file"

clean_logs
exit 0
