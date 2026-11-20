#!/bin/sh
# Exercise install.sh and rollback.sh against a fake HOME and a fake systemctl.
# The fake systemctl fails if a command is not a user-manager command, or if
# it names bluetooth, PipeWire, WirePlumber or ModemManager.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mock=$work/bin
mkdir -p "$mock"
cat > "$mock/systemctl" <<'EOF'
#!/bin/sh
log=${FP5_PBAP_SYSTEMCTL_LOG:?}
printf '%s\n' "$*" >> "$log"
has_user=0
for a in "$@"; do
	if [ "$a" = "--user" ]; then
		has_user=1
	fi
	case "$a" in
	--system|*bluetooth*|*pipewire*|*wireplumber*|*ModemManager*|*modemmanager*)
		echo "forbidden systemctl arg: $*" >&2
		exit 99
		;;
	esac
done
if [ "$has_user" != 1 ]; then
	echo "systemctl without --user: $*" >&2
	exit 99
fi
cmd=
for a in "$@"; do
	case "$a" in
	--user|--quiet|--now) ;;
	*) cmd=$a; break ;;
	esac
done
case "$cmd" in
restart|try-restart|reload-or-restart|isolate|poweroff|reboot|halt|kexec)
	echo "refusing $cmd" >&2
	exit 99
	;;
esac
if [ "$cmd" = "is-enabled" ]; then
	if [ "${FP5_PBAP_OBEX_ENABLED:-0}" = 1 ]; then
		exit 0
	fi
	exit 1
fi
if [ "$cmd" = "is-active" ]; then
	exit 1
fi
exit 0
EOF
chmod 755 "$mock/systemctl"

fakeid=$work/fake-id
mkdir -p "$fakeid"
cat > "$fakeid/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
	echo 0
	exit 0
fi
exit 0
EOF
chmod 755 "$fakeid/id"

# Scripts must not call systemctl except as a user manager.
for f in "$root/install.sh" "$root/rollback.sh" "$root/fp5-car-pbap-activate"; do
	if grep -n systemctl "$f" | grep -v -- '--user' >/dev/null; then
		grep -n systemctl "$f" | grep -v -- '--user' >&2 || true
		fail "$f has a systemctl invocation without --user"
	fi
done

if grep -n 'bluetooth.service' "$root/fp5-car-pbap.service" >/dev/null; then
	fail "unit file references bluetooth.service"
fi
if ! grep -q 'ConditionPathExists=!%h/.config/fp5-car-pbap.off' "$root/fp5-car-pbap.service"; then
	fail "unit file missing the off-switch condition"
fi
if ! grep -q -- '--plugin=bluetooth,pbap' "$root/fp5-car-pbap.service"; then
	fail "unit file must load the bluetooth transport and the pbap plugin"
fi

# Root is refused before any install.
home=$work/root-home
mkdir -p "$home"
log=$work/systemctl.log
: > "$log"
if env -u FP5_PBAP_SKIP_ARCH HOME="$home" PATH="$fakeid:$mock:$PATH" \
	FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/install.sh"; then
	fail "install as uid 0 should fail"
fi

# Non-aarch64 is refused unless the override is set.
if env HOME="$home" PATH="$PATH" \
	FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/install.sh"; then
	fail "install on $(uname -m) should fail without FP5_PBAP_SKIP_ARCH"
fi

staging=$work/staging
mkdir -p "$staging"
printf 'not an obexd\n' > "$staging/obexd"
(cd "$staging" && sha256sum obexd > SHA256SUMS)

# A non-ELF is refused unless the override is set.
if env HOME="$home" PATH="$mock:$PATH" \
	FP5_PBAP_SKIP_ARCH=1 \
	FP5_PBAP_STAGING="$staging" \
	FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/install.sh"; then
	fail "non-ELF obexd should be refused"
fi
if [ -e "$home/.config/systemd/user/fp5-car-pbap.service" ]; then
	fail "refused install still wrote the unit"
fi

# ELF header checker.
elf=$work/elf-aarch64
x64=$work/elf-x86_64
python3 - "$elf" "$x64" <<'PY'
import sys
def hdr(path, machine):
    b = bytearray(64)
    b[0:4] = b"\x7fELF"
    b[4] = 2
    b[5] = 1
    b[18] = machine & 0xff
    b[19] = (machine >> 8) & 0xff
    open(path, "wb").write(b)
hdr(sys.argv[1], 183)  # EM_AARCH64
hdr(sys.argv[2], 62)   # EM_X86_64
PY
(
	FP5_PBAP_LIB=1
	# shellcheck disable=SC1091
	. "$root/install.sh"
	is_aarch64_elf "$elf" || { echo "aarch64 header rejected" >&2; exit 1; }
	if is_aarch64_elf "$x64"; then
		echo "x86_64 header accepted" >&2
		exit 1
	fi
	if is_aarch64_elf "$staging/obexd"; then
		echo "text file accepted as ELF" >&2
		exit 1
	fi
) || fail "ELF header checks"

run_install() {
	env HOME="$1" PATH="$mock:$PATH" \
		FP5_PBAP_SKIP_ARCH=1 \
		FP5_PBAP_ALLOW_NON_ELF=1 \
		FP5_PBAP_STAGING="$staging" \
		FP5_PBAP_SYSTEMCTL_LOG="$log" \
		FP5_PBAP_OBEX_ENABLED="${2:-0}" \
		sh "$root/install.sh" > "$work/install.out"
}

home=$work/home
mkdir -p "$home"
: > "$log"
run_install "$home" 0

unit=$home/.config/systemd/user/fp5-car-pbap.service
activate=$home/.local/libexec/fp5-car-pbap/fp5-car-pbap-activate
obex=$home/.local/libexec/fp5-car-pbap/obexd
dbus=$home/.local/share/dbus-1/services/org.bluez.obex.service
for f in "$unit" "$activate" "$obex" "$dbus"; do
	[ -f "$f" ] || fail "missing $f"
done
if grep -q SystemdService "$dbus"; then
	fail "dbus activation file must not set SystemdService"
fi
if ! grep -q "Exec=$home/.local/libexec/fp5-car-pbap/fp5-car-pbap-activate" "$dbus"; then
	fail "dbus Exec path is wrong"
fi
grep -q 'enable --now fp5-car-pbap.service' "$log" || fail "service was not enabled"
grep -q 'bluetooth' "$log" && fail "systemctl log mentions bluetooth" || true
# Every logged command includes --user. The mock would have exited otherwise.
first=$(sha256sum "$unit" | awk '{ print $1 }')
grep -q "$first" "$work/install.out" || fail "install did not print the unit sha256"
obex_hash=$(sha256sum "$staging/obexd" | awk '{ print $1 }')
got=$(sha256sum "$obex" | awk '{ print $1 }')
[ "$obex_hash" = "$got" ] || fail "installed obexd hash differs"
grep -q "$obex_hash" "$work/install.out" || fail "install did not print the obexd sha256"

bk1=$(find "$home/.local/share/fp5-car-pbap/backup" -mindepth 1 -maxdepth 1 -type d ! -name '*.applied' | sort | tail -n 1)
[ -n "$bk1" ] || fail "no backup"
grep -q "$unit" "$bk1/new-files.list" || fail "first install should record the unit as new"
[ ! -s "$bk1/replaced.list" ] || fail "first install replaced an existing file"

# Second install replaces the unit. Change the source unit in a copied tree
# so the new bytes differ, then roll back to the first install.
copy=$work/tree
mkdir -p "$copy"
cp "$root/install.sh" "$root/rollback.sh" "$root/fp5-car-pbap-activate" "$root/fp5-car-pbap.service" "$copy/"
printf '\n# second-install-marker\n' >> "$copy/fp5-car-pbap.service"
: > "$log"
env HOME="$home" PATH="$mock:$PATH" \
	FP5_PBAP_SKIP_ARCH=1 \
	FP5_PBAP_ALLOW_NON_ELF=1 \
	FP5_PBAP_STAGING="$staging" \
	FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$copy/install.sh"
second=$(sha256sum "$unit" | awk '{ print $1 }')
[ "$second" != "$first" ] || fail "second install did not change the unit"
bk2=$(find "$home/.local/share/fp5-car-pbap/backup" -mindepth 1 -maxdepth 1 -type d ! -name '*.applied' | sort | tail -n 1)
[ "$bk2" != "$bk1" ] || fail "second install did not create a new backup"
grep -q "$unit" "$bk2/replaced.list" || fail "second install should back up the unit"

: > "$log"
env HOME="$home" PATH="$mock:$PATH" FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/rollback.sh"
now=$(sha256sum "$unit" | awk '{ print $1 }')
[ "$now" = "$first" ] || fail "rollback did not restore the first unit"
grep -q 'disable --now fp5-car-pbap.service' "$log" || fail "rollback did not disable the unit"
grep -q 'start ' "$log" && fail "rollback started a service" || true

: > "$log"
env HOME="$home" PATH="$mock:$PATH" FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/rollback.sh"
[ ! -e "$unit" ] || fail "second rollback left the unit in place"
[ ! -e "$dbus" ] || fail "second rollback left the dbus override in place"
[ ! -e "$obex" ] || fail "second rollback left obexd in place"

# Off switch: enable, but do not --now. Distro obex was enabled, so rollback
# re-enables it and does not start it.
home=$work/home-off
mkdir -p "$home/.config"
touch "$home/.config/fp5-car-pbap.off"
: > "$log"
run_install "$home" 1
grep -q 'enable --now' "$log" && fail "off switch install used --now" || true
grep -q 'enable fp5-car-pbap.service' "$log" || fail "off switch install did not enable"
: > "$log"
env HOME="$home" PATH="$mock:$PATH" FP5_PBAP_SYSTEMCTL_LOG="$log" \
	sh "$root/rollback.sh"
grep -q 'enable obex.service' "$log" || fail "did not re-enable obex.service"
if grep 'enable obex.service' "$log" | grep -q -- '--now'; then
	fail "re-enable of obex.service must not start it"
fi
if grep -q 'start ' "$log"; then
	fail "rollback started a service"
fi

echo "ok"
