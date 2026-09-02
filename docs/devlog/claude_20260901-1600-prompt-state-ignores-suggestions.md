# 2026-09-01 — `cc-prompt-state` read Claude Code's ghost suggestion as user input

## Symptom, found from the consumer side

`~/.claude/hooks/auto-compact-continue.sh` never fired in a live session. The
input box looked empty on screen, but:

```
$ cc-prompt-state ac-e2e
Name one SQL keyword.        # exit 1 = "user is typing, do NOT send-keys"
```

Nothing had been typed. That string was Claude Code's **inline prompt
suggestion** — the greyed-out next-prompt it offers in an idle box. Every
consumer of `cc-prompt-state` fails closed on exit 1 (correctly), so for as long
as a suggestion is on screen the whole send-keys stack — auto-compact, the
`/color` actuator, banner dismiss-on-typing — is silently disabled. This is the
same class of bug as LESSONS #20: the pane is the only observable, so anything
the TUI *draws* looks like input unless we can tell decoration from typing.

Two decorations qualify: the inline suggestion and the placeholder hint
("describe a task for a new session").

## Why the obvious fix is wrong

The suggestion is drawn **dim** (SGR 2), so "strip dim runs" looks like a
one-liner. It is not:

| Pane | box borders | decoration text | typed input |
|---|---|---|---|
| plain session | `38;5;244` (grey) | `2` (dim) | `39` (default fg) |
| tw/hub pane | `2` (dim) | `38;5;246` (grey) | `39` (default fg) |

Dim marks the *borders* in some themes and the *hint* in others; grey does the
same in reverse. Stripping dim wholesale deletes the rule lines the box is
located by, and `box_text` starts returning 2 ("no input box") for perfectly
normal panes — verified: it did exactly that on `farishijazi-2` and the hub pane.

The invariant that actually holds in every pane checked: **typed input is drawn
in the default foreground with no attributes; every decoration carries an
explicit SGR** — dim (2) or a colour (30-37 / 90-97 / 38;5;n).

## Fix

`capture-pane` now runs with `-e`, and one `awk` pass emits **two readings of
every row**, `$SEP`-separated:

- `clean` — all escapes stripped. What the box structure is detected on, so the
  rule lines and the `❯` marker survive whatever colour they are drawn in.
- `real` — default-foreground runs only. What the user actually typed.

`box_text` keeps its existing structure logic on `clean` and takes content from
`real`. Emitting both from one pass keeps them row-aligned; parallel arrays would
not — `$(...)` strips trailing newlines, and a decoration-only row collapses to
empty in one reading but not the other, which shifts every index after it.

The awk tracks dim via 2/22 and colour via 30-37/90-97/38/39, resetting both on
0, and re-initialises per line (tmux re-emits attributes at each line start).

## Validation — all 7 live panes, before vs after

| pane | before | after |
|---|---|---|
| `ac-e2e` (suggestion showing) | `1` `"Name one SQL keyword."` | **`0` `""`** |
| `farishijazi-2` (placeholder) | `1` `"describe a task for a new session"` | **`0` `""`** |
| `hub/farishijazi__…` (placeholder) | `1` `"describe a task…"` | **`0` `""`** |
| 4 genuinely empty boxes | `0` `""` | `0` `""` |
| real text typed | `1` `"genuine input here"` | `1` `"genuine input here"` |
| after `C-u` | — | `0` `""` |
| `/` command menu open | `1` | `1` (the `/` is real input) |
| nonexistent target | `2` | `2` |

Exit-code contract unchanged. No regression: nothing that was safe became
unsafe, and three panes that were wrongly unsafe are now correctly safe.

## Not done here

Version not bumped and nothing committed — this tree is mid-v1.8.0 with a dozen
files already modified. The same patch was applied to the live plugin cache copy
(`plugins/cache/*/cc-notify/1.7.17/bin/cc-prompt-state`) so the fix is effective
immediately; that copy is disposable and will be replaced by the next install,
which is why the durable fix is a release from here.
