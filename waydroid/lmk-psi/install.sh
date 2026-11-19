#!/bin/sh
# FP5 Waydroid: switch Android lmkd from legacy minfree levels (counts only host MemFree)
# to the PSI/watermark strategy. Persistent via waydroid.cfg [properties] (re-applied by
# `waydroid init/upgrade` make_base_props) + waydroid_base.prop (read at every session start).
set -eu
W=/var/lib/waydroid
B=${BACKUP_DIR:-/var/lib/fp5-backup/20261119-waydroid-lmk}
PROPS="ro.lmk.use_minfree_levels=false"
mkdir -p "$B"
for f in waydroid.cfg waydroid_base.prop waydroid.prop; do
  [ -e "$B/$f.orig" ] || cp -a "$W/$f" "$B/$f.orig"
done
python3 - "$W/waydroid.cfg" $PROPS <<'PY'
import configparser, sys
path, props = sys.argv[1], sys.argv[2:]
c = configparser.ConfigParser(); c.read(path)
if not c.has_section("properties"): c.add_section("properties")
for p in props:
    k, v = p.split("=", 1); c.set("properties", k, v)
with open(path, "w") as f: c.write(f)
PY
for p in $PROPS; do
  k=${p%%=*}
  grep -v "^$k=" "$W/waydroid_base.prop" > "$W/waydroid_base.prop.new" || true
  echo "$p" >> "$W/waydroid_base.prop.new"
  chmod 644 "$W/waydroid_base.prop.new"; mv "$W/waydroid_base.prop.new" "$W/waydroid_base.prop"
done
cat > "$B/rollback.sh" <<RB
#!/bin/sh
# Restore pre-change waydroid.cfg and waydroid_base.prop, then restart the session:
#   run0 sh $B/rollback.sh
set -eu
cp -a "$B/waydroid.cfg.orig" "$W/waydroid.cfg"
cp -a "$B/waydroid_base.prop.orig" "$W/waydroid_base.prop"
U=\$(id -u fp5)
runuser -u fp5 -- env XDG_RUNTIME_DIR=/run/user/\$U systemctl --user restart waydroid-session.service
echo "rolled back; session restarted"
RB
chmod 755 "$B/rollback.sh"
sha256sum "$W/waydroid.cfg" "$W/waydroid_base.prop" > "$B/SHA256SUMS.after"
echo APPLIED; tail -3 "$W/waydroid.cfg"; tail -2 "$W/waydroid_base.prop"
