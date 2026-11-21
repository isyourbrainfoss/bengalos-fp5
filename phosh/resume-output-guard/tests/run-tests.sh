#!/bin/sh
# Offline tests for the resume output guard. No phone, no real systemctl.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tests=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail=0

check() {
    name=$1
    shift
    if "$@"; then
        printf 'ok  %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name" >&2
        fail=1
    fi
}

# --- wait helper: already ready (one probe, no sleep loop) ---
ready_once() {
    tmp=$(mktemp -d)
    count=$tmp/count
    printf '0\n' > "$count"
    probe=$tmp/probe
    cat > "$probe" <<'EOF'
#!/bin/sh
n=$(cat "$FP5_COUNT")
printf '%s\n' "$((n + 1))" > "$FP5_COUNT"
exit 0
EOF
    chmod 0755 "$probe"
    FP5_COUNT=$count FP5_WAIT_OUTPUT_PROBE=$probe FP5_WAIT_OUTPUT_TIMEOUT=5 \
        "$root/fp5-phosh-wait-output" >/dev/null
    n=$(cat "$count")
    rm -rf "$tmp"
    [ "$n" -eq 1 ]
}

# --- wait helper: timeout still exits 0 ---
timeout_ok() {
    tmp=$(mktemp -d)
    count=$tmp/count
    printf '0\n' > "$count"
    probe=$tmp/probe
    cat > "$probe" <<'EOF'
#!/bin/sh
n=$(cat "$FP5_COUNT")
printf '%s\n' "$((n + 1))" > "$FP5_COUNT"
exit 1
EOF
    chmod 0755 "$probe"
    log=$tmp/log
    start=$(date +%s)
    FP5_COUNT=$count FP5_WAIT_OUTPUT_PROBE=$probe FP5_WAIT_OUTPUT_TIMEOUT=1 \
        FP5_WAIT_OUTPUT_INTERVAL=0.2 \
        "$root/fp5-phosh-wait-output" >"$log" 2>&1
    rc=$?
    end=$(date +%s)
    n=$(cat "$count")
    elapsed=$((end - start))
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] && [ "$n" -ge 2 ] && [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 3 ]
}

# --- wait helper: fails twice, then ready ---
becomes_ready() {
    tmp=$(mktemp -d)
    count=$tmp/count
    printf '0\n' > "$count"
    probe=$tmp/probe
    cat > "$probe" <<'EOF'
#!/bin/sh
n=$(cat "$FP5_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$FP5_COUNT"
if [ "$n" -ge 3 ]; then
    exit 0
fi
exit 1
EOF
    chmod 0755 "$probe"
    FP5_COUNT=$count FP5_WAIT_OUTPUT_PROBE=$probe FP5_WAIT_OUTPUT_TIMEOUT=5 \
        FP5_WAIT_OUTPUT_INTERVAL=0.2 \
        "$root/fp5-phosh-wait-output" >/dev/null
    n=$(cat "$count")
    rm -rf "$tmp"
    [ "$n" -eq 3 ]
}

# --- missing probe does not burn the timeout ---
missing_probe() {
    tmp=$(mktemp -d)
    log=$tmp/log
    start=$(date +%s)
    FP5_WAIT_OUTPUT_PROBE=$tmp/does-not-exist FP5_WAIT_OUTPUT_TIMEOUT=20 \
        "$root/fp5-phosh-wait-output" >"$log" 2>&1
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] && [ "$elapsed" -le 1 ]
}

setup_fake_path() {
    work=$1
    mkdir -p "$work/bin" "$work/home/.config/systemd/user/mobi.phosh.Shell.service.d" \
        "$work/home/.local/bin"
    cp "$tests/fake-id" "$work/bin/id"
    cp "$tests/fake-systemctl" "$work/bin/systemctl"
    chmod 0755 "$work/bin/id" "$work/bin/systemctl"
    printf 'seventy\n' > "$work/home/.config/systemd/user/mobi.phosh.Shell.service.d/70-fp5-respawn.conf"
    printf 'lights\n' > "$work/home/.config/systemd/user/mobi.phosh.Shell.service.d/ha-lights.conf"
    printf 'wrapper\n' > "$work/home/.local/bin/fp5-phosh-respawn"
    chmod 0755 "$work/home/.local/bin/fp5-phosh-respawn"
}

# --- dry-run writes nothing ---
dry_run_clean() {
    work=$(mktemp -d)
    setup_fake_path "$work"
    log=$work/systemctl.log
    : > "$log"
    PATH="$work/bin:$PATH" HOME="$work/home" FAKE_USER=fp5 FAKE_UID=1000 \
        XDG_STATE_HOME="$work/home/.local/state" SYSTEMCTL_LOG="$log" \
        "$root/install.sh" --dry-run >/dev/null
    state=$work/home/.local/state/fp5-phosh-resume-guard
    if [ -d "$state" ]; then
        rm -rf "$work"
        return 1
    fi
    if [ -f "$work/home/.config/systemd/user/mobi.phosh.Shell.service.d/80-fp5-resume-output-guard.conf" ]; then
        rm -rf "$work"
        return 1
    fi
    if [ -s "$log" ]; then
        rm -rf "$work"
        return 1
    fi
    rm -rf "$work"
    return 0
}

# --- root is refused, even for dry-run ---
refuse_root() {
    work=$(mktemp -d)
    setup_fake_path "$work"
    log=$work/systemctl.log
    : > "$log"
    set +e
    PATH="$work/bin:$PATH" HOME="$work/home" FAKE_USER=root FAKE_UID=0 \
        SYSTEMCTL_LOG="$log" \
        "$root/install.sh" --dry-run >/dev/null 2>&1
    rc=$?
    set -e
    rm -rf "$work"
    [ "$rc" -eq 1 ]
}

# --- install + rollback, neighbours intact, only daemon-reload ---
install_and_rollback() {
    work=$(mktemp -d)
    setup_fake_path "$work"
    log=$work/systemctl.log
    : > "$log"
    unit=$work/home/.config/systemd/user/mobi.phosh.Shell.service.d
    seventy_before=$(sha256sum "$unit/70-fp5-respawn.conf")
    lights_before=$(sha256sum "$unit/ha-lights.conf")
    wrap_before=$(sha256sum "$work/home/.local/bin/fp5-phosh-respawn")
    PATH="$work/bin:$PATH" HOME="$work/home" FAKE_USER=fp5 FAKE_UID=1000 \
        XDG_STATE_HOME="$work/home/.local/state" SYSTEMCTL_LOG="$log" \
        "$root/install.sh" >/dev/null
    drop=$unit/80-fp5-resume-output-guard.conf
    [ -f "$drop" ]
    [ -x "$work/home/.local/bin/fp5-phosh-wait-output" ]
    [ -x "$work/home/.local/bin/fp5-phosh-output-ready" ]
    grep -q "$work/home/.local/bin/fp5-phosh-wait-output" "$drop"
    grep -q 'StartLimitBurst=4' "$drop"
    grep -q 'RestartSec=2' "$drop"
    [ "$(cat "$log")" = "--user daemon-reload" ]
    [ "$(sha256sum "$unit/70-fp5-respawn.conf")" = "$seventy_before" ]
    [ "$(sha256sum "$unit/ha-lights.conf")" = "$lights_before" ]
    [ "$(sha256sum "$work/home/.local/bin/fp5-phosh-respawn")" = "$wrap_before" ]
    : > "$log"
    PATH="$work/bin:$PATH" HOME="$work/home" FAKE_USER=fp5 FAKE_UID=1000 \
        XDG_STATE_HOME="$work/home/.local/state" SYSTEMCTL_LOG="$log" \
        "$work/home/.local/state/fp5-phosh-resume-guard/rollback.sh" >/dev/null
    [ ! -f "$drop" ]
    [ ! -e "$work/home/.local/bin/fp5-phosh-wait-output" ]
    [ ! -e "$work/home/.local/bin/fp5-phosh-output-ready" ]
    [ -f "$unit/70-fp5-respawn.conf" ]
    [ -f "$unit/ha-lights.conf" ]
    [ -f "$work/home/.local/bin/fp5-phosh-respawn" ]
    [ "$(sha256sum "$unit/70-fp5-respawn.conf")" = "$seventy_before" ]
    [ "$(cat "$log")" = "--user daemon-reload" ]
    rm -rf "$work"
}

check "wait already ready" ready_once
check "wait timeout still starts" timeout_ok
check "wait becomes ready" becomes_ready
check "missing probe does not delay" missing_probe
check "install dry-run writes nothing" dry_run_clean
check "install refuses root" refuse_root
check "install and rollback" install_and_rollback

python3 "$tests/test-output-ready.py"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
printf 'all resume-guard tests passed\n'
