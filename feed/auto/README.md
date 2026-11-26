# fp5-feed-auto (desk only, never touches the phone)

Keeps the FP5 sysupdate feed (GitHub release `fp5-feed` in isyourbrainfoss/bengalos-fp5) in step with official
BengalOS (`https://bengalos.phosh.mobi/images/roaming/arm64/sdm845/`), built exactly like 0.26.1114.1 on 2026-11-15
(the 1114.1 rebuild by this script is byte-identical to the published assets).

    bash <desk>/official-20261114/auto/fp5-feed-auto.sh            # daily run
    bash .../auto/fp5-feed-auto.sh --dry-run                                                         # build + checks, no upload
    bash .../auto/fp5-feed-auto.sh --dry-run --version 0.26.1114.1 --force                           # rebuild a published version

Exit 0 = UP_TO_DATE / PUBLISHED / DRYRUN_OK, 1 = CHECK_FAILED (needs a human, nothing published), 2 = ERROR
(network/tooling, retry next day), 3 = already running. Last result: `../logs/auto/STATUS`; one line per run:
`../logs/auto/history.log`; full logs `../logs/auto/run-*.log` (kept 60 days); per-version reports `work/<v>/report/`.

Steps: signed official index (gpgv, key C0B91FCC..., pinned keyring `keys/` taken from the 1114.1 usr) -> newest
version with usr+verity+sig+efi -> no-op if the feed already lists it -> download + sha256 against the signed index
-> usr-verity-sig cert pinned -> veritysetup verify -> UKI via `../uki/build-uki.py` from the panel3 source (sha pinned)
-> official cmdline must be the exact base of the FP5 cmdline, FP5 additions must be the known set, only .osrel/.cmdline
may differ from the previous FP5 UKI -> sysexts via `../sysext/build-sysexts.sh` in fp5-official-tools (offline)
-> `lib/container-checks.sh`: usr os-release (ID, VERSION_ID, no SYSEXT_LEVEL), usr must not ship the FP5 kernel's
module dir, volte-modules must match the UKI kernel, sysext payloads identical to the previous version, ELF NEEDED +
symbol versions (qtee, imsd, /opt libs) vs the new usr, python imports of the qtee scripts, unit Exec/drop-in targets,
official sysupdate.d vs `baseline/` (20-uki.transfer change = stop), secret audit (hard scan for real keys, SSH keys,
serial, lab paths, PSKs; hit list and shadow fingerprint must equal the reviewed 1114.1 baseline)
-> publish: 5 assets, verify each by download, then SHA256SUMS last, then prune (keep newest 3 versions, `--keep N`).

Needs a human when: CHECK_FAILED (read the STATUS reason), the official signing key or verity cert rotates, the
official cmdline or 20-uki.transfer changes, the FP5 kernel/module payload itself must change (new panel3 UKI or new
sysext/src inputs: update the pins in fp5-feed-auto.sh and re-baseline with a reviewed run), or the GitHub token expires.

Waydroid (2026-11-15): every run also builds `fp5-waydroid-fix_<V>` (see `../waydroid/README.md`): official waydroid
sysext downloaded + sha256-checked, caches regenerated from base usr + waydroid in `fp5-waydroid-fix-tools:20261115`,
effective schema set must contain every base schema incl. mobi.phosh.phoc; any failure = CHECK_FAILED. Published as a
6th asset for versions > 0.26.1114.1. A change to the official waydroid.transfer/feature also stops the run.

Carry (2026-11-19): every run also builds `fp5-modemmanager_<V>` (MM#1110 daemon) and `fp5-frunk-qs_<V>` (Frunk tile)
from `../sysext/carry/` (pinned, see PROVENANCE.md). These two used to be re-pinned by hand on the phone for every
version. Fail closed, so the version is not published, if:
- the inputs' sha256 do not match;
- official modemmanager is not 1.25.95-1 (check for 9317cbc4 and drop the sysext);
- official phosh is not 0.59.0 (rebuild the plugin);
- a carry raw is missing;
- fsck, extension-release or xz==raw fails;
- the payload differs from the previous version's carry build;
- any undefined symbol does not resolve against the new /usr (`lib/symcheck.py`).

They are also covered by the ELF, python, unit and secret checks. They are published from `CARRY_FROM` (0.26.1119.1).
The phone needs `../sysupdate.d/35-fp5-modemmanager.transfer` and `36-fp5-frunk-qs.transfer` in /etc/sysupdate.d.
Install those only once the feed offers both for the candidate version.

Review checkout: `FP5_FEED_O=<live official-20261114> FP5_FEED_LOGD=<scratch> bash feed/auto/fp5-feed-auto.sh --dry-run ...`.
This uses this checkout's script, lib, build-sysexts.sh and carry, and the live uki/, sysext/src+out, baseline and waydroid.
The lab identifiers for the secret audit live in the untracked `auto/lab-patterns.local` (name<TAB>regex).

Post-upload index compare: 6 tries with backoff (5..160 s, about 5 min), cache-busted, instead of a single `sleep 5`.
This failed with ERROR on 15, 17, 18 and 19 Nov.
