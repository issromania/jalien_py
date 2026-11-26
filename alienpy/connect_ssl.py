"""alienpy:: SSL and certificate tooling"""

import datetime
import functools
import getpass
import sys
import os
import logging
import uuid
from typing import Callable
import tempfile
import ssl

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
except Exception:
    print("cryptography module could not be imported! Make sure you can do:\npython3 -c 'import cryptography'", file = sys.stderr, flush = True)
    sys.exit(1)

try:
    import OpenSSL
except Exception:
    print("OpenSSL module could not be loaded", file = sys.stderr, flush = True)
    sys.exit(1)

##   GLOBALS
from .setup_logging import DEBUG, DEBUG_FILE, print_err
from .data_structs import CertsInfo, RET, SSLctxException
from .global_vars import AlienSessionInfo, COLORS, TOKENCERT_NAME, TOKENKEY_NAME, USERCERT_NAME, USERKEY_NAME, USER_HOME, I_AM_GRID_JOB, get_certs_names
from .tools_nowb import PrintColor, path_readable


def is_x509dir_valid(x509dir: str = '') -> bool:
    """Determine validity of X509_CERT_DIR"""
    path = os.path.abspath(os.path.expanduser(x509dir))
    if not os.path.isdir(path): return False
    pem_files_in_dir = [f for f in os.listdir(path) if os.path.isfile(f'{path}/{f}') and f.endswith('.pem')]
    return len(pem_files_in_dir) > 0


def get_ca_path() -> str:
    """Return either the CA path or file, priority given to X509_CERT_FILE and X509_CERT_DIR"""
    # Fast path, when some local CAs are explicitly requested - ALIENPY_USE_LOCAL_CAS case
    local_ca_certs_dir = f'{USER_HOME}/.globus/certificates'
    use_local_cas_dir = os.getenv('ALIENPY_USE_LOCAL_CAS', default = '')

    if use_local_cas_dir:  # explicit requested by env var, so top priority
        use_local_cas_dir = os.path.abspath(os.path.expanduser(use_local_cas_dir))
        # if ALIENPY_USE_LOCAL_CAS is set to a directory that is present we can assume that is the CAs location
        if os.path.isdir(use_local_cas_dir):
            local_ca_certs_dir = use_local_cas_dir

        # This is location of ALIEN-CAS repository download
        if is_x509dir_valid(local_ca_certs_dir) and os.path.isfile(f'{local_ca_certs_dir}/CERN-GridCA.pem'):
            logging.debug(f'CApath::LOCAL_CAS:: requested and set to {local_ca_certs_dir}')
            os.environ['X509_CERT_DIR'] = local_ca_certs_dir
            return local_ca_certs_dir

        msg = f'usage of local CAs was requested by presence of ALIENPY_USE_LOCAL_CAS, but no certificates found in {local_ca_certs_dir}!!!\nrun: "alien.py getCAcerts" first'
        print_err(msg)
        logging.error(msg)
        # do not exit, is fine to have empty CA path, to allow non-wb functions to work, including getCAcerts

    # Fast path 2, when some local CAs are explicitly requested - X509_CERT_DIR case
    x509dir = os.getenv('X509_CERT_DIR', default = '')
    if x509dir:
        x509dir = os.path.abspath(os.path.expanduser(x509dir))
        if is_x509dir_valid(x509dir):
            logging.debug(f'CApath::X509_CERT_DIR:: requested and set to {x509dir}')
            return x509dir

        msg = f'X509_CERT_DIR set by environment is invalid! Check content of {x509dir}'
        print_err(msg)
        logging.error(msg)
        # do not exit, is fine to have empty CA path, to allow non-wb functions to work, including getCAcerts

    # X509_CERT_FILE case
    x509file = os.getenv('X509_CERT_FILE', default = '')
    if x509file:
        x509file = os.path.abspath(os.path.expanduser(x509file))
        if os.path.isfile(x509file):
            logging.debug(f'CApath::X509_CERT_FILE:: requested and set to {x509file}')
            return x509file

        msg = f'X509_CERT_FILE set by environment but is missing! Check existence of {x509file}'
        print_err(msg)
        logging.error(msg)
        # do not exit, is fine to have empty CA path, to allow non-wb functions to work, including getCAcerts

    system_ca_path = '/etc/grid-security/certificates'
    alice_cvmfs_ca_path_lx = '/cvmfs/alice.cern.ch/etc/grid-security/certificates'
    alice_cvmfs_ca_path_macos = f'/Users/Shared{alice_cvmfs_ca_path_lx}'

    capath_default = ''

    if is_x509dir_valid(alice_cvmfs_ca_path_lx):
        capath_default = alice_cvmfs_ca_path_lx

    if not capath_default and is_x509dir_valid(alice_cvmfs_ca_path_macos):
        capath_default = alice_cvmfs_ca_path_macos

    if not capath_default and is_x509dir_valid(system_ca_path):
        capath_default = system_ca_path

    if not capath_default:
        msg = "No CA locations found!!! Connection will not be possible!! Either set X509_CERT_DIR to a known good CApath or run:\nalien.py getCAcerts\nto download CAs to ~/.globus/certificates"
        print_err(msg)
        logging.error(msg)
        # do not exit, is fine to have empty CA path, to allow non-wb functions to work, including getCAcerts

    if not capath_default: capath_default = 'empty_notvalid'
    os.environ['X509_CERT_DIR'] = capath_default
    logging.debug('CApath:: found and set to %s', capath_default)
    return capath_default


@functools.lru_cache(maxsize = None)
def ca_path() -> str:
    """CA location, looked up at the first use (connection or certificate verification), so that the commands without connection (e.g. getCAcerts) do not report missing CAs"""
    return get_ca_path()


def cert_invalid_reason(fname: str) -> str:
    """Return the reason for which the certificate file is not usable, empty string if valid; less than 10 min of validity is not valid"""
    if not fname: return 'no certificate file name'
    try:
        with open(fname, "rb") as f: cert_bytes = f.read()
    except FileNotFoundError:
        return f'certificate file {fname} not found'
    except OSError as e:
        return f'certificate file {fname} cannot be read: {e.strerror}'
    if not cert_bytes: return f'certificate file {fname} is empty'

    try:
        x509cert = x509.load_pem_x509_certificate(cert_bytes)
    except Exception as e:
        return f'certificate file {fname} is not a valid PEM certificate: {e}'

    time_remaining = int(x509cert.not_valid_after_utc.timestamp()) - int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    if time_remaining < 600:
        return f'certificate {fname} is expired (not valid after {x509cert.not_valid_after_utc:%Y-%m-%d %H:%M:%S} UTC, or less than 10 min left)'
    return ''


def IsValidCert(fname: str) -> bool:
    """Check if the certificate file (argument) is present and valid. It will return false also for less than 10 min of validity"""
    if not fname: return False
    reason = cert_invalid_reason(fname)
    if not reason: return True
    if not os.path.exists(fname):  # normal for the token before its first creation and for the usercert of GRID jobs
        if not I_AM_GRID_JOB: logging.info('IsValidCert:: %s', reason)
    else:
        if DEBUG: print_err(f'IsValidCert:: {reason}')
        logging.error('IsValidCert:: %s', reason)
    return False


def cred_invalid_reason(cert: str, key: str) -> str:
    """Return the reason for which the cert/key pair cannot be used, empty string if no problem was found"""
    reason = cert_invalid_reason(cert)
    if not reason and not path_readable(key): reason = f'key file {key} not found or not readable'
    return reason


def get_valid_certs() -> tuple:
    """Return valid names for user certificate or None"""
    if 'AlienSessionInfo' in globals() and AlienSessionInfo['verified_cert']: return AlienSessionInfo['user_cert'], AlienSessionInfo['user_key']

    FOUND = path_readable(USERCERT_NAME) and path_readable(USERKEY_NAME)
    if not FOUND:
        msg = None
        if I_AM_GRID_JOB:
            if DEBUG: msg = 'GRID jobs do not use usercert files, usercert missing is fine.'
        else:
            msg = f'User certificate files NOT FOUND or NOT accessible!!! Connection might be not be possible!!\nCheck content of {os.path.expanduser("~")}/.globus'
        if msg: logging.error(msg)
        return (None, None)

    INVALID = not IsValidCert(USERCERT_NAME)
    if INVALID:
        msg = f'Invalid/expired user certificate!! Check the content of {USERCERT_NAME}'
        logging.error(msg)
        return (None, None)

    if 'AlienSessionInfo' in globals():
        AlienSessionInfo['verified_cert'] = True  # This means that we already checked
        AlienSessionInfo['user_cert'] = USERCERT_NAME
        AlienSessionInfo['user_key'] = USERKEY_NAME
    return (USERCERT_NAME, USERKEY_NAME)


PEM_CERT_BEGIN = '-----BEGIN CERTIFICATE-----'
PEM_KEY_BEGIN = ('-----BEGIN RSA PRIVATE KEY-----', '-----BEGIN PRIVATE KEY-----', '-----BEGIN EC PRIVATE KEY-----')  # PKCS#1, PKCS#8, SEC1


def token_env_content() -> bool:
    """True if JALIEN_TOKEN_CERT or JALIEN_TOKEN_KEY hold the PEM content (not a file name): such a token cannot be written, re-created or destroyed"""
    certs_info = get_certs_names()
    return (certs_info.token_cert.startswith(PEM_CERT_BEGIN) and not path_readable(certs_info.token_cert)) or \
           (certs_info.token_key.startswith(PEM_KEY_BEGIN) and not path_readable(certs_info.token_key))


def get_valid_tokens() -> tuple:
    """Get the token filenames, including the temporary ones used as env variables"""
    global TOKENCERT_NAME, TOKENKEY_NAME
    cert_suffix = None
    ENV_TOKENCERT = ENV_TOKENKEY = None
    if not path_readable(TOKENCERT_NAME) and TOKENCERT_NAME.startswith(PEM_CERT_BEGIN):  # and is not a file
        cert_suffix = f'_{str(os.getuid())}_{str(uuid.uuid4())}.pem'
        temp_cert = tempfile.NamedTemporaryFile(prefix = 'tokencert_', suffix = cert_suffix, delete = False)
        temp_cert.write(TOKENCERT_NAME.encode(encoding = "ascii", errors = "replace"))
        temp_cert.close()
        TOKENCERT_NAME = temp_cert.name  # temp file was created, let's give the filename to tokencert
        ENV_TOKENCERT = True
    if not path_readable(TOKENKEY_NAME) and TOKENKEY_NAME.startswith(PEM_KEY_BEGIN):  # and is not a file
        temp_key = tempfile.NamedTemporaryFile(prefix = 'tokenkey_', suffix = cert_suffix, delete = False)
        temp_key.write(TOKENKEY_NAME.encode(encoding = "ascii", errors = "replace"))
        temp_key.close()
        TOKENKEY_NAME = temp_key.name  # temp file was created, let's give the filename to tokenkey
        ENV_TOKENKEY = True

    if IsValidCert(TOKENCERT_NAME) and path_readable(TOKENKEY_NAME):
        if 'AlienSessionInfo' in globals():
            AlienSessionInfo['verified_token'] = True
            AlienSessionInfo['token_cert'] = TOKENCERT_NAME
            AlienSessionInfo['token_key'] = TOKENKEY_NAME
            if ENV_TOKENCERT: AlienSessionInfo['templist'].append(TOKENCERT_NAME)  # type: ignore[attr-defined]
            if ENV_TOKENKEY: AlienSessionInfo['templist'].append(TOKENKEY_NAME)  # type: ignore[attr-defined]
        return (TOKENCERT_NAME, TOKENKEY_NAME)
    return (None, None)


def renewCredFilesInfo() -> CertsInfo:
    """Recheck and refresh the values of valid credential definitions"""
    token_cert, token_key = get_valid_tokens()
    user_cert, user_key = get_valid_certs()
    return CertsInfo(user_cert, user_key, token_cert, token_key)


def cert_key_load_reason(e: Exception, cert: str, key: str) -> str:
    """Return a human readable reason for which SSLContext.load_cert_chain(cert, key) failed with exception e; it never prompts for a passphrase"""
    ssl_reason = getattr(e, 'reason', None) if isinstance(e, ssl.SSLError) else None
    if ssl_reason == 'KEY_VALUES_MISMATCH':  # authoritative; also means that a passphrase (if any) was accepted
        return f'the private key {key} does NOT match the certificate {cert}'
    if ssl_reason and (ssl_reason.endswith('_TOO_SMALL') or ssl_reason.endswith('_TOO_WEAK')):
        return f'OpenSSL security level of this system rejects the certificate (key size or signature digest too weak): {e}'

    try:
        with open(cert, 'rb') as f: cert_bytes = f.read()
    except OSError as err:
        return f'certificate file {cert} cannot be read: {err.strerror}'
    try:
        x509cert = x509.load_pem_x509_certificate(cert_bytes)
    except Exception as err:
        return f'certificate file {cert} is not a valid PEM certificate: {err}'

    try:
        with open(key, 'rb') as f: key_bytes = f.read()
    except OSError as err:
        return f'key file {key} cannot be read: {err.strerror}'
    try:
        private_key = serialization.load_pem_private_key(key_bytes, password = None)
    except TypeError:  # cryptography: "Password was not given but private key is encrypted"
        return f'the private key {key} is passphrase protected and the passphrase was wrong/empty or could not be read (no terminal for the prompt)'
    except Exception as err:
        return f'key file {key} is not a valid/supported PEM private key: {err}'

    pub_der = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if x509cert.public_key().public_bytes(*pub_der) != private_key.public_key().public_bytes(*pub_der):
        return f'the private key {key} does NOT match the certificate {cert}'

    return f'no problem found in the files, OpenSSL error is: {type(e).__name__}: {e}'


def key_passphrase_prompt(key: str) -> Callable[[], bytes]:
    """Password callback for load_cert_chain (called only for an encrypted key): prompt on the terminal, as OpenSSL does when no callback is given.
    Python 3.15 always installs its own callback, so without this the encrypted key fails to load without any prompt.
    Without a terminal the passphrase is empty (the load fails, as with the OpenSSL prompt); stdin is never read."""
    def _prompt() -> bytes:
        if os.name != 'nt':  # getpass falls back to stdin when there is no terminal: check that the terminal is available
            try:
                with open('/dev/tty', 'rb'): pass
            except OSError:
                return b''
        return getpass.getpass(f'Enter PEM pass phrase for {key}: ').encode()
    return _prompt


def create_ssl_context(use_usercert: bool = False, user_cert: str = '', user_key: str = '', token_cert: str = '', token_key: str = '') -> ssl.SSLContext:
    """Create SSL context using either the default names for user certificate and token certificate or X509_USER_{CERT,KEY} JALIEN_TOKEN_{CERT,KEY} environment variables"""
    use_token = not (use_usercert or not token_cert)
    if not use_token:
        if AlienSessionInfo: AlienSessionInfo['use_usercert'] = True
        cert, key = user_cert, user_key
    else:
        cert, key = token_cert, token_key

    if not cert or not key:
        cred_type = 'user certificate' if use_usercert else 'user certificate or token'
        raise SSLctxException(f'no valid {cred_type} found to be used for SSL context; check the previous messages in {DEBUG_FILE}')

    cafile = capath = None
    if os.path.isfile(ca_path()):
        cafile = ca_path()
    else:
        capath = ca_path()

    if DEBUG: logging.debug('\nCert = %s\nKey = %s\nCreating SSL context .. ', cert, key)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.options |= ssl.OP_NO_SSLv3
    # INTENTIONAL: no hostname check; we connect to jbox/localhost or any other service that might not have the hostname in certificate
    ctx.check_hostname = False

    # INTENTIONAL: the server certificate is verified against the CAs only for usercert connections, not for token connections
    if not use_token:
        ctx.verify_mode = ssl.CERT_REQUIRED  # CERT_NONE, CERT_OPTIONAL, CERT_REQUIRED
        logging.info('SSL context:: Loading verify location:\n%s', ca_path())
        try:
            ctx.load_verify_locations(cafile = cafile, capath = capath)
        except Exception as e:
           logging.exception("SSL context:: Could not load verify location %s", ca_path(), stack_info = True)
           raise SSLctxException(f'CA verify location could not be loaded, check content of >>> {ca_path()} <<< : {type(e).__name__}: {e}') from e
    else:
        ctx.verify_mode = ssl.CERT_NONE  # INTENTIONAL for token connections (JAliEn central services and JBox proxy particularities)

    if DEBUG: logging.debug('SSL context:: Loading cert,key pair:\n%s\n%s', cert, key)
    try:
        ctx.load_cert_chain(certfile = cert, keyfile = key, password = key_passphrase_prompt(key))
    except Exception as e:
        reason = cert_key_load_reason(e, cert, key)
        logging.exception("SSL context:: Could not load cert/key pair:\nCert: %s\nKey: %s\nReason: %s", cert, key, reason, stack_info = True)
        raise SSLctxException(f'could not load cert/key pair (cert: {cert} ; key: {key}): {reason}') from e

    ctx.alienpy_cert = cert  # type: ignore[attr-defined]  # for the error messages of the connection
    logging.info('\n... SSL context done.')
    return ctx


def tls_cert_error_msg(e: BaseException, cert: str = '') -> str:
    """Return an explanation if the TLS connection failure e is caused by a certificate, empty string otherwise"""
    if isinstance(e, ssl.SSLCertVerificationError):
        return (f'The server certificate could not be verified: {e.verify_message}\n'
                f'Check the CA certificates (and their hash links) used for verification: {ca_path()}\n'
                'Either set X509_CERT_DIR to a directory with up-to-date IGTF CAs or run "alien.py getCAcerts" and set ALIENPY_USE_LOCAL_CAS=1')
    reason = str(getattr(e, 'reason', None) or '') if isinstance(e, ssl.SSLError) else ''
    if '_ALERT_' in reason and ('CERTIFICATE' in reason or reason.endswith('UNKNOWN_CA') or reason.endswith('ACCESS_DENIED')):
        return (f'The server rejected the client certificate {cert} ({reason})\n'
                'Check it with: alien.py cert-info ; alien.py cert-verify')
    cause = e.__cause__ or e.__context__
    if type(e).__name__ == 'InvalidMessage' and isinstance(cause, EOFError):  # websockets.exceptions.InvalidMessage, after the TLS handshake
        return (f'The server closed the connection right after the TLS handshake, without HTTP answer: most probably it rejected the client certificate {cert}\n'
                '(with TLS 1.3 the rejection is not reported to the client) Check it with: alien.py cert-info ; alien.py cert-verify')
    return ''


def make_connection_ctx(use_usercert: bool = False) -> ssl.SSLContext:
    """Create SSL context using AlienSessionInfo information; raise SSLctxException (with the reason as message) on failure"""
    # Check the content of AlienSessionInfo for values of cert and token files
    certs_info = None
    user_cert = user_key = token_cert = token_key = ''

    # the cached names are used only while the token is still valid (it can expire during a long session); otherwise re-check all
    if 'AlienSessionInfo' in globals() and AlienSessionInfo['token_cert'] and AlienSessionInfo['token_key'] and AlienSessionInfo['user_cert'] and AlienSessionInfo['user_key'] \
            and IsValidCert(AlienSessionInfo['token_cert']):
        user_cert, user_key = AlienSessionInfo['user_cert'], AlienSessionInfo['user_key']
        token_cert, token_key = AlienSessionInfo['token_cert'], AlienSessionInfo['token_key']
    else:
        certs_info = renewCredFilesInfo()
        user_cert, user_key = certs_info.user_cert, certs_info.user_key
        token_cert, token_key = certs_info.token_cert, certs_info.token_key

    # Check the presence of user certs and bailout before anything else
    # a missing or expired token is normal (a new one is created after the connection with the usercert): the usercert problem is the one to report
    # GRID jobs have only the token
    if not token_cert and not user_cert and I_AM_GRID_JOB:
        raise SSLctxException(f'no valid token found!! {cred_invalid_reason(TOKENCERT_NAME, TOKENKEY_NAME) or "unknown problem"}')
    if not user_cert and (use_usercert or not token_cert):
        raise SSLctxException(f'no valid user certificate found!! {cred_invalid_reason(USERCERT_NAME, USERKEY_NAME) or "unknown problem"}')

    return create_ssl_context(use_usercert, user_cert = user_cert, user_key = user_key, token_cert = token_cert, token_key = token_key)


def CertInfo(fname: str) -> RET:
    """Print certificate information (subject, issuer, notbefore, notafter)"""
    if not fname:
        return RET(2, '', 'No certificate filename provided!')  # ENOENT /* No such file or directory */

    cert_bytes = None
    try:
        with open(fname, "rb") as f: cert_bytes = f.read()
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(2, '', f'File >>> {fname} <<< not found/accessible!')  # ENOENT /* No such file or directory */

    if cert_bytes is None:
        msg = f'CertInfo:: {fname} read but empty!'
        logging.error(msg)
        return RET(2, '', msg)  # ENOENT /* No such file or directory */

    try:
        x509cert = x509.load_pem_x509_certificate(cert_bytes)
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(5, '', f'CertInfo::load_pem_x509_certificate:: error loading certificate >>> {fname} <<<')  # EIO /* I/O error */

    utc_time_notafter = x509cert.not_valid_after_utc.strftime("%Y-%m-%d %H:%M:%S")
    utc_time_notbefore = x509cert.not_valid_before_utc.strftime("%Y-%m-%d %H:%M:%S")

    issuer_comp_list = x509cert.issuer.rfc4514_string().split(',')
    issuer_comp_list.reverse()
    issuer = '/'.join(issuer_comp_list)

    subject_comp_list = x509cert.subject.rfc4514_string().split(',')
    subject_comp_list.reverse()
    subject = '/'.join(subject_comp_list)

    info = f'DN >>> {subject}\nISSUER >>> {issuer}\nBEGIN >>> {utc_time_notbefore}\nEXPIRE >>> {utc_time_notafter}'
    return RET(0, info)


def CertVerify(fname: str) -> RET:
    """Verify the certificate against the CA location in use (ca_path())"""
    cert_bytes = None
    try:
        with open(fname, "rb") as f: cert_bytes = f.read()
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(2, "", f"File >>> {fname} <<< not found/accesible")  # ENOENT /* No such file or directory */

    if cert_bytes is None:
        msg = f'CertVerify:: {fname} read but empty!'
        logging.error(msg)
        return RET(2, '', msg)  # ENOENT /* No such file or directory */

    try:
        x509cert = OpenSSL.crypto.load_certificate(OpenSSL.crypto.FILETYPE_PEM, cert_bytes)
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(5, "", f"Could not load certificate >>> {fname} <<<")  # EIO /* I/O error */

    x509store = OpenSSL.crypto.X509Store()
    x509store.set_flags(OpenSSL.crypto.X509StoreFlags.ALLOW_PROXY_CERTS)

    cafile = capath = None
    if os.path.isfile(ca_path()):
        cafile = ca_path()
    else:
        capath = ca_path()

    try:
        x509store.load_locations(cafile = cafile, capath = capath)
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(5, '', f'Could not load verify location >>> {ca_path()} <<< : {e}')  # EIO /* I/O error */

    store_ctx = OpenSSL.crypto.X509StoreContext(x509store, x509cert)
    try:
        store_ctx.verify_certificate()
        return RET(0, f'SSL Verification {PrintColor(COLORS.BIGreen)}successful{PrintColor(COLORS.ColorReset)} for {fname}')
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(1, '', f'SSL Verification {PrintColor(COLORS.BIRed)}failed{PrintColor(COLORS.ColorReset)} for {fname} : {e} (CA location: {ca_path()})')


def CertKeyMatch(cert_fname: str, key_fname: str) -> RET:
    """Check if Certificate and key match"""
    cert_bytes = None
    try:
        with open(cert_fname, "rb") as f: cert_bytes = f.read()
        x509cert = OpenSSL.crypto.load_certificate(OpenSSL.crypto.FILETYPE_PEM, cert_bytes)
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(5, "", f'Could not load certificate >>>{cert_fname}<<< : {e}')  # EIO /* I/O error */

    key_bytes = None
    try:
        with open(key_fname, "rb") as g: key_bytes = g.read()
        x509key = OpenSSL.crypto.load_privatekey(OpenSSL.crypto.FILETYPE_PEM, key_bytes)
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(5, "", f'Could not load key >>>{key_fname}<<< : {e or type(e).__name__}')  # EIO /* I/O error */

    # the CA certificates are not needed to check that the key belongs to the certificate
    ctx = OpenSSL.SSL.Context(OpenSSL.SSL.TLS_METHOD)  # skipcq: PTC-W6001
    ctx.use_privatekey(x509key.to_cryptography_key())  # passing pyOpenSSL PKey/X509 objects is deprecated (pyOpenSSL >= 25)
    ctx.use_certificate(x509cert.to_cryptography())

    try:
        ctx.check_privatekey()
        return RET(0, f'Cert/key {PrintColor(COLORS.BIGreen)}match{PrintColor(COLORS.ColorReset)}!')
    except OpenSSL.SSL.Error:
        return RET(42, '', f'Cert/key {PrintColor(COLORS.BIRed)}DO NOT match{PrintColor(COLORS.ColorReset)}!')
    except Exception as e:
        if DEBUG: logging.exception(e)
        return RET(1, '', 'Cert/key match :: unknown error')


# Populate information in AlienSessionInfo
_ = renewCredFilesInfo()


if __name__ == '__main__':
    print('This file should not be executed!', file = sys.stderr, flush = True)
    sys.exit(95)
