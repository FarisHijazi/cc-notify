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
# multi-GB of alerter RAM (see LESSONS #19). Back to 120s: a session that ends with a
# live banner is reaped immediately by the SessionEnd hook (cc-capture-window.sh), and
# 120s caps any un-reaped walk-away orphan to 2min — so the real orphan fix is the
# SessionEnd reap, not a long timeout. Trade-off: a reply >120s after the banner
# appeared can't --remove an already-exited worker, so that stale banner lingers until
# dismissed. Override via CC_BANNER_TIMEOUT if you want a longer removal window.
timeout="${CC_BANNER_TIMEOUT:-120}"

# Dismiss-on-typing: if you start typing in the session the banner came from,
# you've plainly seen it — clear it now instead of waiting for you to submit
# (UserPromptSubmit) or click. Unsubmitted input isn't exposed by any hook, so
# cc-prompt-state reads the input box off the tmux pane; it fires on the first
# CHANGE from what was there when the banner appeared, so text you'd already
# typed doesn't count. Only works for tmux-hosted sessions; everything else
# keeps the reply/click paths. Off switch: CC_NO_TYPE_DISMISS=1.
watcher=
prompt_state="$script_dir/../bin/cc-prompt-state"
tmux_target=$(sed -n 's/^tmux_target=//p' "/tmp/cc-notify/$1.route" 2>/dev/null | head -1)
if [ -z "${CC_NO_TYPE_DISMISS:-}" ] && [ -n "$tmux_target" ] && [ -x "$prompt_state" ]; then
  (
    if "$prompt_state" --watch "$tmux_target" "$timeout" "${CC_TYPE_POLL:-1}"; then
      # --remove works by telling the LIVE worker to self-close its delivered
      # notification (~50ms); pkill it too early and the removal aborts with the
      # banner still on screen. Same ordering as the click/reply paths (LESSONS #11).
      "$alerter_bin" --remove "cc-$1" >/dev/null 2>&1
      sleep 0.3
      pkill -f "alerter.*cc-$1 " 2>/dev/null
    fi
  ) &
  watcher=$!
fi

result=$("$alerter_bin" \
  "${sender_args[@]}" \
  "${image_args[@]}" \
  --title    "$2" \
  --subtitle "$3" \
  --message  "$4" \
  --sound    "$5" \
  --group    "cc-$1" \
  --timeout  "$timeout" \
  --ignore-dnd 2>/dev/null)

# Banner is gone (clicked, dismissed, or timed out) — never leave the poller behind.
[ -n "$watcher" ] && kill "$watcher" 2>/dev/null

case "$result" in
  *CONTENTCLICKED*|*contentClicked*|*ACTIONCLICKED*|*actionClicked*)
    bash "$script_dir/cc-focus.sh" "$1" >>"$HOME/.claude/cc-notify.log" 2>&1
    ;;
esac
