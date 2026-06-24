# CLAUDE.md — cc-notify plugin

State snapshot for picking up later. See @README.md for user-facing docs, @LESSONS.md for gotchas, @TODO.md for known issues.

## Status

- **Deploy after pushing to `main`** (the two commands the user runs, in order):
  1. `/plugin marketplace update farishijazi-plugins`  ← re-pulls the bumped plugin from `main` (needs the `plugin.json` version bumped, else no-op)
  2. `/reload-plugins`  ← reloads hooks into the session
  Then **new** Claude Code sessions run the new hook scripts. Editor-extension changes additionally need an editor window reload (Cmd+Shift+P → Developer: Reload Window).
- **Version**: 1.7.5 (extension 1.0.1). **Single source of truth = the `cc-notify` repo** (develop here, push to `main`). The marketplace `github.com/FarisHijazi/claude-plugins` references it externally (`source: {github, repo: FarisHijazi/cc-notify}`; bundled copy deleted) so there's no second copy to drift. **MUST bump `.claude-plugin/plugin.json` version on every change** or `/plugin update` no-ops and installed sessions run a frozen stale cache (this bit us — frozen 1.7.0). Latest session handoff: @docs/devlog/claude_2026-06-24-v1.7.x-session.md.
- **v1.7.0 adds**: (a) Claude orange logo on the banner via `alerter --sender com.anthropic.claudefordesktop`; (b) exact integrated-terminal-pane focus for VS Code/Cursor via the new `editor-extension/` + `bin/cc-install-editor-extension`.
- **v1.7.5 fixes**: **stuck-⏳ tabs**. The `Stop`/`Notification` tab write in `cc-notify.sh` was gated `if term=vscode && shell_pids` (cc_write_tab) with NO else — but `cc_detect_terminal` is FLAKY under tmux, while the mid-turn ⏳ comes from the UNGATED cheap path (`cc_set_status` in cc-capture-window.sh). So a flaked detection on Stop left ⏳ frozen forever (deployed 1.7.1 had `cc_set_status` count=0 in cc-notify.sh — confirmed). Fix: added `else ( cc_set_status "$sid" "$status_emoji" & )` so the outcome emoji is ALWAYS swapped onto the existing `.tab`, term-detection or not. Only ever bit tmux-in-Cursor sessions. One-off resync of already-stuck tabs: loop `.tab`s starting with ⏳ → `cc_set_status` to (transcript token || ℹ️), skipping active sessions (transcript mtime <45s). See @LESSONS.md #18.
- **v1.7.4 adds**: **idle Notification is tab-only (no banner)**. CC's ~60s `idle_prompt` ("waiting for your input") now updates the tab to ❓ but spawns NO banner — `cc-notify.sh` sets `notif_tab_only=1` in the idle case and `exit 0`s before the bg worker. Permission prompts + the generic fallback still banner; instant `Stop` already covers "done". Also synced the repo `docs/cc-notify-tokens.md` (was missing 💯) + the global `~/.claude/cc-notify-tokens.md` with the rule: token emojis appear ONLY as the single trailing token, never inline/as heading marks.
- **v1.7.3 adds**: (a) **🔀 AskUserQuestion** — its multiple-choice menu fires NO Notification (only `idle_prompt`/`permission_prompt` exist), but it's a tool, so `cc-capture-window.sh` keys off `PreToolUse` with `tool_name=AskUserQuestion` → `options` status (🔀); PostToolUse falls back to ⏳. Needed adding `tool_name` to that hook's JSON parse. (b) **💯 token now recognized** — it was in `cc-notify-tokens.md` (priority 2) but missing from `cc_last_status_token`'s array, so it silently fell through to ℹ️; now detected and **displayed as 💯✅** (two-glyph, via `cc_status_emoji complete`). `cc_set_status`'s strip regex now strips a *run* of leading status emojis so the two-glyph 💯✅ is replaced cleanly by later cheap swaps. Reminder: ⏳ = working/in-progress, NOT done (done = outcome token or ℹ️/👀).
- **v1.7.2 adds**: tab title **self-heals on focus** — the extension's `onDidChangeActiveTerminal` (fires when a terminal becomes active = "you opened the session") now re-asserts that terminal's name straight from its `.tab` file (`reapplyActiveTab()`), replacing the old `pending` map. Single source of truth = the `.tab` file on disk; a background terminal whose `.tab` changed while inactive gets the right title the instant you focus it. **Decision: focus does NOT clear notifications** — clearing stays on `UserPromptSubmit` (respond), because flicking through tabs fast would silently dismiss unread notifications. Needs an editor window reload to pick up the new `extension.js`.
- **Installed**: via marketplace, autoUpdate on. Live caches at `~/.claude/plugins/cache/farishijazi-plugins/cc-notify/{1.0.0,1.3.2,1.3.3,1.4.0}/` — all have been hand-patched to v1.6.0 scripts.
- **Hotkey**: Karabiner-Elements rule binds `Option+Shift+A` → `bin/cc-banner-click`. Fires on key release (not key-down) with 150 ms settle delay + 800 ms debounce. Banner dismisses via `alerter --remove` only on successful focus.

## Architecture (3-script split + 1 capture helper)

```
hooks/cc-notify.sh         Hook entry — parses JSON, gates Stop, writes route file, spawns bg worker, exits <100ms.
hooks/cc-notify-bg.sh      Detached worker — blocks on alerter (120s timeout), on click invokes cc-focus.sh. Adds --sender for Claude icon.
hooks/cc-focus.sh          Click handler — focuses target window via Aerospace, switches tmux, focuses VS Code/Cursor terminal pane.
hooks/cc-lib.sh            Sourced library: cc_detect_terminal (shared GUI/term + shell-pid walk), color/status emoji, session meta (color+title), tab name, cc_write_tab, cc_set_status (cheap status swap), cc_last_status_token.
hooks/cc-capture-window.sh Status updater for 7 hooks (SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/SubagentStop/PreCompact/SessionEnd). FULL update (window capture + transcript grep) only on SessionStart/UserPromptSubmit; cheap status-emoji swap (no grep) on the rest.
bin/cc-banner-click        Hotkey handler — finds latest live banner, runs cc-focus.sh, dismisses alerter on success.
bin/cc-install-editor-extension  Symlinks editor-extension/ into ~/.vscode/extensions + ~/.cursor/extensions.
editor-extension/          VS Code/Cursor extension: vscode://farishijazi.cc-notify-focus/focus?pids=… handler → terminal.show().
```

State files in `/tmp/cc-notify/`:
- `<session_id>.route` — captured context (term, tmux_target, client_tty, cwd, tmux_socket, gui_pid, target_wid, editor_app, shell_pids)
- `<session_id>.window` — Aerospace window-id captured by cc-capture-window.sh (terminal/editor windows only)
- `<session_id>.tab` — `{pids,name}` the editor extension watches to set the tab name (status+color+title)
- `focus.log` — extension breadcrumb: last focus/rename action (pid/name or "no match")

## Decisions / non-obvious mechanics

- **Window detection precedence**: captured `target_wid` (from cc-capture-window.sh) > `gui_pid` walk > AppleScript-by-tty (Terminal.app) > **VS Code/Cursor workspace-folder match by walking up cwd** (v1.6.0) > `open -a` last resort. Never `--reuse-window` (it opens cwd as a sub-view).
- **VS Code/Cursor terminal-pane focus** (v1.7.0): after window focus, `cc-focus.sh:focus_vscode_terminal()` fires `open "<vscode|cursor>://farishijazi.cc-notify-focus/focus?pids=$shell_pids"` — but only if the extension dir exists (else the editor pops a "not installed" toast). Scheme picked from `editor_app` (captured) or the focused window's Aerospace app-name. `shell_pids` = hook's ancestor PPID chain **plus** every pid on `client_tty` (the latter covers tmux-inside-editor, where the editor's shell == tmux client shell is a *sibling*, not an ancestor). Extension matches by `Terminal.processId ∈ shell_pids`, then `.show()`. See @LESSONS.md gotcha #13.
- **Per-session color emoji** (v1.7.0): reads `agentColor` (set by `/color`, stored as `"agentColor":"…"` in the transcript JSONL — same source `gsd-statusline.js` uses) from `transcript_path`, maps red/orange/yellow/green/blue/purple/pink/cyan → 🔴🟠🟡🟢🔵🟣🩷🩵, prefixes the banner subtitle.
- **Session name** (v1.7.0): `/rename` writes a `{"type":"custom-title","customTitle":"…"}` line to the transcript; Claude also auto-writes `{"type":"ai-title","aiTitle":"…"}`. cc-notify reads the cascade customTitle → aiTitle → cwd basename in one `grep` pass over the transcript (alongside agentColor).
- **Status emojis** (v1.7.0): tab + banner title share one vocab. **hooks.json registers 9 events** (added PreToolUse/PostToolUse/SubagentStop/PreCompact/SessionEnd) so the status self-heals/stays current — more triggers = fresher. Mapping: SessionStart→⏸️ startup, UserPromptSubmit/PreToolUse/PostToolUse/SubagentStop→⏳ running (EXCEPT `PreToolUse` with `tool_name=AskUserQuestion`→🔀 options, since its menu fires no Notification — v1.7.3), PreCompact→🗜️ compacting, SessionEnd→cleared (status removed), Notification→🔐 permission / ❓ question-input / 🔔 generic (split by `notification_type`+message; raw types logged to `notiftypes.log` — only `idle_prompt`/`permission_prompt` seen in practice). v1.7.4: the ❓ idle one (`idle_prompt`) is TAB-ONLY (sets `notif_tab_only=1`, no banner); 🔐 permission + 🔔 generic still banner, Stop→ outcome (💯✅/✅/❌/… from the message token, else 👀). High-frequency hooks use `cc_set_status` (swap the leading status emoji on the existing `.tab`, NO transcript grep / aerospace call, detached) so they don't slow tool calls; only SessionStart/UserPromptSubmit do the full grep. Colored circles stay reserved for `/color` identity. Format: `<status> <color> <name>`. NOTE: hooks.json changes need a new Claude Code session to take effect.
- **Resume names the tab too** (v1.7.0): detection lives in `cc_detect_terminal` (cc-lib.sh), used by BOTH cc-notify.sh and cc-capture-window.sh. cc-capture-window self-detects the terminal + shell pids (no longer reads them from the route file), so `claude --resume` — a new terminal with no prior route — still names its tab at SessionStart. PreToolUse/PostToolUse stay cheap (cc_set_status, no detection). Was: capture-window depended on cc-notify.sh's route, so resumed sessions had stale/no pids until the first turn-end.
- **Tab status decoupled from banner** (v1.7.0): the `.tab` write happens in `cc-notify.sh` BEFORE the Stop banner gating (and `cc_write_tab` is no longer in the bg worker), so the tab updates even when the banner is suppressed/kill-switched. This was the "stuck on ⏳" bug — the tab write used to live in the gated bg path. Status flows from all 4 registered hooks (SessionStart/UserPromptSubmit via cc-capture-window; Notification/Stop via cc-notify). NOTE: stuck tabs from before need a one-time editor reload (the file-watcher's activation pass re-applies current `.tab` files).
- **Turn outcome on Stop** (v1.7.0): the global `~/.claude/CLAUDE.md` instructs Claude to end every message with a trailing token: `✅` task done / `❌` task failed / `👍` good news / `👎` bad news / `💬` neutral (priority: task outcome → good/bad sentiment → neutral). `cc_last_status_token` reads the last text-bearing assistant message and returns that emoji → Stop status, falling back to 👀 "your turn" when no token is present. Banner subtitle: Task complete / Task failed / Good news / Bad news / Turn complete. NOTE: depends on an out-of-repo instruction in the user's global CLAUDE.md.
- **Terminal-tab rename = FILE-WATCH, not `open`** (v1.7.0): hooks write `/tmp/cc-notify/<sid>.tab` (`{pids,name}`) via `cc_write_tab`; the extension `fs.watch`es the dir and renames via `renameWithArg`. **Why not `open`:** `open -g "<scheme>://…"` STILL activates the editor and yanks Aerospace focus across workspaces (a URL scheme forces app activation even with `-g`) — that was the "window randomly grabs focus" bug. `renameWithArg` only acts on the active terminal and does NOT raise the window, so the extension renames when the target is active, else defers to `onDidChangeActiveTerminal` — **never `show()`** (show raises the window). Native tab *color* is unsettable via API → emoji-only. See @LESSONS.md #16/#17.
- **Window capture is whitelisted** (v1.7.0): `cc-capture-window.sh` only saves the focused window as the jump-back target if its app is a terminal/editor (Cursor/Code/Terminal/iTerm2/Ghostty/…). Sessions driving Chrome (browser automation) were capturing Chrome → click focused Chrome. See @LESSONS.md #16.
- **Banner icon/color** (v1.7.0): orange Claude mark always shown as `--content-image` (right thumbnail). The left icon can only be changed via `--sender` impersonation (Big Sur+ ignores `--app-icon`), BUT **macOS silently drops notifications from a bundle id lacking notification permission**, and `com.anthropic.claudefordesktop` is unauthorized on this machine (confirmed absent from `~/Library/Preferences/com.apple.ncprefs.plist`). Impersonating it killed all banners and left only Claude Code's `terminal_bell` — the v1.7.0 "no notifications" regression. So `--sender` is now **opt-in** via `~/.claude/notify.claude_icon` (default off → default authorized sender → reliable banners). See @LESSONS.md #14. Diagnose with `bin/cc-notify-doctor`.
- **Stop gating** (v1.7.0: fires immediately by default): Stop = "fully done" (subagents already returned, bg shells/watchers don't hold the turn), so we fire on it instead of relying on CC's ~60s idle Notification. Two opt-outs, both OFF by default: `notify.disable_stop` (kill-switch) and `notify.suppress_when_focused` (only then run the frontmost check → suppress if the captured target window is Aerospace-focused; app-level frontmost is the fallback). Frontmost suppression was inverted to opt-in because its detection is unreliable in VS Code/Cursor and ate legitimate pings.
- **PPID walk first, then tty walks**: handles both non-tmux (`$TMUX` not set or stripped) and tmux-attached (PPID hits launchd-parented server). See @LESSONS.md gotcha #11 about multi-client tmux iteration.
- **Hotkey fires on key release**: prevents key-repeat from cycling through all live banners. Plus 800ms script-level debounce.
- **alerter timeout = 120s**: gives time to react to the hotkey.

## Known issues to pick up

1. **tmux-watch monitor clients** — see @TODO.md. Sessions with only monitor clients (no real Terminal attached) can't be focused. Options: (a) skip monitor-client ttys when iterating, (b) spawn new Terminal as fallback, (c) refactor tmux-watch to mark its clients.
2. **VS Code / Cursor pane focus** — SOLVED in v1.7.0 via the `editor-extension/` (`terminal.show()` matched by shell pid). Requires the extension installed + window reloaded. Without it, falls back to window-level focus only (the URI is suppressed when the extension dir is absent).
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
2. **Terminal-pane focus (v1.7.0)** — install the extension (`bin/cc-install-editor-extension`), reload the editor window, then fire `open "cursor://farishijazi.cc-notify-focus/focus?pids=<shell_pids from route>"` and check `$TMPDIR/cc-notify-focus.last` says `matched pid=…`. Confirm the *exact* pane (with multiple terminals open + tmux inside it) gets focus, not just the panel.
3. **Stop suppression works correctly in side-by-side layouts** (already verified for Terminal.app, untested for Cursor).
4. **autoUpdate pulls latest cache** — currently the cache dirs are 1.0.0–1.4.0; newer versions arrive on next session start with autoUpdate. All existing caches have been hand-patched.
