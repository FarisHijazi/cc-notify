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
# --raw is necessary but NOT sufficient, which cost this hook roughly half its
# applies (colorsync.log: "box holds '', expected '/color blue'"). Typing
# "/color " opens the slash-command menu; that moves the input row, so
# cc-prompt-state stops finding a box at all and exits 2 with EMPTY stdout. The
# old code captured stdout and dropped the exit code, so "menu is open" was
# indistinguishable from "our text vanished" and it aborted one keystroke before
# Enter. The same blind comparison ended the Enter-retry loop on its first pass,
# so a swallowed Enter was never actually retried. Both now verify against the
# PANE (still_typed) whenever the box reads empty or unreadable, and only a box
# holding genuinely DIFFERENT text still aborts — that one really is the user
# typing. Cross-checked against auto-compact-continue.sh, which types into the
# same pane and learned this first.
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
# Serialise against the other hook that types into this same pane (the
# auto-compact continue message). Absent → best-effort, no locking.
# shellcheck source=../bin/cc-type-lock.sh
[ -r "$script_dir/../bin/cc-type-lock.sh" ] && . "$script_dir/../bin/cc-type-lock.sh"
command -v cc_type_lock >/dev/null 2>&1 || { cc_type_lock() { :; }; cc_type_unlock() { :; }; }

mkdir -p /tmp/cc-notify 2>/dev/null
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>/tmp/cc-notify/colorsync.log 2>/dev/null; }

MARK=$'\342\235\257'   # U+276F  the prompt marker Claude Code draws
NBSP=$'\302\240'        # U+00A0  separates the marker from UNSENT text

# --raw read with the input row's padding treated as the whitespace it is, and
# the exit code PRESERVED. Claude Code separates "❯" from the text with U+00A0;
# bash trims that with [[:space:]] on macOS but not under glibc, so without this
# a Debian box compares "\u00a0/color blue" against "/color blue" and never
# matches. stdout: normalised text. return: 0 empty, 1 has text, 2 no box.
read_raw() {
  local t rc
  t=$("$prompt_state" --raw "$1" 2>/dev/null); rc=$?
  t="${t//$NBSP/ }"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
  return "$rc"
}

# Is $2 still sitting UNSENT in the input row of pane $1?
# Read straight off the pane, because typing "/color " opens the slash-command
# menu and cc-prompt-state then reports "no input box" (exit 2, empty stdout) --
# which is indistinguishable from "our text vanished" unless we look ourselves.
# The UNSENT row is "❯" + U+00A0 + text; a SUBMITTED echo uses an ordinary
# space, so the NBSP is exactly what separates "waiting" from "gone". Bottom 12
# rows only, prefix-matched, so a wrapped row and the scrollback both behave.
still_typed() {
  tmux capture-pane -p -t "$1" 2>/dev/null | tail -12 |
    grep -qF -- "$MARK$NBSP${2:0:24}"
}

want="/color $color"
deadline=$(( $(date +%s) + ${CC_COLOR_APPLY_TIMEOUT:-25} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  "$prompt_state" "$target" >/dev/null 2>&1
  case $? in
    0)  # box drawn and empty — take the pane's type-lock, re-check, then type
      cc_type_lock "$target" || { log "$target: SKIP — another hook holds the type-lock"; exit 1; }
      if ! "$prompt_state" "$target" >/dev/null 2>&1; then
        cc_type_unlock                 # it filled up while we waited for the lock
        sleep 1; continue
      fi
      tmux send-keys -t "$target" -l -- "$want" 2>/dev/null || { log "$target: send-keys failed"; exit 1; }
      sleep "${CC_COLOR_ENTER_DELAY:-1}"
      cur=$(read_raw "$target"); rc=$?
      if [ "$cur" != "$want" ]; then
        if [ "$rc" -eq 1 ] && [ -n "$cur" ]; then
          # The box genuinely holds something else: the user typed in the gap.
          # Leave it UNSENT (visible, harmless) -- backspacing would eat the
          # characters they just typed.
          log "$target: ABORT before Enter — box holds '$cur', expected '$want'"
          exit 1
        fi
        # Empty or unreadable. That is NOT evidence our text is missing: typing
        # "/color " opens the slash-command menu, which moves the input row and
        # makes cc-prompt-state report "no box" with empty stdout. Ask the pane.
        if ! still_typed "$target" "$want"; then
          log "$target: ABORT before Enter — '$want' never reached the input row"
          exit 1
        fi
        log "$target: box read '$cur' (rc=$rc) but '$want' is on the row — proceeding"
      fi
      tmux send-keys -t "$target" Enter 2>/dev/null
      # A swallowed Enter leaves the command in the box looking submitted. Keep
      # pressing while it is still there; stop the moment it clears.
      # Watch the ROW, not cc-prompt-state: while the slash-command menu is up
      # the box reads empty, which the old comparison took as "submitted" and
      # broke out on the first pass -- so a swallowed Enter was never retried.
      end=$(( $(date +%s) + ${CC_COLOR_CONFIRM_SECS:-10} )); n=0
      while :; do
        sleep 0.5
        still_typed "$target" "$want" || break
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
