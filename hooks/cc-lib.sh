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
    running)     printf '⏳' ;;   # UserPromptSubmit / tool use — Claude is working
    compacting)  printf '🗜️' ;;   # PreCompact — compacting context
    permission)  printf '🔐' ;;   # Notification — needs permission to run a tool
    question)    printf '❓' ;;   # Notification — asking you / waiting for input
    needs_input) printf '🔔' ;;   # Notification — generic "needs you" fallback
    idle|done)   printf '👀' ;;   # Stop — turn complete, your turn
    success)     printf '✅' ;;   # last message ended with ✅ (task done)
    failure)     printf '❌' ;;   # last message ended with ❌ (task failed)
    good)        printf '👍' ;;   # last message ended with 👍 (good news, no task outcome)
    bad)         printf '👎' ;;   # last message ended with 👎 (bad news, no task outcome)
    other)       printf '💬' ;;   # last message ended with 💬 (neutral reply / no outcome)
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
  if(["✅","❌","👍","👎","💬"].includes(last)) process.stdout.write(last);
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

# Detect the GUI terminal/editor hosting this hook + collect candidate shell pids
# for the editor extension to match. Walks from the CALLER's process, so any hook
# can name the tab WITHOUT a route file — which is what makes `claude --resume`
# (a new terminal, no prior route) name its tab. Sets:
#   CC_TERM       vscode | Apple_Terminal | iTerm.app | ghostty | <TERM_PROGRAM>
#   CC_EDITOR_APP Cursor | Code | ""        CC_GUI_PID   GUI process pid (best effort)
#   CC_CLIENT_TTY tmux client tty (if tmux) CC_TMUX_TARGET session:window.pane
#   CC_SHELL_PIDS csv: caller's ancestor chain + every pid on CC_CLIENT_TTY
cc_detect_terminal() {
  CC_TERM="${TERM_PROGRAM:-unknown}"; CC_EDITOR_APP=""; CC_GUI_PID=""
  CC_CLIENT_TTY=""; CC_TMUX_TARGET=""
  if [ -n "$TMUX" ] && [ -n "$TMUX_PANE" ]; then
    CC_TMUX_TARGET=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P' 2>/dev/null)
    CC_CLIENT_TTY=$(tmux display-message -t "$TMUX_PANE" -p '#{client_tty}' 2>/dev/null)
  fi

  _cc_walk_tty() {  # walk a tty's process tree up to a GUI terminal; set CC_* on hit
    local cand="$1" pid hops cmd
    pid=$(ps -t "${cand#/dev/}" -o pid= 2>/dev/null | head -1 | tr -d ' '); hops=0
    while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
      cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
      case "$cmd" in
        */Terminal|Terminal)              [ "$CC_TERM" = tmux ] && CC_TERM=Apple_Terminal; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
        */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$CC_TERM" = tmux ] && CC_TERM=iTerm.app;      CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
        */Ghostty|Ghostty|*/ghostty|ghostty) [ "$CC_TERM" = tmux ] && CC_TERM=ghostty;     CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
        */Cursor|Cursor)                  [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Cursor; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
        */Code\ Helper*|*/Electron|*/Code|Code) [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Code; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
      esac
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '); hops=$((hops + 1))
    done
    return 1
  }

  # ancestor PID chain of the caller (one of these == the editor's shell pid)
  CC_SHELL_PIDS=""; local _p=$$ _h=0
  while [ -n "$_p" ] && [ "$_p" != "1" ] && [ "$_h" -lt 30 ]; do
    CC_SHELL_PIDS="${CC_SHELL_PIDS:+$CC_SHELL_PIDS,}$_p"
    _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' '); _h=$((_h + 1))
  done

  # primary: PPID walk (non-tmux). Under tmux this hits the launchd-parented
  # server and finds nothing → the tty walks below recover it.
  local _mp=$$ _mh=0 _cmd
  while [ -n "$_mp" ] && [ "$_mp" != "1" ] && [ "$_mh" -lt 30 ]; do
    _cmd=$(ps -o comm= -p "$_mp" 2>/dev/null)
    case "$_cmd" in
      */Terminal|Terminal)              [ "$CC_TERM" = tmux ] && CC_TERM=Apple_Terminal; CC_GUI_PID="$_mp"; break ;;
      */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$CC_TERM" = tmux ] && CC_TERM=iTerm.app;      CC_GUI_PID="$_mp"; break ;;
      */Ghostty|Ghostty|*/ghostty|ghostty) [ "$CC_TERM" = tmux ] && CC_TERM=ghostty;     CC_GUI_PID="$_mp"; break ;;
      */Cursor|Cursor)                  [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Cursor; CC_GUI_PID="$_mp"; break ;;
      */Code\ Helper*|*/Electron|*/Code|Code) [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Code; CC_GUI_PID="$_mp"; break ;;
    esac
    _mp=$(ps -o ppid= -p "$_mp" 2>/dev/null | tr -d ' '); _mh=$((_mh + 1))
  done

  [ -z "$CC_GUI_PID" ] && [ -n "$CC_CLIENT_TTY" ] && _cc_walk_tty "$CC_CLIENT_TTY"
  if [ -z "$CC_GUI_PID" ] && [ -n "$TMUX" ]; then
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      _cc_walk_tty "$cand" && break
    done < <(tmux list-clients -F '#{client_focused}|#{client_activity}|#{client_tty}' 2>/dev/null | sort -t'|' -k1,1nr -k2,2nr | cut -d'|' -f3)
  fi

  # tmux-inside-editor: the editor's shell is the tmux client's shell (a sibling,
  # not an ancestor) — it lives on the client tty, so add every pid there.
  if [ -n "$CC_CLIENT_TTY" ]; then
    local _tp
    for _tp in $(ps -t "${CC_CLIENT_TTY#/dev/}" -o pid= 2>/dev/null); do
      CC_SHELL_PIDS="${CC_SHELL_PIDS:+$CC_SHELL_PIDS,}$_tp"
    done
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

# Cheaply swap just the leading status emoji on an existing <sid>.tab, WITHOUT
# re-reading the (possibly huge) transcript. Used by high-frequency hooks
# (PreToolUse/PostToolUse/etc.) so they stay fast — they only re-assert the state,
# not recompute color/title. Empty emoji clears the status. No-op if the .tab
# doesn't exist yet (a full update will create it). Args: sid status_emoji
cc_set_status() {
  local sid="$1" emoji="$2" f="/tmp/cc-notify/$1.tab"
  [ -f "$f" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  CC_NEW="$emoji" node -e '
const fs=require("fs"), f=process.argv[1];
let d; try{ d=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ process.exit(0); }
const rest=(d.name||"").replace(/^(?:⏸️|⏳|🔐|❓|🔔|👀|✅|❌|👍|👎|💬|🗜️)\s*/u,"");
const ne=process.env.CC_NEW||"";
const name=ne?ne+" "+rest:rest;
if(name===d.name) process.exit(0);
try{ fs.writeFileSync(f, JSON.stringify({pids:d.pids,name:name})); }catch(e){}
' "$f" 2>/dev/null
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
