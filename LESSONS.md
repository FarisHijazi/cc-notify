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

## 11. Don't use `code --reuse-window` / `cursor --reuse-window` for *focus*

It looks like a focus command but it's actually `--reuse-window <path>` — meaning "open `<path>` in an existing window, even if that path is a subdirectory of an already-open workspace." If `cwd` is a subdir, it re-opens that subdir as the active view, effectively losing the user's broader workspace context.

For "just focus the right window," enumerate windows from Aerospace and match by title:
- Editor titles follow `FILE — FOLDER` (or `FOLDER` if no file).
- Walk up from `cwd`: at each level, find a window whose last `—`-separated segment equals the basename.
- Priority: exact cwd basename, then parent, grandparent, etc.
- Focus the match with `aerospace focus --window-id <wid>` — no editor CLI involved, no path-reopening side effect.

## 12. tmux `allow-passthrough on` matters for OSC escape sequences

Not used in cc-notify v1 (the SSH branch just uses `\a` bell), but if you ever want to forward iTerm2-native notifications through tmux from a remote machine, you need this in `~/.tmux.conf`:

```
set -g allow-passthrough on
```

Then `printf '\033]9;your message\007'` from inside tmux makes iTerm2 show its own native notification on the host machine, with no third-party tool. Doesn't work for Terminal.app, only iTerm2/Ghostty.

## 13. Focusing a specific VS Code / Cursor terminal pane requires an extension

There is **no** way to focus a specific integrated terminal pane from outside the
editor. Confirmed dead ends (2026):

- **CLI**: `code` / `cursor` have no `--command` / focus flag. `workbench.action.terminal.focusAtIndex1..9` exist internally but can't be invoked from the CLI.
- **URI**: `open "vscode://command:..."` does **not** execute `command:` URIs — those only run inside trusted contexts (markdown hovers, webviews, tasks), not external `open`.
- **OSC escape sequences**: shell integration (OSC 633) is one-way (terminal → editor: cwd, exec status). No focus/reveal sequence exists, even though our hook runs *inside* the exact terminal.

The **only** working path is the extension Terminal API: `vscode.window.terminals[*].show()`. So cc-notify ships a ~40-line extension (`editor-extension/`) that registers a URI handler `vscode://farishijazi.cc-notify-focus/focus?pids=…` and calls `.show()` on the terminal whose `processId` is in the pid set.

**Matching by pid, two cases:**
- **No tmux**: Claude's shell is a direct ancestor of the hook (`hook → claude → shell → editor pty`), so the shell pid (== `Terminal.processId`) is in the hook's ancestor PPID chain.
- **tmux inside the editor**: the chain hits the launchd-parented tmux *server* and never reaches the editor's shell. The real `Terminal.processId` is the tmux *client's* login shell — a sibling, found via `ps -t <client_tty>`. So cc-notify adds every pid on `client_tty` to the candidate set too.

PIDs are unique per live process, so an ancestor/tty pid can only ever match the terminal we actually came from — never a sibling terminal.

Install unpacked by symlinking the folder into `~/.vscode/extensions/` and `~/.cursor/extensions/` (`bin/cc-install-editor-extension`); reload the window. `Terminal.processId` is a `Thenable<number>` (await it). `terminal.show(false)` reveals **and takes focus** (`true` would preserve focus elsewhere).

## 14. Claude logo on the banner: impersonate the bundle id — but only if it's AUTHORIZED

On modern macOS (Big Sur+) macOS ignores a notifier's custom icon and uses the
**sending app's** icon. So `alerter --app-icon <path>` does nothing. The icon can
only be changed by impersonating a bundle id: `alerter --sender com.anthropic.claudefordesktop`
draws Claude's orange logo (same trick as Boris Buliga's `terminal-notifier -sender`).

**The trap:** macOS **silently drops** a notification whose `--sender` bundle id
has no notification permission. `Claude.app` is usually unauthorized (people run
the Claude Code CLI, not the desktop app — it's never launched, never granted
notification permission). Result: every banner vanishes and you're left with only
Claude Code's own `terminal_bell` (the `\a` you hear). No error, no banner — looks
like cc-notify broke.

Check authorization in `~/Library/Preferences/com.apple.ncprefs.plist` (the `apps`
array, keyed by `bundle-id`, has a `flags` field; absent entirely = never
authorized). An authorized app (Cursor `com.todesktop.230313mzl4w4u92`, ScriptEditor
`com.apple.ScriptEditor2`) shows banners; `com.anthropic.claudefordesktop` was
absent → dropped. `bin/cc-notify-doctor` flags this.

So `--sender` is **opt-in** (`~/.claude/notify.claude_icon`); the default uses
alerter's own authorized sender so banners always show. The always-on orange comes
from `--content-image` instead (an attachment, no authorization needed). Don't
confuse "alerter ran successfully" with "the banner showed" — auth-dropped
notifications still exit 0.

## 15. Claude Code session name/color live in the transcript JSONL as typed lines

`/rename` writes `{"type":"custom-title","customTitle":"…"}`; Claude auto-writes
`{"type":"ai-title","aiTitle":"…"}`; `/color` writes `{"type":"agent-color","agentColor":"…"}`
(also appears inline). There is **no** session name/color in the hook stdin payload
or any env var — read them from `transcript_path`. Cascade name: customTitle →
aiTitle → cwd basename. (An earlier research pass wrongly concluded no session name
exists; the `/rename` → `custom-title` line is the source of truth.)

Renaming a VS Code/Cursor terminal tab: `workbench.action.terminal.renameWithArg`
with `{name}` works, but **only on the active terminal** — there's no terminal-id
variant. To rename a *specific* tab safely, the extension checks
`window.activeTerminal.processId ∈ pids` and only renames when it matches (true at
turn-end / prompt, when the user is in that terminal). Fire the URI with `open -g`
so the editor isn't pulled to the foreground. Native tab **color** can't be set for
an existing terminal via any API (`createTerminal({color})` only, and even that is
unreliable) → use a color **emoji** in the name instead.
