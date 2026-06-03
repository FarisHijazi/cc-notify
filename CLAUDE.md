# CLAUDE.md — cc-notify plugin

State snapshot for picking up later. See @README.md for user-facing docs, @LESSONS.md for gotchas, @TODO.md for known issues.

## Status

- **Version**: 1.6.0 (pushed to `github.com/FarisHijazi/claude-plugins` marketplace + `github.com/FarisHijazi/cc-notify` standalone)
- **Installed**: via marketplace, autoUpdate on. Live caches at `~/.claude/plugins/cache/farishijazi-plugins/cc-notify/{1.0.0,1.3.2,1.3.3,1.4.0}/` — all have been hand-patched to v1.6.0 scripts.
- **Hotkey**: Karabiner-Elements rule binds `Option+Shift+A` → `bin/cc-banner-click`. Fires on key release (not key-down) with 150 ms settle delay + 800 ms debounce. Banner dismisses via `alerter --remove` only on successful focus.

## Architecture (3-script split + 1 capture helper)

```
hooks/cc-notify.sh         Hook entry — parses JSON, gates Stop, writes route file, spawns bg worker, exits <100ms.
hooks/cc-notify-bg.sh      Detached worker — blocks on alerter (120s timeout), on click invokes cc-focus.sh.
hooks/cc-focus.sh          Click handler — focuses target window via Aerospace, switches tmux.
hooks/cc-capture-window.sh Captures Aerospace focused window-id at SessionStart + UserPromptSubmit → /tmp/cc-notify/<sid>.window.
bin/cc-banner-click        Hotkey handler — finds latest live banner, runs cc-focus.sh, dismisses alerter on success.
```

State files in `/tmp/cc-notify/`:
- `<session_id>.route` — captured context (term, tmux_target, client_tty, cwd, gui_pid, target_wid)
- `<session_id>.window` — Aerospace window-id captured by cc-capture-window.sh

## Decisions / non-obvious mechanics

- **Window detection precedence**: captured `target_wid` (from cc-capture-window.sh) > `gui_pid` walk > AppleScript-by-tty (Terminal.app) > **VS Code/Cursor workspace-folder match by walking up cwd** (v1.6.0) > `open -a` last resort. Never `--reuse-window` (it opens cwd as a sub-view).
- **Stop gating**: only suppresses if the captured target window is currently Aerospace-focused. App-level frontmost check is a fallback when no Aerospace + no gui_pid.
- **PPID walk first, then tty walks**: handles both non-tmux (`$TMUX` not set or stripped) and tmux-attached (PPID hits launchd-parented server). See @LESSONS.md gotcha #11 about multi-client tmux iteration.
- **Hotkey fires on key release**: prevents key-repeat from cycling through all live banners. Plus 800ms script-level debounce.
- **alerter timeout = 120s**: gives time to react to the hotkey.

## Known issues to pick up

1. **tmux-watch monitor clients** — see @TODO.md. Sessions with only monitor clients (no real Terminal attached) can't be focused. Options: (a) skip monitor-client ttys when iterating, (b) spawn new Terminal as fallback, (c) refactor tmux-watch to mark its clients.
2. **VS Code / Cursor pane focus** — can't target a specific integrated terminal pane (no API). Window-level match works; user still finds the pane by eye.
3. **Two Cursor windows with the same workspace basename** — workspace-folder-basename matching picks the first one. Rare. Could disambiguate via `cursor --status` window list if it becomes an issue.

## Karabiner config

Rule at `~/.config/karabiner/karabiner.json` profile[0].complex_modifications.rules — search for "cc-notify". Points at the stable marketplaces/ path so it survives plugin version bumps:
```
"$HOME/.claude/plugins/marketplaces/farishijazi-plugins/plugins/cc-notify/bin/cc-banner-click"
```

## Debug tips when resuming

To re-instrument the diagnostic logging that was here during v1.4-v1.5 debugging:
- Stop gating decisions → add `printf '[%s] DEBUG_GATE event=%s gui_pid=%s claude_wid=%s focused_wid=%s\n' ...` near top of Stop block in cc-notify.sh
- tmux_jump steps → log return codes of switch-client / select-window / select-pane to `/tmp/cc-notify.tmux.log`
- Hotkey path → cc-banner-click already logs picked session_id + live alerters to `/tmp/cc-notify.gate.log`

Useful one-liner to see live state:
```bash
ls -t /tmp/cc-notify/*.route | head -3 | xargs -I{} sh -c 'echo "--- {} ---"; cat {}'
pgrep -fl 'alerter.*cc-'
tmux list-clients -F '#{client_tty} #{session_name} #{?client_focused,focused,unfocused}'
aerospace list-windows --focused --format '%{window-id}|%{app-name}|%{window-title}'
```

## What to verify on resume

1. **Cursor click-back lands on the right workspace window** (v1.6.0 workspace-folder match). Test by clicking from a Claude session whose cwd is a subdir of an open Cursor workspace — should focus that workspace's window, not re-open the subdir.
2. **Stop suppression works correctly in side-by-side layouts** (already verified for Terminal.app, untested for Cursor).
3. **autoUpdate pulls v1.6.0 cache** — currently the cache dirs are 1.0.0–1.4.0; v1.5.0/v1.6.0 will arrive on next session start with autoUpdate. All existing caches have been hand-patched.
