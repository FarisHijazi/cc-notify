#!/usr/bin/env bash
# Backgrounded worker spawned by cc-notify.sh.
# Args: $1=session_id $2=title $3=subtitle $4=body $5=sound
# Runs alerter blocking, invokes cc-focus.sh on click.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
alerter_bin="$(command -v alerter 2>/dev/null || echo /opt/homebrew/bin/alerter)"
result=$("$alerter_bin" \
  --title    "$2" \
  --subtitle "$3" \
  --message  "$4" \
  --sound    "$5" \
  --group    "cc-$1" \
  --timeout  30 \
  --ignore-dnd 2>/dev/null)

case "$result" in
  *CONTENTCLICKED*|*contentClicked*|*ACTIONCLICKED*|*actionClicked*)
    bash "$script_dir/cc-focus.sh" "$1" >>"$HOME/.claude/cc-notify.log" 2>&1
    ;;
esac
