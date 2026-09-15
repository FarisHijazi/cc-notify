# 2026-09-15 — v1.8.9: chasing a reported 14s click, and what it actually costs

Follow-up to `claude_20260915-1045-cursor-vscode-focus.md`. User report: *"it
takes like 14 seconds to focus on the cc notify claude session when in cursor
for a remote session"*.

## Method

Nothing here is a guess — every number below was measured on the live setup
(Mac, Cursor Remote-SSH window on `thmanyah`, tw hub running ON that box).

v1.8.8 had already added elapsed-since-start stamps to `focus-route.log`. That
alone found the first 3s (see below). The rest of this session was spent trying
to find the other ~10s, and failing to reproduce it.

## What was measured

| step | cost |
|---|---|
| `cc_remote_hub_pane` (1 ssh) | 0.27s |
| `cc_focus_named_terminal <remote hub>` (fails — Ghostty-only) | 0.46s |
| `cc_focus_editor_window <host>` (aerospace) | 0.24s |
| `aerospace list-windows` | 0.03s |
| ssh warm (ControlMaster) / cold (`ControlPath=none`) | 0.03s / 0.21–0.27s |
| **materialize branch**: osascript returns | 0.31s |
| **materialize branch**: Ghostty window on screen | 0.49s |
| **materialize branch**: tmux client attached (what a user waits for) | 0.64s |
| hotkey no-op, 50 stale routes (before) | 1.73s |
| hotkey no-op (after) | 0.22s (0.15s of it the deliberate settle sleep) |
| **full hotkey → remote Cursor focus, end to end** | **1.14s** |

The materialize measurement used a throwaway **local** tmux session
(`cc-perf-probe`, killed by exact name afterwards) rather than the real remote
one: attaching a second client to the live hub would reflow the user's grid,
because tmux sizes a session to its smallest client.

## Conclusions

1. **The materialize branch was NOT the 14s.** It was the obvious suspect — it
   ran on every remote-Cursor click until 1.8.7 and opens a whole new window —
   and it is 0.64s. Same for ssh, the other obvious suspect, at 0.03s warm.
2. **The worst click actually recorded was 5s** (11:14:15 → 11:14:20, pre-1.8.8:
   3s dead poll + a cold-ish ssh + the window focus). Everything since 1.8.8 is
   0.5–1.1s end to end.
3. **14s was not reproducible.** Rather than keep theorising about Cursor's
   window raise or the remote terminal's repaint — neither of which any shell
   measurement can see — both entry points now log their own total, so the next
   slow click says where the time went instead of inviting another guess.

## Changes

- `bin/cc-banner-click`: stop `pgrep`-ing every `.route` ever written. `ls -t` is
  newest-first and a route is (re)written when its banner is posted, so a route
  older than the banner's own lifetime cannot have a live alerter — break there.
  Cutoff is `CC_BANNER_TIMEOUT` (120s) + 5min of slack, which covers the wrapper
  not inheriting a session's raised timeout. **1.73s → 0.22s.**
- `bin/cc-banner-click`: one `elapsed_log` helper, called at **both** exits — the
  no-op exit is precisely the branch the stale scan was costing 1.7s in.
- `hooks/cc-notify-bg.sh`: time the click→focus leg (`BANNER CLICK end-to-end`).
  This is the only place that can measure the banner path; the hotkey path has
  its own timer.

Both write to `/tmp/cc-notify/focus-route.log`, next to the per-tier lines, so a
total and its breakdown are always in the same place.

## Not done, deliberately

- **`ConnectTimeout=5` on the remote path's ssh.** Off the home LAN,
  `thmanyah.local` (192.168.0.43) is unroutable and that call would block its
  full 5s before any fallback runs — the one mechanism found that *could*
  produce a double-digit click. Not tuned: it has never been observed, and a
  shorter timeout trades a real failure mode (slow link) for a hypothetical one.
  Listed here so the next person recognises it rather than re-deriving it.
- Hub-tile-vs-own-window precedence ("whichever was focused last") — still
  skipped at the user's choice; the hub tile wins for local sessions.
