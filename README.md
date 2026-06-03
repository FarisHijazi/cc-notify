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

## Toggle Stop notifications

`Stop` fires on every assistant turn end — noisy if you're actively iterating. Two gates:

1. **Auto-suppression**: skipped when the originating terminal app is currently frontmost.
2. **Global kill-switch**: while `~/.claude/notify.disable_stop` exists, Stop never fires.

```bash
touch ~/.claude/notify.disable_stop    # silence Stop
rm ~/.claude/notify.disable_stop       # re-enable
```

`Notification` events (input requests) always fire — those are the high-signal ones.

## Click-routing by terminal

| Terminal | Behavior |
|---|---|
| **Terminal.app + tmux** | AppleScript-by-tty finds the exact window/tab, Aerospace switches workspace, `tmux switch-client` + `select-window` + `select-pane` jumps the pane. |
| **iTerm2 / Ghostty + tmux** | `open -a` + tmux jump. |
| **VS Code / Cursor integrated terminal** | Focuses the existing editor window whose workspace folder matches `cwd` (exact, then closest parent dir) via Aerospace — no `--reuse-window` (which would re-open a sub-folder as a new view). **Cannot focus a specific integrated terminal pane** — VS Code exposes no API. |
| **SSH session on remote** | Bell + line appended to remote `~/.claude/inbox.log`. No Mac notification crosses the wire by design. |

## Why alerter and not `osascript`

`osascript -e 'display notification'` is truly native but **not clickable** — Apple removed the click-callback path for unsigned scripts in 10.14+. `alerter` uses modern `UNUserNotificationCenter` and returns click signals to stdout. `terminal-notifier` is broken on macOS Tahoe (uses deprecated `NSUserNotification`).

## How it works

1. Hook fires → `cc-notify.sh` captures context (term, tmux session/window/pane, client_tty, cwd) and writes a route file to `/tmp/cc-notify/<sid>.route`.
2. Hook spawns `cc-notify-bg.sh` fully detached via `( bash ... & )` — parent returns in <100ms.
3. `cc-notify-bg.sh` blocks on `alerter`; on click, invokes `cc-focus.sh`.
4. `cc-focus.sh` reads the route file, runs AppleScript to find the matching Terminal tab by `tty`, switches Aerospace workspace if needed, then `tmux switch-client` + `select-window` + `select-pane`.

For the non-obvious gotchas hit during development (alerter `@ACTIONCLICKED` quirk, tmux clobbering `TERM_PROGRAM`, detached spawn pattern, etc.), see [LESSONS.md](./LESSONS.md).

## License

MIT.
