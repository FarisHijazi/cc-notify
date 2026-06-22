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
    running)     printf '⏳' ;;   # UserPromptSubmit — Claude is working
    needs_input) printf '🔔' ;;   # Notification — wants input/permission
    idle|done)   printf '✅' ;;   # Stop — turn complete, waiting for you
    *)           printf '' ;;
  esac
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

# Resolve the URI scheme for an editor, but ONLY if the focus extension is
# installed (else the editor pops a "not installed" toast). Echoes scheme or "".
cc_editor_scheme() {
  local app="$1" scheme extdir
  case "$app" in
    Cursor) scheme=cursor; extdir="$HOME/.cursor/extensions" ;;
    *)      scheme=vscode; extdir="$HOME/.vscode/extensions" ;;
  esac
  ls -d "$extdir/farishijazi.cc-notify-focus"* >/dev/null 2>&1 || return 0
  printf '%s' "$scheme"
}

# Fire the terminal-tab rename URI in the background (open -g → no focus steal).
# Args: scheme pids name
cc_fire_rename() {
  local scheme="$1" pids="$2" name="$3" enc
  [ -n "$scheme" ] && [ -n "$pids" ] && [ -n "$name" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  enc=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$name" 2>/dev/null)
  [ -n "$enc" ] && open -g "$scheme://farishijazi.cc-notify-focus/rename?pids=$pids&name=$enc" 2>/dev/null
}
