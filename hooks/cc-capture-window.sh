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

# 1. Capture focused window id (needs aerospace).
if command -v aerospace >/dev/null 2>&1; then
  wid=$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)
  [ -n "$wid" ] && printf '%s' "$wid" > "/tmp/cc-notify/${session_id}.window"
fi

# 2. On a new prompt, flip the tab to ⏳ running. The routing (term/editor_app/
# shell_pids) was captured by cc-notify.sh on a prior turn; the first prompt of a
# session has no route yet, so it simply gets named on the first turn-end instead.
if [ "$event" = "UserPromptSubmit" ]; then
  proj=$(basename "${cwd:-$PWD}")
  route="/tmp/cc-notify/${session_id}.route"
  if [ -f "$route" ]; then
    term="" editor_app="" shell_pids=""
    # shellcheck disable=SC1090
    . "$route"
    if [ "$term" = "vscode" ]; then
      scheme=$(cc_editor_scheme "$editor_app")
      if [ -n "$scheme" ] && [ -n "$shell_pids" ]; then
        cc_session_meta "$transcript_path" "$proj"
        name=$(cc_tab_name "$(cc_status_emoji running)" "$CC_COLOR_EMOJI" "$CC_TITLE")
        ( cc_fire_rename "$scheme" "$shell_pids" "$name" </dev/null >/dev/null 2>&1 & )
      fi
    fi
  fi
fi
exit 0
