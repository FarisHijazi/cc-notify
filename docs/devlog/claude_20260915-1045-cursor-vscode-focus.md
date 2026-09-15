# 2026-09-15 — v1.8.7: click-to-focus for Claude in tmux inside Cursor / VS Code

Goal: a notification click should land correctly when Claude Code runs in tmux
inside a Cursor / VS Code **integrated terminal**. Two topologies, both in daily
use, both broken for different reasons:

- **local** — a `tcc` session in a local Cursor terminal, also tiled into a hub;
- **Remote-SSH** — a Cursor `[SSH: thmanyah]` window whose integrated terminal
  runs `tw` (a tmux-watch hub) *on the remote box*, with the Claude sessions
  remote and bridged here by `bin/cc-remote-bridge`.

Everything below was measured against the live setup before and after.

## What was actually wrong

| # | bug | evidence |
|---|---|---|
| 1 | the `vscode)` branch of `cc-focus.sh` issued **no tmux command at all** — `tmux_jump` was wired for Terminal.app/iTerm/Ghostty only | `grep -n tmux_jump` → 3 call sites, none in `vscode)` |
| 2 | `cc_pane_route` returns a hub tile as `term=vscode` when the hub's client lives in a Cursor terminal → the resolved `focus_pane` was routed into (1) and discarded | `cc-lib.sh` sets `CC_TERM=tmux` then `cc_walk_tty` resets it to `vscode` |
| 3 | `cc_detect_terminal` adopted a client from an **unrelated session** | `farishijazi-1` (monitor client only) resolved to `/dev/ttys001`, a Ghostty client on `hub/dema-local-service…`, `CC_TERM=ghostty` |
| 4 | no tier could see a Cursor window, so a remote hub hosted in one materialized a **new Ghostty window** | `focus-route.log`: `→ NOTHING on screen was showing it; materialized a new window` |
| 5 | `#{client_focused}` **is not a tmux format** — both client-selection sorts had a permanently blank primary key | `focused=[]` == `typo=[]`; absent from the binary's format table |
| 6 | a remote route's `cwd` is a **remote** path, and the vscode branch walked it up to match a **local** window | `cwd=/home/service/Projects/thmanyah.d/…` + a local `thmanyah.d` folder |
| 7 | `switch-client -c` fired on a recycled tty, because an empty `cc_client_session` compares unequal to everything | code read |
| 8 | the `.tab` write was gated on a flaky `term=vscode` with **no else** in `cc-capture-window.sh`, and `cc_set_status` no-ops when the file is absent → a session that flaked its first full event never got a tab, ever | `cc-lib.sh` `[ -f "$f" ] \|\| return 0` |

## What changed

- **`cc-focus.sh`**: `vscode)` now calls `tmux_jump`; the `*)` fallback does too
  (instead of logging "unknown term" and dropping a resolved tile); `tmux_jump`
  returns early when the tty hosts no client; the cwd→workspace walk is replaced
  by `cc_focus_editor_window` and gated on `remote_host` being empty.
- **`cc-lib.sh`**: `cc_detect_terminal`'s fallback loop is scoped to **this
  session's** clients (as `cc_pane_route` already was) and leaves `CC_GUI_PID`
  empty rather than fabricating one; `#{client_focused}` deleted from both sorts;
  new `cc_focus_editor_window <host> [cwd]` matching a Cursor/Code window on the
  `[SSH: <host>]` marker (with `cc_hub_pane`'s alias normalisation) or the
  workspace folder.
- **remote branch**: one `||` widens the *existing* window-focusing step —
  `cc_focus_named_terminal "$hub_sess" || cc_focus_editor_window "$remote_host"`.
  Deliberately **not** a new tier: inserted earlier, a host-level match would beat
  `cc_remote_hub_pane`'s session-level one, which in this topology always wins.
- **tab status**: the `term=vscode` gate is gone from **both** writers. The `.tab`
  is only ever acted on by a terminal whose `processId` is in its pid set, so
  writing one for a non-editor session is inert — this deletes the flaky
  conditional rather than adding a third branch to compensate for it (LESSONS #18
  at the root).
- **extension**: `"extensionKind": ["ui"]` (an extension with a `main` and no
  `extensionKind` deduces `['workspace']`, i.e. it would run on the remote host,
  where `~/.cursor-server/extensions/` is empty → no handler at all); breadcrumb
  **appends** instead of truncating; a pid miss no longer focuses an arbitrary
  terminal and logs what it saw instead.
- **doctor**: new section 8 — install per editor, `extensionKind`, folder-name vs
  manifest version drift (the v1.7.10 toast), `focus.log` liveness.

## Verified live

Remote-SSH headline, `career-coach-5` (tile deliberately **not** active):

```text
BEFORE  focused=163|Google Chrome   ghostty=3   active tile=%76 (career-coach-7)
AFTER   focused=98|Cursor … [SSH: thmanyah]   ghostty=3   active tile=%72 zoomed (career-coach-5)
```

`focus-route.log` across the change, same session, same hub:

```text
10:42:30   → NOTHING on screen was showing it; materialized a new window   ← before
10:45:13   → focused window for hub 'hub/thmanyah-d__66e6d0' (pane %72)    ← after
```

Regressions checked and clean: a `dema.local` session whose hub tile *is* local
→ Ghostty 61, pane `%156` zoomed; a local `tcc` session → Ghostty 60, pane `%63`
zoomed. Ghostty window count 3 → 3 throughout (nothing materialized).

Host alias matching: `thmanyah.local`, `thmanyah` and `faris@thmanyah:22` all
resolve to window 98; `dema` correctly resolves to nothing.

Detection fix: `farishijazi-1` now reports `CC_TERM=tmux`, empty `CC_GUI_PID`,
and its **own** `/dev/ttys010` — no longer another session's Ghostty client.

## Still open

- **Local tmux-in-Cursor** (topology a) is implemented but not yet exercised
  end-to-end — it needs a local (non-SSH) Cursor window with a `tcc` session in
  its terminal, which did not exist on the machine during this session.
- **`extensionKind: ["ui"]` needs a Cursor window reload** to take effect, and
  whether `Terminal.processId` then yields the *remote* pid (making the exact
  terminal revealable inside a Remote-SSH window) is untested. It only affects
  the best-effort terminal reveal: window focus + the ssh `select-pane` already
  put the right tile on screen without it.
- **`cc_wid_for_tty` still ends in `aerospace --pid | head -1`** for editors,
  which is a coin flip when Cursor runs several windows under one pid
  (LESSONS #10/#24). Not hit today (one window); worth the same "return nothing
  when ambiguous" treatment if it ever is.
- **Precedence when a session is visible in BOTH a hub tile and its own Cursor
  terminal** was specified (prefer the most recently focused) but is **not
  implemented** — tmux cannot report focus at all (LESSONS #33), so it needs
  Aerospace, and no session on this machine currently has two GUI clients to test
  against. Today the hub tile still wins for local sessions.
