# Click keeps the tmux zoom (2026-09-10)

Reported: with a hub window maximized on one tile (`prefix+z`), clicking a
notification for a different session navigated the Ghostty window but left the
tmux side in the tiled grid.

Cause: tmux drops a window's zoom whenever the active pane changes, and the
click's last act is `select-pane`. Nothing was preserving the flag, and by the
time the pane is selected the flag is already 0 — so it has to be read first.

`cc_select_keep_zoom <pane-target>` (cc-lib.sh) reads `#{window_zoomed_flag}`,
selects window + pane, then re-zooms on the pane it selected. Used by all three
places that land on a pane: `tmux_jump` (the common path), the local-hub-by-title
tier, and — inline inside the single ssh command — the remote-hub tier.

It **preserves** a zoom, it does not invent one; a tiled window stays tiled.

## Tests

Isolated session, three panes (`zoom_test.sh`):

```text
A: zoomed on %299, select %301  -> zoomed=1 active=%301   PASS zoom follows
B: not zoomed,     select %300  -> zoomed=0 active=%300   PASS none invented
C: zoomed on %300, select %300  -> zoomed=1 active=%300   PASS unchanged
```

End-to-end on the live `hub/dema-local-service__f29e35`, original state saved and
restored:

```text
saved:  active=%295 zoomed=1
set up: zoomed on %281 (control-service-1)
click for demaenergy_d-5 -> active=%285 zoomed=1   (landed maximized)
restored: active=%295 zoomed=1
```

See @../../LESSONS.md #30.
