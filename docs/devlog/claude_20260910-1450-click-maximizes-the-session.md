# A click maximizes the session it was for (2026-09-10)

Reported: with a hub window maximized on one tile (`prefix+z`), clicking a
notification for a different session navigated the Ghostty window but left the
tmux side in the tiled grid.

First cut preserved an existing zoom. That was the wrong reading — the ask is
that a click **always** lands on the clicked session maximized, whatever the
window was doing before. `cc_select_and_zoom` (cc-lib.sh) selects window + pane
and then zooms.

Ordering is the whole trick, for two separate reasons:

- changing the active pane unzooms the window, so the zoom must come after;
- `resize-pane -Z` **toggles**, so "read flag → select → toggle" un-maximizes
  precisely when the window was already zoomed on the target — clicking the same
  banner twice. Select, then read, then zoom only if it is off.

Guards: only windows with more than one pane (a single-pane Claude session has
nothing to maximize), and `CC_NO_FOCUS_ZOOM=1` /
`~/.claude/notify.disable_focus_zoom` to keep the old select-only behaviour.

Used by all three places that land on a pane: `tmux_jump` (the common path), the
local-hub-by-title tier, and — inline inside the single ssh command — the
remote-hub tier.

## Tests

Isolated session, three panes (`zoom_test2.sh`):

```text
A tiled, click %305          -> zoomed=1 active=%305   maximizes
B zoomed on %305, click %303 -> zoomed=1 active=%303   maximize follows
C already zoomed on %303     -> zoomed=1 active=%303   stays (toggle guard)
D CC_NO_FOCUS_ZOOM=1         -> zoomed=0 active=%304   selects only
E single-pane session        -> zoomed=0               no stray flag
```

End-to-end on the live `hub/dema-local-service__f29e35`, forced tiled first,
original state saved and restored:

```text
saved:    active=%287 zoomed=1
set up:   tiled (zoomed=0)
click demaenergy_d-1 -> active=%283 zoomed=1  (maximized on the clicked session)
restored: active=%287 zoomed=1
```

See @../../LESSONS.md #30.
