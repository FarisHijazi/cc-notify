# cc-notify

Native macOS notifications + click-to-focus for [Claude Code](https://www.anthropic.com/claude-code).

When Claude needs your attention or finishes a turn, you get a macOS banner. Click it and you jump to the **exact Terminal.app window, Aerospace workspace, and tmux session/window/pane** where Claude is waiting.

## Quickstart

cc-notify is a Claude Code plugin — there's nothing to run; it fires automatically via hooks. Setup:

```text
/plugin marketplace add FarisHijazi/claude-plugins   # in Claude Code
/plugin install cc-notify@farishijazi-plugins
```
```bash
brew install vjeantet/tap/alerter                     # the notifier (required)
```

That's the whole core — you'll now get clickable banners. Optional extras:

1. **VS Code / Cursor terminal-pane focus + live status tabs** — run
   `"$HOME/.claude/plugins/marketplaces/farishijazi-plugins/plugins/cc-notify/bin/cc-install-editor-extension"`, then reload the editor window. ([details](#optional-focus-the-exact-vs-code--cursor-terminal-pane))
2. **Keyboard hotkey** to "click" the latest banner — [Karabiner rule](#optional-keyboard-hotkey-to-click-the-latest-banner).
3. **Outcome emojis** (✅/❌/👍/👎/💬 on the banner + tab) — add the [token instruction](#per-session-color--name) to `~/.claude/CLAUDE.md`.

To verify / debug: `bin/cc-notify-doctor`. After a plugin update, re-run `bin/cc-install-editor-extension` if you use the extension.

## Install (via marketplace)

```text
/plugin marketplace add FarisHijazi/claude-plugins
/plugin install cc-notify@farishijazi-plugins
```

Then install the notifier binary (one-time):

```bash
brew install vjeantet/tap/alerter
```

That's it. The plugin's `hooks/hooks.json` registers the `Notification` and `Stop` hooks automatically.

**First click** triggers two macOS Automation permission prompts ("Terminal would like to control Terminal", "System Events"). Allow them once.

## Optional: keyboard hotkey to "click" the latest banner

macOS doesn't natively let you click a notification banner with the keyboard. The plugin ships `bin/cc-banner-click` — a small script that finds the most recent route file and triggers the same focus action as clicking. Bind it to any hotkey.

**Karabiner-Elements** example (Option+Shift+A): add this rule to `~/.config/karabiner/karabiner.json` under `profiles[0].complex_modifications.rules`:

```json
{
  "description": "Focus most-recent Claude Code notification with Option+Shift+A (cc-notify)",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "a",
        "modifiers": { "mandatory": ["option", "shift"], "optional": ["any"] }
      },
      "to": [
        {
          "shell_command": "\"$HOME/.claude/plugins/marketplaces/farishijazi-plugins/plugins/cc-notify/bin/cc-banner-click\""
        }
      ]
    }
  ]
}
```

The script exits non-zero if no route file exists or focus didn't fire, and the wrapper only dismisses the banner (via `alerter --remove`) on success — so the hotkey is safe to mash.

## Optional: focus the exact VS Code / Cursor terminal pane

By default, clicking a notification from a VS Code / Cursor session focuses the
right **window**. To also jump to the **exact integrated terminal pane** Claude is
running in, install the bundled editor extension (one-time):

```bash
"$HOME/.claude/plugins/marketplaces/farishijazi-plugins/plugins/cc-notify/bin/cc-install-editor-extension"
```

Then reload the window in each editor (Cmd+Shift+P → "Developer: Reload Window").

This is the *only* way to focus a specific integrated terminal — VS Code/Cursor
expose no CLI flag, `vscode://command:` URI, or terminal escape sequence for it.
The extension ([`editor-extension/`](./editor-extension/)) registers a
`vscode://farishijazi.cc-notify-focus/focus?pids=…` URI handler and calls
`terminal.show()` on the terminal whose shell pid matches. See
[LESSONS.md](./LESSONS.md) gotcha #13.

## Per-session color & name

cc-notify reflects two pieces of Claude Code session identity:

- **Color** — `/color` sets `agentColor` in the transcript; cc-notify maps it to a
  colored emoji (🔴🟠🟡🟢🔵🟣🩷🩵) and prefixes the banner subtitle with it (the same
  color your statusline / tmux already show). No `/color` → no emoji.
- **Name** — `/rename` sets `customTitle` (falls back to Claude's auto `aiTitle`,
  then the project folder).

**Terminal tab renaming** (needs the [editor extension](#optional-focus-the-exact-vs-code--cursor-terminal-pane)):
on VS Code / Cursor, cc-notify renames the integrated terminal tab to
`<status> <color> <session name>` (e.g. `👀 🟠 cc-notify`) so you can tell sessions
apart — and see their state — at a glance. The status emoji tracks the session:

| State | Emoji |
|---|---|
| fresh session (startup) | ⏸️ |
| working (turn in progress) | ⏳ |
| needs permission | 🔐 |
| asking you / input | ❓ |
| multiple-choice menu open (AskUserQuestion) | 🔀 |
| done (no outcome token) | ℹ️ |

(⏳ means Claude is **actively working** — not done. "Done" shows an outcome emoji
below, or ℹ️/👀 when there's no token.)

The done state can reflect the actual **outcome** if you instruct Claude to end
each message with a trailing emoji. Priority order (clearest → weakest):

| Outcome | Emoji |
|---|---|
| accident / disaster | 🚨 |
| all tasks done, nothing left | 💯✅ |
| task completed | ✅ |
| task failed | ❌ |
| blocked | 🚫 |
| waiting for instructions | 🙋 |
| good news | 👍 |
| bad news | 👎 |
| work to be done | 🏃 |
| just info | ℹ️ |

Add the token rules to your `~/.claude/CLAUDE.md` (Claude appends the first that
applies; cc-notify reads it on `Stop`). Without it, the done state is just 👀.
Ready-made rules: [`docs/cc-notify-tokens.md`](./docs/cc-notify-tokens.md) — copy
it next to your `~/.claude/CLAUDE.md` and add a line `@cc-notify-tokens.md` to keep
CLAUDE.md clean (Claude Code imports `@`-referenced files).

cc-notify reads that trailing emoji from the transcript on `Stop`. Without it, the
done state is just 👀 "your turn".

It's driven by a state file the extension watches (`/tmp/cc-notify/<sid>.tab`) —
**no `open`/URL**, because opening a URL scheme activates the editor and steals
focus across spaces. The extension renames via the terminal API without raising the
window, so it never disturbs you. Native tab *color* isn't settable by any VS Code
API, so the color rides along as the emoji prefix.

A **background** terminal's tab can only re-render when it becomes active, so when a
backgrounded session changes state (e.g. finishes: ⏳→✅) its tab would stay stale
until you focus it. To fix that, cc-notify **auto-sweeps** on settled events (`Stop`,
`Notification`, `SessionStart`, `SessionEnd`): it touches `/tmp/cc-notify/.sweep`,
which every editor window's extension watches and responds to by briefly cycling its
terminals (`focusNext`) so each tab repaints, then landing back where it started. The
sweep is **throttled** (≤1 / 10 s), **skipped while you're typing** (no keystroke in
the last 3 s — read live from the OS, no daemon/permissions), and **queued** if
blocked (it fires the moment you stop typing) — so it never interrupts you mid-type.
Mouse movement doesn't block it.

Hooks only fire on events (and only in sessions started after a plugin update), so
for a steady heartbeat that repaints tabs even when nothing is happening, install the
**60s sweep agent** (one-time):

```bash
"$HOME/.claude/plugins/marketplaces/farishijazi-plugins/plugins/cc-notify/bin/cc-install-sweep-agent"
```

It installs a launchd LaunchAgent that runs `cc-sweep` every 60s. Each tick obeys the
same guards (throttled, skipped while typing, queued if blocked), so it's invisible
while you work. Re-run it after a plugin update; `--uninstall` removes it.

**Disable sweeping entirely** (tabs then only update on focus / the next turn in
that window):

```bash
touch ~/.claude/notify.disable_sweep   # no more sweeps anywhere
rm    ~/.claude/notify.disable_sweep   # re-enable
```

The flag is honored by the extension, `cc-sweep`, and the hook trigger. Reload the
editor window once so the extension picks it up. (The heartbeat agent is separate —
remove it with `cc-install-sweep-agent --uninstall`.)

## Toggle Stop notifications

`Stop` fires the moment Claude is **fully done** — after every subagent has
returned and the final response is written (background shells/watchers don't hold
the turn open). cc-notify fires on it **immediately** rather than relying on Claude
Code's ~60s idle Notification, so "done" pings are instant. Two opt-outs, both off
by default:

1. **Global kill-switch**: while `~/.claude/notify.disable_stop` exists, Stop never fires.
2. **Suppress when focused** (opt-in): while `~/.claude/notify.suppress_when_focused`
   exists, Stop is skipped when the originating window is already frontmost. Off by
   default — the frontmost detection is unreliable in VS Code/Cursor and was eating
   legitimate pings.

```bash
touch ~/.claude/notify.disable_stop          # silence Stop entirely
rm ~/.claude/notify.disable_stop             # re-enable

touch ~/.claude/notify.suppress_when_focused # don't ping the window you're on
rm ~/.claude/notify.suppress_when_focused    # always ping (default)
```

**Permission** `Notification`s always fire a banner — those are the high-signal
ones. The **idle** `Notification` (Claude Code's ~60s "waiting for your input")
is **tab-status-only — no banner** (it updates the terminal tab to ❓ but doesn't
ping); it's low-signal and noisy, and the instant `Stop` ping already covers "done".

## Click-routing by terminal

| Terminal | Behavior |
|---|---|
| **Terminal.app + tmux** | AppleScript-by-tty finds the exact window/tab, Aerospace switches workspace, `tmux switch-client` + `select-window` + `select-pane` jumps the pane. |
| **iTerm2 / Ghostty + tmux** | `open -a` + tmux jump. |
| **VS Code / Cursor integrated terminal** | Focuses the existing editor window whose workspace folder matches `cwd` (exact, then closest parent dir) via Aerospace — no `--reuse-window` (which would re-open a sub-folder as a new view). **With the [companion extension](#optional-focus-the-exact-vs-code--cursor-terminal-pane) installed, it also focuses the exact integrated terminal pane** Claude runs in. |
| **SSH session on remote** | Bell + line appended to remote `~/.claude/inbox.log`. No Mac notification crosses the wire by design. |

## Why alerter and not `osascript`

`osascript -e 'display notification'` is truly native but **not clickable** — Apple removed the click-callback path for unsigned scripts in 10.14+. `alerter` uses modern `UNUserNotificationCenter` and returns click signals to stdout. `terminal-notifier` is broken on macOS Tahoe (uses deprecated `NSUserNotification`).

## Icon

The banner always carries an **orange Claude mark** as a right-side content image.

The notification *icon* (left square) can only be overridden by impersonating an
app's bundle id (`alerter --sender`); on modern macOS (Big Sur+) a custom
`--app-icon` is ignored. Impersonating `com.anthropic.claudefordesktop` gives the
orange Claude logo — **but macOS silently drops notifications sent under a bundle
id that lacks notification permission, and `Claude.app` usually has none** (most
people run the Claude Code CLI, not the desktop app). That kills the banner and
leaves only the terminal bell. So the Claude icon is **opt-in**:

```bash
# 1. Launch Claude.app once and allow its notifications (System Settings → Notifications → Claude)
# 2. then:
touch ~/.claude/notify.claude_icon    # use the orange Claude logo as the icon
rm   ~/.claude/notify.claude_icon     # back to the default authorized sender (reliable banners)
```

## How it works

1. Hook fires → `cc-notify.sh` captures context (term, tmux session/window/pane, client_tty, cwd) and writes a route file to `/tmp/cc-notify/<sid>.route`.
2. Hook spawns `cc-notify-bg.sh` fully detached via `( bash ... & )` — parent returns in <100ms.
3. `cc-notify-bg.sh` blocks on `alerter`; on click, invokes `cc-focus.sh`.
4. `cc-focus.sh` reads the route file, runs AppleScript to find the matching Terminal tab by `tty`, switches Aerospace workspace if needed, then `tmux switch-client` + `select-window` + `select-pane`.

For the non-obvious gotchas hit during development (alerter `@ACTIONCLICKED` quirk, tmux clobbering `TERM_PROGRAM`, detached spawn pattern, etc.), see [LESSONS.md](./LESSONS.md).

## License

MIT.
