# HFP speaker volume floor

During a car (HFP) call, log the SCO sink volume and raise the active
`handsfree-hf-output` route and the `pw-play` downlink stream to 100% if
they are below 50%, rate-limited like the v3 mic floor (at most 6 writes
per call). The A2DP route is never set to 100%. If a write was made, the
pre-call A2DP volume is put back on restore so a shared sink-node volume
cannot leak 100% into media. `fp5-car-mpris-guard` still handles a
post-call 0%. Transport volume (AT+VGS / AVRCP) is logged when the sink
properties expose it.

Install on the FP5 as user `fp5`, no root: `sh install.sh`.
This only restarts `fp5-hfp-modem-bridge`. Rollback: `sh rollback.sh`.
