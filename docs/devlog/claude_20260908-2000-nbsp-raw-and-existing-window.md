# 2026-08 → 1.8.2: the input row's non-breaking space, `--raw`, and not stacking windows

2026-09-08. Three bugs, all found while fixing an out-of-repo hook
(`~/.claude/hooks/auto-compact-continue.sh`) that types `/compact`. Every one of
them lives in code this repo owns, and two of them had silently disabled a
shipped feature on every machine.

## The input row, byte for byte

```
ESC[39m ❯ U+00A0 ESC[38;5;153m /compact ESC[39m
```

- **A recognised slash command is COLOURED.** `cc-prompt-state`'s whole design is
  that typed input is default-foreground and decoration is not (LESSONS #20, the
  prompt-suggestion fix). Claude Code colours `/compact` and `/color orange`, so
  the reading a caller gets back is `""` and `orange` respectively. Both callers
  compare that to what they typed, so **both aborted one keystroke before
  Enter** — `cc-color-apply.sh` had never once applied a colour on this machine
  (`colorsync.log` is nothing but `ABORT before Enter — box holds 'orange',
  expected '/color orange'`), and the auto-compact hook had never once
  compacted.
- **The marker and the text are separated by U+00A0**, and an EMPTY row is
  exactly `❯`+U+00A0. `normalize()` trims with `[[:space:]]`, which matches
  U+00A0 on macOS and **not** under glibc — so the identical empty box reads as
  `""` on the Mac and as one character of "the user is typing" on Debian. That is
  why colour sync on dema/thmanyah only ever logged `SKIP — user is typing`.

## Changes

- `bin/cc-prompt-state`: `normalize()` folds U+00A0 first, so emptiness means the
  same thing on both OSes. New **`--raw`** mode reports the box with escapes
  merely stripped instead of dropping coloured runs. The default reading stays
  the right answer to *"is the user typing?"*; `--raw` is the right answer to
  *"is the text I just typed still sitting there?"*, which is a different
  question and only a caller that knows what it typed may ask it.
- `hooks/cc-color-apply.sh`: read back with `--raw`; wait `CC_COLOR_ENTER_DELAY`
  (1s) before Enter; then poll for `CC_COLOR_CONFIRM_SECS` (10s) and press Enter
  again while the command is still in the box. A swallowed Enter looks exactly
  like success, which is why this needs proving rather than assuming.
- `hooks/cc-lib.sh: cc_hub_pane` matches in three tiers — exact `(host,
  session)`, then the same box under another alias (strip `user@`, `:port`,
  case, `.local`), then **the session name alone when exactly one remote watch
  pane carries it**. `tw-remote` builds hubs from `faris@dema-dev:~` while the
  bridge stamps `dema`, so the exact match failed and every click materialized a
  second window onto a session already on screen. A local pane (empty host) is
  never returned for a remote lookup.
- `hooks/cc-lib.sh: cc_focus_named_terminal` + `hooks/cc-focus.sh`: before
  materializing, focus a Ghostty window ALREADY attached to that session — its
  tab name is the remote tmux title, `"<session> · <host>"`. Clicking twice used
  to open two windows.

## Trap: `focus` reorders Ghostty's window list under an in-flight reference

The first version read the tab name *after* focusing:

```applescript
if name of t starts with "<sess> · " then
  focus (focused terminal of t)
  return name of t          -- wrong tab, every time
end if
```

`t` is an index-based reference (`tab N of window M`). `focus` makes the target
window frontmost, which **renumbers `windows`**, so the later `name of t`
dereferences into the reordered list and comes back with an unrelated tab — which
the aerospace title lookup then dutifully focused. `set n to name of t` before
the `focus`, return `n`. Any AppleScript that mutates window order mid-iteration
has this bug.

## Also found: `set-titles` is a per-SERVER option

Both Debian boxes had `set-titles off` and the stock `set-titles-string`, because
their tmux servers were started before the dotfiles gained those lines — a config
file is read at server start, not on reconnect. So no remote session had a title
for anything to match on, which defeats both `cc_wid_for_tty`'s remote path and
the new window reuse. Set live on both servers; worth checking with
`tmux show -g set-titles` on any box where remote focus misbehaves.

## Tested

- `cc_hub_pane`, against the live hub (`thmanyah.local` + `career-coach-1`):
  exact ✓, `thmanyah` ✓, `service@thmanyah-dev` ✓, `192.168.0.43` ✓ (tier 3),
  unknown session → empty ✓, a LOCAL session name never returned ✓.
- `cc_focus_named_terminal`: materialized a real window for a throwaway remote
  session, matched `cc-focus-test · thmanyah` and focused it (aerospace confirmed
  the window id); no match → returns 1 and touches nothing.
- `cc-prompt-state`: on macOS AND thmanyah, empty box → `0 ''`, `/compact` typed
  → `0 ''` (default) / the text (`--raw`), plain text → `1 '<text>'` — identical
  verdicts on both OSes for the first time.
- `shellcheck` clean on the changed files apart from pre-existing notes.

The auto-compact hook deliberately does NOT depend on `--raw`: it lives outside
this repo and has to work against whatever plugin version a box happens to have,
so it reads the raw input row itself (anchored on the same U+00A0). Its half is
in `~/.claude/docs/devlog/claude_20260908-1930-autocompact-enter-and-nbsp.md`.

## Addendum (20:15) — the collision the `--raw` fix exposed

With `--raw` in place the read-back finally told the truth, and the truth was a
race. The first live PostCompact after deploying it logged, in the same second:

```text
colorsync.log      farishijazi-3:0.0: ABORT before Enter — box holds '/color bluecontinue and complete all tasks the user asked for', expected '/color blue'
cc-autocompact.log farishijazi-3:   ABORT before Enter — box is 'bluecontinue and complete all tasks the user asked for', expected 'continue and complete all tasks the user asked for'
```

Before the fix the same collision was there but unreadable: the colour hook's
line said `box holds 'blue'` (the `/color ` prefix eaten as decoration), which
looks like a parsing bug rather than a second writer. That is also the origin of
the stray `orange` that once got prepended to an auto-compact message.

Fix: `bin/cc-type-lock.sh`, a sourceable mkdir-lock keyed on `#{pane_id}` — see
@../../LESSONS.md #26 for why the key, the stale-break and the
no-lock-on-unknown-pane fallback all matter.

**Test** (`race_test.sh`): launch a real Claude in an isolated tmux session, wait
for the box, then fire three typists at once — SessionStart's own `/color purple`
(from `.cc/settings.json`), an injected `/color blue`, and
`auto-compact-continue.sh --force`. All three land in sequence:

```text
20:10:57 cctest-race:0.0: applied '/color purple'
20:10:59 cctest-race:   sent '/compact'
20:11:02 cctest-race:   applied '/color blue'
```

with the pane showing all three executed and the input box empty afterwards.
Mutual exclusion and stale-lock breaking are unit-tested separately on macOS and
on Debian (thmanyah).

**Harness trap**: `auto-compact-continue.sh --force` resolves its session from
`$TMUX`, so a test must fake it as `<socket_path>,<server_pid>,<session_id>` —
a bogus socket path silently yields an empty session name and the hook exits 0
having done nothing, which reads exactly like "the hook is broken".

## Addendum (20:35) — window reuse missed the box-side hub entirely

Reported: dema sessions still opened new Ghostty windows although they were on
screen in an `ssh dema` + `tw` window. `cc_focus_named_terminal` only ever looked
for a tab titled `"<session> · "`, and `cc_hub_pane` only reads LOCAL panes —
neither can see a hub that lives on the remote box. Live titles at the time:

```text
hub/farishijazi__3652b2 · fm3        Mac-side hub   (cc_hub_pane path, worked)
hub/thmanyah-local-service__96336b · fm3
hub/service__eec13a · dema           hub ON dema    (no local @tw-src at all)
```

`cc_remote_hub_pane` (cc-lib.sh) + a new tier in cc-focus.sh's fallback. Verified
against the live boxes with `focus` and the remote `select-pane` neutered so
nothing on screen moved:

```text
demaenergy_d-5    → hub/service__eec13a %562 → aerospace window 11270
control-service-2 → hub/service__eec13a %554 → aerospace window 11270
not-in-any-hub    → falls through and materializes (unchanged)
```

window 11270 is `hub/service__eec13a · dema`. See @../../LESSONS.md #27 for the
attached-hub preference and the `exit`-still-runs-`END` awk trap.
