#!/bin/sh
# Offline test of fp5-call-mic v2 + fp5-call-audio-snap with mocked pactl/amixer/busctl/parecord/logger.
H=$(cd "$(dirname "$0")" && pwd)
scenario() { name=$1 appear=$2 active=$3 wrong=$4
  M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0
  [ "$appear" != never ] && echo $appear > $M/appear_at; echo $active > $M/active_at
  [ "$wrong" = 1 ] && touch $M/wrong
  PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap XDG_RUNTIME_DIR=$M \
    timeout 14 sh $H/fp5-call-mic; rc=$?
  echo "===== $name (rc=$rc)"; cat $M/log; echo "--- actions"; cat $M/actions; rm -rf $M
}
# wrong=1 -> the FIRST parecord stream reports a BT source (simulates PipeWire moving it)
scenario "A voice source after 1.2 s, answered at 6 s"   1.2 6 0
scenario "B voice source never appears (fallback)"        never 6 0
scenario "D source appears late (7 s): fallback, then rewired at answer" 7 8 0
scenario "C stream on wrong source at answer -> rewire"   0.4 3 1
