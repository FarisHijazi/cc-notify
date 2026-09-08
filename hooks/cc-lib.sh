#!/usr/bin/env bash
# Shared helpers for cc-notify hooks. SOURCED, not executed.
# Single source of truth for session color/title, status emojis, the tab-name
# format, and firing the terminal-rename URI.

# Claude /color (agentColor) → identity color emoji.
cc_color_emoji() {
  case "$1" in
    red) printf '🔴' ;; orange) printf '🟠' ;; yellow) printf '🟡' ;;
    green) printf '🟢' ;; blue) printf '🔵' ;; purple) printf '🟣' ;;
    pink) printf '🩷' ;; cyan) printf '🩵' ;; *) printf '' ;;
  esac
}

# Session state → status emoji. (Colored circles are reserved for /color identity,
# never status — keep the two vocabularies distinct.)
cc_status_emoji() {
  case "$1" in
    startup)     printf '⏸️' ;;   # SessionStart — fresh session, no turn yet
    running)     printf '⏳' ;;   # UserPromptSubmit / tool use — Claude is working
    compacting)  printf '🗜️' ;;   # PreCompact — compacting context
    permission)  printf '🔐' ;;   # Notification — needs permission to run a tool
    question)    printf '❓' ;;   # Notification — asking you / waiting for input
    options)     printf '🔀' ;;   # PreToolUse AskUserQuestion — multiple-choice menu open
    needs_input) printf '🔔' ;;   # Notification — generic "needs you" fallback
    idle|done)   printf 'ℹ️' ;;   # Stop fallback — turn complete, no outcome token present
    polling)     printf '🥱' ;;   # loop/poll/schedule tick, nothing new — NO banner (see cc-notify.sh)
    # Outcome tokens (Claude's trailing emoji), ordered clearest → weakest:
    disaster)    printf '🚨' ;;   # accident/disaster — emergency
    complete)    printf '💯✅' ;; # 💯 token — ALL tasks done, nothing left (shown as 💯✅)
    success)     printf '✅' ;;   # task completed
    failure)     printf '❌' ;;   # task failed
    blocked)     printf '🚫' ;;   # blocked — can't proceed without you
    waiting)     printf '🙋' ;;   # waiting for your instructions / a decision
    work)        printf '🏃' ;;   # work to be done — next steps await
    good)        printf '👍' ;;   # good news (no task)
    bad)         printf '👎' ;;   # bad news (no task)
    info)        printf 'ℹ️' ;;   # just info — weakest signal
    *)           printf '' ;;
  esac
}

# Outcome token: Claude is instructed (global CLAUDE.md) to end every message with
# a trailing ✅/❌/⭕. Read the LAST text-bearing assistant message from the
# transcript and echo that trailing emoji (or nothing). Used to show real
# success/failure on Stop instead of the generic "your turn".
cc_last_status_token() {
  local tp="$1"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  # No node (remote boxes installed via the native installer): fall back to a grep.
  # The token is the last message's trailing emoji, so in the JSONL it sits right
  # before the closing quote of a "text" block — take the last such hit in the last
  # few assistant lines. Only reached when node is ABSENT, so local behaviour
  # (the exact parse below) is unchanged.
  if ! command -v node >/dev/null 2>&1; then
    grep '"type":"assistant"' "$tp" 2>/dev/null | tail -3 \
      | grep -oE '(🚨|💯|✅|❌|🚫|🙋|👍|👎|🏃|🥱|ℹ️|💬)"' | tail -1 | tr -d '"'
    return 0
  fi
  node -e '
const fs=require("fs");
let lines; try{ lines=fs.readFileSync(process.argv[1],"utf8").split("\n"); }catch(e){ process.exit(0); }
for(let i=lines.length-1;i>=0;i--){
  const l=lines[i]; if(!l) continue;
  let j; try{ j=JSON.parse(l); }catch(e){ continue; }
  if(j.type!=="assistant" || !j.message || !Array.isArray(j.message.content)) continue;
  const text=j.message.content.filter(b=>b&&b.type==="text").map(b=>b.text).join("");
  if(!text.trim()) continue;                 // skip tool-only turns
  const t=text.replace(/\s+$/,"");
  // endsWith (not last code point) so multi-codepoint emojis like ℹ️ match.
  for(const e of ["🚨","💯","✅","❌","🚫","🙋","👍","👎","🏃","🥱","ℹ️","💬"]){ if(t.endsWith(e)){ process.stdout.write(e); break; } }
  process.exit(0);                           // only the final message matters
}
' "$tp" 2>/dev/null
}

# Read agentColor + session title from a transcript JSONL in one pass.
# Title cascade: /rename customTitle → auto aiTitle → fallback (project).
# Sets globals: CC_COLOR_EMOJI, CC_COLOR_NAME, CC_TITLE.
cc_session_meta() {
  local tp="$1" fallback="$2" meta ac ct at
  CC_COLOR_EMOJI=""
  CC_COLOR_NAME=""
  CC_TITLE="$fallback"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  meta=$(grep -oE '"(customTitle|aiTitle)":"[^"]*"' "$tp" 2>/dev/null)
  # Color is ANCHORED to the real record shape (a line saveAgentColor appended),
  # not any inline "agentColor":"…" text — a transcript that merely QUOTES such a
  # string (e.g. a session developing cc-notify itself) must not repaint, and
  # since v1.7.17 the color is also persisted+applied (actuation), so a false
  # positive would leak into <cwd>/.cc/settings.json and recolor future sessions.
  ac=$(grep -o '^{"type":"agent-color","agentColor":"[^"]*"' "$tp" 2>/dev/null | tail -1 | sed 's/.*:"//;s/"$//')
  ct=$(printf '%s\n' "$meta" | grep '"customTitle"' | tail -1 | sed 's/.*:"//;s/"$//')
  at=$(printf '%s\n' "$meta" | grep '"aiTitle"'     | tail -1 | sed 's/.*:"//;s/"$//')
  CC_COLOR_EMOJI=$(cc_color_emoji "$ac")
  CC_COLOR_NAME="$ac"
  if   [ -n "$ct" ]; then CC_TITLE="$ct"
  elif [ -n "$at" ]; then CC_TITLE="$at"
  fi
}

# Claude Code's own /color vocabulary. Anything we persist to disk or (worse)
# type back into a TUI input box MUST pass this — never free text.
cc_color_valid() {
  case "$1" in red|orange|yellow|green|blue|purple|pink|cyan|default) return 0 ;; *) return 1 ;; esac
}

# Persist the session's color to <cwd>/.cc/settings.json (key "color") so future
# sessions in this project adopt it on SessionStart (see cc-color-apply.sh).
# Merge-write: other keys survive, no write when unchanged. With several live
# sessions in one cwd the last active one wins — that's the intended semantics
# ("the project's color is whatever I last set here").
cc_color_persist() {
  local cwd="$1" color="$2"
  [ -n "$cwd" ] && [ -d "$cwd" ] && cc_color_valid "$color" || return 0
  command -v node >/dev/null 2>&1 || return 0
  mkdir -p "$cwd/.cc" 2>/dev/null || return 0
  CC_COLOR="$color" node -e '
const fs=require("fs"), f=process.argv[1]+"/.cc/settings.json";
let d={}; try{ d=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){}
if(typeof d!=="object"||d===null||Array.isArray(d)) d={};
if(d.color===process.env.CC_COLOR) process.exit(0);
d.color=process.env.CC_COLOR;
try{ fs.writeFileSync(f, JSON.stringify(d,null,2)+"\n"); }catch(e){}
' "$cwd" 2>/dev/null
}

# The configured color from <cwd>/.cc/settings.json → stdout ("" if none/invalid).
cc_color_settings() {
  local cwd="$1" c
  [ -n "$cwd" ] && [ -f "$cwd/.cc/settings.json" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  c=$(node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(typeof d.color==="string")process.stdout.write(d.color)}catch(e){}' "$cwd/.cc/settings.json" 2>/dev/null)
  cc_color_valid "$c" && printf '%s' "$c"
}

# Walk a tty's process tree up to a GUI terminal/editor; on a hit sets CC_TERM
# (when it was still "tmux"), CC_GUI_PID and CC_CLIENT_TTY, and returns 0.
# Top-level because BOTH cc_detect_terminal (walks from the caller) and
# cc_pane_route (walks from an arbitrary tmux pane's client) need it.
cc_walk_tty() {  # walk a tty's process tree up to a GUI terminal; set CC_* on hit
  local cand="$1" pid hops cmd
  pid=$(ps -t "${cand#/dev/}" -o pid= 2>/dev/null | head -1 | tr -d ' '); hops=0
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$cmd" in
      */Terminal|Terminal)              [ "$CC_TERM" = tmux ] && CC_TERM=Apple_Terminal; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
      */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$CC_TERM" = tmux ] && CC_TERM=iTerm.app;      CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
      */Ghostty|Ghostty|*/ghostty|ghostty) [ "$CC_TERM" = tmux ] && CC_TERM=ghostty;     CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
      */Cursor|Cursor)                  [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Cursor; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
      */Code\ Helper*|*/Electron|*/Code|Code) [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Code; CC_GUI_PID="$pid"; CC_CLIENT_TTY="$cand"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '); hops=$((hops + 1))
  done
  return 1
}

# Detect the GUI terminal/editor hosting this hook + collect candidate shell pids
# for the editor extension to match. Walks from the CALLER's process, so any hook
# can name the tab WITHOUT a route file — which is what makes `claude --resume`
# (a new terminal, no prior route) name its tab. Sets:
#   CC_TERM       vscode | Apple_Terminal | iTerm.app | ghostty | <TERM_PROGRAM>
#   CC_EDITOR_APP Cursor | Code | ""        CC_GUI_PID   GUI process pid (best effort)
#   CC_CLIENT_TTY tmux client tty (if tmux) CC_TMUX_TARGET session:window.pane
#   CC_SHELL_PIDS csv: caller's ancestor chain + every pid on CC_CLIENT_TTY
cc_detect_terminal() {
  CC_TERM="${TERM_PROGRAM:-unknown}"; CC_EDITOR_APP=""; CC_GUI_PID=""
  CC_CLIENT_TTY=""; CC_TMUX_TARGET=""
  if [ -n "$TMUX" ] && [ -n "$TMUX_PANE" ]; then
    CC_TMUX_TARGET=$(tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P' 2>/dev/null)
    CC_CLIENT_TTY=$(tmux display-message -t "$TMUX_PANE" -p '#{client_tty}' 2>/dev/null)
  fi


  # ancestor PID chain of the caller (one of these == the editor's shell pid)
  CC_SHELL_PIDS=""; local _p=$$ _h=0
  while [ -n "$_p" ] && [ "$_p" != "1" ] && [ "$_h" -lt 30 ]; do
    CC_SHELL_PIDS="${CC_SHELL_PIDS:+$CC_SHELL_PIDS,}$_p"
    _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' '); _h=$((_h + 1))
  done

  # primary: PPID walk (non-tmux). Under tmux this hits the launchd-parented
  # server and finds nothing → the tty walks below recover it.
  local _mp=$$ _mh=0 _cmd
  while [ -n "$_mp" ] && [ "$_mp" != "1" ] && [ "$_mh" -lt 30 ]; do
    _cmd=$(ps -o comm= -p "$_mp" 2>/dev/null)
    case "$_cmd" in
      */Terminal|Terminal)              [ "$CC_TERM" = tmux ] && CC_TERM=Apple_Terminal; CC_GUI_PID="$_mp"; break ;;
      */iTerm2|iTerm2|*/iTerm|iTerm)    [ "$CC_TERM" = tmux ] && CC_TERM=iTerm.app;      CC_GUI_PID="$_mp"; break ;;
      */Ghostty|Ghostty|*/ghostty|ghostty) [ "$CC_TERM" = tmux ] && CC_TERM=ghostty;     CC_GUI_PID="$_mp"; break ;;
      */Cursor|Cursor)                  [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Cursor; CC_GUI_PID="$_mp"; break ;;
      */Code\ Helper*|*/Electron|*/Code|Code) [ "$CC_TERM" = tmux ] && CC_TERM=vscode; CC_EDITOR_APP=Code; CC_GUI_PID="$_mp"; break ;;
    esac
    _mp=$(ps -o ppid= -p "$_mp" 2>/dev/null | tr -d ' '); _mh=$((_mh + 1))
  done

  [ -z "$CC_GUI_PID" ] && [ -n "$CC_CLIENT_TTY" ] && cc_walk_tty "$CC_CLIENT_TTY"
  if [ -z "$CC_GUI_PID" ] && [ -n "$TMUX" ]; then
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      cc_walk_tty "$cand" && break
    done < <(tmux list-clients -F '#{client_focused}|#{client_activity}|#{client_tty}' 2>/dev/null | sort -t'|' -k1,1nr -k2,2nr | cut -d'|' -f3)
  fi

  # tmux-inside-editor: the editor's shell is the tmux client's shell (a sibling,
  # not an ancestor) — it lives on the client tty, so add every pid there.
  if [ -n "$CC_CLIENT_TTY" ]; then
    local _tp
    for _tp in $(ps -t "${CC_CLIENT_TTY#/dev/}" -o pid= 2>/dev/null); do
      CC_SHELL_PIDS="${CC_SHELL_PIDS:+$CC_SHELL_PIDS,}$_tp"
    done
  fi
}

# Join non-empty parts with single spaces → "<status> <color> <title>".
cc_tab_name() {
  local out="" p
  for p in "$@"; do
    [ -n "$p" ] && out="${out:+$out }$p"
  done
  printf '%s' "$out"
}

# Cheaply swap just the leading status emoji on an existing <sid>.tab, WITHOUT
# re-reading the (possibly huge) transcript. Used by high-frequency hooks
# (PreToolUse/PostToolUse/etc.) so they stay fast — they only re-assert the state,
# not recompute color/title. Empty emoji clears the status. No-op if the .tab
# doesn't exist yet (a full update will create it). Args: sid status_emoji
cc_set_status() {
  local sid="$1" emoji="$2" f="/tmp/cc-notify/$1.tab"
  [ -f "$f" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  CC_NEW="$emoji" node -e '
const fs=require("fs"), f=process.argv[1];
let d; try{ d=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ process.exit(0); }
// Strip a RUN of leading status emojis (the two-glyph 💯✅ needs the run) plus
// spaces. Color circles are not in the set, so the run stops at the color/name.
const rest=(d.name||"").replace(/^(?:(?:⏸️|⏳|🔐|❓|🔀|🔔|👀|💯|🚨|✅|❌|🚫|🙋|🏃|👍|👎|🥱|ℹ️|💬|🗜️)\s*)+/u,"");
const ne=process.env.CC_NEW||"";
const name=ne?ne+" "+rest:rest;
if(name===d.name) process.exit(0);
try{ fs.writeFileSync(f, JSON.stringify({pids:d.pids,name:name})); }catch(e){}
' "$f" 2>/dev/null
}

# Write the desired tab name + pids to a state file the editor extension watches
# (/tmp/cc-notify/<sid>.tab). File-based on PURPOSE: `open <url>` activates the
# editor and yanks Aerospace focus across workspaces even with `-g`, so we must
# NOT use it for proactive (non-click) updates. The extension renames via
# renameWithArg (no `open`, no `show()` → never raises the window). Tab whichever
# editors have the terminal; harmless if none do. Args: sid pids(csv) name
cc_write_tab() {
  local sid="$1" pids="$2" name="$3"
  [ -n "$sid" ] && [ -n "$pids" ] && [ -n "$name" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  CC_TAB_PIDS="$pids" CC_TAB_NAME="$name" node -e '
const fs=require("fs");
const pids=(process.env.CC_TAB_PIDS||"").split(",").map(Number).filter(Boolean);
try{fs.writeFileSync("/tmp/cc-notify/"+process.argv[1]+".tab",
  JSON.stringify({pids:pids,name:process.env.CC_TAB_NAME}));}catch(e){}
' "$sid" 2>/dev/null
}

# Fire a tab-repaint sweep so BACKGROUND windows' tabs catch up to a status change
# (a backgrounded session's .tab updates, but its tab only re-renders when its
# terminal becomes active — a sweep cycles them so each repaints). Safe to call on
# any status change: cc-sweep self-throttles to 1/10s, skips while the user is
# typing, and queues if blocked (see bin/cc-sweep). Backgrounded so the hook returns
# fast. cc-lib.sh lives in hooks/, so cc-sweep is ../bin/cc-sweep.
cc_trigger_sweep() {
  [ -f "$HOME/.claude/notify.disable_sweep" ] && return 0   # kill-switch
  local sweep
  sweep="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)/cc-sweep"
  [ -x "$sweep" ] && ( "$sweep" </dev/null >/dev/null 2>&1 & )
}

# ---------------------------------------------------------------------------
# Presentation: facts → what the banner and the tab say.
# ---------------------------------------------------------------------------

# The SINGLE source of truth for the banner/tab vocabulary. Called by the local
# hook (cc-notify.sh) and by the remote bridge (bin/cc-remote-bridge), so a
# session on another machine presents identically to a local one.
# Args: event_kind notif_type message token color_emoji session_title cwd_base branch
# Sets: CC_STATUS CC_SUBTITLE CC_BODY CC_SOUND CC_BANNER_TITLE CC_TAB_ONLY
cc_present() {
  local kind="$1" ntype="$2" msg="$3" token="$4" color="$5" title="$6" base="$7" branch="$8"
  CC_TAB_ONLY=""
  if [ "$kind" = "notification" ]; then
    CC_SOUND="Glass"
    # Distinguish permission requests (🔐) from questions / idle input (❓), via
    # notification_type with a message-text fallback. Unknown types → 🔔.
    # The idle one (CC's ~60s "waiting for your input") is LOW-signal and noisy →
    # tab status only, NO banner. Permission + generic still banner.
    case "$ntype $msg" in
      *permission*|*Permission*)           CC_STATUS=$(cc_status_emoji permission);  CC_SUBTITLE="Needs permission" ;;
      *idle*|*waiting*|*input*|*question*) CC_STATUS=$(cc_status_emoji question);    CC_SUBTITLE="Awaiting your input"; CC_TAB_ONLY=1 ;;
      *)                                   CC_STATUS=$(cc_status_emoji needs_input); CC_SUBTITLE="Needs your attention" ;;
    esac
    CC_BODY="${msg:-Claude needs you}"
  else
    CC_STATUS="$token"
    [ -z "$CC_STATUS" ] && CC_STATUS=$(cc_status_emoji idle)
    CC_SOUND="Hero"
    case "$CC_STATUS" in
      🚨) CC_SUBTITLE="⚠️ Accident / disaster" ;;
      💯) CC_SUBTITLE="All tasks complete"; CC_STATUS=$(cc_status_emoji complete) ;;  # 💯 → display 💯✅
      ✅) CC_SUBTITLE="Task complete" ;;
      ❌) CC_SUBTITLE="Task failed" ;;
      🚫) CC_SUBTITLE="Blocked" ;;
      🙋) CC_SUBTITLE="Waiting for instructions" ;;
      👍) CC_SUBTITLE="Good news" ;;
      👎) CC_SUBTITLE="Bad news" ;;
      🏃) CC_SUBTITLE="Work to be done" ;;
      🥱) CC_SUBTITLE="Still waiting — nothing new"; CC_TAB_ONLY=1 ;;  # loop/poll tick → tab only
      ℹ️) CC_SUBTITLE="FYI" ;;
      *)  CC_SUBTITLE="Turn complete" ;;
    esac
    CC_BODY="$base"
    [ -n "$branch" ] && CC_BODY="$base · $branch"
  fi
  CC_BANNER_TITLE=$(cc_tab_name "$CC_STATUS" "$color" "${title:-$base}")
}

# ---------------------------------------------------------------------------
# tmux-watch hub panes: the one place a session (local OR remote) is visible
# on this Mac. Pane identity is tmux-watch's @tw-src = "<host>\t<session>"
# (host empty for local) — a stable key that survives pane renumbering and
# inner programs rewriting the title.
# ---------------------------------------------------------------------------

# Local pane id displaying <host>:<tmux session> → stdout ("" if not shown here).
# host="" means a LOCAL tmux session (tmux-watch stores an empty host field).
cc_hub_pane() {
  local host="$1" sess="$2" panes out
  [ -n "$sess" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  panes=$(tmux list-panes -a -F '#{pane_id}	#{@tw-src}' 2>/dev/null) || return 0

  # 1. exact — the host string the bridge stamped IS how the hub was built.
  out=$(printf '%s\n' "$panes" | awk -F'\t' -v h="$host" -v s="$sess" '$2==h && $3==s {print $1; exit}')
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }

  # 2. the same box under a different alias. `tw-remote` builds hubs from
  #    `faris@dema-dev:~` while the bridge streams `dema`; without this the click
  #    finds nothing and materializes a SECOND window onto a session that is
  #    already on screen. Strip user@, any :port/:path, case, a .local suffix.
  out=$(printf '%s\n' "$panes" | awk -F'\t' -v h="$host" -v s="$sess" '
    function key(x) { sub(/^[^@]*@/, "", x); sub(/:.*$/, "", x); x = tolower(x); sub(/\.local$/, "", x); return x }
    $3 == s && key($2) == key(h) { print $1; exit }')
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }

  # 3. the session NAME alone, but only when exactly one REMOTE watch pane
  #    carries it (an empty host is a LOCAL session, which this is not). Session
  #    names are far more distinctive than host aliases, so this catches every
  #    remaining way of spelling the same box — and stays silent the moment two
  #    machines genuinely run a session of the same name.
  printf '%s\n' "$panes" | awk -F'\t' -v s="$sess" '$2 != "" && $3 == s { n++; p = $1 } END { if (n == 1) print p }'
}

# Focus a terminal window that is ALREADY showing tmux session $1, on any host.
# Ghostty names each tab after the tmux title, which .tmux.conf pins to
# "<session> · <host>" — so the session name plus that separator identifies it.
# Used before materializing a new window: a previous click (or the user) may
# already have one open, and stacking another on top of it is the one thing a
# click should never do. Returns 0 only when something was really focused.
# Find the tmux-watch hub ON THE REMOTE BOX that is displaying <host>:<sess>.
#
# There are two watch topologies and cc_hub_pane only sees one of them. When the
# hub runs on this Mac, its panes are local and carry @tw-src — cc_hub_pane
# resolves them. When you instead `ssh <host>` and run `tw` THERE, the hub is a
# tmux session on that box, attached from a Ghostty window: nothing local
# carries @tw-src, so every click used to conclude "nothing here is showing it"
# and materialize a SECOND window onto a session already on screen.
#
# One ssh, cheap, only on the fallback path (the click is about to ssh anyway).
# Prints "<hub_session>\t<pane_id>"; empty when the box shows no hub for it.
# Attached hubs win: an unattached one is not on anybody's screen.
cc_remote_hub_pane() {
  local host="$1" sess="$2"
  [ -n "$host" ] && [ -n "$sess" ] || return 0
  case "$sess" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
      "tmux list-panes -a -F '#{session_attached}|#{session_name}|#{pane_id}|#{@tw-src}' 2>/dev/null" 2>/dev/null \
    | awk -F'|' -v s="$sess" '
        {
          n = split($4, tw, "\t")            # @tw-src = "<host>\t<session>"
          if (n < 2 || tw[2] != s) next
          if ($1 + 0 > 0) { print $2 "\t" $3; hit = 1; exit }   # attached — take it
          if (best == "") best = $2 "\t" $3
        }
        END { if (!hit && best != "") print best }   # awk runs END after exit'
}

cc_focus_named_terminal() {
  local sess="$1" name="" wid=""
  [ -n "$sess" ] || return 1
  [ -d /Applications/Ghostty.app ] || return 1
  # '/' is allowed: tmux-watch hub sessions are named "hub/<user>__<hash>", and
  # a REMOTE hub's window is the only thing showing its watched sessions.
  case "$sess" in ""|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  name=$(osascript 2>/dev/null <<OSA
tell application "Ghostty"
  repeat with w in windows
    repeat with t in tabs of w
      -- Read the name BEFORE focusing: `t` is an index-based reference and
      -- `focus` reorders Ghostty's window list, so a `name of t` afterwards
      -- resolves to a DIFFERENT tab (it returned the wrong window every time).
      set n to name of t
      if n starts with "$sess · " then
        focus (focused terminal of t)
        return n
      end if
    end repeat
  end repeat
  return ""
end tell
OSA
)
  [ -n "$name" ] || return 1
  # AppleScript focused the tab; only aerospace can bring its workspace along.
  if command -v aerospace >/dev/null 2>&1; then
    wid=$(aerospace list-windows --monitor all --format '%{window-id}|%{window-title}' 2>/dev/null \
      | awk -F'|' -v n="$name" '{ id=$1; sub(/^[^|]*\|/,""); if ($0==n) { print id; exit } }')
    [ -n "$wid" ] && aerospace focus --window-id "$wid" >/dev/null 2>&1
  fi
  return 0
}

# Show a session's live status on its hub pane's border, so the hub doubles as a
# dashboard of every session. Written to a pane user-option (NOT the pane title):
# the pane runs `tmux attach`/`ssh`, and an inner program can rewrite the title at
# any moment — it cannot touch @cc-status. Idempotent; safe to call on every event.
cc_pane_status() {
  local pane="$1" name="$2"
  [ -n "$pane" ] && [ -n "$name" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  [ "$(tmux show -p -t "$pane" -v @cc-status 2>/dev/null)" = "$name" ] && return 0
  tmux set -p -t "$pane" @cc-status "$name" 2>/dev/null
  tmux set -w -t "$pane" pane-border-format '#{?@cc-status,#{@cc-status},#{pane_title}}' 2>/dev/null
  tmux set -w -t "$pane" pane-border-status top 2>/dev/null
}

# Route fields for a session that is displayed in the local tmux pane $1 — i.e.
# "which GUI window + tmux coordinates do I focus to look at that pane". This is
# cc_detect_terminal's job done from a PANE instead of from the calling process,
# which is what lets a click on a remote session's banner land exactly where a
# local one does. Sets the same CC_* globals cc-focus.sh consumes.
cc_pane_route() {
  local pane="$1" sess
  CC_TERM="tmux"; CC_EDITOR_APP=""; CC_GUI_PID=""; CC_CLIENT_TTY=""
  CC_TMUX_TARGET=""; CC_SHELL_PIDS=""
  [ -n "$pane" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  CC_TMUX_TARGET=$(tmux display-message -p -t "$pane" '#S:#I.#P' 2>/dev/null) || return 1
  [ -n "$CC_TMUX_TARGET" ] || return 1
  sess="${CC_TMUX_TARGET%%:*}"
  # Clients attached to that pane's session, most useful first (focused, then
  # most recently active) — the same ordering cc_detect_terminal uses.
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    cc_walk_tty "$cand" && break
  done < <(tmux list-clients -F '#{client_focused}|#{client_activity}|#{client_session}|#{client_tty}' 2>/dev/null \
             | awk -F'|' -v s="$sess" '$3==s' | sort -t'|' -k1,1nr -k2,2nr | cut -d'|' -f4)
  # The editor extension matches its integrated terminal by shell pid — every pid
  # on the client tty (the tmux client's shell is a sibling, not an ancestor).
  if [ -n "$CC_CLIENT_TTY" ]; then
    local _tp
    for _tp in $(ps -t "${CC_CLIENT_TTY#/dev/}" -o pid= 2>/dev/null); do
      CC_SHELL_PIDS="${CC_SHELL_PIDS:+$CC_SHELL_PIDS,}$_tp"
    done
  fi
  [ -n "$CC_CLIENT_TTY" ]
}

# Exact Aerospace window id for a tty. Terminal.app and Ghostty run MANY windows
# under ONE pid, so the pid→first-window lookup cc-focus.sh falls back to is a coin flip
# (LESSONS #10) — locally that is covered by the window id captured at
# SessionStart, which a session on another machine has no equivalent of. Only
# AppleScript knows which window holds a tty, and only Aerospace can focus a
# window across workspaces: bridge the two on the window TITLE, which both report
# identically. Args: tty pid term. Echoes a window id, or nothing.
cc_wid_for_tty() {
  local tty="$1" pid="$2" term="$3" name="" wid=""
  command -v aerospace >/dev/null 2>&1 || return 1
  if [ "$term" = "Apple_Terminal" ] && [ -n "$tty" ]; then
    name=$(osascript -e "tell application \"Terminal\"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if tty of t is \"$tty\" then return name of w
      end try
    end repeat
  end repeat
  return \"\"
end tell" 2>/dev/null)
    [ -n "$name" ] && wid=$(aerospace list-windows --monitor all \
      --format '%{window-id}|%{window-title}' 2>/dev/null \
      | awk -F'|' -v n="$name" '{ id=$1; sub(/^[^|]*\|/,""); if ($0==n) { print id; exit } }')
  fi
  # Ghostty: many windows under one pid too, and no tty in its AppleScript
  # dictionary — but tabs/terminals have a NAME, which is the tmux title
  # (set-titles-string, "<session> · <host>" in the repo .tmux.conf). Expand
  # that format for the client on this tty, ask Ghostty to focus the terminal
  # carrying it (this also selects a background tab, so the window title
  # becomes it), then take the window id from aerospace by that title so the
  # caller can switch workspace. With no match fall through to the pid lookup.
  if [ "$term" = "ghostty" ] && [ -n "$tty" ] && [ -z "$wid" ]; then
    name=$(tmux display-message -c "$tty" -p '#{T:set-titles-string}' 2>/dev/null)
    if [ -n "$name" ]; then
      osascript >/dev/null 2>&1 <<OSA
tell application "Ghostty"
  repeat with w in windows
    repeat with t in tabs of w
      if name of t is "$name" then
        focus (focused terminal of t)
        return
      end if
    end repeat
  end repeat
end tell
OSA
      wid=$(aerospace list-windows --monitor all --format '%{window-id}|%{window-title}' 2>/dev/null \
        | awk -F'|' -v n="$name" '{ id=$1; sub(/^[^|]*\|/,""); if ($0==n) { print id; exit } }')
    fi
  fi
  # Anything else (editors, one-window apps): the pid lookup is unambiguous enough.
  [ -z "$wid" ] && [ -n "$pid" ] && wid=$(aerospace list-windows --monitor all --pid "$pid" \
    --format '%{window-id}' 2>/dev/null | head -1)
  [ -n "$wid" ] && printf '%s' "$wid"
}
