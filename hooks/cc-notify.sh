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

# Recent tmux overrides TERM_PROGRAM=tmux. Recover the outer terminal app by
# walking up from any process on the client tty until we hit a known GUI term.
if [ "$term" = "tmux" ] && [ -n "$client_tty" ]; then
  tty_short="${client_tty#/dev/}"
  # Pick any process attached to the tty (e.g. login/zsh/tmux) and walk up.
  tty_pid=$(ps -t "$tty_short" -o pid= 2>/dev/null | head -1 | tr -d ' ')
  hops=0
  while [ -n "$tty_pid" ] && [ "$tty_pid" != "1" ] && [ "$hops" -lt 20 ]; do
    cmd=$(ps -o comm= -p "$tty_pid" 2>/dev/null)
    case "$cmd" in
      */Terminal|Terminal)              term="Apple_Terminal"; break ;;
      */iTerm2|iTerm2|*/iTerm|iTerm)    term="iTerm.app"; break ;;
      */Ghostty|Ghostty|*/ghostty|ghostty) term="ghostty"; break ;;
      */Cursor|Cursor)                  term="vscode"; break ;;
      */Code\ Helper*|*/Electron|*/Code|Code) term="vscode"; break ;;
    esac
    tty_pid=$(ps -o ppid= -p "$tty_pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
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
