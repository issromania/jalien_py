#!/usr/bin/env bash

# cat and edit of a small text lfn in a self created test dir in the user home:
# cat downloads a temporary copy and runs the system cat;
# edit runs $EDITOR on a temporary copy and uploads it when changed, the old content is kept as <lfn>~
# a non-interactive editor script is used

clean_logs () { rm -rf xrdlog_*.txt xrdlog.txt log.txt out.log ci_cat_edit &> /dev/null ; }
clean_logs

export XRD_LOGLEVEL='Dump' XRD_LOGFILE=xrdlog.txt ALIENPY_DEBUG=1 ALIENPY_DEBUG_FILE=log.txt ALIENPY_DEBUG_APPEND=1
export ALIENPY_NO_CWD_RESTORE=1 ALIENPY_NO_HISTORY=1
TEST_SCRIPT="$(realpath "${0}")"
THIS_TEST="$(basename "$(dirname "${TEST_SCRIPT}")")/$(basename "${TEST_SCRIPT}")"

alien.py version 2>&1 | grep -q '^XRootD version: Not Found!' && { echo "XRootD python module not found, cat/edit cannot work; skip ${THIS_TEST}"; exit 0; }

ALIEN_HOME="$(alien.py home)"
EXITCODE="${?}"
[[ -z "${ALIEN_HOME}" ]] && { echo "Could not get ALIEN_HOME in ${THIS_TEST}"; exit "${EXITCODE}"; }

NOW="$(date +%Y%m%d_%H%M%S)"
R="${ALIEN_HOME}alienpy_ci_cat_edit_${NOW}_$$"  # home already includes slash at the end
L="ci_cat_edit"
SPECS="@disk:2,ALICE::CERN::EOS"  # as in 005: 2 + CERN for the safety of the test
F="${R}/edit.txt"
EDITOR_APPEND=""
LINE1="alienpy ci original line ${NOW}"
LINE2="alienpy ci edited line ${NOW}"

cleanup () {
alien.py rm -rf "${R}" &> /dev/null || echo "WARNING: the test dir ${R} could not be removed, remove it by hand"
[[ -n "${EDITOR_APPEND}" ]] && rm -f "${EDITOR_APPEND}"
}
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
echo "  output   :"
sed 's/^/    | /' out.log
exit 1
}

# run_rc <command...> : run with output in out.log, set RC; the command is kept for the failure report
run_rc () { LAST_CMD="$*"; "$@" &> out.log; RC="${?}"; }

# expect_ok <check> <command...>
expect_ok () { local desc="${1}"; shift; echo "Trying ${desc} .."; run_rc "$@"; [[ "${RC}" == "0" ]] || fail "${desc}" "exitcode 0"; }

# has_line / no_line <check> <line> : the output of the last command has / has not the exact line
has_line () { grep -qxF "${2}" out.log || fail "${1}" "the output has the line >${2}<"; }
no_line () { grep -qxF "${2}" out.log && fail "${1}" "the output does not have the line >${2}<"; return 0; }

echo "Test dir: ${R}"
mkdir -p "${L}"
printf '%s\n' "${LINE1}" > "${L}/edit.txt"
# non-interactive editors: the edit command runs "$EDITOR <temporary file>", split as a shell command line,
# so the editor script must be in a path without spaces (the test dir may have them): it is made in TMPDIR
EDITOR_APPEND="$(mktemp "${TMPDIR:-/tmp}/alienpy_ci_editor_XXXXXX.sh")"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "${1}"\n' "${LINE2}" > "${EDITOR_APPEND}"
chmod +x "${EDITOR_APPEND}"

expect_ok "upload of the text file edit.txt" alien.py cp "file:${L}/edit.txt" "${F}${SPECS}"

expect_ok "cat of edit.txt" alien.py cat "${F}"
has_line "cat of edit.txt shows its content" "${LINE1}"

# editor that does not change the file: no upload, no backup
expect_ok "edit with an editor that changes nothing (EDITOR=true)" env EDITOR=true alien.py edit "${F}"
echo "Trying stat of the backup edit.txt~ after an edit without change (must fail) .."
run_rc alien.py stat "${F}~"
[[ "${RC}" != "0" ]] || fail "an edit without change does not upload nor create the backup ${F}~" "exitcode != 0 (no backup)"

# editor that appends a line: upload of the new content, backup of the old one
expect_ok "edit with an editor that appends a line" env EDITOR="${EDITOR_APPEND}" alien.py edit "${F}"
grep -qF "Uploaded ${F}" out.log || fail "edit with change uploads the new content" "the output has >Uploaded ${F}<"

expect_ok "cat of edit.txt after the edit" alien.py cat "${F}"
has_line "cat after the edit shows the original line" "${LINE1}"
has_line "cat after the edit shows the appended line" "${LINE2}"

expect_ok "cat of the backup edit.txt~" alien.py cat "${F}~"
has_line "the backup has the original line" "${LINE1}"
no_line "the backup does not have the appended line" "${LINE2}"

expect_ok "rm -rf of the test dir" alien.py rm -rf "${R}"
trap - EXIT
rm -f "${EDITOR_APPEND}"
clean_logs
exit 0
