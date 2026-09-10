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
UserPromptSubmit (`cc-capture-window.sh` — the precise cleanup); (b) restore the
default timeout `86400 → 120` (env `CC_BANNER_TIMEOUT`) so any un-reaped walk-away
orphan self-dies in 2min. The **SessionEnd reap is the real orphan fix**; the short
timeout is the backstop. Trade-off: a reply >120s after the banner appeared can't
`--remove` an already-exited worker → that stale banner lingers (raise
`CC_BANNER_TIMEOUT` if you want a longer removal window, but note the RAM cost).
Peak concurrent alerter RAM is now ≈ (sessions with a banner in the last 2min) ×
30MB, self-limiting. **Rule: a per-item blocking helper's timeout is a memory
multiplier — `timeout × peak concurrent items`. Any long-lived-process design needs
an owner that reaps it on *every* exit path (here: reply AND session end), not just
the happy one.**

## 20. Unsubmitted TUI input is invisible to hooks — read the pane, and let a menu look like a menu

Anything that types into a Claude Code session with `tmux send-keys` (an
auto-`/compact` hook, an auto-continue, any nudge) will happily append its text
to a half-written message and submit the whole thing. Claude Code exposes
**nothing** for in-progress input: no hook fires on a keystroke, no env var or
file holds the draft, and `UserPromptSubmit` is by definition too late. The only
observable is **what the TUI has drawn**, so read it: `tmux capture-pane -p -t <target>`.

**Locating the input box — don't grep for `❯`.** The obvious check ("last line
starting with `❯`, is there text after it?") has a dangerous false positive: an
**AskUserQuestion menu uses `❯` as its selection cursor**, so an open menu reads
as "prompt with text", and worse, other dialog states read as an empty prompt.
Instead match the box *structurally*: it is the region between the **last two
horizontal-rule (`─`) lines** at the bottom of the screen, whose first row starts
with `❯`. A menu's cursor isn't bracketed that way, so it correctly reports "no
input box" — which callers must treat as **unsafe to type into**, not as empty.
This also handles multi-line drafts (the whole region is the content) and
survives the slash-command autocomplete popup, which renders *above* the box and
leaves the region intact.

**Two things about that row are not what they look like** (both cost a shipped
feature; fixed in 1.8.2):

- **A recognised slash command is drawn COLOURED**
  (`ESC[38;5;153m/compact`), so the default default-foreground-only reading —
  the very rule that keeps the prompt suggestion out — reports `""` for
  `/compact` and `orange` for `/color orange`. A caller that types text and then
  compares the read-back to it therefore ALWAYS aborts. Read back with `--raw`
  (escapes stripped, colours kept) for that check, and keep the default reading
  for the is-it-empty check beforehand: they are different questions.
- **The marker is separated from the text by U+00A0**, and an empty row is
  exactly `❯`+U+00A0. `[[:space:]]` matches U+00A0 on macOS but **not** under
  glibc, so the same empty box read as empty on the Mac and as one character of
  user input on Debian — every Linux box silently refused to type anything.
  Fold U+00A0 before trimming. It is also the one reliable way to tell an UNSENT
  row from the transcript echo of a submitted line, which uses an ordinary
  space.

**A swallowed Enter looks exactly like success.** Typing and pressing Enter are
two keystrokes, and Enter can land while the TUI is still opening the
slash-command menu. Pause (~1s) between them, and afterwards poll the input row
and press Enter again for as long as the text is still there.

**Check twice, and never "clean up".** Between the emptiness check and the
`Enter` there is a real (if small) window for a keystroke. So: check empty →
send the text literally → **re-read the box and confirm it holds exactly what you
typed** → only then send `Enter`. On a mismatch, abort and leave the text sitting
there unsent. Do NOT try to erase it with `BSpace` — backspaces delete from the
cursor backwards, which is precisely the characters the user just typed. An
unsent stray `/compact` is visible and harmless; eating their input is not.

**Fail closed.** If the box can't be read at all (helper missing, not tmux, pane
gone), do nothing. A skipped compaction is recoverable on the next turn; a
mangled and submitted message isn't.

The same primitive answers "is the user typing *right now*" for anything else
that wants it — cc-notify uses `cc-prompt-state --watch` to clear a banner on
the first keystroke, comparing against a snapshot taken when the banner appeared
so a pre-existing draft doesn't count as a fresh keystroke.

## 21. Session color has NO programmatic API — but `/color` takes an inline argument

Researched exhaustively (docs, GitHub issues, `strings` over the v2.1.222
binary): a **running** session's color can only be changed from inside its own
TUI. No CLI flag, env var, settings key, SessionStart-hook output field, or SDK
option exists (each has an open feature request). Externally appending an
`{"type":"agent-color",…}` line to the transcript does nothing live — the TUI
keeps color in-process and only re-reads it on resume. A hidden
`--agent-color <color>` launch flag exists (teammate spawning), but it feeds
in-memory state and writes **no transcript line**, so transcript-reading tools
never see it.

Two facts make self-service possible anyway: `/color` accepts an inline
argument (`/color purple` — full list red/orange/yellow/green/blue/purple/pink/
cyan/default), and it's a *local* command (applies instantly, no API turn, no
Stop hook). So a hook CAN recolor its own session by typing into its own tmux
pane — through the #20 `cc-prompt-state` dance, never blind. That's v1.7.17's
`.cc/settings.json` color sync (`hooks/cc-color-apply.sh`).

**Corollary — anchor transcript greps the moment they drive actuation.** The
loose `"agentColor":"[^"]*"` match was fine when it only picked a banner emoji,
but a transcript that merely *quotes* such a string (any session developing
cc-notify!) would have leaked quoted colors into `.cc/settings.json` and
recolored future sessions. Real records are whole lines — match
`^{"type":"agent-color",…` (verified: anchored count == loose count across real
transcripts). Display can tolerate false positives; actuation can't.

## 22. Remote sessions: the hard half is already solved by whatever DISPLAYS them

"Notify me about Claude Code running on another machine" looks like one problem
and is really two, and only one of them is hard:

1. **Signal out** — get the event home. Easy, and there are four ways.
2. **Route back** — make a click land somewhere useful. This is the one that
   normally kills the feature… unless something already answers "where is that
   remote session visible on this Mac?"

For cc-notify that something is **tmux-watch**, which tiles remote tmux sessions
into a local hub and tags each pane `@tw-src = "<host>\t<session>"`. That tag is a
stable address (it survives pane renumbering, and inner programs rewriting the
title can't corrupt it), so `pane = f(host, session)` is one `tmux list-panes -a`.
Once you have the pane, "focus a remote session" reduces to "focus a local pane" —
the code that already existed. **Before designing a routing scheme, look for a
component whose whole job is displaying the thing; it is holding the key.**

**Transport: prefer the Mac pulling over the remote pushing.** Four options
weighed: `ssh -R` reverse socket (dies with the ssh session, only reaches the
attached Mac), ntfy/webhook (third party sees your data), OSC escape sequences
(not clickable, terminal-specific), and a local `ssh <host> tail -F <events>`
streamer. The streamer wins on the axis that matters: it works whether or not
anyone is attached, reconnects on its own, and every Mac running one gets the
banner. It is also where **identity translation** has to live: the remote knows
only its own `hostname`, while the local pane is keyed by the **ssh alias** you
connect with (`ftower`). The streamer is the one process that knows both, so it
stamps the alias — no mapping table, no configuration.

**Split it so policy has one home.** The remote reports only facts its own
machine can know (transcript colour/title/outcome token, tmux coordinates, cwd,
branch); the Mac owns every decision about what that becomes. Concretely: the
facts→banner block was extracted from the local hook into `cc_present` and is
called by both paths, so local and remote presentation cannot drift — and the
remote half needs no redeployment when the vocabulary changes. It also keeps the
remote dependency-free (sed for the hook payload, grep for the transcript), which
matters: boxes running Claude Code's native installer have no `node` on PATH.

**Rotate an append-only event file by RENAME, never by truncation.** `tail -F`
follows the path: on rename it picks up the new empty file and reads nothing,
while an in-place truncate makes it re-read from offset 0 and replay every line
as a fresh event.

**Replay a little on reconnect, and dedupe by timestamp.** `tail -n 0` after a
blip silently swallows the "done" ping you were waiting for. Replaying the last
60s fixes that but re-fires banners — and, worse, re-fires a 🚨 auto-focus. Keep
the last handled timestamp per host and drop anything not newer. Whole seconds
are not enough (two events in one second → one dropped); use `$EPOCHREALTIME`,
with `LC_ALL=C` so the decimal separator is a dot.

## 23. A LaunchAgent has NONE of your shell's environment — `set -u` turns that into a silent half-write

The bridge worked perfectly when run from a terminal and failed under launchd
with no error: the route file it writes was **truncated mid-way** and no banner
appeared. Cause: the route includes `tmux_socket=${TMUX%%,*}`, and under launchd
`$TMUX` is unset. With `set -u` that is a fatal error, thrown *inside* a
`{ …; } > file` block — so the file was created, partially written, and the
function never reached the banner.

Two lessons, both general:

- **Every `$VAR` a daemon reads must be `${VAR:-}`.** A LaunchAgent inherits no
  `TMUX`, `TERM_PROGRAM`, `SSH_CONNECTION`, or `PATH` beyond what its plist sets
  (do set `PATH` — launchd's default omits `/opt/homebrew/bin`, where `tmux` and
  `alerter` live). Test with `env -i HOME=$HOME PATH=… bash script` before
  trusting a launchd run; it reproduces the failure in one command.
- **`set -u` inside an output redirection fails PARTIALLY.** The artifact exists
  and looks plausible — the tell was a 55-byte route file where a good one is
  184. When a script writes a record, a truncated record is a louder bug than a
  missing one; check sizes/line counts, not just existence.

## 24. `aerospace focus --pid` is a coin flip for Terminal.app — bridge AppleScript and Aerospace on the window TITLE

Terminal.app runs **many windows under one pid**, so
`aerospace list-windows --pid <pid> | head -1` focuses an arbitrary one. Locally
cc-notify dodges this by capturing the exact window id at SessionStart, when the
user was demonstrably looking at the right window — a session on another machine
has no such moment.

The two tools each know half the answer: only **AppleScript** can say which
window holds a given tty (`tty of t` over `tabs of w`), and only **Aerospace** can
focus a window across workspaces (LESSONS #10). They have no shared identifier —
but they report the **window title** identically (`farishijazi — tmux attach -t
hub/… — 212×68`), so matching on it converts one to the other exactly. That is
`cc_wid_for_tty`, and it is worth remembering as a general pattern: when two
tools address the same object with incompatible ids, look for a *rendered* field
both derive from the same source.

## 25. AppleScript `focus` REORDERS the window list — read what you need before mutating

```applescript
repeat with t in tabs of w
  if name of t starts with "<prefix>" then
    focus (focused terminal of t)
    return name of t          -- returns a DIFFERENT tab, every time
  end if
end repeat
```

`t` is an index-based reference (`tab N of window M`), not a snapshot. `focus`
makes the target window frontmost, which renumbers `windows`, so the `name of t`
evaluated afterwards resolves into the reordered list. The caller then looked up
that wrong name in Aerospace and focused a completely unrelated window — with no
error anywhere. `set n to name of t` **before** the `focus`, and return `n`.

The general rule: in AppleScript, treat every element reference as live. Any
command that can reorder, close or open windows invalidates every reference you
are holding, including the loop variable you are standing on.

## 26. Two hooks, one input box: the check-type-verify dance needs a LOCK

`cc-color-apply.sh` types `/color <name>` on SessionStart and the out-of-repo
`~/.claude/hooks/auto-compact-continue.sh` types `/compact` (or the continue
message) at a turn boundary — into the SAME pane. **PostCompact fires both at
the same instant.** Each one is individually correct and fails closed, and that
is exactly what makes the collision invisible: each checks the box is empty,
types, then re-reads and finds *the other one's text glued to its own*, so both
abort without pressing Enter. Neither command is ever submitted, and the loser's
text is left sitting in the box for whatever types there next to submit along
with its own. Real log lines, same second:

```text
colorsync.log      cctest: ABORT before Enter — box holds '/color bluecontinue and complete all…', expected '/color blue'
cc-autocompact.log cctest: ABORT before Enter — box is 'bluecontinue and complete all…', expected 'continue and complete all…'
```

That is where the mystery `orange`/`blue` prefixes on auto-compact messages came
from — not a parsing bug, a second writer.

`bin/cc-type-lock.sh` is a sourceable mkdir-lock (macOS has no `flock`) held
across the whole dance. Three things it must get right:

- **Key on `#{pane_id}`, not the caller's target string.** The two callers name
  the same pane differently (`farishijazi-3` vs `farishijazi-3:0.0`); keying on
  the string gives two locks and no exclusion at all.
- **Break a dead holder's lock** (pid recorded in the dir, `kill -0`), or one
  crash inside the dance wedges every later apply.
- **No pane id → return success WITHOUT a lock.** This is best-effort ordering;
  it must never become a reason to skip the work.

Verified with three real typists racing into one live Claude pane (`/color
purple` from SessionStart, `/color blue`, `/compact`): all three applied in
sequence, box empty afterwards. Mutual exclusion + stale-break also tested on
macOS and Debian.

## 27. There are TWO watch topologies, and the window is titled after the HUB

`cc_hub_pane` answers "which LOCAL pane is displaying `<host>:<session>`" by
reading `@tw-src` off local panes. That is the whole answer only when the
tmux-watch hub runs on the Mac. The other topology — `ssh <host>` in a Ghostty
window and run `tw` THERE — puts the hub on the remote box: **nothing local
carries `@tw-src`**, so the click concluded "nothing here is showing it" and
materialized a second window onto a session already visible on screen.

The tell is the window title. `set-titles-string '#S · #h'` names the tmux
session the client is attached to, which for this topology is the HUB:

```text
hub/farishijazi__3652b2 · fm3     Mac-side hub  → cc_hub_pane resolves it
hub/service__eec13a · dema        hub ON dema   → nothing local to match
```

`cc_remote_hub_pane <host> <sess>` closes it with one ssh: list the remote
panes, find the one whose `@tw-src` session field is `<sess>`, return
`<hub_session>\t<pane_id>`. Then focus the local window titled
`"<hub_session> · "` and `select-pane` the remote hub onto it. Two details that
matter:

- **Prefer an ATTACHED hub.** A box can hold several hub sessions (dema had
  three); an unattached one is on nobody's screen, so focusing a window named
  after it finds nothing and the click silently does nothing.
- **`exit` in awk still runs `END`.** The first version printed the attached hub
  *and* the fallback — two lines, and the caller's `${hub%%…}` split produced a
  session name with a newline in it. Guard END with the same flag.

Also: `cc_focus_named_terminal`'s injection guard had to learn `/`, since every
hub session is named `hub/<user>__<hash>`.

## 28. The click had a stale-version glob and one unlogged cliff

Two separate reasons a click still opened a new window when the session was
plainly on screen.

**The hotkey ran a two-year-old script.** `bin/cc-banner-click` picked its focus
script with a plain `for candidate in ~/.claude/plugins/cache/*/cc-notify/*/hooks/cc-focus.sh`.
The cache keeps EVERY installed version and the glob is sorted ASCIIbetically, so
it always took the LOWEST — `1.7.17`, which predates remote-session handling
entirely: it returns 1, focuses nothing, and leaves the banner up. Sort the
candidates with `sort -V` and take the last. Any "newest plugin copy" lookup has
this bug latent in it; the auto-compact hook's `find_prompt_state` avoids it by
comparing mtimes.

**`cc_pane_route` failing was treated as "no window exists".** The remote branch
read `if [ -n "$pane" ] && cc_pane_route "$pane"` — but those are two different
questions. `cc_hub_pane` answers *is a pane displaying this session*;
`cc_pane_route` answers *can I walk that pane's tmux client tty up to a GUI
process*. The second can fail while the window is very much on screen, and the
`else` branch went straight to materializing a second window onto it. When the
pane was found, fall back to focusing **the hub session's own window by title**
and `select-pane` onto the tile — never materialize.

Both were invisible after the fact, because nothing recorded which tier
answered and the panes/clients/windows are gone by the time anyone asks.
`/tmp/cc-notify/focus-route.log` now logs every tier of the remote branch,
including the materialize as an explicit "NOTHING on screen was showing it".

## 29. tw OWNS the hub grid — wait for its watcher, never add a tile yourself

A click on a remote session whose hub tile did not exist opened a new Ghostty
window. The obvious fix — have cc-focus.sh `split-window` the missing tile into
the hub itself — is wrong, and measurably so: `tw` runs its own watcher and
re-adds tiles for sessions it discovers, so the click races it and the hub ends
up with **two tiles for one session**. Reproduced twice (panes %291/%292, then
%293/%294) before the approach was abandoned.

The right shape is to wait the owner out: on a miss, re-poll `cc_hub_pane` for
~3s and only fall through when the tile never appears. Same window, one tile,
and a session `tw` genuinely doesn't watch still materializes as before.

**Two tmux traps found on the way:**

- **tmux does NOT expand `\t` in a `-F` format.** `-F '#{pane_id}\t#{@tw-src}'`
  emits the two characters, so `awk -F'\t'` then splits on the REAL tab stored
  *inside* `@tw-src` and `$1` comes out as `%281\tdema.local`. `cc_hub_pane` has
  always used a literal tab in the format; a copy of it that used `\t` silently
  matched nothing. Byte-check with `od -c`, never by eye — the two look
  identical in a terminal.
- **A "read-only probe" that calls a function which splits a window is not
  read-only.** Probing `cc_hub_add_pane` with a non-existent session created a
  real pane; it only vanished because the `ssh … attach` failed and the pane
  closed itself.

## 30. A click maximizes the clicked session — and `resize-pane -Z` TOGGLES

You clicked a notification for one session; landing you on one tile of the grid
it happens to live in is not the answer. `cc_select_and_zoom` selects the pane
and zooms it, so the session you asked for fills the window.

Two tmux facts make the ordering matter:

- **Changing the active pane unzooms the window.** So the zoom has to be applied
  after the select, never before.
- **`resize-pane -Z` toggles.** The tempting shape — read the flag, select, then
  toggle — un-maximizes in exactly the case where the window was already zoomed
  on the pane you want, i.e. clicking the same banner twice. Select first, then
  read the flag, then zoom only when it is off.

Only windows with `#{window_panes} > 1` are zoomed: an ordinary single-pane
Claude session has nothing to maximize and setting the flag just leaves a stray
`Z` in its status line. Off switch `CC_NO_FOCUS_ZOOM=1` /
`~/.claude/notify.disable_focus_zoom` still selects the pane, it just leaves the
layout alone. The remote-hub tier does the same dance on the far box, inside its
single ssh command.

Tested for all five shapes (tiled → maximizes; zoomed elsewhere → moves the
maximize; already zoomed on the target → stays; off switch → selects only;
single-pane → no flag), then end-to-end on a live hub with the state restored.
