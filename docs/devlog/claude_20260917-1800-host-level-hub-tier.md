# v1.9.2 — a click should land in the hub that already holds the box

**Reported:** after v1.9.1 fixed remote click routing, ftower clicks still
sometimes opened a new Ghostty window. The logs showed why, and it was not the
locale bug again:

```
17:40:46 ftower:servarr-2 — tw does not watch this host locally; skipped the 3s watcher wait
17:40:46 ftower:servarr-2 — cc_hub_pane=none
17:40:47   cc_remote_hub_pane=hub/faris__b6f10d  %32
17:40:49   → NOTHING on screen was showing it; materialized a new window
```

Every line true: `hub/ftower-faris__5cffc3` was created at **17:41:52**, a minute
after the click. With no tile anywhere there was nothing to focus, and
materializing was right. The verified-good case, from the same evening:

```
17:51:33 ftower:servarr-2 — cc_hub_pane=%61
17:51:34   → local hub pane %61, target=hub/ftower-faris__5cffc3:0.2 wid=6506
17:51:34 BANNER CLICK end-to-end (rc=0) — 0.86s
```

## The gap that is left

The tiers go: this session's local tile → its hub window by title → a window
already attached to the session → a hub running ON the box → materialize. Every
one of them is keyed to the *session*. So a hub that watches the **host** but has
no tile for this one session skips straight to materializing — and a new window
is a second place to look for a machine already on screen.

## Fix

`cc_host_hub_session <host>` in cc-lib.sh: the local hub session whose panes
carry `@tw-src` for that box, under any session name. An *attached* hub wins,
since that is the one in a real window; a detached hub is the fallback (it would
itself need materializing, which is the thing being avoided). Host spellings are
normalised exactly as `cc_hub_pane` tier 2 does it.

cc-focus.sh calls it as the last tier before materializing, and deliberately
does **not** select or zoom anything inside that hub: only a tier that found the
real session has earned the right to move what is focused inside it.

## Verified

`tests/cc_host_hub_session_test.sh` — 8 cases against the exact line shape tmux
emits, tab inside the third field included, plus a ninth check that re-extracts
the awk from cc-lib.sh and fails if the test has drifted from it. Writing it
turned up two defects:

- `exit` still runs `END`, so an attached hub printed the detached fallback as a
  **second line**. The tier would have fed two session names to
  `cc_focus_named_terminal` as one string.
- `key()` strips `user@` and `:path` but does not map a *renamed* box
  (`dema-dev` -> `dema`) — that is `cc_hub_pane` tier 3's job (session name
  alone), not this one's. The test's expectation was wrong, not the code.

Live end-to-end for this tier still wants one click while a `tw ftower:` hub is
up and the clicked session has no tile — the hubs were closed by the time the
tier existed, and a synthetic tile would have appeared in the user's own grid.
