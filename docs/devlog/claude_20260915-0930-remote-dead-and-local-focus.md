# 2026-09-15 — v1.8.6: remote notifications were dead; local clicks focused the wrong window

Two reported symptoms, four root causes, none of which had logged anything.

> "cc-notify is not working on the remote machines, I don't get notifications
> here, and also even for local sessions on ghostty tmux claude sessions, when I
> click them … it's still not focusing the exact session pane"

## A. Remote: nothing was emitting, and nothing was collecting

Both halves were broken independently, which is why it looked total.

**A1 — the collector could not start.** `launchctl list` showed `-` in the PID
column and status **78** for `com.farishijazi.cc-notify-remote`. The plist, written
by `cc-install-remote-agent`, baked in its install-time path:

```
…/plugins/cache/farishijazi-plugins/cc-notify/1.8.1/bin/cc-remote-bridge
```

The cache had since pruned 1.8.1 (only 1.8.4/1.8.5 remained), so launchd had
nothing to exec and `KeepAlive` respawned into the same missing file forever.
`/tmp/cc-notify/remote-agent.log` was **empty** — `StandardErrorPath` is written by
the program, so a program that never runs writes nothing, and that reads exactly
like "no errors". Same fuse as the Karabiner hotkey in v1.7.11 (LESSONS #28).

Fix: the plist now **resolves the bridge at launch** — dev repo first, else the
newest cache by `sort -Vr` — so a plugin update can't orphan it. No more "re-run
after every update".

**A2 — no remote box was emitting.** On all three hosts:
`~/.claude/hooks/cc-remote-emit.sh` absent, zero `cc-remote-emit` references in
`~/.claude/settings.json`, `settings.json.cc-bak` still present from the original
install, and `cc-events.jsonl` stopping dead on 2026-09-10 (dema 15:20, thmanyah
14:58) while 44 Claude processes ran on dema alone.

The remote half was only ever wired by `bin/cc-install-remote` merging entries into
the remote's `~/.claude/settings.json` — a file with other owners. Something
rewrote it and the wiring went with it, silently. Meanwhile the cc-notify **plugin**
was installed and auto-updating on those same boxes, and its `hooks.json` never
mentioned the emitter at all.

Fix: dispatch the emitter from the hooks the plugin already registers.
`cc_remote_emit` + `cc_remote_kind` (cc-lib.sh) are called by
`cc-capture-window.sh` (start/prompt/menu/tool/compact/end) and `cc-notify.sh`
(notification/stop) — the same event→kind table `cc-install-remote` used, so
traffic is unchanged (PreToolUse/PostToolUse still only for AskUserQuestion).
**No new hooks.json entries, no scp, nothing merged into a foreign file**, and it
reaches every box by itself on the next plugin update.

The collector opts out: `cc-install-remote-agent` now drops
`~/.claude/notify.disable_remote_emit`, so the Mac running the bridge doesn't emit
to itself. Installing the bridge *is* the declaration that a machine is the hub.

In `cc-notify.sh` the emit deliberately sits **above** the `$SSH_CONNECTION` early
return: a remote session almost never has that variable, because the tmux server it
runs under was started by an earlier login.

## B. Local: the click focused one window and switched a different one

`tcc` sessions are never in a window of their own. The only client attached to
`farishijazi-3` is tw's monitor client, which belongs to no GUI process at all
(`ps` walk → nothing); what you actually look at is a *tile* of
`hub/farishijazi__3652b2` in a Ghostty window. Nine tmux clients, two Ghostty
windows.

The captured route cannot express that, and the captured values proved it:

| route | captured `client_tty` | captured `target_wid` | truth |
|---|---|---|---|
| `farishijazi-3` | `/dev/ttys001` (hub **B**) | `60` (hub **A**) | crossed |
| `farishijazi-5` | `/dev/ttys001` (hub B) | `61` (hub B) | tile is in **60** |
| `farishijazi-6` | `/dev/ttys001` → wid 61 | *and* `/dev/ttys002` → wid 60, minutes apart | nondeterministic |

`cc_detect_terminal` walks the monitor client's tty up through whichever hub pane
happens to host it, while `target_wid` is whatever window was focused when the hook
fired — the two are captured independently and don't have to agree.

**B1 — the local path never looked at `@tw-src`.** The *remote* branch re-resolves
the hub tile at click time from tw's stable key; the local branch went straight to
`aerospace focus` + `tmux_jump` on the session's own single pane, which is a no-op.
So the hub's active pane never moved to the tile the banner was about.

`cc_hub_pane "" "<session>"` already handled local tiles correctly (tw stamps an
*empty* host field for them) — it was simply never called. Local sessions now walk
the same path as remote ones: resolve the tile, adopt its client/window, and
`cc_select_and_zoom` it.

**B2 — `display-message -c` was lying.** See LESSONS #31. `-c <tty>` is accepted,
returns 0, and answers about the **caller**. Two consequences, both invisible:
`cc_wid_for_tty` matched the caller's title (never any window) and fell through to
the `--pid | head -1` coin flip it exists to avoid; and `tmux_jump`'s `cur_ses`
always equalled its target, so `switch-client` was **skipped entirely**. Replaced
with `cc_client_session` (`list-clients` + awk).

### Answering the naming question

> "if you'd rather the `tcc` command use a different naming convention like having
> random numbers or hashes … then let's use that"

Not needed — `tcc`'s names were never the problem. `farishijazi-N` is already
unique, and tw already stamps the stable address `@tw-src = "<host>\t<session>"` on
every tile. Hashes would have changed nothing: the local click path simply never
read that key. `tcc` is untouched.

## Verified

- `cc_client_session` on four ttys → each client's own session (was: the caller's, four times).
- Title→window: ttys002 → `hub/farishijazi__3652b2 · fm3` → wid **60**; ttys001 → wid **61**. Matches `aerospace` exactly; `cc_wid_for_tty` previously returned 61 for ttys002.
- Dry-run of the new local branch (actuators stubbed, nothing focused) over the three real route files above: all three resolve to hub `…__3652b2`, wid **60**, and the correct tile (`%63`, `%150`, `%161`).
- Emit, sandboxed `$HOME`: leaf emits one valid JSON line (parsed with node); collector sentinel suppresses it; `SubagentStop` and non-AskUserQuestion tools emit nothing.
- Agent: `launchctl list` → PID 54004/83241, status **0** (was `-`/78); supervisor + streamers for dema, ftower, thmanyah.local.
- **End-to-end on a real box**: staged the changed hooks in a temp dir on `ftower`, fired SessionStart → event line appended, Mac wrote `/tmp/cc-notify/cctest-remote-fix.route` with `remote_host=ftower` and recorded the timestamp in `bridge-ftower.ts`; fired Stop through `cc-notify.sh` → **`banner cctest-remote-fix: ℹ️ faris | FYI`** on the Mac. Test files and event lines removed afterwards (ftower back to 59 lines).

## Left alone deliberately

- **`dema.local` gets no streamer.** `_hosts` returns it from the hub panes in an
  interactive shell but not in a bare launchd-like env (reproducible; same tmux
  server, same 35 panes, so not a socket-visibility issue — cause not chased).
  It is the *same box* as the pinned `dema`, so one streamer is the correct
  outcome anyway: two would double-fire every dema banner. Worth understanding
  before adding any host that is only discoverable from a hub pane.
- `bin/cc-install-remote` is untouched and still works; it is now redundant for
  any box that has the plugin.
