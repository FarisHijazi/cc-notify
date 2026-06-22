#!/usr/bin/env bash
# Claude Code notification dispatcher.
# Invoked as: cc-notify.sh {notification|stop}
# Reads hook event JSON on stdin. Backgrounds alerter and returns fast.

event_kind="${1:-stop}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log="$HOME/.claude/cc-notify.log"
state_dir="/tmp/cc-notify"
mkdir -p "$state_dir" 2>/dev/null

input=$(cat 2>/dev/null)

# Parse minimal fields via node (matches existing hook convention, no jq dep).
# transcript_path comes before the free-text message (paths have no spaces).
read -r session_id cwd transcript_path message <<<"$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{const j=JSON.parse(d||"{}");
    const s=j.session_id||"";
    const c=(j.cwd||"").replace(/\s/g,"_");
    const t=(j.transcript_path||"").replace(/\s/g,"_")||"-";
    const m=(j.message||j.title||"").replace(/\s+/g," ").slice(0,200);
    process.stdout.write(`${s} ${c} ${t} ${m}`);
  }catch(e){process.stdout.write("   ")}
});' 2>/dev/null)"
cwd="${cwd//_/ }"  # restore spaces
[ "$transcript_path" = "-" ] && transcript_path=""
transcript_path="${transcript_path//_/ }"

# Session color: Claude Code's /color sets "agentColor" in the transcript JSONL.
# Map it to a colored emoji so each session's banners (and terminal tab) carry a
# consistent color marker — same source the gsd statusline/tmux color uses.
color_emoji() {
  case "$1" in
    red) printf '🔴' ;; orange) printf '🟠' ;; yellow) printf '🟡' ;;
    green) printf '🟢' ;; blue) printf '🔵' ;; purple) printf '🟣' ;;
    pink) printf '🩷' ;; cyan) printf '🩵' ;; *) printf '' ;;
  esac
}
agent_color="" emoji=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  agent_color=$(grep -oE '"agentColor":"[^"]+"' "$transcript_path" 2>/dev/null | tail -1 | sed 's/.*:"//;s/"$//')
  emoji=$(color_emoji "$agent_color")
fi

# SSH branch: hook is running on a remote box. Bell + log, exit.
if [ -n "$SSH_CONNECTION" ]; then
  printf '\a' >/dev/tty 2>/dev/null
  printf '[%s] [%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$event_kind" "$cwd" "$message" \
    >>"$HOME/.claude/inbox.log" 2>/dev/null
  exit 0
fi

# Capture local context.
term="${TERM_PROGRAM:-unknown}"
tmux_target=""
client_tty=""
if [ -n "$TMUX" ] && [ -n "$TMUX_PANE" ]; then
  tmux_target=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P' 2>/dev/null)
  client_tty=$(tmux display-message -t "$TMUX_PANE" -p '#{client_tty}' 2>/dev/null)
fi

# Walk ps tree from client_tty up to find the GUI terminal app's PID.
# Helper: try walking from a single tty. Sets `gui_pid` + `term` if it succeeds.
_try_walk_tty() {
  local candidate_tty="$1"
  local tty_short="${candidate_tty#/dev/}"
  local pid hops cmd
  pid=$(ps -t "$tty_short" -o pid= 2>/dev/null | head -1 | tr -d ' ')
  hops=0
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$cmd" in
      */Terminal|Terminal)              [ "$term" = "tmux" ] && term="Apple_Terminal"; gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
      */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$term" = "tmux" ] && term="iTerm.app";      gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
      */Ghostty|Ghostty|*/ghostty|ghostty) [ "$term" = "tmux" ] && term="ghostty";     gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
      */Cursor|Cursor)                  [ "$term" = "tmux" ] && term="vscode"; editor_app="Cursor"; gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
      */Code\ Helper*|*/Electron|*/Code|Code) [ "$term" = "tmux" ] && term="vscode"; editor_app="Code"; gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  return 1
}

gui_pid=""
editor_app=""

# Capture the ancestor PID chain of this hook. For VS Code / Cursor, the
# integrated terminal's shell PID (== Terminal.processId) is always one of these,
# so the editor extension can focus the exact terminal pane on click. PIDs are
# unique per live process, so an ancestor PID can only match the terminal we
# actually came from — never a sibling terminal.
shell_pids=""
_p=$$
_h=0
while [ -n "$_p" ] && [ "$_p" != "1" ] && [ "$_h" -lt 30 ]; do
  shell_pids="${shell_pids:+$shell_pids,}$_p"
  _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
  _h=$((_h + 1))
done

# Primary: walk PPID from our own process up. Works when claude is run
# directly from a terminal shell (no tmux, or tmux env got stripped along
# the way). For tmux-attached claude, the PPID chain typically goes through
# the tmux server (launchd-parented) and finds no terminal — the tty walks
# below cover that case.
_my_pid=$$
_hops=0
while [ -n "$_my_pid" ] && [ "$_my_pid" != "1" ] && [ "$_hops" -lt 30 ]; do
  _cmd=$(ps -o comm= -p "$_my_pid" 2>/dev/null)
  case "$_cmd" in
    */Terminal|Terminal)              [ "$term" = "tmux" ] && term="Apple_Terminal"; gui_pid="$_my_pid"; break ;;
    */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$term" = "tmux" ] && term="iTerm.app";      gui_pid="$_my_pid"; break ;;
    */Ghostty|Ghostty|*/ghostty|ghostty) [ "$term" = "tmux" ] && term="ghostty";     gui_pid="$_my_pid"; break ;;
    */Cursor|Cursor)                  [ "$term" = "tmux" ] && term="vscode"; editor_app="Cursor"; gui_pid="$_my_pid"; break ;;
    */Code\ Helper*|*/Electron|*/Code|Code) [ "$term" = "tmux" ] && term="vscode"; editor_app="Code"; gui_pid="$_my_pid"; break ;;
  esac
  _my_pid=$(ps -o ppid= -p "$_my_pid" 2>/dev/null | tr -d ' ')
  _hops=$((_hops + 1))
done

# Fallback: the client_tty captured from the current pane.
[ -z "$gui_pid" ] && [ -n "$client_tty" ] && _try_walk_tty "$client_tty"

# Fallback: a tmux session may have multiple attached clients on different
# ttys, and the captured one can be a zombie (terminal closed but tmux still
# holds the slave). Iterate ALL attached clients, preferring focused + most
# recently active, until one reaches a real GUI terminal.
if [ -z "$gui_pid" ] && [ -n "$TMUX" ]; then
  while IFS= read -r candidate_tty; do
    [ -z "$candidate_tty" ] && continue
    _try_walk_tty "$candidate_tty" && break
  done < <(tmux list-clients -F '#{client_focused}|#{client_activity}|#{client_tty}' 2>/dev/null \
            | sort -t'|' -k1,1nr -k2,2nr \
            | cut -d'|' -f3)
fi

# Captured Aerospace window id from SessionStart / UserPromptSubmit hooks.
# This is the most reliable signal for which GUI window the user is in,
# especially for editors (VS Code, Cursor) where one process owns many
# windows and process-tree walking can't distinguish them.
target_wid=""
[ -n "$session_id" ] && [ -f "/tmp/cc-notify/${session_id}.window" ] \
  && target_wid=$(cat "/tmp/cc-notify/${session_id}.window" 2>/dev/null)

cwd_basename=$(basename "${cwd:-$PWD}")
git_branch=$(git -C "${cwd:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)

# Stop event gating.
#
# Stop fires the moment Claude is fully done — after all subagents have returned
# and the final response is written (background shells/watchers don't hold the
# turn open). So we treat Stop as the authoritative "done" signal and fire
# immediately, rather than relying on Claude Code's ~60s idle Notification.
#
# Two opt-out gates, both off by default:
#   notify.disable_stop          — kill-switch: never fire Stop.
#   notify.suppress_when_focused — only then suppress Stop when the originating
#                                  window is already frontmost. Off by default
#                                  because the frontmost detection is unreliable
#                                  in VS Code/Cursor (it ate legitimate pings).
if [ "$event_kind" = "stop" ]; then
  # Kill-switch sentinel.
  [ -f "$HOME/.claude/notify.disable_stop" ] && exit 0

  # Opt-in frontmost suppression. Prefer the captured target_wid (most reliable,
  # especially for editors); fall back to gui_pid-based lookup; final fallback is
  # app-level frontmost (only when Aerospace is unavailable or no window captured).
  if [ -f "$HOME/.claude/notify.suppress_when_focused" ]; then
    if command -v aerospace >/dev/null 2>&1; then
      focused_wid=$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)
      claude_wid="$target_wid"
      [ -z "$claude_wid" ] && [ -n "$gui_pid" ] \
        && claude_wid=$(aerospace list-windows --monitor all --pid "$gui_pid" --format '%{window-id}' 2>/dev/null | head -1)
      if [ -n "$claude_wid" ] && [ "$claude_wid" = "$focused_wid" ]; then
        exit 0
      fi
    else
      frontmost=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null)
      case "$term" in
        Apple_Terminal) [ "$frontmost" = "Terminal" ] && exit 0 ;;
        vscode)         [ "$frontmost" = "Code" ] || [ "$frontmost" = "Cursor" ] && exit 0 ;;
        iTerm.app)      [ "$frontmost" = "iTerm2" ] || [ "$frontmost" = "iTerm" ] && exit 0 ;;
        ghostty)        [ "$frontmost" = "ghostty" ] || [ "$frontmost" = "Ghostty" ] && exit 0 ;;
      esac
    fi
  fi
fi

# When Claude runs in tmux inside VS Code/Cursor, the integrated terminal's shell
# (== Terminal.processId) is the tmux *client's* shell — a sibling of our process
# tree, not an ancestor (our chain hits the launchd-parented tmux server). But it
# lives on client_tty, so add every pid on that tty to the candidate set.
shell_pids_all="$shell_pids"
if [ -n "$client_tty" ]; then
  for _tp in $(ps -t "${client_tty#/dev/}" -o pid= 2>/dev/null); do
    shell_pids_all="${shell_pids_all:+$shell_pids_all,}$_tp"
  done
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

# Build notification copy.
if [ "$event_kind" = "notification" ]; then
  title="Claude Code"
  body="${message:-Awaiting input}"
  sound="Glass"
else
  title="Claude Code"
  body="Turn complete"
  sound="Hero"
fi
subtitle="$cwd_basename"
[ -n "$git_branch" ] && subtitle="$cwd_basename ($git_branch)"
[ -n "$emoji" ] && subtitle="$emoji $subtitle"

# Spawn the bg worker fully detached: the outer subshell exits immediately,
# orphaning bg to launchd. No quote-nesting, no nohup needed.
( bash "$script_dir/cc-notify-bg.sh" \
    "${session_id:-default}" "$title" "$subtitle" "$body" "$sound" \
    </dev/null >/dev/null 2>&1 & )

exit 0
