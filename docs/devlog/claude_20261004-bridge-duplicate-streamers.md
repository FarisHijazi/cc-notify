# 2026-10-04 — v1.9.3: 4x banners per remote event (leaked bridge streamers)

**Symptom**: every event from `ssh dema` fired 4 banners.

**Measured**: dema's `~/.claude/cc-events.jsonl` had one line per event. On the Mac the
supervisor (pid 21544, up since 09-16) had 4 streamer generations per host (09-16, 09-20,
09-25, 09-30), each with its own `ssh dema tail -F`. Only the newest was in
`bridge-dema.pid`; `bridge-supervisor.pid` was missing entirely.

**Cause**: `_supervise` used `/tmp/cc-notify/bridge-<host>.pid` + `kill -0` as liveness.
Those files get purged out of /tmp after a few days → "no pidfile" = "dead" → respawn
beside the live streamer. Details: LESSONS #38.

**Fix**: in-memory host→pid arrays in `_supervise` (bash 3.2-safe); pidfiles kept for
`--stop`. New `tests/cc_remote_bridge_supervise_test.sh` (real `_supervise`, stubbed hosts,
sleeper streamers, purge simulated): new code passes 6/6, old code fails 5/6 with 2 → 4.

**Deployed locally**: `launchctl kickstart -k` on the agent — its TERM trap reaped all
four generations; now exactly one `ssh … tail -F` per host (dema/ftower/sahalat;
thmanyah unreachable at the time).
