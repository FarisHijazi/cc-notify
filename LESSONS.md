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

## 16. `open -g <url>` STILL activates the app — never use it for background updates

`open -g` is documented as "do not bring the application to the foreground," and
that holds for `open -g -a App`. But `open -g "cursor://…"` (a URL **scheme**)
*still activates the app* — macOS brings the handler app forward to deliver the
URL, and under Aerospace that yanks you to the app's workspace. Confirmed by test:
from workspace 2, `open -g "cursor://…"` jumped focus to workspace 7 (Cursor).

So a URL must only be `open`ed in response to a real user action (clicking a
notification — activation is wanted there). For **proactive** background updates
(e.g. renaming a terminal tab on every turn-end) do NOT use `open`. cc-notify
writes a state file (`/tmp/cc-notify/<sid>.tab`) that the extension watches with
`fs.watch` and acts on — zero `open`, zero activation, zero focus steal.

Related: `cc-capture-window.sh` must only save the focused window as the jump-back
target when it belongs to a terminal/editor app. A session driving Chrome (browser
automation) would otherwise capture Chrome's window → clicking the notification
focuses Chrome. Whitelist the real hosts (Cursor/Code/Terminal/iTerm2/Ghostty/…).

## 17. Renaming a VS Code/Cursor terminal tab safely (no focus steal)

`workbench.action.terminal.renameWithArg` with `{name}` works, but **only on the
active terminal** — no terminal-id variant exists. Two ways to target a specific
non-active terminal, and only one is steal-free:
- `terminal.show()` first → reveals/raises the window (focus steal). ❌
- Wait until that terminal is the active one, then `renameWithArg`. ✅

So the extension: on a `.tab` change, if the target's pid == `activeTerminal`'s pid
→ rename now; else stash it and rename on the next `onDidChangeActiveTerminal`.
Crucially, `renameWithArg` on an active terminal does **not** raise the window —
even in a background (unfocused) window it renames silently. So tabs update across
workspaces with no steal, as long as we never call `show()`.

For single-terminal windows (e.g. one Cursor terminal running tmux) the terminal
is always the active one, so renames land immediately. Native tab **color** can't
be set for an existing terminal via any API (`createTerminal({color})` only, and
even that is unreliable) → use a color **emoji** in the name instead.

## 18. The tab status had two writers with MISMATCHED gating → ⏳ froze forever

The terminal-tab status has two write paths:
- **cheap** (`cc_set_status`, in `cc-capture-window.sh` for PreToolUse/PostToolUse/…):
  swaps just the leading status emoji on the existing `.tab`. **No gate** — needs
  only the file to exist. This is what writes the mid-turn **⏳ "running"**.
- **full** (`cc_write_tab`, in `cc-notify.sh` for Notification/Stop): rebuilds the
  whole `<status> <color> <title>` name. **Gated** on `term=vscode` from
  `cc_detect_terminal` — which is **flaky under tmux** (it walks the tmux client
  tty up to the GUI app; a momentary miss leaves `term=tmux`, not `vscode`).

The bug: a session ends → `Stop` fires → `cc_detect_terminal` flakes →
`if term=vscode` is false → **the full write is skipped entirely** (there was no
`else`). The last thing that touched the tab was the *ungated* cheap ⏳, so the tab
**freezes on ⏳** even though the turn is done. Only bites tmux-in-editor sessions
(plain non-tmux Cursor detects reliably). Symptom: "finished sessions still show the
hourglass, and clicking/focusing doesn't fix it" — focus can't help, the `.tab` file
itself held ⏳.

**Rule: if a low-frequency 'final' write is gated more strictly than the
high-frequency 'in-progress' write that precedes it, the in-progress state sticks
whenever the gate fails.** Fix = give the gated write a cheap, ungated fallback:
`if term=vscode … else cc_set_status "$sid" "$status_emoji"`. The cheap path can
always at least swap the emoji on the existing tab, so ⏳ can never outlive the turn.

To resync already-stuck tabs without restarting sessions: for each `.tab` whose name
starts with ⏳, `cc_set_status` it to (transcript token via `cc_last_status_token`,
else `ℹ️`). Skip sessions whose transcript changed in the last ~45s — those are
genuinely still running, and a ⏳ that reverts right after you "fix" it is the tell
that the session is active, not stuck.

## 19. A long banner `--timeout` × orphaned workers = multi-GB alerter RAM leak

Each `alerter` banner is a **blocking ~30MB process** that lives for the whole
`--timeout` (it exits cleanly at the end: `@TIMEOUT`). v1.7.11 raised the timeout
`120s → 86400s` (24h) so a late reply could still `--remove` the banner (on Tahoe
`--remove` only works by closing a *live* worker — see #14). The trap: `kill-stale`
in `cc-notify.sh` (`pkill -f "alerter.*cc-<sid> "`) only matches the **same
session_id**, so it dedups *within* a session but never reaps another session's
worker. When a session **ends** (or you just walk away) with an unclicked banner,
its alerter becomes an **orphan** — a new session has a new id, so nothing kills it,
and at 24h it's a 30MB zombie for a full day. Across hundreds of sessions/day the
orphans piled up to ~20GB RSS (~680 procs). With the old 120s timeout orphans
self-died in 2 min so they never accumulated — the leak was *created* by the 24h
bump, not present before.

Symptom: `alerter` using tens of GB with **no single huge process** — it's hundreds
of ~30MB processes. `ps -eo rss,command | awk '/\/alerter /{r+=$1;n++}END{print n, r/1024/1024" MB"}'`.

Fix (v1.7.13): (a) reap the session's worker on **SessionEnd** too, not just
UserPromptSubmit (`cc-capture-window.sh` — the precise cleanup); (b) drop the
default timeout `86400 → 600` (10min) — still 5× longer than the 120s that was too
short to cover real reply windows, but bounds a walk-away orphan to minutes instead
of a day. Peak concurrent alerter RAM is now ≈ (sessions with a banner in the last
10min) × 30MB, self-limiting. **Rule: a per-item blocking helper's timeout is a
memory multiplier — `timeout × peak concurrent items`. Any long-lived-process design
needs an owner that reaps it on *every* exit path (here: reply AND session end), not
just the happy one.**
