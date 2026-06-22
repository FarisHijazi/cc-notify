# TODO

## Must-do

### Support tmux-watch (or refactor it) so monitor clients can be distinguished from real ones

**Context**: tmux-watch (github.com/FarisHijazi/tmux-watch) attaches to tmux sessions as a control-mode client to observe activity. These attachments show up in `tmux list-clients` indistinguishable from real Terminal-window clients — same tty entry, same "attached" flag.

When a tmux session has ONLY tmux-watch clients (no real Terminal attached), cc-notify's multi-client iteration tries every tty and none reach a GUI terminal in the ps tree → click does nothing.

**Possible directions** (any of these solves it):

1. **tmux-watch side**: register clients with a distinguishing marker — e.g. set a tmux user-option `@watch_client=1` on the client, or use a recognizable client_user_id, or name the controlling process something we can filter on. cc-notify would skip those when iterating.

2. **cc-notify side**: detect tmux-watch's pty master holder via `lsof /dev/ttysXXX` — its master will be held by the tmux-watch python process, not a Terminal app. If all masters point to tmux-watch, treat as "no real client attached" and fall back to spawning a new Terminal.

3. **New fallback**: if multi-client walk finds zero GUI terminals, spawn a new Terminal and run `tmux attach -t $tmux_session`. The user clicks the banner and gets a brand-new attached window. Doesn't require tmux-watch changes.

Option 3 is the easiest user-facing fix. Option 1 is the cleanest architecturally. Probably do both.

## Done

- ~~VS Code / Cursor: individual integrated terminal panes can't be focused~~ — **SOLVED in v1.7.0** via the `editor-extension/` (`terminal.show()` matched by shell pid; install with `bin/cc-install-editor-extension`). Remaining edge: two terminals whose shells share a pid set can't happen (pids are unique), but a session with *no* matching live terminal falls back to focusing the terminal panel.

## Other known limitations

- VS Code / Cursor: needs the companion extension installed + window reloaded for pane-level focus; otherwise falls back to window-level focus.
- SSH-remote sessions can't deliver Mac banners back (Tier 1: just bell + remote log).
- First click triggers macOS Automation permission prompts; user must allow once.
