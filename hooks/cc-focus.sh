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
# Every line carries elapsed-since-start, because "the click feels slow" is not
# actionable and the tiers are all sub-second individually — only the gaps show
# where the time actually goes. LC_ALL=C so EPOCHREALTIME uses a dot.
_cc_t0="${EPOCHREALTIME:-0}"; _cc_t0="${_cc_t0/,/.}"
rlog() {
  local now="${EPOCHREALTIME:-0}"; now="${now/,/.}"
  local el; el=$(LC_ALL=C awk -v a="$now" -v b="$_cc_t0" 'BEGIN{ printf "+%05.2fs", (a>0&&b>0)?a-b:0 }')
  printf '[%s %s] %s\n' "$(date '+%F %T')" "$el" "$*" >>/tmp/cc-notify/focus-route.log 2>/dev/null
}

if [ -n "${remote_host:-}" ]; then
  remote_sess="${remote_tmux%%:*}"
  pane=$(cc_hub_pane "$remote_host" "$remote_sess")
  if [ -z "$pane" ]; then
    # tw owns the hub grid and runs its own watcher, so a session that has just
    # appeared gets its tile a beat later. A click landing in that gap used to
    # open a whole new Ghostty window — and cc-notify adding the tile ITSELF
    # just races the watcher and leaves two tiles for one session (measured).
    # Wait the watcher out instead; only a session it never adds falls through.
    #
    # ...but ONLY when tw watches this host on this Mac at all. With the hub
    # running ON the box (ssh + tw there), no local pane will EVER carry
    # @tw-src for it, so this loop cannot succeed — it just burns its full 3s
    # on every single click, which measured as ~70% of the click's latency for
    # that topology. Ask first; the check is one tmux call.
    if cc_host_watched_locally "$remote_host"; then
      for _ in 1 2 3 4 5 6; do
        sleep 0.5
        pane=$(cc_hub_pane "$remote_host" "$remote_sess")
        [ -n "$pane" ] && break
      done
      [ -n "$pane" ] && rlog "${remote_host}:${remote_sess} — hub tile appeared while waiting"
    else
      rlog "${remote_host}:${remote_sess} — tw does not watch this host locally; skipped the 3s watcher wait"
    fi
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
        cc_select_and_zoom "$pane"
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
      # Widen the WINDOW-FOCUSING step; do not add a tier. cc_focus_named_terminal
      # only knows Ghostty (it matches tab names against the tmux title), so a hub
      # running in a Cursor Remote-SSH integrated terminal was invisible and the
      # click materialized a new Ghostty window on top of a session already on
      # screen. The editor match belongs HERE, after cc_remote_hub_pane has
      # already identified the exact hub+pane — putting it earlier would let a
      # host-level match ("any Cursor window on thmanyah") beat this session-level
      # one, which in this topology is always.
      if cc_focus_named_terminal "$hub_sess" || cc_focus_editor_window "$remote_host" "" >/dev/null; then
        rlog "  → focused window for hub '$hub_sess' (pane $hub_pane)"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" \
            "tmux select-window -t '$hub_pane' 2>/dev/null; \
             tmux select-pane -t '$hub_pane' 2>/dev/null; \
             w=\$(tmux display-message -p -t '$hub_pane' '#{session_name}:#{window_index}' 2>/dev/null); \
             [ \"\$(tmux display-message -p -t \"\$w\" '#{window_panes}')\" -gt 1 ] && \
             [ \"\$(tmux display-message -p -t \"\$w\" '#{window_zoomed_flag}')\" != 1 ] && \
             tmux resize-pane -Z -t '$hub_pane' 2>/dev/null" \
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

# A LOCAL session can be on screen exactly the same way a remote one is: not in
# a window of its own, but as one TILE of a tmux-watch hub. `tcc` sessions are
# always like this — the only client attached to `farishijazi-3` is tw's monitor
# client, which belongs to no GUI window at all, while the thing you actually
# look at is a pane of `hub/farishijazi__…` in a Ghostty window.
#
# The captured route cannot express that. `cc_detect_terminal` walks the monitor
# client's tty up through whichever hub pane happens to host it, so client_tty
# lands on A hub's client and target_wid on whichever hub window was focused when
# the hook fired — independently. Measured: one `farishijazi-3` route paired
# client_tty=/dev/ttys001 (hub B) with target_wid=60 (hub A), and two routes for
# `farishijazi-6` captured minutes apart had the pairing swapped. So the click
# focused one window and switched the other's tmux client, and the tile for the
# session it was about was never selected.
#
# Re-resolve from the stable key instead, exactly as the remote branch does:
# tw stamps `@tw-src = "<host>\t<session>"` on every tile, with an EMPTY host
# field for a local session. That is already a unique address — which is why the
# session NAMES need no hashes or ids; nothing was ever ambiguous about them, the
# local path simply never looked at this key.
if [ -z "${remote_host:-}" ] && [ -n "${tmux_target:-}" ]; then
  local_sess="${tmux_target%%:*}"
  local_pane=$(cc_hub_pane "" "$local_sess")
  if [ -n "$local_pane" ] && cc_pane_route "$local_pane"; then
    term="$CC_TERM"; tmux_target="$CC_TMUX_TARGET"; client_tty="$CC_CLIENT_TTY"
    gui_pid="$CC_GUI_PID"; editor_app="$CC_EDITOR_APP"; shell_pids="$CC_SHELL_PIDS"
    # The hub's window, resolved from the hub client's OWN title — not the wid
    # captured at SessionStart, which is the cross-wired one.
    hub_wid=$(cc_wid_for_tty "$CC_CLIENT_TTY" "$CC_GUI_PID" "$CC_TERM")
    [ -n "$hub_wid" ] && target_wid="$hub_wid"
    # Select + MAXIMIZE this tile, not the session's own single pane (which is
    # already "selected" within itself and so a no-op).
    focus_pane="$local_pane"
    rlog "local ${local_sess} — hub pane ${local_pane} target=${tmux_target} tty=${client_tty} wid=${target_wid:-none}"
  else
    rlog "local ${local_sess} — no hub tile (pane='${local_pane:-none}'), using captured route"
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
  # `cc_client_session`, NOT `display-message -c` — the latter answers with the
  # CALLER's session (see cc-lib.sh). That made cur_ses == tmux_session almost
  # always, so this switch-client was skipped and the window kept showing
  # whatever it was on. `switch-client -c` itself is fine: it targets a client
  # directly rather than expanding a format.
  cur_ses=$(cc_client_session "$client_tty")
  # No client on that tty → the route is stale and this tty is not ours. ttys are
  # recycled (reload a Cursor window and the next terminal claims the number), and
  # an empty cur_ses compares unequal to everything, so without this the line
  # below would `switch-client` whatever DOES live there now onto our session —
  # silently, since the command is 2>/dev/null. Answer nothing when unsure.
  [ -n "$cur_ses" ] || return 0
  if [ "$cur_ses" != "$tmux_session" ]; then
    tmux switch-client -c "$client_tty" -t "$tmux_session" 2>/dev/null
  fi
  # A resolved hub tile is the thing to land on; `$tmux_target`'s own pane is a
  # no-op for a single-pane session.
  if [ -n "${focus_pane:-}" ]; then
    cc_select_and_zoom "$focus_pane"
  elif [ -n "$tmux_window" ] && [ -n "$tmux_pane" ]; then
    # Lands MAXIMIZED on the clicked session rather than on one tile of the
    # hub's grid — see cc_select_and_zoom.
    cc_select_and_zoom "$tmux_session:$tmux_window.$tmux_pane"
  else
    [ -n "$tmux_window" ] && tmux select-window -t "$tmux_session:$tmux_window" 2>/dev/null
  fi
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
    # If the captured target_wid focus didn't fire (e.g. a session that started
    # before cc-capture-window.sh existed), find the window ourselves. Never
    # `--reuse-window`: that OPENS a new view rooted at cwd instead of focusing
    # an existing window. cc_focus_editor_window holds both keys (cc-lib.sh).
    #
    # WHICH key depends on where the session lives. `cwd` is only a local path
    # for a LOCAL session — a remote session's route carries the REMOTE cwd
    # verbatim (measured: `/home/service/Projects/thmanyah.d/...`), and walking
    # that up hits `thmanyah.d` / `demaenergy.d`, folder names that also exist on
    # this Mac, so the old cwd walk would confidently focus the WRONG, local
    # window. For a remote session the host is the key instead: the
    # `[SSH: <host>]` marker in the title is what identifies its window.
    if [ -z "$aerospace_focused" ]; then
      if [ -n "${remote_host:-}" ]; then
        match_wid=$(cc_focus_editor_window "$remote_host" "") && focused=1
      else
        match_wid=$(cc_focus_editor_window "" "$cwd") && focused=1
      fi
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
    focused_wid="${wid:-${match_wid:-}}"
    focus_vscode_terminal "$focused_wid"

    # Revealing the terminal is only half the jump: Claude almost always runs in
    # tmux INSIDE that terminal, and one integrated terminal hosts a client that
    # can be sitting on any session. Without this the click focused the right
    # pane and left tmux showing whatever was there before — and a hub tile
    # resolved into `focus_pane` above was computed and then silently thrown
    # away, because `cc_pane_route` hands a Cursor-hosted hub back as term=vscode
    # (see LESSONS). Every other terminal type has always done this.
    sleep 0.15
    tmux_jump
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
    # Reached whenever the session is in NO window of its own — term stays `tmux`
    # because no client of it walks to a GUI process. That is the normal shape of
    # a tcc session (its only client is tw's monitor client), and it is now also
    # the honest answer cc_detect_terminal gives instead of adopting some other
    # session's client. The block above may still have resolved a perfect hub
    # tile into focus_pane/target_wid, so do NOT drop it on the floor the way the
    # bare log line did — that is the same "resolved tile routed into a branch
    # that does no tmux work" cliff this release exists to close. tmux_jump
    # self-noops without a client_tty, so this is safe in the genuinely unknown
    # case too.
    rlog "no GUI branch for term='$term' — tmux_jump only (session in no window of its own)"
    echo "$(date -u +%FT%TZ) no GUI branch for term '$term', session $session_id" >>"$HOME/.claude/inbox.log"
    tmux_jump
    ;;
esac

[ -n "$focused" ] && exit 0
exit 1
