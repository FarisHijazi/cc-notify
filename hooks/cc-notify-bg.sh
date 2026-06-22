#!/usr/bin/env bash
# Backgrounded worker spawned by cc-notify.sh.
# Args: $1=session_id $2=title $3=subtitle $4=body $5=sound
# Runs alerter blocking, invokes cc-focus.sh on click.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/cc-lib.sh"
alerter_bin="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"

# Status tab: write the desired "<status> <color> <name>" to the file the editor
# extension watches. File-based → no `open`, so it never steals Aerospace focus.
# $6=eligible(1|empty) $7=pids $8=name. Off the hook's critical path.
[ -n "$6" ] && cc_write_tab "$1" "$7" "$8"

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

result=$("$alerter_bin" \
  "${sender_args[@]}" \
  "${image_args[@]}" \
  --title    "$2" \
  --subtitle "$3" \
  --message  "$4" \
  --sound    "$5" \
  --group    "cc-$1" \
  --timeout  120 \
  --ignore-dnd 2>/dev/null)

case "$result" in
  *CONTENTCLICKED*|*contentClicked*|*ACTIONCLICKED*|*actionClicked*)
    bash "$script_dir/cc-focus.sh" "$1" >>"$HOME/.claude/cc-notify.log" 2>&1
    ;;
esac
