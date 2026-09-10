#!/usr/bin/env bash
# Click handler for Claude Code notifications.
# Usage: cc-focus.sh <session_id>
# Reads routing state from /tmp/cc-notify/<session_id>.route written by cc-notify.sh.

session_id="${1:-default}"
route_file="/tmp/cc-notify/${session_id}.route"

[ -f "$route_file" ] || { echo "no route file: $route_file"; exit 0; }
# shellcheck disable=SC1090
. "$route_file"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cc-lib.sh"

# Remote session (bridged by bin/cc-remote-bridge): the route's local coordinates
# were resolved when the event fired, and panes come and go — so re-resolve NOW
# from the stable key (tmux-watch's @tw-src = "<host>\t<session>") and rebuild the
# routing from the pane that is displaying it. Everything below then runs exactly
# as it does for a local session.
# Every tier is logged: "it opened a new window again" is otherwise unfalsifiable
# after the fact — the panes, clients and windows it looked at are all gone by the
# time anyone asks. /tmp/cc-notify/focus-route.log says which tier answered.
rlog() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>/tmp/cc-notify/focus-route.log 2>/dev/null; }

if [ -n "${remote_host:-}" ]; then
  remote_sess="${remote_tmux%%:*}"
  pane=$(cc_hub_pane "$remote_host" "$remote_sess")
  if [ -z "$pane" ]; then
    # tw owns the hub grid and runs its own watcher, so a session that has just
    # appeared gets its tile a beat later. A click landing in that gap used to
    # open a whole new Ghostty window — and cc-notify adding the tile ITSELF
    # just races the watcher and leaves two tiles for one session (measured).
    # Wait the watcher out instead; only a session it never adds falls through.
    for _ in 1 2 3 4 5 6; do
      sleep 0.5
      pane=$(cc_hub_pane "$remote_host" "$remote_sess")
      [ -n "$pane" ] && break
    done
    [ -n "$pane" ] && rlog "${remote_host}:${remote_sess} — hub tile appeared while waiting"
  fi
  rlog "${remote_host}:${remote_sess} — cc_hub_pane=${pane:-none}"
  if [ -n "$pane" ] && cc_pane_route "$pane"; then
    term="$CC_TERM"; tmux_target="$CC_TMUX_TARGET"; client_tty="$CC_CLIENT_TTY"
    gui_pid="$CC_GUI_PID"; editor_app="$CC_EDITOR_APP"; shell_pids="$CC_SHELL_PIDS"
    target_wid=$(cc_wid_for_tty "$CC_CLIENT_TTY" "$CC_GUI_PID" "$CC_TERM")
    rlog "  → local hub pane $pane, target=$tmux_target tty=$client_tty wid=${target_wid:-none}"
  else
    # The pane exists but its client could not be resolved (cc_pane_route walks
    # the tmux client's tty to a GUI pid, and that walk can fail while the window
    # is very much on screen). Materializing here is the WORST answer: the hub
    # window we just found is the thing the user is looking at. Focus it by the
    # hub session's own title — the same mechanism that works for remote hubs.
    if [ -n "$pane" ]; then
      hub_local=$(tmux display-message -p -t "$pane" '#S' 2>/dev/null)
      rlog "  cc_pane_route FAILED for $pane (hub '${hub_local:-?}') — trying its window by title"
      if [ -n "$hub_local" ] && cc_focus_named_terminal "$hub_local"; then
        tmux select-window -t "$pane" 2>/dev/null
        tmux select-pane   -t "$pane" 2>/dev/null
        rlog "  → focused local hub '$hub_local' on pane $pane"
        echo "focused local hub '${hub_local}' on pane ${pane} (${remote_sess})"
        exit 0
      fi
    fi
    # No hub pane — but a window may already be attached to this session from an
    # earlier click. Focus that before creating anything: a click should land on
    # the session, never pile a second window onto one already showing it.
    if cc_focus_named_terminal "$remote_sess"; then
      rlog "  → focused a window titled '${remote_sess} · …'"
      echo "focused existing window showing ${remote_host}:${remote_sess}"
      exit 0
    fi
    # Still nothing? The hub may live ON the box (ssh + tw there), in which case
    # the local window is titled after the HUB session, not this one. Focus that
    # window and move the remote hub's active pane onto the session.
    hub=$(cc_remote_hub_pane "$remote_host" "$remote_sess")
    rlog "  cc_remote_hub_pane=${hub:-none}"
    if [ -n "$hub" ]; then
      tab=$(printf '\t')
      hub_sess="${hub%%"$tab"*}"; hub_pane="${hub##*"$tab"}"
      if cc_focus_named_terminal "$hub_sess"; then
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" \
            "tmux select-window -t '$hub_pane' 2>/dev/null; tmux select-pane -t '$hub_pane' 2>/dev/null" \
            >/dev/null 2>&1 &
        echo "focused ${remote_host} hub '${hub_sess}' on pane ${hub_pane} (${remote_sess})"
        exit 0
      fi
    fi
    # Nothing on this Mac is showing it — materialize the view. A click is an
    # explicit user action, so opening a window is what they asked for. The
    # session name comes from another machine: only ever pass a plain tmux name.
    case "$remote_sess" in
      ""|*[!A-Za-z0-9._-]*) echo "remote session name not addressable: '$remote_sess'"; exit 1 ;;
    esac
    # Open it in Ghostty when it is installed (its AppleScript dictionary makes a
    # window in the RUNNING instance and launches the app if needed — never
    # `open -na … --args`, which spawns a whole new Ghostty process per call),
    # else in Terminal.app.
    if [ -d /Applications/Ghostty.app ]; then
      osascript >/dev/null 2>&1 <<OSA || exit 1
tell application "Ghostty"
  set cfg to new surface configuration
  set command of cfg to "ssh -t ${remote_host} tmux attach -t ${remote_sess}"
  new window with configuration cfg
  activate
end tell
OSA
      rlog "  → NOTHING on screen was showing it; materialized a new window"
      echo "materialized remote session ${remote_host}:${remote_sess} in a new Ghostty window"
    else
      osascript -e "tell application \"Terminal\" to do script \"ssh -t ${remote_host} tmux attach -t ${remote_sess}\"" \
                -e 'tell application "Terminal" to activate' >/dev/null 2>&1 || exit 1
      rlog "  → NOTHING on screen was showing it; materialized a new window"
      echo "materialized remote session ${remote_host}:${remote_sess} in a new Terminal window"
    fi
    exit 0
  fi
fi

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
  [ -n "$tmux_session" ] || return 0
  [ -n "$client_tty" ]  || return 0
  local cur_ses
  cur_ses=$(tmux display-message -c "$client_tty" -p '#S' 2>/dev/null)
  if [ "$cur_ses" != "$tmux_session" ]; then
    tmux switch-client -c "$client_tty" -t "$tmux_session" 2>/dev/null
  fi
  [ -n "$tmux_window" ] && tmux select-window -t "$tmux_session:$tmux_window" 2>/dev/null
  [ -n "$tmux_pane" ]   && tmux select-pane   -t "$tmux_session:$tmux_window.$tmux_pane" 2>/dev/null
}

# Ask the cc-notify-focus editor extension to reveal the exact integrated
# terminal pane Claude runs in. The extension matches the terminal by its shell
# pid (one of the captured `shell_pids`) and calls .show(). This is the only way
# VS Code/Cursor allow focusing a specific terminal pane. No-op (the window is
# already focused) when the extension isn't installed.
focus_vscode_terminal() {
  local wid="$1" app="$editor_app" scheme ext_dir
  [ -n "$shell_pids" ] || return 0

  # Resolve which editor: captured editor_app, else the focused window's app.
  if [ -z "$app" ] && [ -n "$wid" ] && command -v aerospace >/dev/null 2>&1; then
    app=$(aerospace list-windows --monitor all --format '%{window-id}|%{app-name}' 2>/dev/null \
      | awk -F'|' -v w="$wid" '$1==w{print $2; exit}')
  fi
  case "$app" in
    Cursor) scheme="cursor"; ext_dir="$HOME/.cursor/extensions" ;;
    Code|"Visual Studio Code"|"Code - Insiders") scheme="vscode"; ext_dir="$HOME/.vscode/extensions" ;;
    *)
      # Unknown editor — fall back to whichever extension is installed.
      if ls -d "$HOME/.cursor/extensions/farishijazi.cc-notify-focus"* >/dev/null 2>&1; then
        scheme="cursor"; ext_dir="$HOME/.cursor/extensions"
      else
        scheme="vscode"; ext_dir="$HOME/.vscode/extensions"
      fi
      ;;
  esac

  # Only fire the URI if the extension is installed; otherwise the editor pops
  # an "extension not installed" toast on every click.
  ls -d "$ext_dir/farishijazi.cc-notify-focus"* >/dev/null 2>&1 || return 0

  open "$scheme://farishijazi.cc-notify-focus/focus?pids=$shell_pids" 2>/dev/null
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
    # If the captured target_wid focus didn't fire (e.g. session started before
    # cc-capture-window.sh existed), match a Cursor/VS Code window by cwd: walk
    # up from cwd looking for an ancestor whose basename matches the workspace
    # folder shown in a window's title (titles look like "FILE — FOLDER"). This
    # avoids `--reuse-window`, which OPENS a new view rooted at cwd instead of
    # focusing an existing window.
    if [ -z "$aerospace_focused" ] && [ -n "$cwd" ] && command -v aerospace >/dev/null 2>&1; then
      candidates=$(aerospace list-windows --monitor all --format '%{window-id}|%{app-name}|%{window-title}' 2>/dev/null \
        | awk -F'|' '$2 == "Cursor" || $2 == "Code" || $2 == "Visual Studio Code"')
      dir="$cwd"
      while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        target_base=$(basename "$dir")
        match_wid=$(printf '%s\n' "$candidates" | awk -F'|' -v tb="$target_base" '
          {
            n = split($3, parts, " — ")
            last = parts[n]
            sub(/ \(Workspace\)$/, "", last)
            if (last == tb) { print $1; exit }
          }')
        if [ -n "$match_wid" ]; then
          aerospace focus --window-id "$match_wid" 2>/dev/null && focused=1
          break
        fi
        dir=$(dirname "$dir")
      done
    fi
    # Last-resort fallback: activate the app (NO --reuse-window — that opens
    # a new window/folder, which is exactly what the user doesn't want).
    if [ -z "$focused" ]; then
      if pgrep -xq Cursor 2>/dev/null; then
        open -a Cursor 2>/dev/null && focused=1
      elif pgrep -xq "Code" 2>/dev/null || pgrep -xq "Code Helper" 2>/dev/null; then
        open -a "Visual Studio Code" 2>/dev/null && focused=1
      else
        open -a "Visual Studio Code" 2>/dev/null && focused=1 || { open -a Cursor 2>/dev/null && focused=1; }
      fi
    fi

    # Now focus the SPECIFIC integrated terminal pane (not just the window). The
    # only mechanism VS Code/Cursor expose for this is the Terminal API, so we
    # ask the cc-notify-focus extension (if installed) to .show() the terminal
    # whose shell pid is in our captured ancestor chain. See editor-extension/.
    focused_wid="${wid:-$match_wid}"
    focus_vscode_terminal "$focused_wid"
    ;;

  iTerm.app)
    [ -z "$aerospace_focused" ] && { open -a iTerm 2>/dev/null && focused=1; }
    sleep 0.15
    tmux_jump
    ;;

  ghostty)
    # Exact window came from target_wid (captured at SessionStart) or, for a
    # remote session, from the tmux-title match in cc_wid_for_tty. Nothing
    # finer exists: Ghostty has no AppleScript dictionary for windows/tabs.
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
