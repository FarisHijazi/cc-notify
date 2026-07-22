# 2026-07-22 — v1.7.15: 🚨 emergency auto-focus

## Ask

When a turn ends with the 🚨 emergency token, don't just post the banner — also
focus the session immediately, without waiting for the banner click. (Per user
clarification: the notification must NOT be skipped — focus is in addition.)

## Change

One block in `hooks/cc-notify.sh`, right after the route file is written and
**before** the Stop banner gating:

```bash
if [ "$event_kind" = "stop" ] && [ "$status_emoji" = "🚨" ]; then
  ( bash "$script_dir/cc-focus.sh" "${session_id:-default}" >>"$log" 2>&1 & )
fi
```

- Reuses `cc-focus.sh` verbatim — the exact same routing a banner click takes
  (Aerospace window focus → tmux session/window/pane → editor terminal pane via
  the extension URI). The route file it reads is written a few lines above, so
  it's always fresh.
- Detached (`( … & )` pattern, LESSONS #5) so the hook still returns <100ms.
- Placed **before** the `notify.disable_stop` / `notify.suppress_when_focused`
  gating on purpose: 🚨 is priority-1 "overrides everything" in the token spec,
  so an emergency focuses even when Stop banners are silenced. The banner itself
  still respects the kill-switch (focus fires, banner doesn't).
- 🚨 keeps its own `status_emoji` (unlike 💯→💯✅ remap), so the string compare
  is safe. Only fires on `stop` — Notification events never auto-focus.

Version bump: plugin.json 1.7.14 → **1.7.15** (mandatory for `/plugin update`
to pick it up — see CLAUDE.md). Extension unchanged (1.0.4).

## Testing (sandboxed, no real banners/focus)

Copied `cc-notify.sh` + `cc-lib.sh` to scratchpad with `cc-focus.sh` and
`cc-notify-bg.sh` replaced by logging stubs; fed fake hook JSON + fake
transcript JSONLs ending in the token:

| Case | Result |
|---|---|
| `stop`, transcript ends 🚨 | FOCUS-CALLED **and** BANNER-CALLED (subtitle "⚠️ Accident / disaster") |
| `stop`, transcript ends ✅ | BANNER-CALLED only, no focus |
| `stop`, 🚨 + `notify.disable_stop` (via fake `$HOME`) | FOCUS-CALLED only, banner suppressed |

## Docs updated

- `README.md`: 🚨 row in the outcome table + an "Emergency auto-focus" paragraph.
- `CLAUDE.md`: v1.7.15 entry + version line.

## Deploy reminder

Push to `main`, then: `/plugin marketplace update farishijazi-plugins` →
`/reload-plugins`. Running sessions re-read hook scripts from disk each fire, so
they pick up the new behavior as soon as the cache updates — no session restart
needed for this one (it's all in `cc-notify.sh`).
