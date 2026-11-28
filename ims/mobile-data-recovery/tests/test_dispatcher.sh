#!/bin/sh
# Tests for 50-fp5-wifi-preferred (dry run, fake nmcli). Exit 0 = all pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D="$HERE/../50-fp5-wifi-preferred"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chmod +x "$HERE/fake-nmcli"
fail=0
check() { # name scenario-lines expected-substring forbidden-substring
  name=$1; scen=$2; want=$3; deny=${4:-@@none@@}
  printf '%b' "$scen" > "$T/scen"; rm -rf "$T/state"
  out=$(FP5_DRY_RUN=1 FP5_NMCLI="$HERE/fake-nmcli" FP5_FAKE_SCENARIO="$T/scen" FP5_STATE="$T/state" sh "$D" wlan0 up 2>&1)
  if echo "$out" | grep -q -- "$want" && ! echo "$out" | grep -q -- "$deny"; then echo "ok   $name"
  else echo "FAIL $name"; echo "$out" | sed 's/^/     /'; fail=1; fi
}
nochange() { # name scenario-lines: nothing may be modified
  name=$1; printf '%b' "$2" > "$T/scen"; rm -rf "$T/state"
  out=$(FP5_DRY_RUN=1 FP5_NMCLI="$HERE/fake-nmcli" FP5_FAKE_SCENARIO="$T/scen" FP5_STATE="$T/state" sh "$D" wlan0 up 2>&1)
  if [ -z "$out" ]; then echo "ok   $name"; else echo "FAIL $name"; echo "$out" | sed 's/^/     /'; fail=1; fi
}
check "client wifi -> v6 default off"        'wifi=infrastructure\ngsm=connected\n' 'ipv6.never-default yes'
check "empty mode (default) is a client"     'wifi=\ngsm=connected\n'                  'ipv6.never-default yes'
nochange "hotspot (ap) alone -> v6 default stays on" 'wifi=ap\ngsm=connected\n'
check "ap + client second device -> off"     'wifi=ap\nwifi2=infrastructure\ngsm=connected\n' 'ipv6.never-default yes'
check "mode lookup fails -> old behaviour"   'wifi=ap\nmodefail=1\ngsm=connected\n'   'ipv6.never-default yes'
nochange "no wifi -> no change"                 'gsm=connected\n'
# hotspot after client: state "yes" must go back to "no"
printf 'wifi=ap\ngsm=connected\n' > "$T/scen"; mkdir -p "$T/state"; echo yes > "$T/state/qrtr0"
out=$(FP5_DRY_RUN=1 FP5_NMCLI="$HERE/fake-nmcli" FP5_FAKE_SCENARIO="$T/scen" FP5_STATE="$T/state" sh "$D" wlan0 up 2>&1)
if echo "$out" | grep -q 'ipv6.never-default no'; then echo "ok   client->hotspot restores v6 default"; else echo "FAIL client->hotspot"; echo "$out"; fail=1; fi
exit $fail
