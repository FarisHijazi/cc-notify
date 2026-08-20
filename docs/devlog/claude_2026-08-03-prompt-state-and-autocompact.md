# 2026-08-03 — cc-prompt-state, dismiss-on-typing, autocompact --force

Three asks, one new primitive underneath all of them. See @../../LESSONS.md #20
for the reasoning, @../../CLAUDE.md for the v1.7.16 summary.

## The primitive: `bin/cc-prompt-state`

Answers "what is in this session's input box right now?" — which nothing else
can. Claude Code exposes no hook, env var, or file for **unsubmitted** input
(`UserPromptSubmit` fires only after Enter), so the sole observable is the drawn
TUI, read with `tmux capture-pane`.

Box location is **structural**, not a `^❯` grep: the region between the last two
`─` rule lines at the bottom of the pane, first row starting with `❯`. That's
what makes an AskUserQuestion menu — whose `❯` is a *selection cursor* — report
"no box" instead of masquerading as a prompt.

```
cc-prompt-state <target>                 # 0 empty · 1 has text · 2 no box
cc-prompt-state --watch <t> [to] [poll]  # 0 when content CHANGES · 1 timeout · 2 gone
```

Written for bash 3.2 (`/bin/bash`) — no `mapfile`/assoc arrays. Prepends the
homebrew/local bin dirs if `tmux` isn't on PATH, since the detached banner
worker doesn't inherit a full environment.

## 1. Dismiss-on-typing (`hooks/cc-notify-bg.sh`)

One `--watch` per banner, target from the route file's `tmux_target`; on change
it runs the LESSONS #11 removal ordering (synchronous `--remove` → `sleep 0.3`
→ `pkill`). Watcher is killed the instant `alerter` returns, so it can't outlive
the banner (LESSONS #19's reap-on-every-exit-path rule). Baseline snapshot at
banner time means a pre-existing draft doesn't self-dismiss. `CC_NO_TYPE_DISMISS=1`
off switch, `CC_TYPE_POLL` interval.

## 2 + 3. `~/.claude/hooks/auto-compact-continue.sh` (out of repo, dotfiles)

- `--force` / `--skip-check`: compacts regardless of context %, so a session can
  self-trigger. No hook JSON on stdin in that mode → session id from
  `CLAUDE_CODE_SESSION_ID` (confirmed present in the Bash tool env).
- **The reported bug**: `/compact` was being appended to whatever the user was
  typing and submitted with it. Now every `send()` (both `/compact` and the
  PostCompact "continue" nudge) is gated: box must be empty → type → **re-read
  and confirm it holds exactly what we typed** → only then Enter. Mismatch =
  abort, leaving the text unsent and NOT backspacing (backspaces would eat the
  user's own newest characters). No helper / not tmux / dialog open → do
  nothing. A skipped Stop-triggered compaction drops the pending marker so the
  next Stop retries rather than dead-windowing for 2 min.
- Resolves cc-prompt-state dev-repo-first, then newest plugin cache — the same
  version-proof pattern as the Karabiner fix (v1.7.11), never a pinned version
  dir. Log: `$TMPDIR/cc-autocompact.log`.

## Verification

- `cc-prompt-state` run against **all 21 live panes**: every result matched a
  hand-checked capture — empty, English/Arabic drafts, and the one session with
  an AskUserQuestion menu open correctly returned "no box" (that pane is exactly
  the case that would have been corrupted).
- `--watch`: stayed blocked 3s idle, exited 0 within 1s of a simulated keystroke
  (synthetic TUI rendered into a throwaway tmux session by `fakebox.sh`).
- Hook against a **real** disposable `claude` session in tmux: with `/compact`
  already typed → refused, box untouched, logged SKIP. With an empty box →
  typed, verified, submitted; the session ran the real command (`Not enough
  messages to compact.`). Confirms the slash-autocomplete popup neither breaks
  parsing nor hijacks Enter.
- Banner E2E: typing cleared it in ~1s; a no-typing banner expired with both
  alerter and watcher gone, no strays (`pgrep cc-prompt-state` → none).
