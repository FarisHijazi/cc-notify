# v1.9.1 — a Ghostty window running `tw dema.local:` was invisible to the click

**Reported:** click-to-focus lands correctly for Cursor/VS Code (tmux, local and
over ssh) and for local Ghostty+tmux, but a **remote** session tiled in a local
`tw` hub does not — the banner opens a *new* Ghostty window attached to just
that tcc session instead of jumping to the hub window already showing it.
`dema` was the live example.

## What the logs said, and why it was a dead end

`/tmp/cc-notify/focus-route.log`, three consecutive dema clicks:

```
dema:demaenergy_d-2 — tw does not watch this host locally; skipped the 3s watcher wait
dema:demaenergy_d-2 — cc_hub_pane=none
  cc_remote_hub_pane=hub/demaenergy-d__e3f05b	%712
  → NOTHING on screen was showing it; materialized a new window
```

Both statements were false at the time they were printed: eight local panes
carried `@tw-src` for that host, and `hub/dema-local-service__f29e35` was on
screen in Ghostty window 990. Running the same lookups by hand returned `%25`
immediately — so the functions were right, and the environment was not.

## Cause

Every "where is this session on screen" lookup splits tmux-watch's
`@tw-src = "<host>\t<session>"` on a tab. **tmux sanitizes unprintable bytes out
of `#{...}` format output when its client is not in UTF-8 mode**, and a TAB is
unprintable. Same pane, same server, same second:

```
LC_CTYPE=UTF-8   →  dema.local \t demaenergy_d-2      (2 fields)
no locale        →  dema.local _  demaenergy_d-2      (1 field, host gone)
```

The remote bridge is a launchd agent whose plist sets `PATH` and nothing else.
Everything it spawns — including `cc-focus.sh` on a banner click — inherited a
locale-free env, so `_hosts`, `cc_hub_pane` and `cc_host_watched_locally` went
blind **together**, and the click fell past every local tier into "materialize".

Local hooks were never affected: a GUI terminal inherits a UTF-8 locale from the
login shell. `thmanyah` masked it too — its hub runs *on* the box, so the click
fell through to `cc_remote_hub_pane` + `cc_focus_editor_window` and landed on the
Cursor Remote-SSH window anyway. One topology happened to have a second path
home; `dema` did not.

This is the same root cause as the "`dema.local` gets no bridge streamer" known
issue in CLAUDE.md, which was logged as reproducible with the cause unchased.

## Fix

- `hooks/cc-lib.sh` — `cc_ensure_utf8`, run at source time. Returns early when
  the env is already UTF-8; otherwise probes `locale charmap` for the first of
  `C.UTF-8` / `en_US.UTF-8` / `UTF-8` that really answers `UTF-8`, unsets a
  hostile `LC_ALL`, exports `LC_CTYPE`. Bare `UTF-8` is macOS-only — on glibc it
  resolves to ANSI_X3.4-1968, i.e. the exact breakage. Per-command `LC_ALL=C awk`
  prefixes still win.
- `hooks/cc-lib.sh` — `cc_remote_hub_pane` sets `LC_CTYPE` on the **far** side
  too; a non-interactive ssh command gets whatever locale sshd hands it.
- `bin/cc-remote-bridge` — `_hosts` now dedupes by `cc_host_key`, pinned entries
  first. Restoring discovery would otherwise have given a box pinned as `dema`
  and tiled as `dema.local` two streamers racing to write the same route file.
- `hooks/cc-lib.sh` — `cc_focus_named_terminal` also matches **Terminal.app**
  tabs, not just Ghostty (both name tabs from the tmux title). Each branch is
  guarded by `pgrep -xq`, because `tell application "X"` launches a non-running
  app — the "is one already open?" question must not itself open one.

## Verified

`env -i HOME=… PATH=…` (the agent's real environment), against the live panes:

| topology | before | after |
|---|---|---|
| local ghostty + tmux hub tile | wid 1212, tile `%38` | unchanged |
| remote thmanyah, Cursor Remote-SSH | wid 89 via remote hub | unchanged |
| **remote dema, local `tw` hub** | **materialized a new window (+1.55s)** | **wid 990 + tile `%25` (+0.09s)** |

Isolated `tmux -L ccztest` server, 4 panes, zoomed on the *wrong* pane, run in
the locale-free env: pre-fix lib → `cc_hub_pane` = none (FAIL); post-fix →
resolves the tile, `cc_select_and_zoom` moves the zoom onto it, idempotent on a
second call.

Bridge `--test` now writes a route carrying real local coordinates
(`term=ghostty`, `tmux_target=hub/dema-local-service__f29e35:0.4`, `gui_pid=656`)
where it previously wrote `term=tmux` and five empty fields — which also restores
dismiss-on-typing and the hub pane status border for remote sessions.

## Note for next time

`env -i` is the test. A daemon's environment is not your shell's, and a lookup
key that comes back *reshaped* rather than *empty* will be reported by the logs
as a confident, wrong conclusion.
