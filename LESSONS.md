# Lessons learned

Hard-won knowledge from building this. Each item caused real debug time on macOS 26 (Tahoe).

## 1. `alerter` returns `@ACTIONCLICKED` on body click, not `@CONTENTCLICKED`

The README on `vjeantet/alerter` suggests `@CONTENTCLICKED` for body clicks. On macOS Tahoe (26), default body-clicks come back as `@ACTIONCLICKED`. Match **both** in your `case` statement:

```bash
case "$result" in
  *CONTENTCLICKED*|*contentClicked*|*ACTIONCLICKED*|*actionClicked*)
    # treat as click
    ;;
esac
```

## 2. `terminal-notifier` is dead on macOS Tahoe

It uses the deprecated `NSUserNotification` API. Don't reach for it. Use `alerter` — it uses modern `UNUserNotificationCenter`, supports clickable callbacks, and is actively maintained at `vjeantet/tap/alerter`.

## 3. Recent tmux overrides `TERM_PROGRAM=tmux`

This clobbers the real outer terminal. To recover, walk the process tree from any process attached to the tmux client tty upward via PPID until you hit a known GUI terminal:

```bash
tty_short="${client_tty#/dev/}"
tty_pid=$(ps -t "$tty_short" -o pid= 2>/dev/null | head -1 | tr -d ' ')
while [ -n "$tty_pid" ] && [ "$tty_pid" != "1" ]; do
  cmd=$(ps -o comm= -p "$tty_pid")
  case "$cmd" in
    */Terminal|Terminal)  term="Apple_Terminal"; break ;;
    */Cursor|Cursor)      term="vscode"; break ;;
    # ...etc
  esac
  tty_pid=$(ps -o ppid= -p "$tty_pid" | tr -d ' ')
done
```

**Do not use `lsof -t /dev/ttysXXX`** — it returned empty in our environment. `ps -t ttysXXX` works reliably.

## 4. `open -a Terminal` does NOT pick the right window

When multiple Terminal.app windows are open, `open -a Terminal` activates whichever was last frontmost — which is almost never the one you want. To target the **specific** window+tab, use AppleScript matching by tab `tty`:

```applescript
tell application "Terminal"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      try
        if tty of t is targetTty then
          set selected of t to true
          set index of w to 1
          set frontmost of w to true
          return
        end if
      end try
    end repeat
  end repeat
end tell
```

First run triggers macOS Automation permission prompt — user must allow once.

## 5. Detach hook background work with `( cmd & )`, not `nohup cmd &; disown`

We started with `nohup bash -c '...' &; disown` with embedded quote-juggling for the inner `bash -c`. Click events captured by `$()` weren't being dispatched — silent failure, no error.

The fix: pull the worker into its own script file (no quote nesting) and spawn it as:

```bash
( bash "$script_dir/worker.sh" "$arg1" "$arg2" </dev/null >/dev/null 2>&1 & )
```

The parenthesised subshell exits immediately, orphaning `worker.sh` to launchd. No nohup needed. Clean and bulletproof.

## 6. `tmux switch-client -c <client_tty> -t <target>` is the magic

Without `-c`, `switch-client` targets the most-recently-active tmux client, which may live in the wrong terminal window. `-c <client_tty>` (from `tmux display-message -p '#{client_tty}'`) routes the switch to the specific tmux client attached to that terminal window. This is what makes multi-window tmux click-back work.

## 7. Hook timeout is not "permission to block"

Stop hooks block the next user turn until they complete (or the configured timeout fires). Even if you set `timeout: 60`, blocking that long destroys interactive feel. Always:

1. Do parsing and gating synchronously.
2. Spawn long-running work (the actual notification) into the detached worker.
3. `exit 0` in <100ms.

The `timeout` field is a safety net, not a budget.

## 8. Aerospace doesn't auto-follow `open -a App`

If Terminal.app's window is on Aerospace workspace 7 and you're on workspace 1, `open -a Terminal` activates Terminal but Aerospace stays on workspace 1. After AppleScript activates the right window, explicitly switch workspaces:

```bash
target_ws=$(aerospace list-windows --focused --format '%{workspace}')
cur_ws=$(aerospace list-workspaces --focused)
[ "$target_ws" != "$cur_ws" ] && aerospace workspace "$target_ws"
```

## 9. `osascript display notification` is NOT a real alternative

It's truly native — and not clickable. Apple removed the click-callback path for unsigned scripts in 10.14+. Don't waste time trying to make it work with click handlers. Use `alerter` (or build a tiny Swift app wrapping `UNUserNotificationCenter` if you really can't depend on brew).

## 10. AppleScript sees only ONE Terminal.app process at a time

macOS allows multiple Terminal.app processes to be running simultaneously (common under tiling WMs like Aerospace, which can spawn a separate Terminal.app per workspace). `tell application "Terminal"` only talks to one of them — windows in the others are completely invisible to AppleScript.

**Symptom**: notification click lands on the wrong Terminal window even though tty-match logic seems correct — because the target tab's tty is in a Terminal.app process that AppleScript can't see.

**Fix**: don't rely on AppleScript for window targeting. Walk `ps` from the tmux client tty up to find the GUI app PID, then use Aerospace:

```bash
wid=$(aerospace list-windows --monitor all --pid "$gui_pid" --format '%{window-id}' | head -1)
aerospace focus --window-id "$wid"   # also switches workspace if window is on another one
```

Aerospace sees every window regardless of which process owns it.

## 11. tmux `allow-passthrough on` matters for OSC escape sequences

Not used in cc-notify v1 (the SSH branch just uses `\a` bell), but if you ever want to forward iTerm2-native notifications through tmux from a remote machine, you need this in `~/.tmux.conf`:

```
set -g allow-passthrough on
```

Then `printf '\033]9;your message\007'` from inside tmux makes iTerm2 show its own native notification on the host machine, with no third-party tool. Doesn't work for Terminal.app, only iTerm2/Ghostty.
