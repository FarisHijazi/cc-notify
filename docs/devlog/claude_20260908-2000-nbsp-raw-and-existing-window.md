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
