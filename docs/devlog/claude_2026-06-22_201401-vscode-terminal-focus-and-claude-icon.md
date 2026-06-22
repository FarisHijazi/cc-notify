# v1.7.0 — VS Code/Cursor terminal-pane focus + Claude logo on banner

Date: 2026-06-22

## What was asked

1. Make notification click-back focus the **specific integrated terminal pane** in
   VS Code/Cursor that Claude runs in — not just the window.
2. Add the **Claude logo** and an **orange color** matching the tmux / Claude Code
   statusline accent to the banner.
3. Take inspiration from Boris Buliga's "Claude Code Notifications That Don't Suck".

## Research conclusion (terminal pane focus)

There is **no** way to focus a specific integrated terminal from outside VS
Code/Cursor — no CLI flag, no `vscode://command:` URI (those only run in trusted
contexts), no OSC escape sequence. The only supported mechanism is the extension
Terminal API `terminal.show()`. So we ship a tiny extension. See @../../LESSONS.md #13.

## Changes

- **`editor-extension/`** (new) — plain-JS VS Code/Cursor extension. Registers
  `vscode://farishijazi.cc-notify-focus/focus?pids=…`; finds the terminal whose
  `processId` is in the pid set and calls `.show(false)` (takes focus). Falls back
  to `workbench.action.terminal.focus`. Writes a breadcrumb to
  `$TMPDIR/cc-notify-focus.last`. Activates `onUri` + `onStartupFinished`.
- **`bin/cc-install-editor-extension`** (new) — symlinks the extension into
  `~/.vscode/extensions` and `~/.cursor/extensions` (whichever exist).
- **`hooks/cc-notify.sh`** — captures `editor_app` (Cursor/Code) and `shell_pids`:
  the hook's ancestor PPID chain **plus** every pid on `client_tty`. The tty pids
  are essential for **tmux-inside-editor**: there the editor's shell
  (`Terminal.processId`) is the tmux *client's* login shell — a sibling of our
  process tree (our chain dead-ends at the launchd-parented tmux server), but it
  lives on `client_tty`. Both written to the route file.
- **`hooks/cc-focus.sh`** — new `focus_vscode_terminal()`: after window focus,
  resolves the editor (from `editor_app` or the focused window's Aerospace
  app-name), and if the extension is installed, fires
  `open "<vscode|cursor>://farishijazi.cc-notify-focus/focus?pids=$shell_pids"`.
  Suppressed when the extension dir is absent (avoids the editor's "not installed"
  toast).
- **`hooks/cc-notify-bg.sh`** — adds `--sender com.anthropic.claudefordesktop` to
  `alerter` (guarded on `/Applications/Claude.app`). macOS draws Claude's orange
  logo. Custom `--app-icon` is ignored on Big Sur+; sender impersonation is the
  only icon override (Boris's `terminal-notifier -sender` trick). See @../../LESSONS.md #14.
- **`install.sh`** — optional step 4b runs the extension installer when
  `~/.vscode` or `~/.cursor` exists.
- Docs: README (icon section + "focus the exact terminal pane" section + routing
  table), LESSONS #13/#14, CLAUDE.md (architecture, decisions, status → 1.7.0),
  TODO.md (limitation → Done).

## Why pid matching is collision-free

PIDs are unique per live process. The candidate set is our own ancestors + the
processes on our own `client_tty`. Another terminal's shell is a different live
process with a different pid, so it can never be in our set. Worst case (no live
match, e.g. terminal already closed) → falls back to focusing the terminal panel.

## Verification

- `bash -n` clean on all four scripts + installer; `node --check` on extension.
- Simulated hook in this very session (Cursor + tmux): route captured
  `editor_app=Cursor`, and `shell_pids` included pid `1403` (`/bin/zsh` on
  `client_tty`, parented by Cursor's pty host) — i.e. the real `Terminal.processId`.
- Extension symlinked into both editors.
- **Pending live test**: reload the Cursor window, fire the focus URI, confirm
  `$TMPDIR/cc-notify-focus.last` shows `matched pid=…` and the right pane focuses.

## Follow-ups

- Bump `plugin.json` version in the `claude-plugins` marketplace repo on next push.
- The breadcrumb file is a debug aid; can be removed once the feature is trusted.
