#!/bin/bash
# cc_remote_bridge_supervise_test.sh — one streamer per host, even when /tmp is purged.
#
# Runs the REAL _supervise, extracted from bin/cc-remote-bridge, under /bin/bash
# (3.2 — what launchd runs) with stubbed hosts and `sleep 300` standing in for
# the streamer, so no ssh is dialled and the live LaunchAgent is untouched.
#
# The bug it pins (LESSONS #38): liveness used to be read from
# /tmp/cc-notify/bridge-<host>.pid, those files got purged, and every purge added
# one more streamer per host — four banners per event after four purges.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
body=$(sed -n '/^_supervise() {/,/^}/p' "$here/../bin/cc-remote-bridge")
tmp=$(mktemp -d); mkdir -p "$tmp/state"
fails=0

{
  echo "set -u; state='$tmp/state'; SCAN=1"
  echo '_log() { :; }; _off() { false; }; _slug() { printf %s "$1"; }'
  echo '_hosts() { printf "dema\nftower\n"; }'
  echo '_kill_tree() { kill "$1" 2>/dev/null; }'
  printf '%s\n' "${body//\"\$0\" \"\$host\"/sleep 300}"   # the streamer -> a sleeper
  echo '_supervise'
} >"$tmp/harness"

/bin/bash "$tmp/harness" & sup=$!
streamers() { pgrep -P "$sup" -f 'sleep 300' | wc -l | tr -d ' '; }
pidfiles()  { ls "$tmp/state" | wc -l | tr -d ' '; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf 'ok    %-42s -> %s\n' "$1" "$3"
  else printf 'FAIL  %-42s -> got [%s] want [%s]\n' "$1" "$3" "$2"; fails=1; fi
}

sleep 1.5
check "one streamer per host at start"      2 "$(streamers)"
rm -f "$tmp/state"/*.pid; sleep 2.5          # the /tmp purge, then 2+ scans
check "pidfiles purged: still one per host" 2 "$(streamers)"
check "no respawn, so no pidfile rewritten" 0 "$(pidfiles)"
kill "$(pgrep -P "$sup" -f 'sleep 300' | head -1)"; sleep 2.5
check "a dead streamer is respawned"        2 "$(streamers)"
check "and only that one"                   1 "$(pidfiles)"
case "$body" in *'cat "$pidf"'*|*'$(cat '*) check "supervisor never reads a pidfile" no yes ;;
                *) check "supervisor never reads a pidfile" no no ;; esac

for c in $(pgrep -P "$sup"); do kill "$c"; done; kill "$sup"; wait 2>/dev/null
rm -rf "$tmp"
[ "$fails" = 0 ] && echo "all passed" || { echo FAILED; exit 1; }
