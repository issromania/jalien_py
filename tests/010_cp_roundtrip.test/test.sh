#!/usr/bin/env bash

# cp round trip on a self created test dir in the user home, with check of the content (md5) of every downloaded file:
# upload of a dir, download of a file / dir content (src/) / dir itself (src without /),
# skip of a valid existing destination, replacement of a destination with other size,
# -f md5 check of a corrupted download and of a changed upload source,
# usage errors (exitcode 64) and invalid -exclude_re (exitcode 22)

clean_logs () { rm -rf xrdlog_*.txt xrdlog.txt log.txt out.log ci_cp_roundtrip &> /dev/null ; }
clean_logs

export XRD_LOGLEVEL='Dump' XRD_LOGFILE=xrdlog.txt ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_CWD_RESTORE=1 ALIENPY_NO_HISTORY=1
TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

alien.py version 2>&1 | grep -q '^XRootD version: Not Found!' && { echo "XRootD python module not found, cp cannot work; skip ${THIS_TEST}"; exit 0; }

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

NOW="$(date +%Y%m%d_%H%M%S)"
R="${ALIEN_HOME}alienpy_ci_cp_roundtrip_${NOW}_$$"  # home already includes slash at the end
L="ci_cp_roundtrip"
SPECS="@disk:2,ALICE::CERN::EOS"  # as in 005: 2 + CERN for the safety of the test

cleanup () { alien.py rm -rf "${R}" &> /dev/null; }  # does not matter if missing
trap cleanup EXIT

fail () { echo "FAIL in ${THIS_TEST} :: ${1}"; cat out.log; exit 1; }

# run_rc <command...> : run with output in out.log, set RC
run_rc () { "$@" &> out.log; RC="${?}"; }

# expect_rc <expected exitcode> <description> <command...>
expect_rc () { local exp="${1}" desc="${2}"; shift 2; run_rc "$@"; [[ "${RC}" == "${exp}" ]] || fail "${desc}: expected exitcode ${exp} got ${RC}"; }

md5_of () { md5sum "${1}" | cut -d' ' -f1; }

# same_content <description> <file1> <file2>
same_content () { [[ -f "${3}" && "$(md5_of "${2}")" == "$(md5_of "${3}")" ]] || fail "${1}: ${3} missing or content different from ${2}"; }

# change one byte in the middle of a file (same size)
flip_byte () { python3 -c 'import sys; f = open(sys.argv[1], "r+b"); f.seek(100); b = f.read(1); f.seek(100); f.write(bytes([b[0] ^ 0xFF])); f.close()' "${1}"; }

# local source files
mkdir -p "${L}/src/sub"
head -c $(( 1024 * 1024 + 13 )) /dev/urandom > "${L}/src/rt.bin"
printf 'alienpy ci test %s\n' "${NOW}" > "${L}/src/sub/small.txt"
touch -d '2001-01-01 00:00:00' "${L}/src/rt.bin" "${L}/src/sub/small.txt"  # sources older than the uploaded lfns

# usage errors, before any transfer
expect_rc 64 "cp -T not a number" alien.py cp -T x "file:${L}/src/" "${R}/"
expect_rc 64 "cp -parent not a number" alien.py cp -parent x "file:${L}/src/" "${R}/"
expect_rc 64 "cp -rmprefix not a number" alien.py cp -rmprefix x "file:${L}/src/" "${R}/"
expect_rc 22 "cp invalid -exclude_re" alien.py cp -exclude_re 'a(' "file:${L}/src/" "${R}/"

# upload of the dir content
export XRD_LOGFILE=xrdlog_upload.txt
expect_rc 0 "upload of dir" alien.py cp "file:${L}/src/" "${R}/${SPECS}"

# upload again: destinations valid, nothing to do
expect_rc 0 "upload again" alien.py cp "file:${L}/src/" "${R}/"
grep -qF 'No copy jobs to be done!' out.log || fail "upload again: valid destinations were not skipped"

export XRD_LOGFILE=xrdlog_download.txt
# download of a file in a dir
expect_rc 0 "download of file" alien.py cp "${R}/rt.bin" "file:${L}/dl_file/"
same_content "download of file" "${L}/src/rt.bin" "${L}/dl_file/rt.bin"

# download of the dir content (source with /)
expect_rc 0 "download of dir content" alien.py cp "${R}/" "file:${L}/dl_content/"
same_content "download of dir content" "${L}/src/rt.bin" "${L}/dl_content/rt.bin"
same_content "download of dir content" "${L}/src/sub/small.txt" "${L}/dl_content/sub/small.txt"

# download of the dir itself (source without /)
expect_rc 0 "download of dir" alien.py cp "${R}/sub" "file:${L}/dl_dir/"
same_content "download of dir" "${L}/src/sub/small.txt" "${L}/dl_dir/sub/small.txt"

# download again: destination valid, nothing to do
expect_rc 0 "download again" alien.py cp "${R}/rt.bin" "file:${L}/dl_file/"
grep -qF 'No copy jobs to be done!' out.log || fail "download again: valid destination was not skipped"

# destination with other size: downloaded again
head -c 10 /dev/urandom > "${L}/dl_file/rt.bin"
expect_rc 0 "download over different size" alien.py cp "${R}/rt.bin" "file:${L}/dl_file/"
same_content "download over different size" "${L}/src/rt.bin" "${L}/dl_file/rt.bin"

# destination with same size and other content: -f checks the md5 and downloads again
flip_byte "${L}/dl_file/rt.bin"
expect_rc 0 "download -f over corrupted" alien.py cp -f "${R}/rt.bin" "file:${L}/dl_file/"
same_content "download -f over corrupted" "${L}/src/rt.bin" "${L}/dl_file/rt.bin"

export XRD_LOGFILE=xrdlog_upload2.txt
# source changed with other size and old mtime: uploaded again (without -f)
printf 'alienpy ci test %s changed size\n' "${NOW}" > "${L}/src/sub/small.txt"
touch -d '2001-01-01 00:00:00' "${L}/src/sub/small.txt"
expect_rc 0 "upload of changed size source" alien.py cp "file:${L}/src/sub/small.txt" "${R}/sub/small.txt${SPECS}"
expect_rc 0 "download after upload of changed size" alien.py cp "${R}/sub/small.txt" "file:${L}/dl_small/"
same_content "upload of changed size source" "${L}/src/sub/small.txt" "${L}/dl_small/small.txt"

# source changed with same size and old mtime: -f checks the md5 and uploads again
flip_byte "${L}/src/rt.bin"
touch -d '2001-01-01 00:00:00' "${L}/src/rt.bin"
expect_rc 0 "upload -f of changed source" alien.py cp -f "file:${L}/src/rt.bin" "${R}/rt.bin${SPECS}"
expect_rc 0 "download after upload -f" alien.py cp -f "${R}/rt.bin" "file:${L}/dl_file/"
same_content "upload -f of changed source" "${L}/src/rt.bin" "${L}/dl_file/rt.bin"

expect_rc 0 "rm -rf of test dir" alien.py rm -rf "${R}"
trap - EXIT
clean_logs
exit 0
