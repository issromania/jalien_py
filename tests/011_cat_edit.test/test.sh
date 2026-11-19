#!/usr/bin/env bash

# cat and edit of a small text lfn in a self created test dir in the user home:
# cat downloads a temporary copy and runs the system cat;
# edit runs $EDITOR on a temporary copy and uploads it when changed, the old content is kept as <lfn>~
# a non-interactive editor script is used

clean_logs () { rm -rf xrdlog_*.txt xrdlog.txt log.txt out.log ci_cat_edit &> /dev/null ; }
clean_logs

export XRD_LOGLEVEL='Dump' XRD_LOGFILE=xrdlog.txt ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_CWD_RESTORE=1 ALIENPY_NO_HISTORY=1
TEST_SCRIPT="$(realpath ${0})"
THIS_TEST="$(basename $(dirname ${TEST_SCRIPT}))/$(basename ${TEST_SCRIPT})"

alien.py version 2>&1 | grep -q '^XRootD version: Not Found!' && { echo "XRootD python module not found, cat/edit cannot work; skip ${THIS_TEST}"; exit 0; }

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

NOW="$(date +%Y%m%d_%H%M%S)"
R="${ALIEN_HOME}alienpy_ci_cat_edit_${NOW}_$$"  # home already includes slash at the end
L="ci_cat_edit"
SPECS="@disk:2,ALICE::CERN::EOS"  # as in 005: 2 + CERN for the safety of the test
F="${R}/edit.txt"
LINE1="alienpy ci original line ${NOW}"
LINE2="alienpy ci edited line ${NOW}"

cleanup () { alien.py rm -rf "${R}" &> /dev/null; }  # does not matter if missing
trap cleanup EXIT

fail () { echo "FAIL in ${THIS_TEST} :: ${1}"; cat out.log; exit 1; }

# run_rc <command...> : run with output in out.log, set RC
run_rc () { "$@" &> out.log; RC="${?}"; }

# expect_ok <description> <command...>
expect_ok () { local desc="${1}"; shift; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}: expected exitcode 0 got ${RC}"; }

has_line () { grep -qxF "${2}" out.log || fail "${1}: line >${2}< not found"; }
no_line () { grep -qxF "${2}" out.log && fail "${1}: line >${2}< should not be present"; return 0; }

mkdir -p "${L}"
printf '%s\n' "${LINE1}" > "${L}/edit.txt"
# non-interactive editors: the edit command runs "$EDITOR <temporary file>"
EDITOR_APPEND="$(realpath "${L}")/editor_append.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "${1}"\n' "${LINE2}" > "${EDITOR_APPEND}"
chmod +x "${EDITOR_APPEND}"

expect_ok "upload" alien.py cp "file:${L}/edit.txt" "${F}${SPECS}"

expect_ok "cat" alien.py cat "${F}"
has_line "cat" "${LINE1}"

# editor that does not change the file: no upload, no backup
expect_ok "edit without change" env EDITOR=true alien.py edit "${F}"
run_rc alien.py stat "${F}~"
[[ "${RC}" != "0" ]] || fail "edit without change: a backup ${F}~ was created"

# editor that appends a line: upload of the new content, backup of the old one
expect_ok "edit with change" env EDITOR="${EDITOR_APPEND}" alien.py edit "${F}"
grep -qF "Uploaded ${F}" out.log || fail "edit with change: upload message not found"

expect_ok "cat after edit" alien.py cat "${F}"
has_line "cat after edit" "${LINE1}"
has_line "cat after edit" "${LINE2}"

expect_ok "cat of backup" alien.py cat "${F}~"
has_line "cat of backup" "${LINE1}"
no_line "cat of backup" "${LINE2}"

expect_ok "rm -rf of test dir" alien.py rm -rf "${R}"
trap - EXIT
clean_logs
exit 0
