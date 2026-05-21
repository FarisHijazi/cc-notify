#!/usr/bin/env bash
# cc-notify uninstaller.
# Removes hook symlinks and strips entries from ~/.claude/settings.json.
# Leaves alerter installed (other things may use it).

set -e

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks_dir="$HOME/.claude/hooks"
settings_file="$HOME/.claude/settings.json"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

for f in cc-notify.sh cc-notify-bg.sh cc-focus.sh; do
  target="$hooks_dir/$f"
  if [ -L "$target" ]; then
    rm "$target" && ok "removed symlink $target"
  elif [ -f "$target" ]; then
    rm "$target" && ok "removed file $target"
  fi
done

if [ -f "$settings_file" ]; then
  say "Stripping hook entries from $settings_file..."
  node "$repo_dir/bin/unpatch-settings.js" "$settings_file"
fi

rm -f "$HOME/.claude/notify.disable_stop" && ok "removed kill-switch sentinel"
rm -rf /tmp/cc-notify && ok "cleared routing state"

cat <<'EOF'

cc-notify uninstalled.

Note: alerter is still installed (brew uninstall vjeantet/tap/alerter to remove).
The repo at this directory is untouched.
EOF
