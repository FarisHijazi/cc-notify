#!/usr/bin/env bash
# Backgrounded worker spawned by cc-notify.sh.
# Args: $1=session_id $2=title $3=subtitle $4=body $5=sound
# Runs alerter blocking, invokes cc-focus.sh on click.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
alerter_bin="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"
# Note: the terminal-tab .tab file is written by cc-notify.sh itself (before the
# Stop banner gating), so the tab updates even when the banner is suppressed.

# Notification icon: impersonating Claude.app's bundle id is the only way to get
# the orange Claude logo as the icon (Big Sur+ ignores custom --app-icon). BUT
# macOS SILENTLY DROPS notifications sent under a bundle id that lacks
# notification permission — and Claude.app usually has none (most people use the
# Claude Code CLI, not the desktop app), so impersonating it kills the banner and
# leaves only the terminal bell. So this is OPT-IN: enable it only after you've
# launched Claude.app once and allowed its notifications.
#   touch ~/.claude/notify.claude_icon   # opt into the orange Claude icon
sender_args=()
if [ -f "$HOME/.claude/notify.claude_icon" ] && [ -d "/Applications/Claude.app" ]; then
  sender_args=(--sender com.anthropic.claudefordesktop)
fi

# Orange Claude mark as a right-side content image (extra brand color in the
# banner body — macOS won't let us color the banner background itself).
image_args=()
logo="$script_dir/../assets/claude-logo.png"
[ -f "$logo" ] && image_args=(--content-image "$logo")

# --timeout is how long this worker BLOCKS waiting for a click — and, crucially, both
# (a) how long the notification stays REMOVABLE and (b) how long this ~30MB process
# lives. On macOS Tahoe alerter can't purge an already-delivered notification once its
# poster has exited (`alerter --list` returns empty; `--remove` only works by closing a
# still-LIVE worker). So a longer timeout keeps a reply (UserPromptSubmit → --remove)
# able to clear the banner — BUT every unclicked banner holds the process for the whole
# timeout, and a session that ENDS with a live banner ORPHANS its worker (kill-stale in
# cc-notify.sh only matches the same session_id). At 24h those orphans piled up to
# multi-GB of alerter RAM (see LESSONS #19). 10min balances the two: it covers any
# realistic reply window (the 120s default was too short — that was the v1.7.11 bug)
# while bounding an orphan's lifetime to minutes. SessionEnd also reaps the worker
# immediately (cc-capture-window.sh). Override via CC_BANNER_TIMEOUT.
result=$("$alerter_bin" \
  "${sender_args[@]}" \
  "${image_args[@]}" \
  --title    "$2" \
  --subtitle "$3" \
  --message  "$4" \
  --sound    "$5" \
  --group    "cc-$1" \
  --timeout  "${CC_BANNER_TIMEOUT:-600}" \
  --ignore-dnd 2>/dev/null)

case "$result" in
  *CONTENTCLICKED*|*contentClicked*|*ACTIONCLICKED*|*actionClicked*)
    bash "$script_dir/cc-focus.sh" "$1" >>"$HOME/.claude/cc-notify.log" 2>&1
    ;;
esac
