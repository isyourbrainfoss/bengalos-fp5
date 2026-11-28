# sc7280 feed staging

This is the publish path for Fairphone 5 images built as variant `sc7280`
(desk kernel `7.2.8-sc7280-fp5+`). It replaces `feed/auto/fp5-feed-auto.sh`
for those versions.

`feed/auto/fp5-feed-auto.sh` is the old sdm845 lineage (official usr plus the
volte UKI). The Saturday job still runs the copy under
`official-20261114/auto/`. That script now exits `CHECK_FAILED` as soon as
the fp5-feed index contains a `BengalOS_*.usr.raw.xz`, and it publishes
nothing. New versions are staged here.

## Stage

```sh
feed/sc7280/stage-release.sh --version 0.26.1127.1 \
  --image-dir DIR --sysext-dir DIR --uki FILE [--usr-tree DIR]
```

`--dry-run` is the default. `--publish` uploads to the `fp5-feed` GitHub
release (assets first, `SHA256SUMS` last). The desk build does not publish.

The release directory contains every asset as `.xz`, each under 2 GiB, and a
`SHA256SUMS` that keeps every name already in the current fp5-feed index and
adds:

- `BengalOS_<version>.efi.xz`
- `BengalOS_<version>.usr.raw.xz`
- `BengalOS_<version>.usr-verity.raw.xz`
- `BengalOS_<version>.usr-verity-sig.raw.xz`
- `BengalOS-waydroid-sysext_<version>.raw.xz`
- `fp5-modemmanager`, `fp5-frunk-qs`, `fp5-phoc`, `fp5-phosh`, `fp5-gnome-calls`,
  `fp5-waydroid-fix`, `fp5-device`, `fp5-ims-app`, `fp5-qtee` (`_<version>.raw.xz`)

There is no `fp5-volte-modules` asset. That sysext belongs to the volte kernel.

## Gates

The script stops, and does not upload, unless all of these pass:

- `scripts/check-carried-fixes` on the sysext directory, profile `daily`,
  with `--uki`. `fp5-volte-modules` is skipped for `7.2.8-sc7280-fp5+`.
  `fp5-pstore-ramoops-image` checks the default cmdline, the ramoops DTB
  node, and the kernel config. `oops=panic` fails the gate.
- The same image check against `--usr-tree` when that directory is passed.
- `feed/auto/tests/carry-reviewed.sh` (the keep-IMS daemon and its patch are
  the only reviewed payload delta).
- Every asset is smaller than 2 GiB.
- A secret audit of the staged files. It uses
  `internal-install/feed-auto-live/feed/auto/lab-patterns.local` and prints
  rule names and counts only.

A red gate is a stop. Do not weaken the check to make the release pass.
