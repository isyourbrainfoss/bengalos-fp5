# Daily 1124.3 sysext set

The build scripts for `0.26.1124.3` live on `feat/upstream-sc7280-sysexts-1124.3`.
This branch does not copy them. Before that path publishes or installs a sysext
set, run the carried-fixes guard and stop if it fails:

```sh
scripts/check-carried-fixes-sysexts "$SYSEXT_DIR" --version "$VERSION_ID" --kernel-uname "$UNAME" || exit 1
```

The default profile is `daily`. For a 1124.3 image pass
`--kernel-uname 7.2.8-sc7280-fp5+` so `fp5-volte-modules` is skipped. The
ModemManager raw must contain the UTF-8 string `sparing IMS bearer`. The
0.26.1124.3 raw that was retagged from the 15 Nov daemon does not, and the
check must fail closed on it. See `docs/CARRIED-FIXES.md`.
