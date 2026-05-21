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
read -r session_id cwd message <<<"$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{const j=JSON.parse(d||"{}");
    const s=j.session_id||"";
    const c=(j.cwd||"").replace(/\s/g,"_");
    const m=(j.message||j.title||"").replace(/\s+/g," ").slice(0,200);
    process.stdout.write(`${s} ${c} ${m}`);
  }catch(e){process.stdout.write("  ")}
});' 2>/dev/null)"
cwd="${cwd//_/ }"  # restore spaces

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
      */Cursor|Cursor)                  [ "$term" = "tmux" ] && term="vscode";         gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
      */Code\ Helper*|*/Electron|*/Code|Code) [ "$term" = "tmux" ] && term="vscode";   gui_pid="$pid"; client_tty="$candidate_tty"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  return 1
}

gui_pid=""
# First attempt: the client_tty captured from the current pane.
[ -n "$client_tty" ] && _try_walk_tty "$client_tty"

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

cwd_basename=$(basename "${cwd:-$PWD}")
git_branch=$(git -C "${cwd:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)

# Stop event gating.
if [ "$event_kind" = "stop" ]; then
  # Kill-switch sentinel.
  [ -f "$HOME/.claude/notify.disable_stop" ] && exit 0

  # Suppress if originating terminal app is currently frontmost.
  frontmost=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null)
  case "$term" in
    Apple_Terminal) [ "$frontmost" = "Terminal" ] && exit 0 ;;
    vscode)         [ "$frontmost" = "Code" ] || [ "$frontmost" = "Cursor" ] && exit 0 ;;
    iTerm.app)      [ "$frontmost" = "iTerm2" ] || [ "$frontmost" = "iTerm" ] && exit 0 ;;
    ghostty)        [ "$frontmost" = "ghostty" ] || [ "$frontmost" = "Ghostty" ] && exit 0 ;;
  esac
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

# Spawn the bg worker fully detached: the outer subshell exits immediately,
# orphaning bg to launchd. No quote-nesting, no nohup needed.
( bash "$script_dir/cc-notify-bg.sh" \
    "${session_id:-default}" "$title" "$subtitle" "$body" "$sound" \
    </dev/null >/dev/null 2>&1 & )

exit 0
