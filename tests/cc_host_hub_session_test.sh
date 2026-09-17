#!/opt/homebrew/bin/bash
# cc_host_hub_session_test.sh — the host-level hub tier, without a tmux server.
#
# The awk below is EXTRACTED from hooks/cc-lib.sh by the check at the bottom, so
# it cannot drift from the function it claims to test. What it feeds in is the
# exact shape `tmux list-panes -a -F '#{session_attached}|#{session_name}|#{@tw-src}'`
# produces, tab inside the third field included — which is the part that has
# broken twice (see LESSONS #37).
#
# Two bugs came out of writing it: `exit` still runs END, so an attached hub
# printed the detached fallback as a second line; and key() strips `user@` and
# `:path` but never maps a renamed box (dema-dev -> dema), which is tier 3 of
# cc_hub_pane's job, not this one's.
awk_prog='
        function key(x) { sub(/^[^@]*@/, "", x); sub(/:.*$/, "", x); x = tolower(x); sub(/\.local$/, "", x); return x }
        {
          n = split($3, tw, "\t")              # @tw-src = "<host>\t<session>"
          if (n < 2 || tw[1] == "") next        # empty host = a LOCAL session
          if (key(tw[1]) != key(h)) next
          # Clear the fallback before exiting: `exit` still runs END, which
          # would then print the detached hub as a second line.
          if ($1 + 0 > 0) { print $2; detached = ""; exit }
          if (detached == "") detached = $2
        }
        END { if (detached != "") print detached }'

run() { printf '%s\n' "$2" | awk -F'|' -v h="$1" "$awk_prog"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf 'ok    %-46s -> %s\n' "$1" "${3:-<none>}"
  else printf 'FAIL  %-46s -> got [%s] want [%s]\n' "$1" "$3" "$2"; fails=1; fi
}
T=$(printf '\t')
attached_hub="1|hub/ftower-faris__5cffc3|ftower${T}servarr-1"
detached_hub="0|hub/old-ftower__dead01|ftower${T}servarr-1"
local_tile="1|hub/farishijazi__3e7719|${T}farishijazi-1"
alias_hub="1|hub/ftower-hub__aa01|faris@ftower:~${T}servarr-1"

check "exact host, attached hub"        "hub/ftower-faris__5cffc3" "$(run ftower "$local_tile
$attached_hub")"
check "attached beats detached"         "hub/ftower-faris__5cffc3" "$(run ftower "$detached_hub
$attached_hub")"
check "detached is the fallback"        "hub/old-ftower__dead01"   "$(run ftower "$detached_hub")"
check "case + .local normalised"        "hub/ftower-faris__5cffc3" "$(run FTOWER.local "$attached_hub")"
check "user@host:path normalised"       "hub/ftower-hub__aa01"     "$(run ftower "$alias_hub")"
check "local tiles (empty host) skipped" ""                        "$(run ftower "$local_tile")"
check "unknown host"                    ""                         "$(run nosuchbox "$attached_hub")"
check "empty input"                     ""                         "$(run ftower "")"
# The awk above must still be the library's. Fail loudly if cc-lib.sh moved on.
lib="$(cd "$(dirname "$0")/.." && pwd)/hooks/cc-lib.sh"
python3 - "$lib" "$0" <<'PYEOF' || exit 1
import re, sys
lib, test = (open(p).read() for p in sys.argv[1:3])
fn = re.search(r"cc_host_hub_session\(\).*?\n}\n", lib, re.S)
if not fn:
    sys.exit("cc_host_hub_session is gone from cc-lib.sh")
want = re.search(r"awk -F'\|' -v h=\"\$host\" '(.*?)'\n}", fn.group(0), re.S).group(1)
have = re.search(r"awk_prog='(.*?)'\n\n", test, re.S).group(1)
if want.strip() != have.strip():
    sys.exit("awk in this test has drifted from cc-lib.sh — re-copy it")
print("ok    awk matches hooks/cc-lib.sh")
PYEOF

exit "${fails:-0}"
