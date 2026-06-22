#!/usr/bin/env bash
# Fired by SessionStart + UserPromptSubmit.
#  1. Captures the currently-focused Aerospace window id (the window the user is
#     reliably looking at) → /tmp/cc-notify/<sid>.window, used to jump back later.
#     This is the only robust way to identify the right window in editors like
#     VS Code / Cursor, where one GUI process hosts many windows.
#  2. On UserPromptSubmit, sets the integrated terminal tab status to ⏳ running
#     (Stop later flips it to 💤, Notification to 🔔). Reuses the editor/pids
#     captured by cc-notify.sh on a prior turn (in the route file).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/cc-lib.sh"

input=$(cat 2>/dev/null)
read -r session_id event transcript_path cwd <<<"$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{const j=JSON.parse(d||"{}");
    const s=j.session_id||"";
    const e=j.hook_event_name||"";
    const t=(j.transcript_path||"").replace(/\s/g,"_")||"-";
    const c=(j.cwd||"").replace(/\s/g,"_")||"-";
    process.stdout.write(`${s} ${e} ${t} ${c}`);
  }catch(err){process.stdout.write("   ")}
});' 2>/dev/null)"
[ "$transcript_path" = "-" ] && transcript_path="" ; transcript_path="${transcript_path//_/ }"
[ "$cwd" = "-" ] && cwd="" ; cwd="${cwd//_/ }"
[ -z "$session_id" ] && exit 0

mkdir -p /tmp/cc-notify 2>/dev/null

# 1. Capture focused window id — but ONLY if it belongs to a terminal/editor app.
# Sessions that drive other apps (e.g. Chrome via browser automation) would
# otherwise capture that app's window as the jump-back target, so clicking the
# notification focuses Chrome instead of the terminal. Whitelist real hosts.
if command -v aerospace >/dev/null 2>&1; then
  line=$(aerospace list-windows --focused --format '%{window-id}|%{app-name}' 2>/dev/null)
  wid="${line%%|*}"; fapp="${line#*|}"
  case "$fapp" in
    Cursor|Code|"Visual Studio Code"|"Code - Insiders"|Terminal|iTerm2|iTerm|Ghostty|Alacritty|kitty|WezTerm)
      [ -n "$wid" ] && printf '%s' "$wid" > "/tmp/cc-notify/${session_id}.window" ;;
    *) : ;;  # focused window isn't a terminal/editor — keep the previous capture
  esac
fi

# 2. Status tab: SessionStart → ✅ idle, UserPromptSubmit → ⏳ running. Reuses the
# editor/pids cc-notify.sh captured on a prior turn (route file); the first prompt
# of a session has no route yet, so it gets named on the first turn-end instead.
status=""
case "$event" in
  UserPromptSubmit) status=running ;;
  SessionStart)     status=idle ;;
esac
if [ -n "$status" ]; then
  route="/tmp/cc-notify/${session_id}.route"
  if [ -f "$route" ]; then
    term="" shell_pids=""
    # shellcheck disable=SC1090
    . "$route"
    if [ "$term" = "vscode" ] && [ -n "$shell_pids" ]; then
      cc_session_meta "$transcript_path" "$(basename "${cwd:-$PWD}")"
      name=$(cc_tab_name "$(cc_status_emoji "$status")" "$CC_COLOR_EMOJI" "$CC_TITLE")
      cc_write_tab "$session_id" "$shell_pids" "$name"
    fi
  fi
fi
exit 0
