#!/usr/bin/env bash
# Captures the currently-focused Aerospace window id and stashes it for
# the session. Fired by SessionStart and UserPromptSubmit hooks — at those
# moments the user is reliably looking at the Claude Code window, so the
# focused window IS the one we want to jump back to later.
#
# This is the only robust way to identify the right window in editors like
# VS Code / Cursor, where a single GUI process hosts many windows and there
# is no process-tree mapping from a terminal pane to its containing window.

command -v aerospace >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null)
session_id=$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{process.stdout.write(JSON.parse(d||"{}").session_id||"")}catch(e){}
});' 2>/dev/null)

[ -z "$session_id" ] && exit 0

mkdir -p /tmp/cc-notify 2>/dev/null
wid=$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)
[ -n "$wid" ] && printf '%s' "$wid" > "/tmp/cc-notify/${session_id}.window"
exit 0
