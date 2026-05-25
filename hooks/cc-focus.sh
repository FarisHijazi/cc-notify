#!/usr/bin/env bash
# Click handler for Claude Code notifications.
# Usage: cc-focus.sh <session_id>
# Reads routing state from /tmp/cc-notify/<session_id>.route written by cc-notify.sh.

session_id="${1:-default}"
route_file="/tmp/cc-notify/${session_id}.route"

[ -f "$route_file" ] || { echo "no route file: $route_file"; exit 0; }
# shellcheck disable=SC1090
. "$route_file"

# Focus via Aerospace. Prefer the explicitly-captured target_wid (captured at
# SessionStart/UserPromptSubmit when the user was reliably looking at the
# right window). Fall back to gui_pid-based lookup if no captured wid.
aerospace_focused=""
if command -v aerospace >/dev/null 2>&1; then
  wid="$target_wid"
  if [ -z "$wid" ] && [ -n "$gui_pid" ]; then
    wid=$(aerospace list-windows --monitor all --pid "$gui_pid" --format '%{window-id}' 2>/dev/null | head -1)
  fi
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
  local cur_ses sw_rc win_rc pane_rc
  cur_ses=$(tmux display-message -c "$client_tty" -p '#S' 2>&1)
  if [ "$cur_ses" != "$tmux_session" ]; then
    sw_rc=$?
  fi
  win_rc=$?
  pane_rc=$?
  printf '[%s] tmux_jump tty=%s sess=%s win=%s pane=%s  cur_ses_was=%s  sw=%s win=%s pane=%s\n' \
    "$(date +%T)" "$client_tty" "$tmux_session" "$tmux_window" "$tmux_pane" \
}

# Track whether ANY focus action actually fired. The hotkey wrapper uses the
# exit code to decide whether to dismiss the banner.
focused=""
[ -n "$aerospace_focused" ] && focused=1

case "$term" in
  Apple_Terminal)
    # Aerospace-by-pid was tried above; if it didn't work, fall back to
    # AppleScript-by-tty (works when there's only one Terminal.app process).
    if [ -z "$aerospace_focused" ] && [ -n "$client_tty" ]; then
      result=$(osascript <<OSA 2>/dev/null
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
          return "matched"
        end if
      end try
    end repeat
  end repeat
  return "nomatch"
end tell
OSA
)
      [ "$result" = "matched" ] && focused=1
    elif [ -z "$aerospace_focused" ]; then
      # Fallback: activate the app (no specific window target — best effort).
      open -a Terminal 2>/dev/null && focused=1
    fi

    sleep 0.1
    tmux_jump
    ;;

  vscode)
    if pgrep -xq Cursor 2>/dev/null; then
      open -a Cursor 2>/dev/null && focused=1
      command -v cursor >/dev/null && [ -n "$cwd" ] && cursor --reuse-window "$cwd" 2>/dev/null &
    elif pgrep -xq "Code" 2>/dev/null || pgrep -xq "Code Helper" 2>/dev/null; then
      open -a "Visual Studio Code" 2>/dev/null && focused=1
      command -v code >/dev/null && [ -n "$cwd" ] && code --reuse-window "$cwd" 2>/dev/null &
    else
      open -a "Visual Studio Code" 2>/dev/null && focused=1 || { open -a Cursor 2>/dev/null && focused=1; }
    fi
    ;;

  iTerm.app)
    [ -z "$aerospace_focused" ] && { open -a iTerm 2>/dev/null && focused=1; }
    sleep 0.15
    tmux_jump
    ;;

  ghostty)
    [ -z "$aerospace_focused" ] && { open -a Ghostty 2>/dev/null && focused=1; }
    sleep 0.15
    tmux_jump
    ;;

  *)
    echo "$(date -u +%FT%TZ) unknown term '$term' for session $session_id" >>"$HOME/.claude/inbox.log"
    ;;
esac

[ -n "$focused" ] && exit 0
exit 1
