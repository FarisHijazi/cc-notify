#!/usr/bin/env bash
# Claude Code notification dispatcher.
# Invoked as: cc-notify.sh {notification|stop}
# Reads hook event JSON on stdin. Backgrounds alerter and returns fast.

event_kind="${1:-stop}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/cc-lib.sh"
log="$HOME/.claude/cc-notify.log"
state_dir="/tmp/cc-notify"
mkdir -p "$state_dir" 2>/dev/null

input=$(cat 2>/dev/null)

# Parse minimal fields via node (matches existing hook convention, no jq dep).
# transcript_path comes before the free-text message (paths have no spaces).
read -r session_id cwd transcript_path notif_type message <<<"$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{const j=JSON.parse(d||"{}");
    const s=j.session_id||"";
    const c=(j.cwd||"").replace(/\s/g,"_");
    const t=(j.transcript_path||"").replace(/\s/g,"_")||"-";
    const n=(j.notification_type||"-").replace(/\s/g,"_");
    const m=(j.message||j.title||"").replace(/\s+/g," ").slice(0,200);
    process.stdout.write(`${s} ${c} ${t} ${n} ${m}`);
  }catch(e){process.stdout.write("    ")}
});' 2>/dev/null)"
cwd="${cwd//_/ }"  # restore spaces
[ "$transcript_path" = "-" ] && transcript_path=""
transcript_path="${transcript_path//_/ }"
[ "$notif_type" = "-" ] && notif_type=""

# Session color (/color → agentColor) + name (/rename → customTitle, else auto
# aiTitle, else project) read from the transcript. See cc-lib.sh.
cc_session_meta "$transcript_path" "$(basename "${cwd:-$PWD}")"
emoji="$CC_COLOR_EMOJI"
session_title="$CC_TITLE"

# SSH branch: hook is running on a remote box. Bell + log, exit.
if [ -n "$SSH_CONNECTION" ]; then
  printf '\a' >/dev/tty 2>/dev/null
  printf '[%s] [%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$event_kind" "$cwd" "$message" \
    >>"$HOME/.claude/inbox.log" 2>/dev/null
  exit 0
fi

# Detect the GUI terminal/editor + candidate shell pids (shared with the other
# hooks — see cc-lib.sh:cc_detect_terminal). Self-contained walk, so it also works
# for `claude --resume` (new terminal, no prior route file).
cc_detect_terminal
term="$CC_TERM"
tmux_target="$CC_TMUX_TARGET"
client_tty="$CC_CLIENT_TTY"
gui_pid="$CC_GUI_PID"
editor_app="$CC_EDITOR_APP"
shell_pids_all="$CC_SHELL_PIDS"

# Captured Aerospace window id from SessionStart / UserPromptSubmit hooks.
# This is the most reliable signal for which GUI window the user is in,
# especially for editors (VS Code, Cursor) where one process owns many
# windows and process-tree walking can't distinguish them.
target_wid=""
[ -n "$session_id" ] && [ -f "/tmp/cc-notify/${session_id}.window" ] \
  && target_wid=$(cat "/tmp/cc-notify/${session_id}.window" 2>/dev/null)

cwd_basename=$(basename "${cwd:-$PWD}")
git_branch=$(git -C "${cwd:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)

# Build the "<status> <color> <session>" line that drives BOTH the banner title
# and the terminal tab (no wasted "Claude Code" — the orange Claude content-image
# already brands it). Status: notification → 🔔; stop → ✅/❌/⭕ from the trailing
# token in Claude's last message (per global CLAUDE.md), else 👀 "your turn".
if [ "$event_kind" = "notification" ]; then
  sound="Glass"
  # Distinguish permission requests (🔐) from questions / idle input (❓), via
  # notification_type with a message-text fallback. Unknown types → 🔔. The exact
  # type strings are logged to notiftypes.log so the mapping can be refined.
  printf '%s\t%s\n' "${notif_type:-?}" "$message" >> "$state_dir/notiftypes.log" 2>/dev/null
  # idle/input notifications (CC's ~60s "waiting for your input") are LOW-signal
  # and noisy → update the tab status only, NO banner (notif_tab_only=1). Permission
  # prompts and the generic fallback still banner.
  case "$notif_type $message" in
    *permission*|*Permission*) status_emoji=$(cc_status_emoji permission); subtitle="Needs permission" ;;
    *idle*|*waiting*|*input*|*question*) status_emoji=$(cc_status_emoji question); subtitle="Awaiting your input"; notif_tab_only=1 ;;
    *) status_emoji=$(cc_status_emoji needs_input); subtitle="Needs your attention" ;;
  esac
  body="${message:-Claude needs you}"
else
  status_emoji=$(cc_last_status_token "$transcript_path")
  [ -z "$status_emoji" ] && status_emoji=$(cc_status_emoji idle)
  sound="Hero"
  case "$status_emoji" in
    🚨) subtitle="⚠️ Accident / disaster" ;;
    💯) subtitle="All tasks complete"; status_emoji=$(cc_status_emoji complete) ;;  # 💯 → display 💯✅
    ✅) subtitle="Task complete" ;;
    ❌) subtitle="Task failed" ;;
    🚫) subtitle="Blocked" ;;
    🙋) subtitle="Waiting for instructions" ;;
    👍) subtitle="Good news" ;;
    👎) subtitle="Bad news" ;;
    🏃) subtitle="Work to be done" ;;
    ℹ️) subtitle="FYI" ;;
    *)  subtitle="Turn complete" ;;
  esac
  body="$cwd_basename"
  [ -n "$git_branch" ] && body="$cwd_basename · $git_branch"
fi
title=$(cc_tab_name "$status_emoji" "$emoji" "${session_title:-$cwd_basename}")

# Terminal-tab status — write it ALWAYS, decoupled from the banner gating below.
# This MUST run even when the Stop banner is suppressed/kill-switched, otherwise
# the tab gets stuck (e.g. frozen on ⏳). File-based (the extension watches it);
# NO `open` (which would steal Aerospace focus).
#
# Two-tier so ⏳ can NEVER stick: the full write (cc_write_tab) refreshes color+title
# but is gated on positively detecting the editor (term=vscode) — which is FLAKY
# under tmux. If detection failed this invocation, fall back to the cheap
# cc_set_status, which just swaps the leading status emoji on the EXISTING .tab with
# NO term/pid dependency. The mid-turn ⏳ comes from that same cheap path (no gate),
# so the outcome/done emoji must be writable the same way — else a flaked detection
# on Stop leaves the tab frozen on ⏳ (the exact bug this fixes).
if [ "$term" = "vscode" ] && [ -n "$shell_pids_all" ]; then
  ( cc_write_tab "${session_id:-default}" "$shell_pids_all" "$title" </dev/null >/dev/null 2>&1 & )
else
  ( cc_set_status "${session_id:-default}" "$status_emoji" </dev/null >/dev/null 2>&1 & )
fi

# Persist routing payload for the click handler.
route_file="$state_dir/${session_id:-default}.route"
{
  printf 'term=%q\n' "$term"
  printf 'tmux_target=%q\n' "$tmux_target"
  printf 'client_tty=%q\n' "$client_tty"
  printf 'cwd=%q\n' "$cwd"
  printf 'tmux_socket=%q\n' "${TMUX%%,*}"
  printf 'gui_pid=%q\n' "$gui_pid"
  printf 'target_wid=%q\n' "$target_wid"
  printf 'editor_app=%q\n' "$editor_app"
  printf 'shell_pids=%q\n' "$shell_pids_all"
} >"$route_file" 2>/dev/null

# Stop BANNER gating (the tab status above already updated, regardless). Both
# opt-outs are off by default:
#   notify.disable_stop          — kill-switch: never show the Stop banner.
#   notify.suppress_when_focused — suppress the Stop banner when the originating
#                                  window is already frontmost (off by default —
#                                  frontmost detection is unreliable in editors).
if [ "$event_kind" = "stop" ]; then
  [ -f "$HOME/.claude/notify.disable_stop" ] && exit 0
  if [ -f "$HOME/.claude/notify.suppress_when_focused" ]; then
    if command -v aerospace >/dev/null 2>&1; then
      focused_wid=$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)
      claude_wid="$target_wid"
      [ -z "$claude_wid" ] && [ -n "$gui_pid" ] \
        && claude_wid=$(aerospace list-windows --monitor all --pid "$gui_pid" --format '%{window-id}' 2>/dev/null | head -1)
      [ -n "$claude_wid" ] && [ "$claude_wid" = "$focused_wid" ] && exit 0
    else
      frontmost=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null)
      case "$term" in
        Apple_Terminal) [ "$frontmost" = "Terminal" ] && exit 0 ;;
        vscode)         { [ "$frontmost" = "Code" ] || [ "$frontmost" = "Cursor" ]; } && exit 0 ;;
        iTerm.app)      { [ "$frontmost" = "iTerm2" ] || [ "$frontmost" = "iTerm" ]; } && exit 0 ;;
        ghostty)        { [ "$frontmost" = "ghostty" ] || [ "$frontmost" = "Ghostty" ]; } && exit 0 ;;
      esac
    fi
  fi
fi

# Idle/input Notification (CC's ~60s "waiting for your input"): tab status already
# updated above — suppress the banner here. Keeps the high-signal pings (permission,
# Stop, generic) while dropping the noisy idle one.
[ -n "$notif_tab_only" ] && exit 0

# Spawn the bg worker (the BANNER) fully detached: the outer subshell exits
# immediately, orphaning bg to launchd. No quote-nesting, no nohup needed.
( bash "$script_dir/cc-notify-bg.sh" \
    "${session_id:-default}" "$title" "$subtitle" "$body" "$sound" \
    </dev/null >/dev/null 2>&1 & )

exit 0
