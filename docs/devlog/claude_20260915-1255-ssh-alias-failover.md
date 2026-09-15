# 2026-09-15 — v1.9.0: the 14s click was a dead ssh alias (and so was the silence)

Same day as `claude_20260915-1135-click-latency.md`, which ended with "14s not
reproducible, instrumented, waiting for the next slow click". The next question
found it instead: *are you seriously opening a full new ssh connection to trigger
a notification?*

Answer: notification **delivery** always rode one long-lived connection per host
(`bin/cc-remote-bridge`'s `ssh <host> tail -F`). But the **click** path opened its
own — and, crucially, opened it to an alias that was dead.

## What was actually wrong

`thmanyah.local` (LAN 192.168.0.43) and `thmanyah` (tailnet) are one machine.
tmux-watch stamps one alias into `@tw-src`; it flows into every route file and
every click. The Mac was off the home LAN:

```
ssh thmanyah.local   -> connect to host 192.168.0.43 port 22: Host is down
ssh thmanyah         -> 0.20s, rc=0        # same box, live master already open
ssh -O check thmanyah.local  -> NO MASTER
ssh -O check thmanyah        -> Master running (pid=6707)
```

Two failures, one root cause:

1. **Clicks.** Dial the corpse — instant failure on this subnet, or the full
   `ConnectTimeout=5` where the address is routable-but-silent (the bridge log
   shows both, alternating) — then fall through and **materialize a Ghostty
   window running `ssh -t <dead host> tmux attach`**, which sits there timing out
   in front of the user. That is the 14 seconds; almost none of it is compute.
2. **Delivery.** The bridge retried that same corpse every 10s: **112
   consecutive failures** while the box was reachable the whole time. No banners
   from that machine at all. Strictly the worse bug, and it looks like nothing.

## Changes

`hooks/cc-lib.sh` — one door to a remote box, three functions:

| fn | does |
|---|---|
| `cc_host_key` | the equivalence class as a shell fn (strip `user@`, `:port`, lowercase, strip `.local`) — was inlined as awk `key()` in three places |
| `cc_ssh_alias` | which alias for this box has a live master *right now*; falls back to a sibling in the class, rc=1 when none is connected |
| `cc_ssh` | run a command there: ride the master when there is one, else `ConnectTimeout=${CC_SSH_TIMEOUT:-2}` — a host with no master is usually a host nothing can reach, and the click must not block on finding out |

`ssh -O check` is a local unix-socket poke (~10ms, measured), so asking is free.

- `cc_remote_hub_pane` and the click's `select-window`/`select-pane` now go
  through `cc_ssh`.
- `cc-focus.sh` **refuses to materialize a window onto an unreachable host** and
  says so; when it does materialize, it dials the alias that answers.
- `bin/cc-remote-bridge` alternates across the equivalence class on retry
  (`dial order: thmanyah.local thmanyah`) instead of hammering one alias. The
  dialled alias is transport only — `$host` remains the identity stamped on every
  event, so click routing is unchanged (LESSONS #22).

## Verified live, with the LAN alias still down

| test | result |
|---|---|
| bridge failover | iteration 1 `thmanyah.local` fails, iteration 2 dials `thmanyah` and has stayed connected; `ps` confirms the live child is `ssh … thmanyah` |
| click through the dead alias | Cursor `[SSH: thmanyah]` window focused, hub pane `%69` selected, **0.58s** |
| `cc_ssh` steady state | thmanyah.local 0.17/0.24/0.28s · dema 0.25/0.20/0.16s · ftower 0.15/0.12/0.11s |
| unreachable host (`192.0.2.1`) | **2.2s**, rc=1, honest message, **no window created** (before: 5s+ then a dead window) |
| dema regression | resolved its hub over ssh and materialized correctly (no Ghostty hub window was on screen); test window closed by PID, remote session intact |
| `cc_host_key` | `service@thmanyah.local:22` → `thmanyah`, `DEMA.local` → `dema`, `faris@dema-dev` → `dema-dev` |

## The assumption, stated plainly

The sibling hop treats `<host>` and `<host>.local` as the same machine. That is
already this project's rule (README: "`dema`, `faris@dema-dev:~` and `dema.local`
are one box"; `cc_hub_pane` tier 2 and `cc_focus_editor_window` both rely on it),
and the hop only ever fires when the sibling has a **live authenticated master**.
If you ever have `foo` and `foo.local` as genuinely different machines, that
assumption breaks here and in three older places with it.
