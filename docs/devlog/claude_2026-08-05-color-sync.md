# 2026-08-05 — v1.7.17: per-project color sync (`.cc/settings.json` + self-typed `/color`)

Goal: programmatically control a Claude Code session's color (`/color` →
`agentColor`). Research first; fallback design second.

## Research: is there a programmatic API? (verdict: NO, for a running session)

Checked docs + GitHub issues (subagent) AND `strings` over the actual v2.1.222
binary. Per entry point:

| Entry point | Verdict |
|---|---|
| CLI flag for a *running* session | none |
| `--agent-color <color>` launch flag | **EXISTS but hidden** (`hideHelp`, "Teammate UI color") — used internally when CC spawns teammates into tmux panes alongside `--agent-id/--agent-name/--team-name`. Accepted at launch without error, but it feeds `initialAgentColor` (in-memory) and **writes no `agent-color` transcript line**, so cc-notify can't read it and it's useless for us. Undocumented/unstable — not used. |
| Env var | none (docs env-vars page exhaustive; nothing in binary) |
| settings.json key | none — open requests [#66642](https://github.com/anthropics/claude-code/issues/66642), [#50393](https://github.com/anthropics/claude-code/issues/50393), [#41887](https://github.com/anthropics/claude-code/issues/41887), [#63264](https://github.com/anthropics/claude-code/issues/63264), [#51493](https://github.com/anthropics/claude-code/issues/51493) |
| Hook output field (SessionStart `hookSpecificOutput`) | none — open request [#49293](https://github.com/anthropics/claude-code/issues/49293) |
| Agent SDK | none (rename/tag only) |
| External transcript append | `restoreSessionMetadata` reads it on **resume only**; the live TUI keeps color in-process (`currentSessionAgentColor`) — an external append does nothing until restart, and the format is explicitly internal. Rejected. |

Two load-bearing binary findings:

1. **`/color` accepts an inline argument** — `argumentHint: [red|orange|yellow|green|blue|purple|pink|cyan|default]`,
   and a `supportsNonInteractive` variant exists. So `/color purple` typed into
   the TUI applies instantly (local command, no API turn, no Stop hook).
2. `saveAgentColor` appends `{"type":"agent-color","agentColor":…,"sessionId":…}`
   to the transcript AND sets in-process state — confirming the input box is the
   only external lever for a live session.

## Design (v1.7.17)

`<cwd>/.cc/settings.json` (key `"color"`) is the per-project color config.
Direction is strictly one-way per event so the two writers never race:

- **SessionStart → settings WIN**: `cc-capture-window.sh` reads
  `cc_color_settings "$cwd"`; if it differs from the session's transcript color,
  it spawns `hooks/cc-color-apply.sh <tmux-target> <color>` detached, which
  types `/color <name>` into the session's OWN pane via the LESSONS #20
  `cc-prompt-state` dance: wait (≤25s, covers TUI startup/trust dialog) for the
  box to be drawn AND empty → `send-keys -l` → re-read box, must equal exactly
  what we typed → `Enter`. Box has text → back off entirely; box unreadable →
  fail closed. tmux-hosted sessions only.
- **UserPromptSubmit / Stop / Notification → session WINS**: `cc_color_persist`
  (cc-lib.sh) merge-writes the transcript's color into
  `<cwd>/.cc/settings.json` (creates `.cc/`, preserves other keys, no write when
  unchanged). Last active session in a cwd wins — intended semantics.

So: `/color pink` once in a project → every future session there starts pink.

Guards: color value whitelisted (`cc_color_valid`) at persist, at read, AND
again inside cc-color-apply.sh (the value comes from a file on disk and is
typed into a live prompt — never free text). Off switch: `CC_NO_COLOR_SYNC=1`
or `~/.claude/notify.disable_color_sync`. Knob: `CC_COLOR_APPLY_TIMEOUT` (25).
Log: `/tmp/cc-notify/colorsync.log`.

**Anchored color extraction** (same commit): `cc_session_meta` now greps
`^{"type":"agent-color","agentColor":"…"` instead of any inline
`"agentColor":"…"`. Every real record is such a line (verified across 4
transcripts incl. one with 404 records — loose count == anchored count), while
a session that merely *quotes* the string (e.g. a session developing cc-notify)
previously false-positived. Cosmetic before; with persist+apply it would have
leaked quoted colors into `.cc/settings.json` and recolored future sessions.
Titles keep the loose match (display-only).

## Tested (live `claude` TUI in detached tmux sessions)

- apply: `/color purple` typed+submitted → transcript gained the anchored
  `agent-color` line; box empty after; no stray text.
- abort: with a draft pre-typed in the box → `SKIP — user is typing`, nothing
  sent, draft intact.
- full SessionStart hook (env-overridden `TMUX`/`TMUX_PANE` → test pane):
  settings blue vs session purple → applied blue. Same color → no spawn.
  NOTE: a fake `TMUX=fake,0,0` breaks target detection — the first field of
  `$TMUX` is the SOCKET PATH tmux uses; tests must pass the real socket.
- persist via UserPromptSubmit hook → settings updated, sibling keys preserved,
  mtime untouched when unchanged; injection strings rejected on write and read.
- anchored extraction: test transcript → `blue`; this dev session's transcript
  (full of quoted `agentColor` strings) → empty.

Repo `.gitignore` now ignores `.cc/`; users should gitignore it too (README).
