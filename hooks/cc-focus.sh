#!/usr/bin/env bash
# Click handler for Claude Code notifications.
# Usage: cc-focus.sh <session_id>
# Reads routing state from /tmp/cc-notify/<session_id>.route written by cc-notify.sh.

session_id="${1:-default}"
route_file="/tmp/cc-notify/${session_id}.route"

[ -f "$route_file" ] || { echo "no route file: $route_file"; exit 0; }
# shellcheck disable=SC1090
. "$route_file"

# Focus the right window via Aerospace by GUI process PID. This bypasses
# AppleScript multi-instance issues — macOS can host multiple Terminal.app
# processes (e.g. one per Aerospace workspace), and `tell application "Terminal"`
# only sees windows of ONE process. Aerospace sees every window regardless of
# which process owns it, and `focus --window-id` also switches workspace.
aerospace_focused=""
if [ -n "$gui_pid" ] && command -v aerospace >/dev/null 2>&1; then
  wid=$(aerospace list-windows --monitor all --pid "$gui_pid" --format '%{window-id}' 2>/dev/null | head -1)
  if [ -n "$wid" ]; then
    aerospace focus --window-id "$wid" 2>/dev/null && aerospace_focused=1
  fi
fi

# Split tmux_target ("session:window.pane") into parts for explicit selection.
tmux_session="" tmux_window="" tmux_pane=""
if [ -n "$tmux_target" ]; then
  tmux_session="${tmux_target%%:*}"
  _rest="${tmux_target#*:}"
  tmux_window="${_rest%%.*}"
  tmux_pane="${_rest#*.}"
fi

# Switch tmux to the captured session, window, and pane. switch-client alone
# doesn't reliably select the target window when the client is already on the
# same session, so do session/window/pane as three explicit steps.
tmux_jump() {
  [ -n "$tmux_session" ] || return 0
  [ -n "$client_tty" ] || return 0
  local cur_ses
  cur_ses=$(tmux display-message -c "$client_tty" -p '#S' 2>/dev/null)
  if [ "$cur_ses" != "$tmux_session" ]; then
    tmux switch-client -c "$client_tty" -t "$tmux_session" 2>/dev/null
  fi
  [ -n "$tmux_window" ] && tmux select-window -t "$tmux_session:$tmux_window" 2>/dev/null
  [ -n "$tmux_pane" ]   && tmux select-pane   -t "$tmux_session:$tmux_window.$tmux_pane" 2>/dev/null
}

case "$term" in
  Apple_Terminal)
    # Aerospace-by-pid was tried above; if it didn't work, fall back to
    # AppleScript-by-tty (works when there's only one Terminal.app process).
    if [ -z "$aerospace_focused" ] && [ -n "$client_tty" ]; then
      osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
  activate
  set targetTty to "$client_tty"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if tty of t is targetTty then
          set selected of t to true
          set index of w to 1
          set frontmost of w to true
          return
        end if
      end try
    end repeat
  end repeat
end tell
OSA
    elif [ -z "$aerospace_focused" ]; then
      open -a Terminal 2>/dev/null
    fi

    sleep 0.1
    tmux_jump
    ;;

  vscode)
    # vscode env var is set by both VS Code and Cursor (Cursor is a fork).
    # Prefer whichever app is actually running.
    if pgrep -xq Cursor 2>/dev/null; then
      open -a Cursor 2>/dev/null
      command -v cursor >/dev/null && [ -n "$cwd" ] && cursor --reuse-window "$cwd" 2>/dev/null &
    elif pgrep -xq "Code" 2>/dev/null || pgrep -xq "Code Helper" 2>/dev/null; then
      open -a "Visual Studio Code" 2>/dev/null
      command -v code >/dev/null && [ -n "$cwd" ] && code --reuse-window "$cwd" 2>/dev/null &
    else
      open -a "Visual Studio Code" 2>/dev/null || open -a Cursor 2>/dev/null
    fi
    # Cannot focus a specific integrated-terminal pane — no API for that.
    ;;

  iTerm.app)
    [ -z "$aerospace_focused" ] && open -a iTerm 2>/dev/null
    sleep 0.15
    tmux_jump
    ;;

  ghostty)
    [ -z "$aerospace_focused" ] && open -a Ghostty 2>/dev/null
    sleep 0.15
    tmux_jump
    ;;

  *)
    echo "$(date -u +%FT%TZ) unknown term '$term' for session $session_id" >>"$HOME/.claude/inbox.log"
    ;;
esac

exit 0
