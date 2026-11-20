#!/bin/sh
# Install the car PBAP user service. Run as the desktop user, never as root.
# Does not write /usr and does not restart system services.
#
#   sh install.sh
#
# Binary: $FP5_PBAP_STAGING/obexd, else ~/.local/share/fp5-pbap-staging/obexd,
# else ./staging/obexd next to this script. SHA256SUMS in that directory must
# match. On the desk the binary is not in git; copy the staging directory to
# the phone with the scripts.
set -eu

is_aarch64_elf() {
	file=$1
	hdr=$(od -An -t x1 -N 20 "$file" 2>/dev/null | tr 'A-F' 'a-f' | tr -s ' ')
	# shellcheck disable=SC2086
	set -- $hdr
	[ "$#" -ge 20 ] || return 1
	[ "$1" = "7f" ] && [ "$2" = "45" ] && [ "$3" = "4c" ] && [ "$4" = "46" ] || return 1
	[ "$5" = "02" ] || return 1
	[ "$6" = "01" ] || return 1
	# ${19} is the 19th field. $19 would be $1 with a literal 9 appended.
	[ "${19}" = "b7" ] && [ "${20}" = "00" ] || return 1
	return 0
}

install_main() {
	script=$1
	script_dir=$(CDPATH= cd -- "$(dirname "$script")" && pwd)
	uid=$(id -u)
	libexec=${HOME:?HOME is required}/.local/libexec/fp5-car-pbap
	unit_dir=$HOME/.config/systemd/user
	dbus_dir=$HOME/.local/share/dbus-1/services
	backup_root=$HOME/.local/share/fp5-car-pbap/backup
	off=${XDG_CONFIG_HOME:-$HOME/.config}/fp5-car-pbap.off

	if [ "$uid" -eq 0 ]; then
		echo "refusing to run as root; this install stays in the user session" >&2
		exit 1
	fi
	if [ "$(uname -m)" != "aarch64" ] && [ "${FP5_PBAP_SKIP_ARCH:-}" != 1 ]; then
		echo "refusing: need aarch64 (FP5_PBAP_SKIP_ARCH=1 overrides)" >&2
		exit 1
	fi

	if [ -n "${FP5_PBAP_STAGING:-}" ]; then
		staging=$FP5_PBAP_STAGING
	elif [ -f "$HOME/.local/share/fp5-pbap-staging/obexd" ]; then
		staging=$HOME/.local/share/fp5-pbap-staging
	elif [ -f "$script_dir/staging/obexd" ]; then
		staging=$script_dir/staging
	else
		echo "no obexd binary. Set FP5_PBAP_STAGING to the staging directory." >&2
		exit 1
	fi

	src_obex=$staging/obexd
	sums=$staging/SHA256SUMS
	[ -f "$src_obex" ] || { echo "missing $src_obex" >&2; exit 1; }
	[ -f "$sums" ] || { echo "missing $sums" >&2; exit 1; }

	expected=$(awk '$2 == "obexd" { print $1; exit }' "$sums")
	actual=$(sha256sum "$src_obex" | awk '{ print $1 }')
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		echo "obexd sha256 does not match SHA256SUMS" >&2
		exit 1
	fi
	if ! is_aarch64_elf "$src_obex"; then
		if [ "${FP5_PBAP_ALLOW_NON_ELF:-}" != 1 ]; then
			echo "refusing: obexd is not an arm64 ELF (FP5_PBAP_ALLOW_NON_ELF=1 overrides)" >&2
			exit 1
		fi
		echo "warning: installing a non-arm64 file because FP5_PBAP_ALLOW_NON_ELF=1" >&2
	fi

	n=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d ! -name '*.applied' 2>/dev/null | wc -l | tr -d ' ')
	stamp=$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04d' "$n")
	bk=$backup_root/$stamp
	mkdir -p "$bk/files" "$libexec" "$unit_dir" "$dbus_dir"

	was=0
	if systemctl --user is-enabled --quiet obex.service; then
		was=1
	fi
	printf '%s\n' "$was" > "$bk/obex-was-enabled"
	systemctl --user disable --now obex.service || true

	: > "$bk/replaced.list"
	: > "$bk/new-files.list"

	place() {
		dest=$1
		mode=$2
		if [ -L "$dest" ]; then
			echo "refusing to follow symlink $dest" >&2
			exit 1
		fi
		if [ -e "$dest" ]; then
			mkdir -p "$bk/files$(dirname "$dest")"
			cp -a "$dest" "$bk/files$dest"
			printf '%s\n' "$dest" >> "$bk/replaced.list"
		else
			printf '%s\n' "$dest" >> "$bk/new-files.list"
		fi
		mkdir -p "$(dirname "$dest")"
		cp -a "$3" "$dest"
		chmod "$mode" "$dest"
	}

	place "$libexec/obexd" 755 "$src_obex"
	place "$libexec/fp5-car-pbap-activate" 755 "$script_dir/fp5-car-pbap-activate"
	place "$unit_dir/fp5-car-pbap.service" 644 "$script_dir/fp5-car-pbap.service"

	dbus_file=$dbus_dir/org.bluez.obex.service
	dbus_tmp=$bk/org.bluez.obex.service.new
	cat > "$dbus_tmp" <<EOF
[D-BUS Service]
Name=org.bluez.obex
Exec=$libexec/fp5-car-pbap-activate
EOF
	place "$dbus_file" 644 "$dbus_tmp"

	systemctl --user daemon-reload
	if [ -e "$off" ]; then
		systemctl --user enable fp5-car-pbap.service
		echo "off switch $off is present; not starting fp5-car-pbap.service"
	else
		systemctl --user enable --now fp5-car-pbap.service
	fi

	echo "backup $bk"
	for installed in \
		"$libexec/obexd" \
		"$libexec/fp5-car-pbap-activate" \
		"$unit_dir/fp5-car-pbap.service" \
		"$dbus_file"
	do
		sha256sum "$installed"
	done
	echo "installed fp5-car-pbap for $HOME"
}

if [ "${FP5_PBAP_LIB:-0}" != 1 ]; then
	install_main "$0"
fi
