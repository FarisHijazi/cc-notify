# 2026-10-04 — v1.9.4: respect Do Not Disturb, except 🚨

**Report**: banners still appeared with Do Not Disturb on.
**Cause**: `cc-notify-bg.sh` passed `alerter --ignore-dnd` on every banner (there since the
initial commit, undocumented).
**Change**: the worker takes the status emoji as `$6` (cc-notify.sh passes `$status_emoji`,
cc-remote-bridge passes `$st`) and adds `--ignore-dnd` only for 🚨, or for everything when
`~/.claude/notify.ignore_dnd` exists.
**Tested**: stub `alerter` on PATH recording args, fake HOME — ✅ → no flag, 🚨 → flag,
no status → no flag, ✅ + `notify.ignore_dnd` → flag.
