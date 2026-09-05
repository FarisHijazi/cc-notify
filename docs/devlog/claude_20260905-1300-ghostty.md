# Ghostty as the host terminal (2026-09-05)

The Mac moved from Terminal.app to Ghostty 1.3.1. cc-notify already detected
Ghostty (`cc_walk_tty`, `cc_detect_terminal`, the capture-window allowlist and
the `ghostty)` focus branch), so LOCAL click-to-focus needed nothing: the window
id captured at SessionStart is terminal-agnostic. Two REMOTE paths were
Terminal.app-only and are now covered:

1. **Exact window for a remote session** (`cc_wid_for_tty`). Terminal.app
   exposes each tab's `tty` to AppleScript; Ghostty does not. What Ghostty does
   expose (1.3 ships a scripting dictionary: windows → tabs → terminals, each
   with a `name`, plus `focus`, `new window`, `new tab`, `close`) is the tab
   NAME, which is whatever tmux put in the outer title. So the dotfiles
   `.tmux.conf` now sets `set-titles on` / `set-titles-string '#S · #h'` (a
   stable string — no `#T`, which changes every prompt), the hook expands that
   same format for the client on the tty (`tmux display-message -c <tty> -p
   '#{T:set-titles-string}'`), asks Ghostty to `focus` the terminal named that
   (which also selects a background tab, so the window title becomes it), and
   then reads the window id off aerospace by title so the caller can still
   switch workspace (LESSONS #9: AppleScript activation does not move
   aerospace). Verified: three Ghostty windows open, a `tmux attach` in one of
   them, `cc_wid_for_tty <client_tty> <pid> ghostty` returned exactly that
   window's id and aerospace reported it focused.
2. **Materialize** (nothing on the Mac shows the session). Was `tell
   application "Terminal" to do script "ssh …"`; now `new window with
   configuration` with `command` set to the ssh line, falling back to the
   Terminal.app script when Ghostty is not installed.

## Trap: `open -na Ghostty.app --args` is NOT "new window"

It spawns a **separate Ghostty process** every call (four instances after four
calls, three of them windowless once their window closed, ~90 MB each), and
AppleScript then targets an arbitrary one. The same trap the aerospace config
documents for Terminal.app. `tell application "Ghostty" to new window` opens a
window in the running instance in ~380 ms warm and launches the app if needed.

## Duplicate banners

Claude Code sends its own desktop notification in Ghostty (OSC 9/777, also from
a remote box), so with cc-notify you get two. `preferredNotifChannel` is set to
`notifications_disabled` in `~/.claude/settings.json`; cc-notify's banner is the
one that can be clicked.
