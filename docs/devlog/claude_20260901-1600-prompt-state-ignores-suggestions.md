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

## Shipped as v1.7.18

Released the fix on its own rather than waiting for v1.8.0: this tree is
mid-v1.8.0 with ~18 other dirty entries, and the bug silently disables every
send-keys consumer in the meantime.

How a release works here, since nothing records it: the marketplace
`farishijazi-plugins` (repo `FarisHijazi/claude-plugins`) points this plugin at
`github:FarisHijazi/cc-notify` with **no version or tag pin**, so it tracks
`main`'s HEAD — pushing to `main` *is* the release. The repo carries no tags at
all. `~/.claude/plugins/cache/farishijazi-plugins/cc-notify/<version>/bin` is
what lands on `$PATH`, and the dir is named by `plugin.json`'s `version`, which
is why the bump matters: without it the new code would overwrite the `1.7.17`
dir and two different states would share one name.

Only `.claude-plugin/plugin.json` (version line), `bin/cc-prompt-state` and this
devlog went into the commit; the v1.8.0 work (including plugin.json's own bump to
1.8.0 and its new description) stayed uncommitted in the tree, restored
afterwards. Then `claude plugin update cc-notify` -> cache dir `1.7.18`, verified
carrying the fix and correct on all 6 live panes.

Note: the update left `installed_plugins.json`'s `gitCommitSha` at the old
`e669259` while `version`/`installPath` moved to 1.7.18 — Claude Code's
bookkeeping, harmless (worst case a future `update` re-fetches).
