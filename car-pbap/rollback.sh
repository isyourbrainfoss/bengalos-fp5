#!/bin/sh
# Undo the newest fp5-car-pbap install. Run as the desktop user, never as root.
# Disables the user unit, restores replaced files, deletes files that install
# created, and reloads the user manager. Does not start or restart anything,
# including bluetooth, PipeWire, WirePlumber or ModemManager.
#
#   sh rollback.sh
#
# Applied backups are renamed to <stamp>.applied and kept for inspection.
# Run again to undo the install before that.
set -eu

if [ "$(id -u)" -eq 0 ]; then
	echo "refusing to run as root" >&2
	exit 1
fi

backup_root=${HOME:?HOME is required}/.local/share/fp5-car-pbap/backup
if [ ! -d "$backup_root" ]; then
	echo "no backup directory at $backup_root" >&2
	exit 1
fi

bk=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d ! -name '*.applied' | sort | tail -n 1)
if [ -z "$bk" ]; then
	echo "no unused backup in $backup_root" >&2
	exit 1
fi

systemctl --user disable --now fp5-car-pbap.service || true

if [ -f "$bk/new-files.list" ]; then
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if [ -L "$path" ]; then
			echo "refusing to remove symlink $path" >&2
			exit 1
		fi
		rm -f "$path"
		echo "removed $path"
	done < "$bk/new-files.list"
fi

if [ -f "$bk/replaced.list" ]; then
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		saved=$bk/files$path
		if [ ! -e "$saved" ]; then
			echo "missing backup copy $saved" >&2
			exit 1
		fi
		if [ -L "$path" ]; then
			echo "refusing to follow symlink $path" >&2
			exit 1
		fi
		mkdir -p "$(dirname "$path")"
		cp -a "$saved" "$path"
		echo "restored $path"
	done < "$bk/replaced.list"
fi

was=0
if [ -f "$bk/obex-was-enabled" ]; then
	was=$(tr -d '[:space:]' < "$bk/obex-was-enabled")
fi
if [ "$was" = 1 ]; then
	systemctl --user enable obex.service || true
	echo "re-enabled obex.service (not started)"
fi

systemctl --user daemon-reload
mv "$bk" "$bk.applied"
echo "rolled back $bk"
echo "user manager reloaded; no system service was started or restarted"
