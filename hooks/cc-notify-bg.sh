#!/usr/bin/env bash
# Backgrounded worker spawned by cc-notify.sh.
# Args: $1=session_id $2=title $3=subtitle $4=body $5=sound
# Runs alerter blocking, invokes cc-focus.sh on click.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
alerter_bin="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"

# Show the Claude logo (orange — matches the Claude Code statusline accent) as the
# notification icon by impersonating Claude.app's bundle id. On modern macOS
# (Big Sur+) custom --app-icon is ignored; impersonating the sender's bundle id
# is the only way to override the icon. Guard so it degrades gracefully if
# Claude.app isn't installed.
sender_args=()
if [ -d "/Applications/Claude.app" ]; then
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
