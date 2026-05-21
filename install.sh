#!/usr/bin/env bash
# cc-notify installer.
# Installs alerter, symlinks the hook scripts into ~/.claude/hooks/,
# and merges Notification + Stop hook entries into ~/.claude/settings.json.
# Idempotent — safe to re-run.

set -e

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="$HOME/.claude"
hooks_dir="$claude_dir/hooks"
settings_file="$claude_dir/settings.json"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

# --- 1. alerter ---------------------------------------------------------------
if command -v alerter >/dev/null 2>&1; then
  ok "alerter already installed at $(command -v alerter)"
else
  say "Installing alerter via brew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: brew is required. Install from https://brew.sh first." >&2
    exit 1
  fi
  brew install vjeantet/tap/alerter
  ok "alerter installed"
fi

# --- 2. ~/.claude/hooks symlinks ---------------------------------------------
mkdir -p "$hooks_dir"
for f in cc-notify.sh cc-notify-bg.sh cc-focus.sh; do
  src="$repo_dir/hooks/$f"
  dst="$hooks_dir/$f"
  if [ ! -f "$src" ]; then
    echo "ERROR: missing $src" >&2
    exit 1
  fi
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    ok "symlink already correct: $dst"
  else
    [ -e "$dst" ] && mv "$dst" "$dst.bak.$(date +%s)" && warn "backed up existing $dst"
    ln -s "$src" "$dst"
    ok "linked $dst -> $src"
  fi
done

# --- 3. settings.json merge ---------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node is required to patch settings.json." >&2
  exit 1
fi

say "Merging hook entries into $settings_file..."
node "$repo_dir/bin/patch-settings.js" "$settings_file"
ok "settings.json updated"

# --- 4. Stop kill-switch sentinel (default: disabled) -------------------------
sentinel="$claude_dir/notify.disable_stop"
if [ -f "$sentinel" ]; then
  ok "kill-switch already exists at $sentinel — Stop notifications disabled"
else
  touch "$sentinel"
  ok "created kill-switch $sentinel — Stop notifications start disabled"
fi

# --- 5. Routing state dir -----------------------------------------------------
mkdir -p /tmp/cc-notify
ok "ready"

cat <<'EOF'

cc-notify installed.

  Notification events  → banner always fires.
  Stop events          → currently DISABLED (kill-switch sentinel present).

To enable Stop notifications:
  rm ~/.claude/notify.disable_stop

To disable again:
  touch ~/.claude/notify.disable_stop

First click of a notification will trigger macOS Automation permission prompts
("Terminal would like to control Terminal", "System Events"). Allow them once.

See README.md for the click-routing details, the SSH branch, and known limits.
EOF
