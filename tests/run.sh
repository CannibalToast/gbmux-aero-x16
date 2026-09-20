#!/bin/bash
# Verification for High security remediations (and wedge-prevention extras).
# This environment is not an AERO X16 — no ACPI/hardware is exercised.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
fail=0
pass=0

ok() { pass=$((pass + 1)); printf 'ok  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

assert_eq() {
    # assert_eq desc expected actual
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1 (expected '$2', got '$3')"
    fi
}

assert_ok() {
    if "$@"; then ok "$*"; else bad "$*"; fi
}

assert_fail() {
    if "$@"; then bad "expected fail: $*"; else ok "expected fail: $*"; fi
}

# --- syntax ---
if bash -n "$ROOT/gbmux"; then ok "bash -n gbmux"; else bad "bash -n gbmux"; fi
if bash -n "$ROOT/gbmux-setup"; then ok "bash -n gbmux-setup"; else bad "bash -n gbmux-setup"; fi
if sh -n "$ROOT/gbmux-acpower"; then ok "sh -n gbmux-acpower"; else bad "sh -n gbmux-acpower"; fi
if sh -n "$ROOT/debian/postinst"; then ok "sh -n debian/postinst"; else bad "sh -n debian/postinst"; fi
if sh -n "$ROOT/debian/prerm"; then ok "sh -n debian/prerm"; else bad "sh -n debian/prerm"; fi
if bash -n "$ROOT/tests/run.sh"; then ok "bash -n tests/run.sh"; else bad "bash -n tests/run.sh"; fi

# --- documented usage still present ---
for cmd in status mode dynamic discrete hybrid "gpu on" "gpu off" "call '<expr>'"; do
    if grep -F -q "$cmd" "$ROOT/gbmux"; then
        ok "gbmux usage mentions $cmd"
    else
        bad "gbmux usage missing $cmd"
    fi
done
if grep -q 'gbmux call' "$ROOT/README.md"; then ok "README documents gbmux call"; else bad "README dropped gbmux call"; fi
if grep -q 'KILL_ON_BATTERY="rustdesk"' "$ROOT/README.md"; then ok "README keep KILL_ON_BATTERY example"; else bad "README lost KILL_ON_BATTERY example"; fi
if grep -q '615.71.09' "$ROOT/gbmux-setup"; then ok "setup still pins 615.71.09"; else bad "setup lost pinned version"; fi

# --- usage paths (non-root; no hardware) ---
gbmux_err=$(bash "$ROOT/gbmux" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$gbmux_err" | grep -q 'needs root'; then
    ok "gbmux without root fails closed"
else
    bad "gbmux without root: rc=$rc err=$gbmux_err"
fi
setup_err=$(bash "$ROOT/gbmux-setup" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$setup_err" | grep -q 'needs root'; then
    ok "gbmux-setup without root fails closed"
else
    bad "gbmux-setup without root: rc=$rc err=$setup_err"
fi

# --- source helper libraries (must not run privileged mains) ---
GBMUX_LIB=1
# shellcheck disable=SC1091
. "$ROOT/gbmux"
unset GBMUX_LIB

GBMUX_SETUP_LIB=1
# shellcheck disable=SC1091
. "$ROOT/gbmux-setup"
unset GBMUX_SETUP_LIB

GBMUX_ACPOWER_LIB=1
# shellcheck disable=SC1091
. "$ROOT/gbmux-acpower"
unset GBMUX_ACPOWER_LIB

# --- HIGH-2: allowlist gbmux call ---
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBC 0 0xE6 {0}'; then
    ok "allow WMBC 0xE6 get-mode"
else
    bad "allow WMBC 0xE6 get-mode"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBD 0 0xE6 { 0 }'; then
    ok "allow WMBD 0xE6 set-mode"
else
    bad "allow WMBD 0xE6 set-mode"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBD 0 0x51 { 0x04 }'; then
    ok "allow WMBD 0x51 gpu on"
else
    bad "allow WMBD 0x51 gpu on"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBD 0 0x51 { 0x03 }'; then
    ok "allow WMBD 0x51 gpu off"
else
    bad "allow WMBD 0x51 gpu off"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBD 0 0xE7 {0}'; then
    bad "rejected 0xE7 Dynamic Boost"
else
    ok "rejected 0xE7 Dynamic Boost"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WXCM 0 0xE6 {0}'; then
    bad "rejected WXCM"
else
    ok "rejected WXCM"
fi
if acpi_expr_allowed '\_SB.PCI0.AMW0.WMBD 0 0x51 { 0x03 }; id'; then
    bad "rejected trailing junk"
else
    ok "rejected trailing junk"
fi
if acpi_expr_allowed '/bin/sh'; then
    bad "rejected /bin/sh"
else
    ok "rejected /bin/sh"
fi

# --- HIGH-1: hash verify on cache hit and mismatch ---
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
hello="$tmpdir/hello.run"
printf 'hello\n' >"$hello"
hello_hash=$(sha256sum "$hello" | awk '{print $1}')
if verify_installer "$hello" "$hello_hash"; then
    ok "verify_installer accepts matching digest"
else
    bad "verify_installer accepts matching digest"
fi
if verify_installer "$hello" "0000000000000000000000000000000000000000000000000000000000000000"; then
    bad "verify_installer rejects mismatch"
else
    ok "verify_installer rejects mismatch"
fi
if [ -f "$hello" ]; then
    ok "verify_installer does not delete on mismatch (caller deletes)"
else
    bad "verify_installer deleted the file itself"
fi

# production digest is NVIDIA's published sha256sum for 615.71.09
if [ "${SHA256:-}" = "cdceed22bbeb61248d1a6deabc2596673e3a6501698ee71ac8d2fdc28f3b70fe" ]; then
    ok "SHA256 pinned to NVIDIA-published 615.71.09 digest"
else
    bad "SHA256 not pinned (got '${SHA256:-}')"
fi

# ensure_installer: cache hit re-hashes; mismatch deletes and fails
export GBMUX_SETUP_DEST="$tmpdir/cache.run"
export GBMUX_SETUP_SHA256="$hello_hash"
export GBMUX_SETUP_URL="https://example.invalid/nvidia.run"
printf 'hello\n' >"$GBMUX_SETUP_DEST"
if ensure_installer; then
    ok "ensure_installer cache hit with good hash"
else
    bad "ensure_installer cache hit with good hash"
fi
printf 'TAMPERED\n' >"$GBMUX_SETUP_DEST"
if ensure_installer 2>"$tmpdir/ensure.err"; then
    bad "ensure_installer must fail on tainted cache"
else
    ok "ensure_installer fails on tainted cache"
fi
if [ ! -f "$GBMUX_SETUP_DEST" ]; then
    ok "tainted cache deleted"
else
    bad "tainted cache still present"
fi
if grep -q 'SHA256' "$tmpdir/ensure.err"; then
    ok "tainted cache reports SHA256 mismatch"
else
    bad "tainted cache error missing SHA256"
fi

# download path: DEST.part then mv only after hash; no chmod +x required
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/curl" <<'EOF'
#!/bin/sh
# fake curl: last -o dest is the part file
out=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || exit 1
printf 'hello\n' >"$out"
EOF
chmod +x "$tmpdir/bin/curl"
export PATH="$tmpdir/bin:$PATH"
export GBMUX_SETUP_DEST="$tmpdir/dl.run"
rm -f "$GBMUX_SETUP_DEST" "${GBMUX_SETUP_DEST}.part"
if ensure_installer; then
    ok "ensure_installer download+hash then mv"
else
    bad "ensure_installer download+hash then mv"
fi
if [ -f "$GBMUX_SETUP_DEST" ] && [ ! -f "${GBMUX_SETUP_DEST}.part" ]; then
    ok "DEST.part removed after successful mv"
else
    bad "DEST.part leftover or DEST missing"
fi
if [ ! -x "$GBMUX_SETUP_DEST" ]; then
    ok "installer not marked executable"
else
    bad "installer was chmod +x"
fi

# dry-run: verify only, do not invoke sh on the payload
export GBMUX_SETUP_DRY_RUN=1
export GBMUX_SETUP_ALLOW_NONROOT=1
printf 'hello\n' >"$GBMUX_SETUP_DEST"
dry=$(bash "$ROOT/gbmux-setup" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$dry" | grep -q 'hash ok'; then
    ok "gbmux-setup dry-run cache hit verifies hash"
else
    bad "gbmux-setup dry-run: rc=$rc out=$dry"
fi
# dry-run must not have tried to execute the payload as an installer
if printf '%s' "$dry" | grep -q 'installer failed'; then
    bad "dry-run executed installer"
else
    ok "dry-run did not run installer"
fi
unset GBMUX_SETUP_DRY_RUN GBMUX_SETUP_ALLOW_NONROOT
unset GBMUX_SETUP_DEST GBMUX_SETUP_SHA256 GBMUX_SETUP_URL

# --- HIGH-3: parse config, never source ---
if grep -n '[[:space:]]\. /etc/gbmux-acpower.conf' "$ROOT/gbmux-acpower" >/dev/null; then
    bad "gbmux-acpower still sources /etc/gbmux-acpower.conf"
else
    ok "gbmux-acpower does not source the config"
fi

shipped=$(parse_kill_on_battery "$ROOT/gbmux-acpower.conf") && rc=0 || rc=$?
assert_eq "shipped conf parses to empty" "" "$shipped"
[ "$rc" -eq 0 ] || bad "shipped conf parse rc=$rc"

ex="$tmpdir/example.conf"
printf '%s\n' 'KILL_ON_BATTERY="rustdesk"' >"$ex"
got=$(parse_kill_on_battery "$ex")
assert_eq "README example parses" "rustdesk" "$got"

printf '%s\n' 'KILL_ON_BATTERY="rustdesk obs"' >"$ex"
got=$(parse_kill_on_battery "$ex")
assert_eq "two allowlisted names" "rustdesk obs" "$got"

printf '%s\n' 'KILL_ON_BATTERY=""' >"$ex"
got=$(parse_kill_on_battery "$ex")
assert_eq "explicit empty" "" "$got"

# must not execute other lines
marker="$tmpdir/pwned"
rm -f "$marker"
printf '%s\n' 'KILL_ON_BATTERY="rustdesk"' 'touch '"$marker" >"$ex"
got=$(parse_kill_on_battery "$ex") && rc=0 || rc=$?
assert_eq "ignores non-assignment line (no RCE)" "rustdesk" "$got"
if [ ! -f "$marker" ]; then ok "did not execute extra line"; else bad "executed extra line"; fi

rm -f "$marker"
printf '%s\n' 'KILL_ON_BATTERY="$(touch '"$marker"')"' >"$ex"
if parse_kill_on_battery "$ex" >/dev/null 2>&1; then
    bad "rejected command-substitution value"
else
    ok "rejected command-substitution value"
fi
if [ ! -f "$marker" ]; then ok "did not run command substitution"; else bad "ran command substitution"; fi

printf '%s\n' 'KILL_ON_BATTERY="bad/name"' >"$ex"
if parse_kill_on_battery "$ex" >/dev/null 2>&1; then
    bad "rejected slash in process name"
else
    ok "rejected slash in process name"
fi

printf '%s\n' 'KILL_ON_BATTERY="*"' >"$ex"
if parse_kill_on_battery "$ex" >/dev/null 2>&1; then
    bad "rejected glob process name"
else
    ok "rejected glob process name"
fi

printf '%s\n' 'KILL_ON_BATTERY=rustdesk;id' >"$ex"
if parse_kill_on_battery "$ex" >/dev/null 2>&1; then
    bad "rejected unquoted metacharacters"
else
    ok "rejected unquoted metacharacters"
fi

# trust checks: non-root-owned file is untrusted; world-writable is untrusted
printf '%s\n' 'KILL_ON_BATTERY="rustdesk"' >"$ex"
chmod 644 "$ex"
if conf_is_trusted "$ex"; then
    bad "non-root-owned 0644 must be untrusted"
else
    ok "non-root-owned 0644 is untrusted"
fi
chmod 666 "$ex"
if conf_is_trusted "$ex"; then
    bad "world-writable file must be untrusted"
else
    ok "world-writable file is untrusted"
fi

# debian conffiles
if [ -f "$ROOT/debian/conffiles" ] && grep -qx '/etc/gbmux-acpower.conf' "$ROOT/debian/conffiles"; then
    ok "debian/conffiles lists acpower conf"
else
    bad "debian/conffiles missing /etc/gbmux-acpower.conf"
fi

# numeric PID helper
if pid_is_numeric 1234; then ok "pid 1234 numeric"; else bad "pid 1234 numeric"; fi
if pid_is_numeric '' || pid_is_numeric '12a' || pid_is_numeric '-1' || pid_is_numeric '1;1'; then
    bad "pid_is_numeric accepted junk"
else
    ok "pid_is_numeric rejects junk"
fi

# --- extra: fuser missing refuses eject (battery path only) ---
if command -v fuser >/dev/null 2>&1; then
    if fuser_available; then ok "fuser_available true when fuser is on PATH"; else bad "fuser_available true when fuser is on PATH"; fi
else
    ok "fuser not installed here — skip positive fuser_available check"
fi
# shadow PATH
mkdir -p "$tmpdir/empty"
oldpath=$PATH
PATH="$tmpdir/empty"
if fuser_available; then
    bad "fuser_available false when missing"
else
    ok "fuser_available false when missing"
fi
PATH=$oldpath

# mode allowlist for AC policy (skip non-[012] so Discrete is not torn-read-ejected)
if mux_mode_ok 0 && mux_mode_ok 1 && mux_mode_ok 2; then
    ok "mux_mode_ok accepts 0/1/2"
else
    bad "mux_mode_ok accepts 0/1/2"
fi
if mux_mode_ok '' || mux_mode_ok 3 || mux_mode_ok error; then
    bad "mux_mode_ok rejects garbage"
else
    ok "mux_mode_ok rejects garbage"
fi

# --- extra: flock around ACPI ---
if grep -q 'flock' "$ROOT/gbmux"; then
    ok "gbmux uses flock around ACPI"
else
    bad "gbmux missing flock"
fi

# curl hardening present
if grep -q -- "--proto '=https'" "$ROOT/gbmux-setup" && grep -q -- '--tlsv1.2' "$ROOT/gbmux-setup"; then
    ok "curl pinned to https+tls1.2"
else
    bad "curl missing https/tls pins"
fi
if grep -q 'Depends:.*curl' "$ROOT/debian/control"; then
    ok "curl is a package Depends"
else
    bad "curl still only Recommends"
fi
if grep -q 'psmisc' "$ROOT/debian/control"; then
    ok "psmisc is a package Depends"
else
    bad "psmisc not a Depends"
fi

# curl must not be open-ended -L
if grep -E 'curl[^\n]*-L' "$ROOT/gbmux-setup" >/dev/null; then
    bad "curl still uses open-ended -L"
else
    ok "curl does not follow arbitrary redirects"
fi

# Production acpower is #!/bin/sh (dash). Re-check parser under dash.
if command -v dash >/dev/null 2>&1; then
    dash_out=$(dash -c '
        GBMUX_ACPOWER_LIB=1
        . "$1/gbmux-acpower"
        parse_kill_on_battery "$1/gbmux-acpower.conf"
    ' _ "$ROOT") && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$dash_out" ]; then
        ok "dash parses shipped conf to empty"
    else
        bad "dash shipped parse rc=$rc out=$dash_out"
    fi
    dash_ex=$(mktemp)
    printf '%s\n' 'KILL_ON_BATTERY="rustdesk"' >"$dash_ex"
    dash_out=$(dash -c '
        GBMUX_ACPOWER_LIB=1
        . "$1/gbmux-acpower"
        parse_kill_on_battery "$2"
    ' _ "$ROOT" "$dash_ex") && rc=0 || rc=$?
    rm -f "$dash_ex"
    if [ "$rc" -eq 0 ] && [ "$dash_out" = rustdesk ]; then
        ok "dash parses README KILL_ON_BATTERY example"
    else
        bad "dash example parse rc=$rc out=$dash_out"
    fi
else
    ok "dash not installed — skip POSIX parser re-check"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
