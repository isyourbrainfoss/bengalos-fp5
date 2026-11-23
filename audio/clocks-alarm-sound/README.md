# fp5-clocks-alarm-sound v2

User-level helper so GNOME Clocks alarms still play when feedbackd will
not: on the `silent` or `quiet` profile, when `TriggerFeedback` is
missing, or when feedbackd accepts a trigger but emits `FeedbackEnded`
with reason `NOT_FOUND` (an event id is not proof that anything plays).

On `full`, if a probe event actually starts, the helper stays idle so
the Clocks/feedbackd sound is not doubled. It stops when the alarm is
stopped or snoozed (`ring_time` changes) or when `ring_minutes` elapse.

Installed on the lab FP5 as:

- `~/.local/bin/fp5-clocks-alarm-sound`
- `~/.config/systemd/user/fp5-clocks-alarm-sound.service`

The feedbackd theme `fp5-strong` is not changed.

## Install / rollback

The live backup and rollback script are written at install time under
`~/.local/state/fp5-clocks-alarm-sound/`. To restore the previous
script and restart only this user unit:

```
sh ~/.local/state/fp5-clocks-alarm-sound/rollback.sh
```

Do not restart feedbackd, gnome-clocks, or PipeWire as part of this
helper.

## Checks without playing a sound

```
python3 -m unittest test_fp5_clocks_alarm_sound.py -v
~/.local/bin/fp5-clocks-alarm-sound simulate --profile silent --probe ok --due
~/.local/bin/fp5-clocks-alarm-sound status    # reads gsettings only
```

`status --probe` and `probe` call TriggerFeedback and may click or
vibrate when the profile is full. The service itself does not probe on
silent/quiet.

## Short live test (needs the owner)

1. Leave the sound profile on silent (lydløs).
2. In Clocks, add a one-shot alarm about two minutes ahead.
3. Wait: the chosen alarm sound should play on the speaker.
4. Stop or snooze: the sound should stop.
5. Optional: switch the profile to full, set another two-minute alarm,
   and confirm there is sound but not a doubled/overlapping ring.
