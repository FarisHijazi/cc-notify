# 2026-10-07 — nested `claude -p` sessions spammed `/color blue` into their parent's pane

**Symptom.** The `fix logins` session (farishijazi-2:0.0) got `/color blue` typed
in every 1–2s: 220+ `applied` lines in `colorsync.log` within minutes.

**Cause.** That session was running skill-trigger evals, launching many headless
`claude -p` runs from its Bash tool. Each child inherits the parent's
`TMUX_PANE=%4`, fires SessionStart in `~`, sees `~/.cc/settings.json` =
`blue` while its own transcript has no color, and spawns `cc-color-apply.sh` at
the PARENT's pane. One `/color blue` per eval run.

**Fix.** `cc_is_nested_claude` (cc-lib.sh) returns true when two or more
`claude` processes are ancestors of the hook. `cc-capture-window.sh` skips the
SessionStart color apply when it is true, because a nested session owns no pane.
Only color apply is gated; banners and status updates for nested sessions are
unchanged.

**Tested.**
- The function returns top-level under one claude and nested under two (a
  symlinked `claude` → bash wrapper as the outer level).
- Live: I copied both files into the 1.9.4 cache (they matched HEAD first).
  Applies went 224 → 225 with one in-flight straggler, then none for 50s+ while
  10 `claude -p` evals were still running.

Not committed and no version bump yet. The cache copy is hand-patched, so the
next `/plugin update` needs a bumped `plugin.json` to keep the fix.
