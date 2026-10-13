# Dismiss a banner when you go to the session yourself (v1.9.6, 2026-10-13)

**Ask:** when the user walks over to the session that wants attention (clicks its tmux pane or hub tile) without clicking the banner, the banner should disappear as if it had been clicked.

**Design:** add a second per-banner watcher beside dismiss-on-typing, with no new daemon and no tmux hooks.
- `bin/cc-pane-seen <target>` treats a pane as seen when its `#{pane_active}#{window_active}` == `11` and a client of its session has `focused` in `#{client_flags}`. Ghostty focus events set that flag; a `tw` hub forwards focus in/out to the nested client in a tile. In the live hub, the active tile's inner client was `focused` and the other tile's was not.
- `--watch` fires only on a not-seen → seen transition. If the banner fires while you're already on the pane, you have to leave and come back.
- `tmux_target` from the route file is the session's own pane for local sessions and the local hub pane for remote ones (cc-remote-bridge), so one check covers both.
- `cc-notify-bg.sh`: the two watchers share `dismiss()` (`--remove` → `sleep 0.3` → `pkill`, LESSONS #11), and both are killed when alerter returns.

**Gotcha:** `tmux display-message -p -t %999` prints blanks and exits 0 for a gone pane, so "gone" is detected by an empty session name, not the exit code.

**Tests** run on throwaway tmux servers driven through a pty, with SGR mouse and `\e[I`/`\e[O` focus sequences:
- `tests/cc_pane_seen_test.py`: 10/10 pass.
- `tests/cc_pane_seen_hub_test.py`: 4/4 pass (local session in a hub tile; clicking the tile fires the watch, terminal focus-out reads as not seen).
- E2E: a real banner for a fake session whose route points at a throwaway hub tile was gone 0.7 s after the tile was clicked; the worker exited 0 and no watchers were left behind.

**Deploy:** the files were copied into the cache dirs 1.9.2, 1.9.4 and 1.9.5 so running sessions use it now. The version is bumped to 1.9.6 for the marketplace.
