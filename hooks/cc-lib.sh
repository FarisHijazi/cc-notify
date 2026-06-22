#!/usr/bin/env bash
# Shared helpers for cc-notify hooks. SOURCED, not executed.
# Single source of truth for session color/title, status emojis, the tab-name
# format, and firing the terminal-rename URI.

# Claude /color (agentColor) → identity color emoji.
cc_color_emoji() {
  case "$1" in
    red) printf '🔴' ;; orange) printf '🟠' ;; yellow) printf '🟡' ;;
    green) printf '🟢' ;; blue) printf '🔵' ;; purple) printf '🟣' ;;
    pink) printf '🩷' ;; cyan) printf '🩵' ;; *) printf '' ;;
  esac
}

# Session state → status emoji. (Colored circles are reserved for /color identity,
# never status — keep the two vocabularies distinct.)
cc_status_emoji() {
  case "$1" in
    startup)     printf '⏸️' ;;   # SessionStart — fresh session, no turn yet
    running)     printf '⏳' ;;   # UserPromptSubmit — Claude is working
    needs_input) printf '🔔' ;;   # Notification — wants input/permission
    idle|done)   printf '👀' ;;   # Stop — turn complete, your turn
    success)     printf '✅' ;;   # last message ended with ✅ (task done)
    failure)     printf '❌' ;;   # last message ended with ❌ (task failed)
    other)        printf '⭕' ;;   # last message ended with ⭕ (question/partial)
    *)           printf '' ;;
  esac
}

# Outcome token: Claude is instructed (global CLAUDE.md) to end every message with
# a trailing ✅/❌/⭕. Read the LAST text-bearing assistant message from the
# transcript and echo that trailing emoji (or nothing). Used to show real
# success/failure on Stop instead of the generic "your turn".
cc_last_status_token() {
  local tp="$1"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e '
const fs=require("fs");
let lines; try{ lines=fs.readFileSync(process.argv[1],"utf8").split("\n"); }catch(e){ process.exit(0); }
for(let i=lines.length-1;i>=0;i--){
  const l=lines[i]; if(!l) continue;
  let j; try{ j=JSON.parse(l); }catch(e){ continue; }
  if(j.type!=="assistant" || !j.message || !Array.isArray(j.message.content)) continue;
  const text=j.message.content.filter(b=>b&&b.type==="text").map(b=>b.text).join("");
  if(!text.trim()) continue;                 // skip tool-only turns
  const last=[...text.replace(/\s+$/,"")].pop()||"";
  if(last==="✅"||last==="❌"||last==="⭕") process.stdout.write(last);
  process.exit(0);                           // only the final message matters
}
' "$tp" 2>/dev/null
}

# Read agentColor + session title from a transcript JSONL in one pass.
# Title cascade: /rename customTitle → auto aiTitle → fallback (project).
# Sets globals: CC_COLOR_EMOJI, CC_TITLE.
cc_session_meta() {
  local tp="$1" fallback="$2" meta ac ct at
  CC_COLOR_EMOJI=""
  CC_TITLE="$fallback"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  meta=$(grep -oE '"(agentColor|customTitle|aiTitle)":"[^"]*"' "$tp" 2>/dev/null)
  ac=$(printf '%s\n' "$meta" | grep '"agentColor"'  | tail -1 | sed 's/.*:"//;s/"$//')
  ct=$(printf '%s\n' "$meta" | grep '"customTitle"' | tail -1 | sed 's/.*:"//;s/"$//')
  at=$(printf '%s\n' "$meta" | grep '"aiTitle"'     | tail -1 | sed 's/.*:"//;s/"$//')
  CC_COLOR_EMOJI=$(cc_color_emoji "$ac")
  if   [ -n "$ct" ]; then CC_TITLE="$ct"
  elif [ -n "$at" ]; then CC_TITLE="$at"
  fi
}

# Join non-empty parts with single spaces → "<status> <color> <title>".
cc_tab_name() {
  local out="" p
  for p in "$@"; do
    [ -n "$p" ] && out="${out:+$out }$p"
  done
  printf '%s' "$out"
}

# Write the desired tab name + pids to a state file the editor extension watches
# (/tmp/cc-notify/<sid>.tab). File-based on PURPOSE: `open <url>` activates the
# editor and yanks Aerospace focus across workspaces even with `-g`, so we must
# NOT use it for proactive (non-click) updates. The extension renames via
# renameWithArg (no `open`, no `show()` → never raises the window). Tab whichever
# editors have the terminal; harmless if none do. Args: sid pids(csv) name
cc_write_tab() {
  local sid="$1" pids="$2" name="$3"
  [ -n "$sid" ] && [ -n "$pids" ] && [ -n "$name" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  CC_TAB_PIDS="$pids" CC_TAB_NAME="$name" node -e '
const fs=require("fs");
const pids=(process.env.CC_TAB_PIDS||"").split(",").map(Number).filter(Boolean);
try{fs.writeFileSync("/tmp/cc-notify/"+process.argv[1]+".tab",
  JSON.stringify({pids:pids,name:process.env.CC_TAB_NAME}));}catch(e){}
' "$sid" 2>/dev/null
}
