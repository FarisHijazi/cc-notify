#!/usr/bin/env bash
# cc-remote-emit.sh — the ENTIRE remote half of cc-notify.
#
# Installed on a remote box by bin/cc-install-remote. It does exactly one thing:
# append a single JSON line describing the event to ~/.claude/cc-events.jsonl.
# A Mac running bin/cc-remote-bridge streams that file over ssh and turns each
# line into a normal banner + hub-pane status, so a remote session behaves like
# a local one. Nothing is decided here: the remote reports FACTS (what only it
# can know — its transcript's color/title/outcome token, its tmux coordinates),
# the Mac owns all presentation and routing policy (cc-lib.sh:cc_present).
#
# Usage (hook): cc-remote-emit.sh <kind>
#   kind ∈ start | prompt | menu | tool | compact | notification | stop | end
#
# No node/jq/python dependency: the hook payload's flat string fields are read
# with sed, and the transcript with grep (cc-lib.sh). Always exits 0, silently.
LC_ALL=C
set -u

[ -f "$HOME/.claude/notify.disable_remote_emit" ] && exit 0

kind="${1:-stop}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/cc-lib.sh" 2>/dev/null || exit 0

events="$HOME/.claude/cc-events.jsonl"
mkdir -p "$HOME/.claude" 2>/dev/null || exit 0

input=$(cat 2>/dev/null)

# Flat top-level string field out of the hook JSON. Greedy .* takes the LAST
# occurrence, which is what we want for repeated keys.
_f() { printf '%s' "$input" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1; }
# Make a value safe to embed in the JSON we emit. Anything malformed makes the
# Mac drop the line, so be strict: no control chars, escape \ and ".
_esc() { printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

sid=$(_f session_id)
[ -n "$sid" ] || exit 0
cwd=$(_f cwd); [ -n "$cwd" ] || cwd="$PWD"
transcript=$(_f transcript_path)
ntype=$(_f notification_type)
msg=$(_f message | cut -c1-200)

# Colour + title from the transcript (grep-only), and — on stop — the trailing
# outcome token from Claude's last message.
cc_session_meta "$transcript" "$(basename "$cwd")"
token=""
[ "$kind" = "stop" ] && token=$(cc_last_status_token "$transcript")

# tmux coordinates: the routing key the Mac uses to find the local pane that is
# displaying this session (tmux-watch's @tw-src = "<host>\t<session>").
target=""
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
  && target=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P' 2>/dev/null)

branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)

# Sub-second, monotonic-per-host timestamp: it is BOTH the reconnect replay
# filter and the bridge's duplicate guard, so whole seconds would drop a second
# event landing in the same second.
ts="${EPOCHREALTIME:-$(date +%s)}"

printf '{"ts":%s,"host":"%s","sid":"%s","event":"%s","token":"%s","color":"%s","title":"%s","cwd":"%s","base":"%s","branch":"%s","tmux":"%s","ntype":"%s","msg":"%s"}\n' \
  "$ts" "$(_esc "$(uname -n)")" "$(_esc "$sid")" "$(_esc "$kind")" \
  "$(_esc "$token")" "$(_esc "$CC_COLOR_EMOJI")" "$(_esc "$CC_TITLE")" \
  "$(_esc "$cwd")" "$(_esc "$(basename "$cwd")")" "$(_esc "$branch")" \
  "$(_esc "$target")" "$(_esc "$ntype")" "$(_esc "$msg")" \
  >>"$events" 2>/dev/null

# Rotate by RENAME, never by truncation: `tail -F` follows the path, so it picks
# up the fresh empty file and reads nothing — whereas an in-place truncate makes
# it re-read from offset 0 and replay every line as a new event.
lines=$(wc -l <"$events" 2>/dev/null || echo 0)
[ "${lines:-0}" -gt 2000 ] && mv -f "$events" "$events.1" 2>/dev/null

exit 0
