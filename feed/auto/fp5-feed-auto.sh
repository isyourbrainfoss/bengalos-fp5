#!/bin/bash
# fp5-feed-auto.sh: keep the FP5 sysupdate feed (GitHub release fp5-feed in isyourbrainfoss/bengalos-fp5) in step
# with official BengalOS (roaming/arm64/sdm845). Desk only; never talks to the phone.
#
#   fp5-feed-auto.sh                      normal daily run: newest official version -> no-op if already in the feed,
#                                         else download + verify, build UKI + sysexts (incl. carried fp5-modemmanager +
#                                         fp5-frunk-qs), check, publish
#   fp5-feed-auto.sh --dry-run            same, but never uploads/deletes anything (build + checks only)
#   fp5-feed-auto.sh --dry-run --version 0.26.1114.1 --force
#                                         rebuild + check a version even if it is already published (no upload);
#                                         also reports whether the rebuild is byte-identical to the published assets
#   other: --keep N (versions kept in the feed, default 3), --no-prune, --keep-work, --write-baseline (human only)
#
# Exit: 0 = UP_TO_DATE / PUBLISHED / DRYRUN_OK, 1 = CHECK_FAILED (needs a human, nothing published),
#       2 = ERROR (network/tooling; safe to retry tomorrow), 3 = another run is active.
# Status: ../logs/auto/STATUS (last run), ../logs/auto/history.log (one line per run), ../logs/auto/run-*.log
set -euo pipefail
umask 022
export LC_ALL=C
AUTO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# O = the desk tree with uki/, sysext/src+out, feed/, logs/, test/, auto/baseline/ (default: parent of this script's dir).
# FP5_FEED_O lets a checkout of this script (e.g. a review branch) run against the live tree without editing it.
O=${FP5_FEED_O:-$(dirname "$AUTO")}; II=$(dirname "$O"); IMG=$II/images
SX=$(cd "$AUTO/../sysext" && pwd)    # build-sysexts.sh + carry/ that go with THIS script
OFF=https://bengalos.phosh.mobi/images/roaming/arm64/sdm845
REPO=isyourbrainfoss/bengalos-fp5; TAG=fp5-feed; FEED=https://github.com/$REPO/releases/download/$TAG
TOOLS=fp5-official-tools:20261114
PANEL3=$(readlink -f "$II/../tests/bengalos-update-20261109/uki/fp5-bos1109-panel3-20261109.efi")
PANEL3_SHA=2757ab04afc0932a8edb2cb6e43d2d478f63a2779982e8a008ed5d2ed25a70c1; PANEL3_VER=0.26.1109.1
RULE=$O/uki/61-bengalos-fp5-ufs-readonly.internal.rules
KEYRING=$AUTO/keys/bengalos-import-pubring.pgp
SIGNER=C0B91FCC7EDC2D60B538C12DC44F0BEE22291241          # "Bengalos Test Images Signing Key"
CERT_FP=c56aaea912c8c09919b36838490564d970f5ce61ea649d1b12ee431faf9f73d5   # usr-verity-sig certificate (1113/1114)
NAMES=(fp5-volte-modules fp5-qtee fp5-ims-app fp5-device)
WDTOOLS=fp5-waydroid-fix-tools:20261115                 # = $TOOLS + libglib2.0-bin, shared-mime-info, gtk-update-icon-cache
WDFIX_FROM=0.26.1114.2   # first version whose feed entry must include fp5-waydroid-fix (1114.1: built 2026-11-15, applied by hand)
# Carried local add-ons (2026-11-19, Kristian: "så alt blir med i nye oppdateringer"): built + checked for EVERY version,
# published from CARRY_FROM on (0.26.1116.1-0.26.1118.1 were re-pinned by hand on the phone). Gates (fail closed):
CARRY=(fp5-modemmanager fp5-frunk-qs)
CARRY_FROM=0.26.1119.1
CARRY_MM_PKG=1.25.95-1        # official modemmanager must still be this (else our daemon would override a newer one)
CARRY_PHOSH_UPSTREAM=0.59.0   # plugin embeds PhoshQuickSetting's instance struct: new phosh => rebuild the plugin
LOGD=${FP5_FEED_LOGD:-$O/logs/auto}; mkdir -p "$LOGD"

DRY=0; FORCE=0; VER=; KEEP=3; PRUNE=1; KEEPWORK=0; BASELINE=0
while [ $# -gt 0 ]; do case $1 in
  --dry-run) DRY=1;; --force) FORCE=1;; --version) VER=$2; shift;; --keep) KEEP=$2; shift;;
  --no-prune) PRUNE=0;; --keep-work) KEEPWORK=1;; --write-baseline) BASELINE=1;;
  -h|--help) sed -n '2,20p' "$0"; exit 0;; *) echo "unknown arg $1" >&2; exit 2;; esac; shift; done
[ "$KEEP" -ge 2 ] 2>/dev/null || { echo "--keep must be >= 2 (InstancesMax=2 on the phone)" >&2; exit 2; }

exec 9>"$LOGD/.lock"; flock -n 9 || { echo "another fp5-feed-auto run is active" >&2; exit 3; }
TS=$(date +%Y%m%d-%H%M%S); LOG=$LOGD/run-$TS.log
exec > >(tee -a "$LOG") 2>&1
RESULT=; REASON=; V=; LATEST=; FEEDVERS=; WARNS=0
status() { # $1 result $2 reason
  RESULT=$1; REASON=$2
  { echo "time=$(date '+%Y-%m-%d %H:%M:%S %Z')"; echo "result=$RESULT"; echo "version=${V:-}"; echo "official_latest=${LATEST:-}"
    echo "feed_versions=${FEEDVERS:-}"; echo "dry_run=$DRY"; echo "warnings=$WARNS"; echo "reason=$REASON"; echo "log=$LOG"; } > "$LOGD/STATUS.tmp"
  mv "$LOGD/STATUS.tmp" "$LOGD/STATUS"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $RESULT v=${V:--} latest=${LATEST:--} dry=$DRY :: $REASON" >> "$LOGD/history.log"
  echo "### RESULT: $RESULT ${V:+($V)} :: $REASON"
}
on_exit() { rc=$?; [ -n "$RESULT" ] || status ERROR "aborted (rc=$rc) near line ${ERRLINE:-?}; see log"; }
trap 'ERRLINE=$LINENO' ERR; trap on_exit EXIT
fail() { status CHECK_FAILED "$*"; exit 1; }
err()  { status ERROR "$*"; exit 2; }
say()  { echo "[$(date +%H:%M:%S)] $*"; }
vre='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

find "$LOGD" -name "run-*.log" -mtime +60 -delete 2>/dev/null || true
say "fp5-feed-auto start (dry_run=$DRY force=$FORCE version=${VER:-auto} keep=$KEEP)"
# ---- preflight
for t in curl gh jq gpgv xz sha256sum python3 docker veritysetup flock; do command -v $t >/dev/null || err "missing tool $t"; done
docker image inspect $WDTOOLS >/dev/null 2>&1 || err "docker image $WDTOOLS missing (build from $O/waydroid/tools/Dockerfile)"
docker image inspect $TOOLS >/dev/null 2>&1 || err "docker image $TOOLS missing (build from $O/tools/Dockerfile)"
[ "$(sha256sum < "$PANEL3" | cut -d' ' -f1)" = $PANEL3_SHA ] || fail "panel3 source UKI checksum changed: $PANEL3"
(cd "$O/sysext/src" && sha256sum -c --quiet SHA256SUMS) || fail "sysext/src inputs do not match their SHA256SUMS"
(cd "$SX/carry" && sha256sum -c --quiet SHA256SUMS) || fail "sysext/carry inputs do not match their SHA256SUMS"
[ -s "$AUTO/lab-patterns.local" ] || err "missing $AUTO/lab-patterns.local (lab identifiers for the secret audit; never committed)"
[ -s "$KEYRING" ] || err "missing $KEYRING"
if [ $DRY = 0 ]; then gh auth status -h github.com >/dev/null 2>&1 || err "gh not logged in"; fi

# ---- official index (signed)
IDX=$AUTO/work/_index; rm -rf "$IDX"; mkdir -p "$IDX"
curl -fsSL --retry 3 -o "$IDX/SHA256SUMS" "$OFF/SHA256SUMS" || err "cannot fetch official SHA256SUMS"
curl -fsSL --retry 3 -o "$IDX/SHA256SUMS.gpg" "$OFF/SHA256SUMS.gpg" || err "cannot fetch official SHA256SUMS.gpg"
gpgv --status-fd 3 --keyring "$KEYRING" "$IDX/SHA256SUMS.gpg" "$IDX/SHA256SUMS" 3>"$IDX/gpg.status" >/dev/null 2>&1 || true
grep -q "^\[GNUPG:\] VALIDSIG $SIGNER " "$IDX/gpg.status" || fail "official SHA256SUMS signature NOT valid for key $SIGNER (key rotated or tampered index)"
say "official index: signature OK ($SIGNER)"
LATEST=$(awk '{print $2}' "$IDX/SHA256SUMS" | sed -n 's/^BengalOS_\(.*\)\.usr-verity-sig\.raw\.xz$/\1/p' | while read -r x; do
  ok=1; for s in usr.raw.xz usr-verity.raw.xz efi.xz; do grep -q " BengalOS_$x\.$s\$" "$IDX/SHA256SUMS" || ok=0; done; [ $ok = 1 ] && echo "$x"; true; done | sort -V | tail -1)
[[ $LATEST =~ $vre ]] || err "could not parse newest official version"
V=${VER:-$LATEST}; [[ $V =~ $vre ]] || err "bad version $V"
grep -q " BengalOS_$V\.usr\.raw\.xz\$" "$IDX/SHA256SUMS" || fail "version $V is not in the official index"
say "official newest: $LATEST; target: $V"

# ---- current feed
FD=$AUTO/work/_feed; rm -rf "$FD"; mkdir -p "$FD"
code=$(curl -sSL --retry 3 -o "$FD/SHA256SUMS" -w '%{http_code}' "$FEED/SHA256SUMS") || err "cannot fetch feed SHA256SUMS"
[ "$code" = 200 ] || { [ "$code" = 404 ] && : > "$FD/SHA256SUMS"; } || err "feed SHA256SUMS http $code"
gh release view $TAG --repo $REPO --json assets -q '.assets[] | "\(.name) \(.size)"' > "$FD/assets" 2>/dev/null || err "cannot list release assets (gh)"
FEEDVERS=$(sed -n 's/.* BengalOS_\(.*\)\.efi\.xz$/\1/p' "$FD/SHA256SUMS" | sort -V | tr '\n' ' ' | sed 's/ $//')
while read -r _ n; do [ -z "$n" ] && continue; grep -q "^$n " "$FD/assets" || fail "feed inconsistent: $n in SHA256SUMS but not a release asset"; done < "$FD/SHA256SUMS"
say "feed versions: ${FEEDVERS:-none}"
wdfix_for() { [ "$(printf '%s\n%s\n' "$1" "$WDFIX_FROM" | sort -V | head -1)" = "$WDFIX_FROM" ]; }
carry_for() { [ "$(printf '%s\n%s\n' "$1" "$CARRY_FROM" | sort -V | head -1)" = "$CARRY_FROM" ]; }
want() { echo "BengalOS_$1.efi.xz"; for n in "${NAMES[@]}"; do echo "${n}_$1.raw.xz"; done; if wdfix_for "$1"; then echo "fp5-waydroid-fix_$1.raw.xz"; fi
  if carry_for "$1"; then for n in "${CARRY[@]}"; do echo "${n}_$1.raw.xz"; done; fi; }
published() { for a in $(want "$1"); do grep -q "  $a\$" "$FD/SHA256SUMS" && grep -q "^$a " "$FD/assets" || return 1; done; }
PUBLISHED=0; published "$V" && PUBLISHED=1
NEWEST_FEED=$(echo "$FEEDVERS" | tr ' ' '\n' | sort -V | tail -1)
if [ $PUBLISHED = 1 ] && [ $FORCE = 0 ]; then status UP_TO_DATE "$V already in the feed; nothing to do"; exit 0; fi
if [ $FORCE = 0 ] && [ -n "$NEWEST_FEED" ] && [ "$(printf '%s\n%s\n' "$V" "$NEWEST_FEED" | sort -V | tail -1)" != "$V" ]; then
  status UP_TO_DATE "feed already has newer $NEWEST_FEED than $V"; exit 0; fi
[ $PUBLISHED = 1 ] && [ $DRY = 0 ] && fail "$V is already published; refusing to re-publish (use --dry-run --force to rebuild/compare)"

# ---- download + verify official artifacts
D=$IMG/$V; mkdir -p "$D"
cp "$IDX/SHA256SUMS" "$D/upstream-SHA256SUMS.sdm845"; cp "$IDX/SHA256SUMS.gpg" "$D/SHA256SUMS.gpg"
for s in usr.raw.xz usr-verity.raw.xz usr-verity-sig.raw.xz manifest osrelease efi.xz; do
  f=BengalOS_$V.$s; exp=$(awk -v n="$f" '$2==n{print $1}' "$IDX/SHA256SUMS"); [ -n "$exp" ] || fail "$f not in official index"
  if [ -f "$D/$f" ] && [ "$(sha256sum < "$D/$f" | cut -d' ' -f1)" = "$exp" ]; then say "have $f (verified)"; continue; fi
  say "download $f"; curl -fSL --retry 3 -s -o "$D/$f.part" "$OFF/$f" || err "download failed: $f"
  [ "$(sha256sum < "$D/$f.part" | cut -d' ' -f1)" = "$exp" ] || { rm -f "$D/$f.part"; fail "checksum mismatch for downloaded $f"; }
  mv "$D/$f.part" "$D/$f"
done
(cd "$D" && grep -E " BengalOS_$V\.(manifest|osrelease|usr\.raw\.xz|usr-verity\.raw\.xz|usr-verity-sig\.raw\.xz)\$" upstream-SHA256SUMS.sdm845 | sha256sum -c > verify.txt) || fail "official artifacts do not verify"
say "official artifacts verified against the signed index"
# carry gates from the signed official manifest
pkgv() { python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); out={}
def w(x):
    if isinstance(x,dict):
        if "name" in x and "version" in x: out[x["name"]]=x["version"]
        for v in x.values(): w(v)
    elif isinstance(x,list):
        for v in x: w(v)
w(m); print(out.get(sys.argv[2],""))' "$D/BengalOS_$V.manifest" "$1"; }
MMV=$(pkgv modemmanager); PHV=$(pkgv phosh)
[ "$MMV" = "$CARRY_MM_PKG" ] || fail "carry: official modemmanager is now '$MMV' (pinned $CARRY_MM_PKG): rebase mm-fp5-keep-ims-bearer (+ 9317cbc4 if missing) onto it and rebuild; never just drop fp5-modemmanager (IMS spare)"
[ "${PHV%%+*}" = "$CARRY_PHOSH_UPSTREAM" ] || fail "carry: official phosh is now '$PHV' (pinned $CARRY_PHOSH_UPSTREAM): rebuild the Frunk plugin against it"
say "carry gates OK (modemmanager $MMV, phosh $PHV)"

W=$AUTO/work/$V; [ -d "$W" ] && docker run --rm --network none -v "$AUTO/work":/x $TOOLS rm -rf "/x/$V"; mkdir -p "$W/out" "$W/report"
SIG=$(xz -dc "$D/BengalOS_$V.usr-verity-sig.raw.xz" | tr -d '\0')
RH=$(jq -r .rootHash <<<"$SIG"); CFP=$(jq -r .certificateFingerprint <<<"$SIG")
[[ $RH =~ ^[0-9a-f]{64}$ ]] || fail "no usr root hash in usr-verity-sig"
[ "$CFP" = $CERT_FP ] || fail "usr-verity-sig certificate changed ($CFP): check the FP5 kernel/keyring still trusts it before publishing"
printf '%s' "$SIG" > "$W/out/usr-verity-sig-$V.json"
say "usr root hash $RH, signing cert unchanged"
xz -T0 -dc "$D/BengalOS_$V.usr.raw.xz" > "$W/usr.raw"; xz -T0 -dc "$D/BengalOS_$V.usr-verity.raw.xz" > "$W/usr-verity.raw"
veritysetup verify "$W/usr.raw" "$W/usr-verity.raw" "$RH" || fail "veritysetup verify failed for the official usr"
say "veritysetup verify OK"

# ---- official UKI: the FP5 cmdline base must still equal the official one
xz -T0 -dc "$D/BengalOS_$V.efi.xz" > "$W/off.efi"
python3 "$AUTO/lib/fp5pe.py" info "$W/off.efi" > "$W/report/official-uki.json"
OFFCMD=$(jq -r .cmdline "$W/report/official-uki.json")
[ "$(jq -r .osrel "$W/report/official-uki.json" | sed -n 's/^VERSION_ID=//p')" = "$V" ] || fail "official UKI .osrel VERSION_ID != $V"
grep -q "usrhash=$RH " <<<"$OFFCMD" || fail "official UKI usrhash != usr-verity-sig rootHash"

# ---- build the FP5 UKI (exactly like 1114.1: panel3 source, build-uki.py)
say "build UKI"
(cd "$O/uki" && python3 build-uki.py "$PANEL3" "$W/out/BengalOS_$V.efi" $PANEL3_VER "$V" "$RH" "$RULE") | tee "$W/report/build-uki.log"
python3 "$AUTO/lib/fp5pe.py" info "$W/out/BengalOS_$V.efi" > "$W/report/fp5-uki.json"
FPCMD=$(jq -r .cmdline "$W/report/fp5-uki.json"); UNAME=$(jq -r .uname "$W/report/fp5-uki.json")
[ "${FPCMD#"$OFFCMD"}" != "$FPCMD" ] || { echo "official: $OFFCMD"; echo "fp5:      $FPCMD"; fail "official UKI cmdline changed vs the FP5 base cmdline (review build-uki.py / panel3 cmdline)"; }
EXTRA=${FPCMD#"$OFFCMD"}
[ "$EXTRA" = " cma=128M pstore.backend=ramoops mem_sleep_default=s2idle qrtr.wake_services=9,5 panic=10 oops=panic softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1 systemd.mask=qbootctl.service systemd.mask=fwupd.service systemd.mask=fwupd-refresh.timer systemd.mask=81voltd.service" ] \
  || fail "FP5 cmdline additions are not the known set: [$EXTRA]"
say "UKI cmdline = official base + known FP5 additions; kernel $UNAME"
PREV=$(ls "$O/sysext/out" | grep -E "$vre" | while read -r p; do [ -f "$O/uki/BengalOS_$p.efi" ] && [ "$(printf '%s\n%s\n' "$p" "$V" | sort -V | head -1)" = "$p" ] && [ "$p" != "$V" ] && echo "$p"; true; done | sort -V | tail -1)
if [ -n "$PREV" ]; then
  python3 "$AUTO/lib/fp5pe.py" cmpsec "$W/out/BengalOS_$V.efi" "$O/uki/BengalOS_$PREV.efi" | tee "$W/report/uki-vs-prev.txt"
  grep -v -E '^\.(osrel|cmdline) ' "$W/report/uki-vs-prev.txt" | grep -q DIFFERS && fail "FP5 UKI differs from $PREV in more than .osrel/.cmdline"
fi

# ---- build the sysexts (exactly like 1114.1: build-sysexts.sh in the tools container, offline)
say "build sysexts (prev=$PREV)"
T=$W/tree; mkdir -p "$T/sysext" "$T/uki"; cp -a "$SX/build-sysexts.sh" "$SX/carry" "$O/sysext/src" "$T/sysext/"; cp "$RULE" "$T/uki/"
docker run --rm --network none -v "$T":/t -w /t/sysext $TOOLS sh -c "sh build-sysexts.sh $V && chown -R $(id -u):$(id -g) /t" | tee "$W/report/build-sysexts.log"

# ---- all checks against the new official usr (offline container)
say "checks"
for n in "${CARRY[@]}"; do [ -s "$T/sysext/out/$V/${n}_$V.raw.xz" ] || fail "carry: ${n}_$V not built"; done
docker run --rm --network none -v "$W":/work -v "$O":/o:ro -v "$AUTO":/auto:ro $TOOLS bash /auto/lib/container-checks.sh "$V" "$UNAME" "$PREV" | tee "$W/report/checks.log"
CLEAN="/work/usrx /work/sxprev /work/ims"; [ $KEEPWORK = 1 ] || CLEAN="$CLEAN /work/aud /work/sx /work/sxc"
docker run --rm --network none -v "$W":/work $TOOLS sh -c "rm -rf $CLEAN; chown -R $(id -u):$(id -g) /work"
WARNS=$(wc -l < "$W/report/warnings")
if [ $BASELINE = 1 ]; then
  cp "$W/report/audit-hits.txt" "$W/report/shadow.txt" "$AUTO/baseline/"; say "BASELINE written from $V (human-reviewed run only)"
fi
if [ -s "$W/report/failures" ]; then fail "$(wc -l < "$W/report/failures") check(s) failed: $(paste -sd';' "$W/report/failures")"; fi
say "all checks passed ($WARNS warning(s))"

# ---- waydroid cache fix: fp5-waydroid-fix_<V> from base usr + the official waydroid sysext (signed index, sha256)
WDN=BengalOS-waydroid-sysext_$V.raw.xz
wexp=$(awk -v n="$WDN" '$2==n{print $1}' "$IDX/SHA256SUMS"); [ -n "$wexp" ] || fail "$WDN not in the official index (waydroid feature gone? review 34-fp5-waydroid-fix.transfer)"
if [ -f "$D/$WDN" ] && [ "$(sha256sum < "$D/$WDN" | cut -d' ' -f1)" = "$wexp" ]; then say "have $WDN (verified)"
else say "download $WDN"; curl -fSL --retry 3 -s -o "$D/$WDN.part" "$OFF/$WDN" || err "download $WDN failed"; mv "$D/$WDN.part" "$D/$WDN"; fi
[ "$(sha256sum < "$D/$WDN" | cut -d' ' -f1)" = "$wexp" ] || fail "$WDN does not match the signed official index"
[ -f "$W/usr.raw" ] || err "$W/usr.raw missing (needed for the waydroid fix)"
xz -dc "$D/$WDN" > "$W/wd.raw"
say "build fp5-waydroid-fix $V"
if ! docker run --rm --network none -v "$W":/work -v "$O":/o:ro $WDTOOLS sh -c \
    "sh /o/waydroid/build-waydroid-fix.sh $V /work/usr.raw /work/wd.raw /work/tree/sysext/out/$V /work/wdfix; rc=\$?; rm -rf /work/wdfix/usr /work/wdfix/wd /work/wdfix/fix /work/wdfix/wd-root.raw; chown -R $(id -u):$(id -g) /work; exit \$rc" \
    | tee "$W/report/waydroid-fix.log"; then
  rm -f "$W/wd.raw"; fail "waydroid fix: $(paste -sd';' "$W/wdfix/report/waydroid-fix-failures" 2>/dev/null || echo 'build failed, see report/waydroid-fix.log')"
fi
rm -f "$W/wd.raw"
grep -q '^effective overlay: .*mobi.phosh.phoc present' "$W/report/waydroid-fix.log" || fail "waydroid fix: effective schema check did not run/pass"
[ -s "$T/sysext/out/$V/fp5-waydroid-fix_$V.raw.xz" ] || fail "waydroid fix: fp5-waydroid-fix_$V.raw.xz not built"
say "waydroid fix OK: $(grep '^== waydroid fix' "$W/report/waydroid-fix.log")"

# ---- carried-fixes guard (fail closed, including --dry-run)
# Runs on the built set in $T/sysext/out/$V, before staging and before DRYRUN_OK
# or publish. Profile feed is the sysexts this pipeline builds (the spare-IMS
# string, MM#1110, frunk, waydroid-fix, qtee, ims-app, device, and volte-modules
# when $UNAME is the volte kernel). Profile daily, the default, also requires
# phoc, phosh, and gnome-calls. See docs/CARRIED-FIXES.md.
CF_CHECK=$(cd "$SX/../.." && pwd)/scripts/check-carried-fixes-sysexts
[ -x "$CF_CHECK" ] || fail "carried-fixes: $CF_CHECK missing"
say "carried-fixes guard"
if ! "$CF_CHECK" "$T/sysext/out/$V" --profile feed --version "$V" --kernel-uname "$UNAME" \
    | tee "$W/report/carried-fixes.log"; then
  reason=$(grep -E '^(MISSING|UNREADABLE):' "$W/report/carried-fixes.log" | paste -sd';' - || true)
  fail "carried-fixes: ${reason:-a required marker is missing under $T/sysext/out/$V}"
fi
say "carried-fixes guard OK"

# ---- stage feed assets
S=$W/feed; mkdir -p "$S"
xz -T0 -9 -c "$W/out/BengalOS_$V.efi" > "$S/BengalOS_$V.efi.xz"
cp "$T/sysext/out/$V/"*.raw.xz "$S/"
wdfix_for "$V" || rm -f "$S/fp5-waydroid-fix_$V.raw.xz"     # 1114.1: not part of the published set
carry_for "$V" || for n in "${CARRY[@]}"; do rm -f "$S/${n}_$V.raw.xz"; done   # built+checked, published from $CARRY_FROM
(cd "$S" && sha256sum $(want "$V") > SHA256SUMS.part)
cat "$FD/SHA256SUMS" "$S/SHA256SUMS.part" | awk 'NF==2' | sort -u -k2,2 > "$S/SHA256SUMS.merged"
[ "$(awk '{print $2}' "$S/SHA256SUMS.merged" | sort | uniq -d)" = "" ] || fail "merged index has duplicate names with different hashes"
ALLV=$(sed -n 's/.* BengalOS_\(.*\)\.efi\.xz$/\1/p' "$S/SHA256SUMS.merged" | sort -V)
PRUNEV=; [ $PRUNE = 1 ] && PRUNEV=$(echo "$ALLV" | head -n -"$KEEP" | tr '\n' ' ')
cp "$S/SHA256SUMS.merged" "$S/SHA256SUMS"
for p in $PRUNEV; do grep -v -E " (BengalOS|fp5-[a-z-]+)_${p//./\\.}\.(efi|raw)\.xz\$" "$S/SHA256SUMS" > "$S/x" && mv "$S/x" "$S/SHA256SUMS"; done
say "new feed index ($(wc -l < "$S/SHA256SUMS") assets; prune: ${PRUNEV:-none}):"; cat "$S/SHA256SUMS"
if [ $PUBLISHED = 1 ]; then
  if diff <(sort -k2 "$S/SHA256SUMS.part") <(grep -F -f <(want "$V") "$FD/SHA256SUMS" | sort -k2) >/dev/null; then say "REPRODUCIBLE: rebuilt $V assets are byte-identical to the published ones"; REPRO=identical
  else say "rebuilt $V assets differ from the published ones:"; diff <(sort -k2 "$S/SHA256SUMS.part") <(grep -F -f <(want "$V") "$FD/SHA256SUMS" | sort -k2) || true; REPRO=different; fi
fi

if [ $DRY = 1 ]; then
  [ $KEEPWORK = 1 ] || rm -f "$W/usr.raw" "$W/usr-verity.raw" "$W/off.efi"
  status DRYRUN_OK "$V built and all checks passed; nothing uploaded${REPRO:+; rebuild $REPRO to published}; staged in $S"; exit 0
fi

# ---- publish: assets first, index last (clients only see a version once the index lists it), then prune
say "upload $V assets"
gh release upload $TAG --repo $REPO --clobber $(for a in $(want "$V"); do echo "$S/$a"; done) || err "asset upload failed (index untouched; next run retries)"
for a in $(want "$V"); do
  got=$(curl -fsSL --retry 3 "$FEED/$a" | sha256sum | cut -d' ' -f1); exp=$(awk -v n="$a" '$2==n{print $1}' "$S/SHA256SUMS")
  [ "$got" = "$exp" ] || err "uploaded $a does not match (got $got); index untouched"
done
say "upload SHA256SUMS"
gh release upload $TAG --repo $REPO --clobber "$S/SHA256SUMS" || err "SHA256SUMS upload failed (new assets are present but not offered yet)"
# the release-download CDN can serve the previous index for a while: retry with backoff (~5 min total), cache-busted
ok=0; for d in 5 10 20 40 80 160; do sleep $d
  if curl -fsSL --retry 3 "$FEED/SHA256SUMS?nocache=$(date +%s%N)" | cmp -s - "$S/SHA256SUMS"; then ok=1; break; fi
  say "published SHA256SUMS not visible yet (waited ${d}s more)"; done
[ $ok = 1 ] || err "published SHA256SUMS does not match staged index after ~5 min (CDN or upload problem)"
for p in $PRUNEV; do for a in $(want "$p"); do
  grep -q "^$a " "$FD/assets" && { say "prune $a"; gh release delete-asset $TAG "$a" --repo $REPO -y || WARNS=$((WARNS+1)); }; done; done
# local records, same layout as 1113.1/1114.1
cp "$W/out/BengalOS_$V.efi" "$O/uki/"; cp "$W/out/usr-verity-sig-$V.json" "$O/uki/"
rm -rf "$O/sysext/out/$V"; cp -a "$T/sysext/out/$V" "$O/sysext/out/$V"
mkdir -p "$O/feed/$V"; cp "$S"/*.xz "$O/feed/$V/"; cp "$S/SHA256SUMS.part" "$O/feed/$V/"
cp "$S"/*.xz "$O/feed/release-staging/"; cp "$S/SHA256SUMS" "$O/feed/release-staging/SHA256SUMS"
cp "$W/report/checks.log" "$O/logs/check-$V.auto.log"
[ $KEEPWORK = 1 ] || rm -f "$W/usr.raw" "$W/usr-verity.raw" "$W/off.efi"
status PUBLISHED "$V published to $TAG ($WARNS warning(s)); pruned: ${PRUNEV:-none}. The phone updates only when Kristian runs sysupdate."
exit 0
