#!/bin/bash
# Runs INSIDE fp5-official-tools (offline, --network none). Mounts: /work (rw, per-version scratch), /o (ro, official-20261114).
# usage: container-checks.sh V UNAME PREV
# Writes /work/report/{failures,warnings,audit-hits.txt,shadow.txt,checks.log}. Exit 0 always unless the script itself breaks;
# the host decides from /work/report/failures.
set -uo pipefail
V=$1 UNAME=$2 PREV=$3
W=/work; R=$W/report; L=/o/auto/lib; mkdir -p $R; : > $R/failures; : > $R/warnings
F() { echo "FAIL: $*"; echo "$*" >> $R/failures; }
WARN() { echo "WARN: $*"; echo "$*" >> $R/warnings; }
OUT=$W/tree/sysext/out/$V; NAMES="fp5-volte-modules fp5-qtee fp5-ims-app fp5-device"
echo "== [1] extract official usr ($V)"
U=$W/usrx; rm -rf $U; mkdir -p $U
fsck.erofs --extract=$U $W/usr.raw >/dev/null 2>&1 || F "official usr: erofs extract/fsck failed"
echo "files: $(find $U -type f | wc -l)"
echo "== [2] usr os-release"
grep -E '^(ID|VERSION_ID|IMAGE_VERSION|VARIANT_ID|SYSEXT_LEVEL)=' $U/lib/os-release
grep -qx 'ID=bengalos' $U/lib/os-release || F "usr os-release ID is not bengalos"
grep -qx "VERSION_ID=$V" $U/lib/os-release || F "usr os-release VERSION_ID != $V (sysext matching would fail)"
grep -q '^SYSEXT_LEVEL=' $U/lib/os-release && F "usr os-release now has SYSEXT_LEVEL (FP5 sysexts match on VERSION_ID; review build-sysexts.sh)"
echo "== [3] FP5 kernel modules vs usr"
ls $U/lib/modules 2>/dev/null | sed 's/^/usr ships modules: /'
[ -e "$U/lib/modules/$UNAME" ] && F "official usr now ships /usr/lib/modules/$UNAME (would collide with fp5-volte-modules)"
echo "== [4] sysexts: fsck, extract, extension-release, xz==raw"
for n in $NAMES; do
  f=$OUT/${n}_$V.raw; X=$W/sx/${n}_$V; rm -rf $X; mkdir -p $X
  [ -f "$f" ] || { F "sysext $n missing"; continue; }
  fsck.erofs "$f" >/dev/null 2>&1 || F "sysext $n: fsck.erofs failed"
  fsck.erofs --extract=$X "$f" >/dev/null 2>&1
  er=$X/usr/lib/extension-release.d/extension-release.${n}_$V
  if [ -f "$er" ]; then
    grep -qx 'ID=bengalos' "$er" && grep -qx "VERSION_ID=$V" "$er" && grep -qx 'ARCHITECTURE=arm64' "$er" || F "sysext $n: extension-release content wrong"
    [ "$(ls $X/usr/lib/extension-release.d | wc -l)" = 1 ] || F "sysext $n: more than one extension-release file"
  else F "sysext $n: extension-release.${n}_$V missing"; fi
  cmp -s <(xz -dc "$f.xz") "$f" && echo "xz==raw $n" || F "sysext $n: .raw.xz does not decompress to .raw"
  echo "$n: $(find $X -type f | wc -l) files"
done
M=$W/sx/fp5-volte-modules_$V/usr/lib/modules
[ -d "$M/$UNAME" ] && { [ -s "$M/$UNAME/modules.dep" ] || [ -s "$M/$UNAME/modules.dep.bin" ]; } || F "fp5-volte-modules has no module tree/modules.dep for UKI kernel $UNAME"
[ "$(ls $M 2>/dev/null)" = "$UNAME" ] || F "fp5-volte-modules module dirs ($(ls $M | tr '\n' ' ')) != UKI kernel $UNAME"
echo "volte-modules: $(find $M -name '*.ko*' | wc -l) modules for $UNAME"
echo "== [5] payload identical to $PREV (only extension-release may differ)"
if [ -n "$PREV" ]; then
  for n in $NAMES; do
    P=$W/sxprev/$n; rm -rf $P; mkdir -p $P
    fsck.erofs --extract=$P /o/sysext/out/$PREV/${n}_$PREV.raw >/dev/null 2>&1 || { F "cannot extract previous $n $PREV"; continue; }
    d=$(diff -rq --no-dereference -x extension-release.d $P $W/sx/${n}_$V 2>&1)
    # A reviewed, intended payload change is accepted only if the WHOLE new payload equals the pinned manifest
    # auto/baseline/sysext-payload/$n.sha256 (2026-11-15: fp5-qtee + pam_fprintd.so + factory pam.d/polkit-1, fp5-qtee PR #11). Anything else fails.
    A=/o/auto/baseline/sysext-payload/$n.sha256
    man() { (cd "$1" && find . -path ./usr/lib/extension-release.d -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
             find . -type l -printf "%p -> %l\n" | LC_ALL=C sort); }
    if [ -z "$d" ]; then echo "same-payload-as-$PREV $n"
    elif [ -f "$A" ] && diff -q <(man $W/sx/${n}_$V) "$A" >/dev/null; then
      echo "$d" | head; WARN "sysext $n payload differs from $PREV but equals the reviewed manifest auto/baseline/sysext-payload/$n.sha256"
    else echo "$d" | head; F "sysext $n payload differs from $PREV"; fi
  done
else WARN "no previous version to compare sysext payloads"; fi
echo "== [5b] fp5-qtee factory pam.d/polkit-1 vs $V usr (it shadows the stock polkit-1 PAM file)"
QP=$W/sx/fp5-qtee_$V/usr/share/factory/etc/pam.d/polkit-1
if [ -f "$QP" ]; then
  [ -e $U/share/factory/etc/pam.d/polkit-1 ] && F "official usr now ships share/factory/etc/pam.d/polkit-1 itself (fp5-qtee would shadow it; review)"
  [ -d $U/share/factory/etc/pam.d ] || F "official usr has no share/factory/etc/pam.d (the /etc/pam.d symlink target moved; fp5-qtee polkit-1 would be ignored)"
  if [ -f $U/lib/pam.d/polkit-1 ] && diff <(grep -v "^#" "$QP" | grep -v pam_fprintd) <(grep -v "^#" $U/lib/pam.d/polkit-1); then
    echo "polkit-1 = stock $V polkit-1 + pam_fprintd line"
  else F "fp5-qtee polkit-1 no longer matches the stock $V usr/lib/pam.d/polkit-1 (copy the new stock body into the fp5-qtee polkit-1)"; fi
fi
echo "== [6] ELF ABI (DT_NEEDED + symbol versions) vs $V usr"
rm -rf $W/ims; mkdir -p $W/ims; tar -C $W/ims -xzf /o/test/opt/imsd-debian-arm64.tar.gz
python3 $L/elfcheck.py $U --libdir $W/ims/imsd-debian-arm64/lib -- $W/sx $W/ims /o/test/opt || F "ELF ABI check failed against $V usr"
echo "== [7] python imports of FP5 scripts vs $V usr"
python3 $L/pydeps.py $U $W/sx/* || F "python import check failed against $V usr"
echo "== [8] systemd units of FP5 sysexts vs $V usr"
python3 $L/unitcheck.py $U $W/sx/* || F "unit check failed against $V usr"
echo "== [9] official usr sysupdate.d vs baseline (1114.1)"
B=/o/auto/baseline/usr-sysupdate.d
for f in $(cd $U/lib/sysupdate.d && ls) ; do
  if [ ! -f "$B/$f" ]; then WARN "new official transfer/feature $f (review: non-gated new transfers must also exist for FP5)"
  elif ! cmp -s "$B/$f" "$U/lib/sysupdate.d/$f"; then
    diff -u "$B/$f" "$U/lib/sysupdate.d/$f" | head -30
    case $f in 20-uki.transfer) F "official 20-uki.transfer changed: review the FP5 /etc override before publishing";;
               waydroid.transfer|waydroid.feature) F "official $f changed: review sysupdate.d/34-fp5-waydroid-fix.transfer (Features=waydroid, name pattern)";;
               1[0-9]-*.transfer) WARN "official usr transfer $f changed";;
               *) WARN "official $f changed";; esac
  fi
done
for f in $(cd $B && ls); do [ -f "$U/lib/sysupdate.d/$f" ] || WARN "official $f removed"; done
echo "== [10] secret audit (FP5 UKI sections + every initrd segment + all sysexts)"
A=$W/aud; rm -rf $A; mkdir -p $A/uki
python3 $L/fp5pe.py split-initrd $W/out/BengalOS_$V.efi $A/uki/parts
for s in $A/uki/parts/seg*; do D=$A/uki/x_$(basename $s); mkdir -p $D
  case $s in *.zst) zstd -dc $s | (cd $D && cpio -idm --quiet 2>/dev/null);; *) (cd $D && cpio -idm --quiet < $s 2>/dev/null);; esac
  echo "$(basename $s): $(find $D -type f | wc -l) files"; done
ln -s ../sx $A/sx
cd $A || exit 2
# lab identifiers live in the untracked lab-patterns.local (name<TAB>regex), not in this public repo
LABP=${FP5_LAB_PATTERNS:-/auto/lab-patterns.local}; export FP5_LAB_PATTERNS=$LABP
[ -s "$LABP" ] || F "secret audit: lab pattern file $LABP missing"
HARD="OPENSSH PRIVATE KEY|BEGIN (RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY|BEGIN PGP PRIVATE KEY BLOCK|$(grep -v '^#' "$LABP" 2>/dev/null | cut -f2 | paste -sd'|')|psk=|wpa-psk"
{
  echo "# name hits"
  find -L . \( -iname '*authorized_keys*' -o -iname 'ssh_host_*' -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname '*fp5_pmos*' -o -iname '*.nmconnection' -o -iname 'wpa_supplicant*.conf' -o -iname '*sim-pin*' -o -iname '*.pem' -o -iname '*.key' -o -iname 'shadow*' -o -iname 'gshadow*' -o -iname 'passwd*' -o -iname '*.psk' \) -print | LC_ALL=C sort
  echo "# content hits"
  grep -RlaE -- "$HARD|ssh-(ed25519|rsa) AAAA|ecdsa-sha2-nistp256 AAAA" . 2>/dev/null | LC_ALL=C sort
  echo "# password-ish text"
  grep -RIl -i -E '(password|passwd|secret|pin)[[:space:]]*[:=][[:space:]]*[^[:space:]$]' . 2>/dev/null | LC_ALL=C sort
  echo "# IMEI/ICCID/IMSI-like digit runs"
  grep -RIl -E '\b(35[0-9]{13}|86[0-9]{13}|89[0-9]{17,18})\b' . 2>/dev/null | LC_ALL=C sort
  echo "# MAC-like"
  grep -RIl -E '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' . 2>/dev/null | LC_ALL=C sort
} | sed "s#$V#@V@#g" > $R/audit-hits.txt
echo "audit hit lines: $(grep -vc '^#' $R/audit-hits.txt)"
# hard patterns (binary-safe, real key material only; magic strings in libgio/mime db are not keys)
python3 $L/secretscan.py . | tee $R/hard-hits.txt
[ -s $R/hard-hits.txt ] && F "secret audit: hard hit (private key / ssh key / serial / lab path / psk) in FP5 artifacts"
find -L . \( -iname 'ssh_host_*' -o -iname '*authorized_keys*' -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname '*.nmconnection' -o -iname '*.psk' -o -iname '*sim-pin*' \) | grep -q . && F "secret audit: SSH key / Wi-Fi / SIM-PIN file in FP5 artifacts"
if ! diff -u /o/auto/baseline/audit-hits.txt $R/audit-hits.txt; then F "secret audit: hit list differs from the reviewed 1114.1 baseline (see diff above)"; else echo "audit hits == reviewed baseline"; fi
# shadow: only the accepted upstream root hash (fingerprint only, never the hash itself)
python3 - "$A" > $R/shadow.txt <<'P'
import glob,hashlib,sys,os
for f in sorted(glob.glob(sys.argv[1]+'/**/etc/*shadow*',recursive=True)):
    for l in open(f,errors='replace'):
        p=l.rstrip('\n').split(':')
        if len(p)>1 and p[1] and p[1][0] not in '!*':
            print(os.path.relpath(f,sys.argv[1]).replace('\\n',''), p[0], 'hashfp='+hashlib.sha256(p[1].encode()).hexdigest()[:16])
P
sed -i "s#$V#@V@#g" $R/shadow.txt; cat $R/shadow.txt
diff -u /o/auto/baseline/shadow.txt $R/shadow.txt >/dev/null || F "secret audit: password hashes differ from the accepted upstream root hash baseline"
echo "== done: $(wc -l < $R/failures) failures, $(wc -l < $R/warnings) warnings"
