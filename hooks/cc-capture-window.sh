#!/usr/bin/env bash
# Status updater + window capture. Registered on many hooks (see hooks.json) so
# the terminal-tab status stays current and self-heals.
#
#   SessionStart      → ⏸️ startup   (FULL: capture window + grep color/title)
#   UserPromptSubmit  → ⏳ running    (FULL: capture window + grep color/title)
#   PreToolUse        → ⏳ running    (cheap: swap status emoji on existing .tab)
#   PostToolUse       → ⏳ running    (cheap)
#   SubagentStop      → ⏳ running    (cheap — main turn continues)
#   PreCompact        → 🗜️ compacting (cheap)
#   SessionEnd        → (clear)      (cheap: drop the status emoji)
#
# "FULL" updates re-read the transcript (for color/title) and only run on the two
# events where the user is reliably looking at the window. The "cheap" updates
# only re-write the leading status emoji on the existing .tab — no transcript
# grep, no aerospace call — so they stay fast even firing on every tool call.

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

# You just responded to this session (sent a prompt) → you've clearly seen it, so
# clear any pending notification banner for it: dismiss it from Notification
# Center and kill the bg alerter still waiting for a click. Detached/fast.
if [ "$event" = "UserPromptSubmit" ]; then
  _al="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"
  ( "$_al" --remove "cc-$session_id" >/dev/null 2>&1; pkill -f "alerter.*cc-$session_id" 2>/dev/null; ) &
fi

# Map the event → status, and whether it needs a FULL (grep) update.
status="" full=0
case "$event" in
  SessionStart)                          status=startup;    full=1 ;;
  UserPromptSubmit)                      status=running;    full=1 ;;
  PreToolUse|PostToolUse|SubagentStop)   status=running ;;
  PreCompact)                            status=compacting ;;
  SessionEnd)                            status=ended ;;
esac
[ -z "$status" ] && exit 0

if [ "$full" = 1 ]; then
  # Capture the focused window id — but ONLY if it's a terminal/editor app, so a
  # session driving Chrome doesn't capture Chrome as the jump-back target.
  if command -v aerospace >/dev/null 2>&1; then
    line=$(aerospace list-windows --focused --format '%{window-id}|%{app-name}' 2>/dev/null)
    wid="${line%%|*}"; fapp="${line#*|}"
    case "$fapp" in
      Cursor|Code|"Visual Studio Code"|"Code - Insiders"|Terminal|iTerm2|iTerm|Ghostty|Alacritty|kitty|WezTerm)
        [ -n "$wid" ] && printf '%s' "$wid" > "/tmp/cc-notify/${session_id}.window" ;;
    esac
  fi
  # Fresh status .tab — self-detect the terminal (NO route-file dependency), so it
  # works on `claude --resume` (new terminal, no prior route) and fresh sessions
  # alike. + color/title from the transcript. Detached so the hook returns fast.
  cc_detect_terminal
  if [ "$CC_TERM" = "vscode" ] && [ -n "$CC_SHELL_PIDS" ]; then
    cc_session_meta "$transcript_path" "$(basename "${cwd:-$PWD}")"
    name=$(cc_tab_name "$(cc_status_emoji "$status")" "$CC_COLOR_EMOJI" "$CC_TITLE")
    ( cc_write_tab "$session_id" "$CC_SHELL_PIDS" "$name" </dev/null >/dev/null 2>&1 & )
  fi
else
  # Cheap: just re-write the leading status emoji on the existing .tab. Detached.
  if [ "$status" = "ended" ]; then
    ( cc_set_status "$session_id" "" </dev/null >/dev/null 2>&1 & )
  else
    ( cc_set_status "$session_id" "$(cc_status_emoji "$status")" </dev/null >/dev/null 2>&1 & )
  fi
fi
exit 0
