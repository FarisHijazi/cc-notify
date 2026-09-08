#!/usr/bin/env bash
# Apply a configured session color by typing `/color <name>` into the session's
# OWN tmux pane. There is no programmatic API for a running session's color
# (researched 2026-08: no CLI flag for a live session, no env var, no settings
# key, no hook-output field, no SDK option — open feature requests only; see
# devlog claude_2026-08-05-color-sync.md). The /color slash command DOES accept
# an inline argument, so the one lever a hook has is the session's input box.
#
# Typing into a TUI is only safe through the cc-prompt-state dance (LESSONS #20):
# never type unless the input box is drawn AND empty, re-read the box and confirm
# it holds exactly our text before Enter, abort WITHOUT backspacing on mismatch,
# and fail closed when the box can't be read at all. A missed recolor is
# harmless; typing into a half-written message is not.
#
# The read-back MUST use --raw: Claude Code colours a recognised slash command,
# and the default reading drops coloured runs as decoration, so `/color orange`
# came back as plain `orange` and every single apply aborted one keystroke before
# Enter — leaving `/color orange` sitting unsent in the box for the next thing
# that typed there to submit along with its own text. Enter also needs a beat
# after the text (the TUI is still opening the slash-command menu) and a
# read-back afterwards, because a swallowed Enter looks exactly like success.
#
# Usage: cc-color-apply.sh <tmux-target> <color>
# Spawned detached by cc-capture-window.sh on SessionStart when
# <cwd>/.cc/settings.json holds {"color": ...} differing from the session's own.
# Off switch: CC_NO_COLOR_SYNC=1 or ~/.claude/notify.disable_color_sync.
# Knobs: CC_COLOR_APPLY_TIMEOUT (25s) — how long to wait for the box to appear
# (covers TUI startup and a pending trust dialog); poll is 1s.
#        CC_COLOR_ENTER_DELAY (1s)   — pause between the text and Enter.
#        CC_COLOR_CONFIRM_SECS (10s) — how long to keep re-pressing Enter while
#                                      the text is still sitting in the box.
set -uo pipefail

target="${1:-}"; color="${2:-}"
[ -n "$target" ] && [ -n "$color" ] || exit 2
[ "${CC_NO_COLOR_SYNC:-0}" = "1" ] && exit 0
[ -f "$HOME/.claude/notify.disable_color_sync" ] && exit 0
# whitelist re-check at the point of actuation — this value came from a file on
# disk and is about to be typed into a live prompt
case "$color" in red|orange|yellow|green|blue|purple|pink|cyan|default) ;; *) exit 2 ;; esac

command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prompt_state="$script_dir/../bin/cc-prompt-state"
[ -x "$prompt_state" ] || exit 0   # fail closed: can't verify the box → do nothing

mkdir -p /tmp/cc-notify 2>/dev/null
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>/tmp/cc-notify/colorsync.log 2>/dev/null; }

want="/color $color"
deadline=$(( $(date +%s) + ${CC_COLOR_APPLY_TIMEOUT:-25} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  "$prompt_state" "$target" >/dev/null 2>&1
  case $? in
    0)  # box drawn and empty — type, verify, submit
      tmux send-keys -t "$target" -l -- "$want" 2>/dev/null || { log "$target: send-keys failed"; exit 1; }
      sleep "${CC_COLOR_ENTER_DELAY:-1}"
      cur=$("$prompt_state" --raw "$target" 2>/dev/null)
      if [ "$cur" != "$want" ]; then
        # User typed in the gap — leave whatever is there UNSENT (visible,
        # harmless); backspacing would eat the characters they just typed.
        log "$target: ABORT before Enter — box holds '$cur', expected '$want'"
        exit 1
      fi
      tmux send-keys -t "$target" Enter 2>/dev/null
      # A swallowed Enter leaves the command in the box looking submitted. Keep
      # pressing while it is still there; stop the moment it clears.
      end=$(( $(date +%s) + ${CC_COLOR_CONFIRM_SECS:-10} )); n=0
      while :; do
        sleep 0.5
        [ "$("$prompt_state" --raw "$target" 2>/dev/null)" = "$want" ] || break
        [ "$(date +%s)" -ge "$end" ] && { log "$target: '$want' STILL unsent after ${CC_COLOR_CONFIRM_SECS:-10}s"; exit 1; }
        tmux send-keys -t "$target" Enter 2>/dev/null; n=$(( n + 1 ))
      done
      [ "$n" -gt 0 ] && log "$target: '$want' went through after $n extra Enter(s)"
      log "$target: applied '$want'"
      exit 0 ;;
    1)  # box has text — the user beat us to the keyboard; back off entirely
      log "$target: SKIP — user is typing"
      exit 0 ;;
    *)  # no box yet (TUI still starting, or a trust/permission dialog) — wait
      sleep 1 ;;
  esac
done
log "$target: timeout — input box never became available"
exit 1
