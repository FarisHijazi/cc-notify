# 2026-08-24 — v1.8.0: remote Claude Code sessions over SSH

Goal: banners + click-to-focus for Claude Code running on other machines.
Design discussion first (see the chat), then implementation.

## The shape of the problem

Two independent halves, only one of them hard:

1. **Signal out** — get the remote hook's event to the Mac.
2. **Route back** — make a click land somewhere useful.

(2) usually kills this feature. Here it was already solved: **tmux-watch** tiles
remote tmux sessions into a local hub and tags each pane
`@tw-src = "<host>\t<session>"`. So `pane = f(host, session)` is one
`tmux list-panes -a`, and from a pane the existing local focus machinery works
unchanged. See @LESSONS.md #22.

## Transport decision

| option | works detached | extra conn | multi-Mac | verdict |
|---|---|---|---|---|
| `ssh -R` unix socket + local listener | ✗ | none | attached Mac only | rejected |
| **local `ssh <host> tail -F` streamer** | ✔ | 1 (free under `ControlMaster auto`) | ✔ | **chosen** |
| ntfy / webhook | ✔ | — | ✔ | third party sees the data |
| OSC 9/777 through the tty | ✗ | none | ✗ | not clickable, iTerm-only |

The streamer is also the natural home for **identity translation**: the remote
knows only its `hostname`, the local pane is keyed by the **ssh alias**, and the
streamer is the one process that knows both — so it stamps the alias on every
event. No mapping table.

## What was built

| file | role |
|---|---|
| `hooks/cc-remote-emit.sh` | THE ENTIRE REMOTE HALF. One JSON facts-line per event → `~/.claude/cc-events.jsonl`. No node/jq/python (sed for the hook payload, grep for the transcript). |
| `bin/cc-remote-bridge` | Mac side. Supervisor (discover hosts → one streamer each) + per-host `ssh tail -F`. Each line → banner + route file + hub-pane status. `--hosts` / `--test` / `--stop`. |
| `bin/cc-install-remote` | scp 2 files + merge hooks into the remote `~/.claude/settings.json` (all JSON handled locally). `--uninstall`. |
| `bin/cc-install-remote-agent` | LaunchAgent (`KeepAlive`) for the supervisor. |
| `cc-lib.sh: cc_present` | facts → status/subtitle/body/sound/title/tab-only. **Extracted from cc-notify.sh** and now called by both, so local and remote presentation can't drift. |
| `cc-lib.sh: cc_hub_pane / cc_pane_route / cc_pane_status / cc_wid_for_tty / cc_walk_tty` | hub-pane resolution, route-from-a-pane, status board, exact tty→window-id. |
| `hooks/cc-focus.sh` | new pre-step: a route with `remote_host` re-resolves the pane AT CLICK TIME, else materializes a Terminal attached to the session. |

Remote hooks registered: SessionStart, UserPromptSubmit, PreCompact,
Notification, Stop, SessionEnd, plus PreToolUse/PostToolUse **matched to
AskUserQuestion only** (its menu fires no Notification, so 🔀 is the only signal;
a plain tool matcher would be pure traffic for a ⏳ UserPromptSubmit already set).

Bonus that fell out: **hub pane borders are a status board** — `@cc-status`
pane user-option + `pane-border-format` (immune to inner programs rewriting the
pane title). Written for LOCAL sessions too, by cc-notify.sh.

## Tested (live, against `ftower`)

- remote emitter → valid JSON line, correct colour/title/token/tmux/branch.
- `cc-install-remote ftower` into an existing settings.json with gsd hooks:
  non-hook keys byte-identical, zero pre-existing hook groups lost, add→remove
  round-trips exactly; backup at `settings.json.cc-bak`.
- real `tmux-watch ftower:~/cctest-demo` hub → `@tw-src` = `ftower\tremotedemo`;
  host auto-discovered.
- end-to-end: hook on ftower → banner "✅ 🟢 ftower deploy / Task complete /
  cctest-demo · master", route written, pane border `✅ 🟢 ftower deploy`.
- click: `cc-focus.sh` → focused window 12969 (the exact hub window) and
  selected pane %137 (the ftower pane). Materialize path (pane removed) opened a
  Terminal running `ssh -t ftower tmux attach -t remotedemo`.
- supervisor + `--stop`: 0 stray processes (ssh included). Banner workers are
  orphaned to launchd by the `( … & )` idiom, so a bridge restart doesn't kill a
  live banner.
- bare environment (`env -i`) and a real LaunchAgent run: full route, banner
  fires.

## Two bugs the testing caught (both now lessons)

1. **`set -u` + `$TMUX` unset under launchd** (@LESSONS.md #23) — the route file
   was written *partially* (55 bytes vs 184) and no banner fired, silently.
   Every var a daemon reads needs `${VAR:-}`; reproduce with
   `env -i HOME=$HOME PATH=… bash script`.
2. **`aerospace focus --pid` picks an arbitrary Terminal.app window**
   (@LESSONS.md #24) — locally covered by the SessionStart-captured window id,
   which a remote session has no equivalent of. Fixed with `cc_wid_for_tty`,
   bridging AppleScript (knows which window holds a tty) and Aerospace (can focus
   across workspaces) on the **window title**, which both report identically.

Also hardened while here: `--stop` and all teardown kill **by PID via a recursive
`_kill_tree`**, never `pkill -f` (a `-f` pattern matches any command line that
merely mentions the script).

## Left deliberately

- Non-tmux remote sessions: banner works, click can't route (nothing addresses
  them). Documented, not worked around.
- `hetzner-1` / `BuzaStation` were unreachable at the time; only `ftower` is
  installed so far. `contabo-1` / `fmox` are good future tests — they have tmux
  but **no node**, which exercises `cc_last_status_token`'s grep fallback.
