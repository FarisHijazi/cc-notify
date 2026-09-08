# shellcheck shell=bash
# cc-type-lock.sh — sourceable mutual exclusion for "type into a Claude Code
# input box". Not executable on its own; `source` it.
#
# Two independent hooks type into the SAME pane — cc-color-apply.sh sends
# `/color <name>` on SessionStart and auto-compact-continue.sh sends `/compact`
# or the continue message at a turn boundary — and PostCompact fires both at
# once. With no lock they interleave inside each other's check-type-verify
# dance and the box ends up holding
#   `/color bluecontinue and complete all tasks the user asked for`
# so BOTH abort (correctly: neither reads back what it typed), neither command
# is ever submitted, and the stray word is left in the box for whatever types
# there next to submit along with its own text. Observed on 2026-09-08 in both
# colorsync.log and cc-autocompact.log at the same second.
#
#   cc_type_lock <tmux-target> [wait_secs]   0 = acquired, 1 = gave up waiting
#   cc_type_unlock                           release (also runs on EXIT)
#
# The key is the pane's `#{pane_id}`, not the caller's target string, because
# the two callers name the same pane differently (`farishijazi-3` vs
# `farishijazi-3:0.0`). A target that can't be resolved to a pane returns 0
# WITHOUT a lock: this is best-effort ordering, never a reason to skip work.
#
# mkdir is the atomic primitive (macOS has no flock). A holder that dies
# mid-dance is detected by its recorded pid and the lock is broken.

CC_TYPE_LOCK_DIR=""

cc_type_lock() {
  local target="$1" wait="${2:-${CC_TYPE_LOCK_WAIT:-40}}" key dir deadline holder
  key="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null)"
  [ -n "$key" ] || return 0
  mkdir -p /tmp/cc-notify/typelock 2>/dev/null
  dir="/tmp/cc-notify/typelock/${key#%}"
  deadline=$(( $(date +%s) + wait ))
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s' "$$" >"$dir/pid" 2>/dev/null
      CC_TYPE_LOCK_DIR="$dir"
      trap 'cc_type_unlock' EXIT INT TERM
      return 0
    fi
    holder="$(cat "$dir/pid" 2>/dev/null)"
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$dir" 2>/dev/null      # holder gone — break its lock and retry
      continue
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.5
  done
}

cc_type_unlock() {
  [ -n "$CC_TYPE_LOCK_DIR" ] && rm -rf "$CC_TYPE_LOCK_DIR" 2>/dev/null
  CC_TYPE_LOCK_DIR=""
}
