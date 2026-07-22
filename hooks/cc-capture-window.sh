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
read -r session_id event transcript_path cwd tool_name <<<"$(printf '%s' "$input" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  try{const j=JSON.parse(d||"{}");
    const s=j.session_id||"";
    const e=j.hook_event_name||"";
    const t=(j.transcript_path||"").replace(/\s/g,"_")||"-";
    const c=(j.cwd||"").replace(/\s/g,"_")||"-";
    const n=(j.tool_name||"-");      // tool names have no spaces
    process.stdout.write(`${s} ${e} ${t} ${c} ${n}`);
  }catch(err){process.stdout.write("    ")}
});' 2>/dev/null)"
[ "$transcript_path" = "-" ] && transcript_path="" ; transcript_path="${transcript_path//_/ }"
[ "$cwd" = "-" ] && cwd="" ; cwd="${cwd//_/ }"
[ "$tool_name" = "-" ] && tool_name=""
[ -z "$session_id" ] && exit 0

mkdir -p /tmp/cc-notify 2>/dev/null

# Clear this session's pending banner + reap its bg alerter worker on:
#   • UserPromptSubmit — you responded, so you've clearly seen it.
#   • SessionEnd       — the session is gone; its banner worker MUST be reaped or it
#                        becomes an ORPHAN (kill-stale in cc-notify.sh only matches
#                        the SAME session_id, and a new session has a new id → the
#                        dead session's worker is never killed). With the banner
#                        timeout at minutes this self-heals, but reaping on SessionEnd
#                        frees the ~30MB immediately instead of waiting it out. This is
#                        the accumulation that ballooned alerter RAM (see LESSONS #19).
case "$event" in
  UserPromptSubmit|SessionEnd)
    _al="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"
    # `--remove` cleanly self-closes the live worker (~50ms) — that's what removes the
    # banner from screen on macOS Tahoe. Delay the pkill so it reaps stragglers WITHOUT
    # interrupting that self-close (an immediate pkill SIGTERMs mid-removal → banner
    # lingers). Detached so the hook returns fast.
    ( "$_al" --remove "cc-$session_id" >/dev/null 2>&1; sleep 0.3; pkill -f "alerter.*cc-$session_id" 2>/dev/null; ) &
    ;;
esac

# Map the event → status, and whether it needs a FULL (grep) update.
# AskUserQuestion is a TOOL (no Notification fires for its menu), so PreToolUse is
# the signal that a multiple-choice menu just opened → 🔀. Its PostToolUse (you
# answered) falls back to ⏳ running like any other tool.
status="" full=0
case "$event" in
  SessionStart)                status=startup;    full=1 ;;
  UserPromptSubmit)            status=running;    full=1 ;;
  PreToolUse)
    if [ "$tool_name" = "AskUserQuestion" ]; then status=options; else status=running; fi ;;
  PostToolUse|SubagentStop)    status=running ;;
  PreCompact)                  status=compacting ;;
  SessionEnd)                  status=ended ;;
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

# Repaint all windows' tabs on the low-frequency settled events only (a session
# appearing or ending). NOT on mid-turn churn (PreToolUse/PostToolUse/…) — those
# would flicker the active window every ~10s. Throttled + typing-guarded + queued
# inside cc-sweep.
case "$event" in
  SessionStart|SessionEnd) cc_trigger_sweep ;;
esac
exit 0
