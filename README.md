# cc-notify

Native macOS notifications + click-to-focus for [Claude Code](https://www.anthropic.com/claude-code) hooks.

When Claude Code needs your attention (asks a question, finishes a turn), you get a banner. Click it, and macOS jumps back to the **exact terminal window, Aerospace workspace, and tmux session/window/pane** where Claude is waiting.

Built and battle-tested on macOS 26 (Tahoe), Terminal.app, tmux, and Aerospace.

## What it does

Two hooks:

| Hook | When it fires | Default sound |
|---|---|---|
| `Notification` | Claude asks for input / permission prompt | Glass |
| `Stop` | Claude finishes a turn | Hero |

Click the banner → click handler:

1. Brings the **specific Terminal.app window+tab** forward (matched by `tty`, not "whichever Terminal was last frontmost").
2. Switches Aerospace workspace if the target window is on a different one.
3. Runs `tmux switch-client -c <client_tty> -t <session:window.pane>` so even multi-window tmux setups land on the right pane.

## Install

```bash
git clone https://github.com/FarisHijazi/cc-notify.git ~/projects/cc-notify
~/projects/cc-notify/install.sh
```

The installer:
- `brew install vjeantet/tap/alerter` (the modern macOS notifier — `terminal-notifier` is dead on Tahoe).
- Symlinks the three hook scripts into `~/.claude/hooks/`.
- Idempotently merges `Notification` and `Stop` hook entries into `~/.claude/settings.json` (existing hooks are preserved; a `.bak` is written before any change).
- Creates `~/.claude/notify.disable_stop` so Stop notifications start **disabled** (recommended — see below).

Then start a new Claude Code session.

**First click** triggers two macOS Automation permission prompts ("Terminal would like to control Terminal", "System Events"). Allow them once.

## Toggle Stop notifications

`Stop` fires on **every** assistant turn end, which is noisy if you're actively iterating. Two layers of gating:

1. **Auto-suppression**: if your originating terminal app is currently frontmost, the Stop banner is skipped. You only get pinged when you've tabbed away.
2. **Global kill-switch**: while `~/.claude/notify.disable_stop` exists, Stop never fires.

```bash
# Silence Stop:
touch ~/.claude/notify.disable_stop

# Re-enable Stop:
rm ~/.claude/notify.disable_stop
```

`Notification` events (input requests) **always** fire — those are the high-signal ones.

## Click-routing behavior by terminal

| Terminal | Click-back behavior |
|---|---|
| **Terminal.app + tmux** | Full: AppleScript-by-tty finds the exact window/tab, Aerospace switches workspace, `tmux switch-client -c <tty> -t <target>` jumps the pane. |
| **iTerm2 / Ghostty + tmux** | Same pattern (`open -a` + tmux switch). |
| **VS Code / Cursor integrated terminal** | Best effort: app activates, `code/cursor --reuse-window $cwd` brings the workspace forward. **Cannot focus a specific integrated terminal pane** — VS Code exposes no API for that. |
| **SSH session on remote machine** | Bell (`\a`) on the controlling tty + line appended to remote `~/.claude/inbox.log`. No Mac notification crosses the wire by design. |

## How TERM_PROGRAM detection works (the tmux fix)

Recent tmux overrides `$TERM_PROGRAM=tmux`, hiding the real outer terminal. `cc-notify.sh` walks `ps -t <tty_short>` upward via PPID until it hits a known terminal binary (`Terminal`, `iTerm`, `Cursor`, `Code`, `Ghostty`).

## Uninstall

```bash
~/projects/cc-notify/uninstall.sh
```

Removes the symlinks, strips the hook entries from `settings.json` (backed up first), removes the sentinel, clears `/tmp/cc-notify/`. `alerter` is left installed (other tools may want it).

## Files

```
hooks/
  cc-notify.sh      Hook entry. Reads JSON, captures context, spawns bg, exits <100ms.
  cc-notify-bg.sh   Detached worker. Blocks on alerter, dispatches focus on click.
  cc-focus.sh       Click handler. AppleScript + Aerospace + tmux.
bin/
  patch-settings.js   Idempotent settings.json merger (used by install.sh).
  unpatch-settings.js Removes our entries (used by uninstall.sh).
install.sh / uninstall.sh
LESSONS.md          The hard-won gotchas. Read this if you're hacking on it.
```

Each hook script uses `$(dirname "${BASH_SOURCE[0]}")` to find its siblings, so install location is flexible — symlinks, copies, alternate paths all work as long as the three scripts stay in the same directory.

## Why alerter and not `osascript display notification`

`osascript -e 'display notification ...'` is truly native but **not clickable** — Apple removed the click-callback path for unsigned scripts on macOS 10.14+. `alerter` uses the modern `UNUserNotificationCenter` API and prints `@CONTENTCLICKED` / `@ACTIONCLICKED` to stdout when the user clicks the banner body, which is what makes click-routing possible.

`terminal-notifier` is the older alternative — it's broken on macOS Tahoe (uses the deprecated `NSUserNotification` API).

## Lessons learned

See [`LESSONS.md`](./LESSONS.md) for the non-obvious things that took real debug time.

## License

MIT.
