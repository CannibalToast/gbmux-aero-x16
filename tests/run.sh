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
lib_err=$(GBMUX_LIB=1 bash "$ROOT/gbmux" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$lib_err" | grep -q 'needs root'; then
    ok "GBMUX_LIB=1 does not no-op an executed gbmux"
else
    bad "GBMUX_LIB=1 executed gbmux: rc=$rc err=$lib_err"
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

cache=$tmpdir/cache.run
# ensure_installer: cache hit re-hashes; mismatch deletes and fails
printf 'hello\n' >"$cache"
if ensure_installer "$cache" "$hello_hash" "https://example.invalid/nvidia.run"; then
    ok "ensure_installer cache hit with good hash"
else
    bad "ensure_installer cache hit with good hash"
fi
printf 'TAMPERED\n' >"$cache"
if ensure_installer "$cache" "$hello_hash" "https://example.invalid/nvidia.run" 2>"$tmpdir/ensure.err"; then
    bad "ensure_installer must fail on tainted cache"
else
    ok "ensure_installer fails on tainted cache"
fi
if [ ! -f "$cache" ]; then
    ok "tainted cache deleted"
else
    bad "tainted cache still present"
fi
if grep -q 'SHA256' "$tmpdir/ensure.err"; then
    ok "tainted cache reports SHA256 mismatch"
else
    bad "tainted cache error missing SHA256"
fi

# production pin is a literal; zero-arg ensure_installer uses script constants
if grep -q 'SHA256=${GBMUX_SETUP_SHA256' "$ROOT/gbmux-setup"; then
    bad "SHA256 still env-overridable at parse time"
else
    ok "SHA256 is a literal pin"
fi
if grep -A2 '^ensure_installer()' "$ROOT/gbmux-setup" | grep -q 'GBMUX_SETUP_DEST='; then
    bad "ensure_installer still rereads DEST from env"
else
    ok "ensure_installer does not reread DEST from env"
fi
if [ "$DEST" = "/var/cache/gbmux/NVIDIA-Linux-x86_64-615.71.09.run" ]; then
    ok "DEST pin is the NVIDIA installer cache path"
else
    bad "DEST pin unexpected: $DEST"
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
# Absolute GBMUX_CURL is the only override. A PATH entry named curl must not win.
export GBMUX_CURL="$tmpdir/bin/curl"
dl=$tmpdir/dl.run
rm -f "$dl" "${dl}.part"
umask 022
before_umask=$(umask)
if ensure_installer "$dl" "$hello_hash" "https://example.invalid/nvidia.run"; then
    ok "ensure_installer download+hash then mv"
else
    bad "ensure_installer download+hash then mv"
fi
after_umask=$(umask)
if [ "$before_umask" = "$after_umask" ]; then
    ok "ensure_installer restores umask after download"
else
    bad "umask leaked: before=$before_umask after=$after_umask"
fi
if [ -f "$dl" ] && [ ! -f "${dl}.part" ]; then
    ok "DEST.part removed after successful mv"
else
    bad "DEST.part leftover or DEST missing"
fi
if [ ! -x "$dl" ]; then
    ok "installer not marked executable"
else
    bad "installer was chmod +x"
fi

# dry-run test entrypoint: verify only, do not invoke sh on the payload
export GBMUX_SETUP_DRY_RUN=1
export GBMUX_SETUP_ALLOW_NONROOT=1
export GBMUX_SETUP_DEST=$dl
export GBMUX_SETUP_SHA256=$hello_hash
export GBMUX_SETUP_URL=https://example.invalid/nvidia.run
printf 'hello\n' >"$dl"
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
unset GBMUX_CURL

# ALLOW_NONROOT alone must not skip the root gate or run sh
allow_out=$(GBMUX_SETUP_ALLOW_NONROOT=1 bash "$ROOT/gbmux-setup" 2>&1) && allow_rc=0 || allow_rc=$?
if [ "$allow_rc" -ne 0 ] && printf '%s' "$allow_out" | grep -q 'needs root'; then
    ok "ALLOW_NONROOT alone still requires root"
else
    bad "ALLOW_NONROOT alone: rc=$allow_rc out=$allow_out"
fi

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
if grep -qx '/etc/modprobe.d/gbmux-nouveau.conf' "$ROOT/debian/conffiles"; then
    ok "debian/conffiles lists nouveau conf"
else
    bad "debian/conffiles missing nouveau conf"
fi
if grep -qx '/etc/udev/rules.d/99-gbmux-acpower.rules' "$ROOT/debian/conffiles"; then
    ok "debian/conffiles lists udev rule"
else
    bad "debian/conffiles missing udev rule"
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

# --- Medium/Low remediations (no AERO hardware) ---

# privileged CLIs must not use env-bash (PATH hijack under sudo)
for priv in gbmux gbmux-setup; do
    shebang=$(head -n 1 "$ROOT/$priv")
    if [ "$shebang" = '#!/bin/bash' ]; then
        ok "$priv shebang is /bin/bash"
    else
        bad "$priv shebang is $shebang"
    fi
done

# ACPI writes use printf, not echo (echo treats -n/-e as flags)
if grep -q "printf '%s\\\\n' \"\$1\"" "$ROOT/gbmux" && ! grep -q 'echo "\$1"' "$ROOT/gbmux"; then
    ok "acall writes with printf"
else
    bad "acall still uses echo for the ACPI payload"
fi

# absolute helpers: PATH cannot substitute modprobe/fuser/logger/curl
if grep -E '(^|[^/])modprobe( |$)' "$ROOT/gbmux-acpower" | grep -v 'MODPROBE=' | grep -v '/modprobe' | grep -v '^#'; then
    bad "gbmux-acpower still invokes modprobe via PATH"
else
    ok "gbmux-acpower does not invoke bare modprobe"
fi
if grep -n 'fuser' "$ROOT/gbmux-acpower" | grep -v 'FUSER' | grep -v 'fuser not found' | grep -v 'fuser_available'; then
    bad "gbmux-acpower still invokes bare fuser"
else
    ok "gbmux-acpower does not invoke bare fuser"
fi
if grep -E '(^|[^$./[:alnum:]_])logger ' "$ROOT/gbmux-acpower"; then
    bad "gbmux-acpower still invokes bare logger"
else
    ok "gbmux-acpower does not invoke bare logger"
fi
case "$FUSER" in
    /*) ok "FUSER is an absolute path ($FUSER)" ;;
    *) bad "FUSER is not absolute ($FUSER)" ;;
esac
mkdir -p "$tmpdir/hijack"
printf '#!/bin/sh\necho hijacked-fuser\n' >"$tmpdir/hijack/fuser"
chmod +x "$tmpdir/hijack/fuser"
oldpath=$PATH
PATH="$tmpdir/hijack:$PATH"
if fuser_available; then
    bad "fuser_available followed PATH"
else
    ok "fuser_available ignores a PATH-injected fuser"
fi
PATH=$oldpath

# curl download ignores PATH. Relative GBMUX_CURL is ignored too.
printf '#!/bin/sh\necho hijacked >"$2"\nexit 0\n' >"$tmpdir/hijack/curl"
chmod +x "$tmpdir/hijack/curl"
hijack_dest=$tmpdir/hijack-dest.run
rm -f "$hijack_dest"
oldpath=$PATH
PATH="$tmpdir/hijack:$PATH"
GBMUX_CURL=curl
if ensure_installer "$hijack_dest" "$hello_hash" "https://example.invalid/nvidia.run" 2>"$tmpdir/hijack.err"; then
    bad "PATH curl must not satisfy ensure_installer"
else
    ok "PATH curl cannot satisfy ensure_installer"
fi
if [ ! -f "$hijack_dest" ]; then
    ok "PATH curl did not create the installer"
else
    bad "PATH curl created $hijack_dest"
fi
unset GBMUX_CURL
PATH=$oldpath

# cache directory: not world-writable; symlink refused; production path named
world=$tmpdir/world
mkdir -p "$world"
chmod 0777 "$world"
if cache_dir_trusted "$world"; then
    bad "world-writable cache dir must be refused"
else
    ok "world-writable cache dir refused"
fi
if prepare_cache_dir "$world" 2>"$tmpdir/world.err"; then
    bad "prepare_cache_dir accepted world-writable dir"
else
    ok "prepare_cache_dir rejects world-writable dir"
fi
mkdir -p "$tmpdir/realcache"
ln -s realcache "$tmpdir/linkcache"
if prepare_cache_dir "$tmpdir/linkcache" 2>"$tmpdir/link.err"; then
    bad "prepare_cache_dir accepted symlink"
else
    ok "prepare_cache_dir rejects symlink"
fi
locked=$tmpdir/locked
mkdir -p "$locked"
chmod 0755 "$locked"
if cache_dir_trusted "$locked"; then
    ok "0755 non-world-writable cache dir accepted for non-root tests"
else
    bad "0755 cache dir rejected"
fi
if grep -q -- '-d -m 0755 -o root -g root' "$ROOT/gbmux-setup"; then
    ok "setup locks cache dir with install -d root:root 0755"
else
    bad "setup missing install -d root:root 0755"
fi

# Secure Boot: fail closed on EFI when the byte cannot be read
sbroot=$tmpdir/efi
rm -rf "$sbroot"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$sb" = skip ]; then
    ok "missing EFI tree skips Secure Boot check"
else
    bad "missing EFI tree: rc=$rc sb=$sb"
fi
mkdir -p "$sbroot/efivars"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "EFI without SecureBoot efivar fails closed"
else
    bad "EFI without efivar returned $sb"
fi
sbfile=$sbroot/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
printf '\006\000\000\000\001' >"$sbfile"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$sb" = on ]; then
    ok "Secure Boot byte 1 is on"
else
    bad "Secure Boot byte 1: rc=$rc sb=$sb"
fi
printf '\006\000\000\000\000' >"$sbfile"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$sb" = off ]; then
    ok "Secure Boot byte 0 is off"
else
    bad "Secure Boot byte 0: rc=$rc sb=$sb"
fi
printf '\006\000\000\000\002' >"$sbfile"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "unexpected Secure Boot byte fails closed"
else
    bad "unexpected Secure Boot byte returned $sb"
fi
printf 'short' >"$sbfile"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "short SecureBoot efivar fails closed"
else
    bad "short SecureBoot efivar returned $sb"
fi
chmod 000 "$sbfile"
sb=$(secure_boot_state "$sbroot") && rc=0 || rc=$?
chmod 644 "$sbfile" || true
if [ "$rc" -ne 0 ]; then
    ok "unreadable SecureBoot efivar fails closed"
else
    bad "unreadable SecureBoot efivar returned $sb"
fi

# internal AC adapter only
if ac_supply_name_trusted ACAD && ac_supply_name_trusted ADP0 && ac_supply_name_trusted ADP1; then
    ok "ACAD and ADP* are trusted adapter names"
else
    bad "ACAD/ADP* trust"
fi
if ac_supply_name_trusted usb || ac_supply_name_trusted hidpp_battery_0 || ac_supply_name_trusted Mains || ac_supply_name_trusted AC0; then
    bad "USB/other Mains names must not be trusted"
else
    ok "USB and non-ADP Mains names are not trusted"
fi
psroot=$tmpdir/ps
mkdir -p "$psroot/ACAD" "$psroot/usb-gadget" "$psroot/BAT0"
printf 'Mains\n' >"$psroot/ACAD/type"
printf '0\n' >"$psroot/ACAD/online"
printf 'Mains\n' >"$psroot/usb-gadget/type"
printf '1\n' >"$psroot/usb-gadget/online"
printf 'Battery\n' >"$psroot/BAT0/type"
printf '1\n' >"$psroot/BAT0/online"
got=$(read_ac_online "$psroot") && rc=0 || rc=$?
assert_eq "USB Mains online does not override offline ACAD" "0" "$got"
[ "$rc" -eq 0 ] || bad "ACAD offline read rc=$rc"
printf '1\n' >"$psroot/ACAD/online"
got=$(read_ac_online "$psroot") && rc=0 || rc=$?
assert_eq "ACAD online is on AC" "1" "$got"
rm -rf "$psroot/ACAD"
got=$(read_ac_online "$psroot") && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "only a USB Mains gadget fails closed"
else
    bad "USB-only Mains returned online=$got"
fi
mkdir -p "$psroot/ADP1"
printf 'Mains\n' >"$psroot/ADP1/type"
printf '1\n' >"$psroot/ADP1/online"
got=$(read_ac_online "$psroot") && rc=0 || rc=$?
assert_eq "ADP1 is an internal adapter" "1" "$got"
rm -rf "$psroot/ADP1"
mkdir -p "$psroot/ACAD"
printf 'Mains\n' >"$psroot/ACAD/type"
printf 'maybe\n' >"$psroot/ACAD/online"
got=$(read_ac_online "$psroot") && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    ok "unreadable AC online value fails closed"
else
    bad "garbage AC online returned $got"
fi

# dGPU by vendor/class, not a hardcoded BDF
if grep -v '^[[:space:]]*#' "$ROOT/gbmux-acpower" | grep -q '64:00.0'; then
    bad "gbmux-acpower still hardcodes 64:00.0"
else
    ok "gbmux-acpower does not hardcode 64:00.0"
fi
kind=$(nvidia_function_kind '0x030000') && rc=0 || rc=$?
assert_eq "class 0x030000 is VGA" "VGA" "$kind"
kind=$(nvidia_function_kind '0x030200') && rc=0 || rc=$?
assert_eq "class 0x030200 is VGA" "VGA" "$kind"
kind=$(nvidia_function_kind '0x040300') && rc=0 || rc=$?
assert_eq "class 0x040300 is AUD" "AUD" "$kind"
if nvidia_function_kind '0x0c0330'; then
    bad "USB class accepted as NVIDIA function"
else
    ok "USB class is not a NVIDIA function"
fi
if nvidia_vendor_ok '0x10de' && nvidia_vendor_ok '0x10DE'; then
    ok "vendor 10de accepted"
else
    bad "vendor 10de accepted"
fi
if nvidia_vendor_ok '0x1002'; then
    bad "AMD vendor accepted"
else
    ok "AMD vendor rejected"
fi

pci=$tmpdir/pci/devices
drv=$tmpdir/pci/drivers
mkdir -p "$pci/0000:64:00.0" "$pci/0000:64:00.1" "$pci/0000:66:00.0" \
    "$drv/nvidia" "$drv/snd_hda_intel" "$drv/amdgpu"
printf '0x10de\n' >"$pci/0000:64:00.0/vendor"
printf '0x030000\n' >"$pci/0000:64:00.0/class"
printf '0x10de\n' >"$pci/0000:64:00.1/vendor"
printf '0x040300\n' >"$pci/0000:64:00.1/class"
printf '0x1002\n' >"$pci/0000:66:00.0/vendor"
printf '0x030000\n' >"$pci/0000:66:00.0/class"
ln -s "../../drivers/nvidia" "$pci/0000:64:00.0/driver"
ln -s "../../drivers/snd_hda_intel" "$pci/0000:64:00.1/driver"
ln -s "../../drivers/amdgpu" "$pci/0000:66:00.0/driver"
: >"$drv/nvidia/unbind"
: >"$drv/snd_hda_intel/unbind"
: >"$drv/amdgpu/unbind"
resolved=$(resolve_nvidia_pci "$pci")
assert_eq "audio function listed before display" "AUD 0000:64:00.1
VGA 0000:64:00.0" "$resolved"
unbind_log=$tmpdir/unbind.log
: >"$unbind_log"
GBMUX_UNBIND_LOG=$unbind_log unbind_nvidia_functions "$pci" "$drv"
assert_eq "unbind order is audio then display" "AUD 0000:64:00.1
VGA 0000:64:00.0" "$(cat "$unbind_log")"
assert_eq "nvidia unbind payload" "0000:64:00.0" "$(cat "$drv/nvidia/unbind")"
assert_eq "hda unbind payload" "0000:64:00.1" "$(cat "$drv/snd_hda_intel/unbind")"
if [ -s "$drv/amdgpu/unbind" ]; then
    bad "AMD iGPU was unbound"
else
    ok "AMD iGPU was not unbound"
fi
# powered-off dGPU: no 10de devices, still success
off=$tmpdir/pci-off/devices
mkdir -p "$off/0000:66:00.0"
printf '0x1002\n' >"$off/0000:66:00.0/vendor"
printf '0x030000\n' >"$off/0000:66:00.0/class"
off_list=$(resolve_nvidia_pci "$off") && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$off_list" ]; then
    ok "powered-off dGPU resolves to no functions"
else
    bad "powered-off resolve rc=$rc list=$off_list"
fi

# udev: internal adapter names only
if grep -q 'KERNEL=="ACAD"' "$ROOT/99-gbmux-acpower.rules" \
    && grep -q 'KERNEL=="ADP\*"' "$ROOT/99-gbmux-acpower.rules"; then
    ok "udev matches ACAD and ADP*"
else
    bad "udev missing ACAD/ADP* match"
fi
if grep -E 'POWER_SUPPLY_TYPE.==."Mains"' "$ROOT/99-gbmux-acpower.rules" | grep -v 'KERNEL==' >/dev/null; then
    bad "udev has a Mains rule without a kernel name"
else
    ok "every Mains udev rule names the adapter"
fi

# systemd sandbox + rate limit
unit=$ROOT/gbmux-acpower.service
for key in ProtectSystem=strict ProtectHome=read-only ProtectKernelTunables=yes \
    PrivateTmp=yes NoNewPrivileges=yes RestrictAddressFamilies=AF_UNIX \
    StartLimitIntervalSec=10 StartLimitBurst=5 TimeoutStartSec=30 \
    'ReadWritePaths=/proc/acpi /sys/bus/pci /sys/module /run' \
    'ConditionPathExistsGlob=/sys/bus/wmi/devices/ABBC0F75-*'; do
    if grep -q -F "$key" "$unit"; then
        ok "unit has $key"
    else
        bad "unit missing $key"
    fi
done
if grep -v '^[[:space:]]*#' "$unit" | grep -q 'ProtectKernelModules=yes'; then
    bad "unit sets ProtectKernelModules=yes"
else
    ok "unit does not set ProtectKernelModules=yes"
fi

# packaging: do not delete /usr/local, enable only with the WMI GUID
if grep -q 'rm -f /usr/local/bin/gbmux' "$ROOT/debian/postinst" \
    || grep -q 'rm -f /usr/local/bin/gbmux-setup' "$ROOT/debian/postinst"; then
    bad "postinst still deletes /usr/local/bin/gbmux*"
else
    ok "postinst does not delete /usr/local/bin/gbmux*"
fi
if grep -q 'ABBC0F75' "$ROOT/debian/postinst" && grep -q 'ABBC0F75' "$ROOT/Makefile"; then
    ok "postinst and Makefile gate enablement on ABBC0F75"
else
    bad "enablement is not gated on ABBC0F75"
fi

# postinst behavior with a fake systemctl and a fake WMI tree
mkdir -p "$tmpdir/bin" "$tmpdir/nowmi" "$tmpdir/wmi/ABBC0F75-TEST"
cat >"$tmpdir/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GBMUX_SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$tmpdir/bin/systemctl"
sc_log=$tmpdir/systemctl.log
: >"$sc_log"
post_err=$(GBMUX_WMI_DEVICES="$tmpdir/nowmi" GBMUX_SYSTEMCTL_LOG="$sc_log" \
    PATH="$tmpdir/bin:$PATH" sh "$ROOT/debian/postinst" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$post_err" | grep -q 'not enabling'; then
    ok "postinst skips enable when WMI GUID is absent"
else
    bad "postinst without WMI: rc=$rc err=$post_err"
fi
if grep -q 'enable gbmux-acpower' "$sc_log"; then
    bad "postinst enabled the service without the WMI GUID"
else
    ok "postinst did not enable the service without the WMI GUID"
fi
: >"$sc_log"
post_err=$(GBMUX_WMI_DEVICES="$tmpdir/wmi" GBMUX_SYSTEMCTL_LOG="$sc_log" \
    PATH="$tmpdir/bin:$PATH" sh "$ROOT/debian/postinst" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'enable gbmux-acpower.service' "$sc_log"; then
    ok "postinst enables the service when ABBC0F75 exists"
else
    bad "postinst with WMI: rc=$rc log=$(cat "$sc_log") err=$post_err"
fi

# muxq: DRM master / GRANT_PERMISSIONS behind an explicit flag
if grep -q -- '--grant-permissions' "$ROOT/tools/muxq.c" \
    && grep -q 'if (!grant)' "$ROOT/tools/muxq.c" \
    && grep -q 'enableConsoleHotplugHandling = grant' "$ROOT/tools/muxq.c"; then
    ok "muxq gates DRM master on --grant-permissions"
else
    bad "muxq does not gate DRM master"
fi
# the ioctl must not sit outside the grant block: the skip return is above it
grant_line=$(grep -n 'if (!grant)' "$ROOT/tools/muxq.c" | head -n 1 | cut -d: -f1)
ioctl_line=$(grep -n 'DRM_IOCTL_SET_MASTER' "$ROOT/tools/muxq.c" | head -n 1 | cut -d: -f1)
skip_line=$(grep -n 'skipping DRM master' "$ROOT/tools/muxq.c" | head -n 1 | cut -d: -f1)
if [ -n "$grant_line" ] && [ -n "$ioctl_line" ] && [ -n "$skip_line" ] \
    && [ "$grant_line" -lt "$skip_line" ] && [ "$skip_line" -lt "$ioctl_line" ]; then
    ok "SET_MASTER is after the grant-permissions skip"
else
    bad "SET_MASTER ordering grant=$grant_line skip=$skip_line ioctl=$ioctl_line"
fi

# optional AppArmor profile and commented sudoers (no call, no gbmux-setup)
if [ -f "$ROOT/apparmor/usr.sbin.gbmux" ] && grep -q '/proc/acpi/call' "$ROOT/apparmor/usr.sbin.gbmux"; then
    ok "optional AppArmor profile allows /proc/acpi/call"
else
    bad "AppArmor profile missing"
fi
sudoers=$ROOT/examples/gbmux.sudoers
if [ -f "$sudoers" ]; then
    ok "commented sudoers fragment shipped"
else
    bad "sudoers fragment missing"
fi
# privilege lines stay comments; call and gbmux-setup are not commands
if grep -v '^[[:space:]]*#' "$sudoers" | grep -v '^[[:space:]]*$' >/dev/null; then
    bad "sudoers fragment has an active rule"
else
    ok "sudoers fragment has no active rule"
fi
if grep -v '^[[:space:]]*#' "$sudoers" | grep -E 'call|gbmux-setup' >/dev/null; then
    bad "sudoers active text mentions call or gbmux-setup"
else
    ok "sudoers active text excludes call and gbmux-setup"
fi
if grep '^#' "$sudoers" | grep -q 'gbmux-setup' && grep '^#' "$sudoers" | grep -q 'call'; then
    ok "sudoers comments document the call and gbmux-setup exclusion"
else
    bad "sudoers comments do not mention the exclusion"
fi

# documented CLI and pinned driver still present
if grep -q '615.71.09' "$ROOT/gbmux-setup" && grep -q 'cdceed22bbeb61248d1a6deabc2596673e3a6501698ee71ac8d2fdc28f3b70fe' "$ROOT/gbmux-setup"; then
    ok "NVIDIA 615.71.09 pin unchanged"
else
    bad "NVIDIA pin changed"
fi
if grep -q 'mokutil --import' "$ROOT/README.md"; then
    ok "README documents MOK enrollment"
else
    bad "README missing mokutil --import"
fi

if command -v dash >/dev/null 2>&1; then
    dash_pci=$(dash -c '
        GBMUX_ACPOWER_LIB=1
        . "$1/gbmux-acpower"
        nvidia_function_kind "0x030200"
        printf " "
        nvidia_function_kind "0x040300"
        printf " "
        if ac_supply_name_trusted usb; then printf BAD; else printf OK; fi
    ' _ "$ROOT") && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && [ "$dash_pci" = "VGA AUD OK" ]; then
        ok "dash resolves NVIDIA class and rejects USB adapter names"
    else
        bad "dash helper check rc=$rc out=$dash_pci"
    fi
else
    ok "dash not installed — skip POSIX helper re-check"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
