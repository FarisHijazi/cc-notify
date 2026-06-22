# cc-notify

Native macOS notifications + click-to-focus for [Claude Code](https://www.anthropic.com/claude-code).

When Claude needs your attention or finishes a turn, you get a macOS banner. Click it and you jump to the **exact Terminal.app window, Aerospace workspace, and tmux session/window/pane** where Claude is waiting.

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

`Notification` events (input requests) always fire — those are the high-signal ones.

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

The banner shows the **orange Claude logo** (matching the Claude Code statusline
accent) when `Claude.app` is installed — cc-notify impersonates its bundle id via
`alerter --sender com.anthropic.claudefordesktop`. On modern macOS (Big Sur+) a
custom `--app-icon` is ignored; sender impersonation is the only way to override
the notification icon. Without `Claude.app`, the icon falls back to the default.

## How it works

1. Hook fires → `cc-notify.sh` captures context (term, tmux session/window/pane, client_tty, cwd) and writes a route file to `/tmp/cc-notify/<sid>.route`.
2. Hook spawns `cc-notify-bg.sh` fully detached via `( bash ... & )` — parent returns in <100ms.
3. `cc-notify-bg.sh` blocks on `alerter`; on click, invokes `cc-focus.sh`.
4. `cc-focus.sh` reads the route file, runs AppleScript to find the matching Terminal tab by `tty`, switches Aerospace workspace if needed, then `tmux switch-client` + `select-window` + `select-pane`.

For the non-obvious gotchas hit during development (alerter `@ACTIONCLICKED` quirk, tmux clobbering `TERM_PROGRAM`, detached spawn pattern, etc.), see [LESSONS.md](./LESSONS.md).

## License

MIT.
