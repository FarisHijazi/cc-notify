# cc-notify-focus (editor extension)

A ~40-line VS Code / Cursor extension that lets [cc-notify](../README.md) focus the
**exact integrated terminal pane** a Claude Code session runs in — not just the window.

## Why it exists

VS Code / Cursor expose **no** way to focus a specific integrated terminal from
outside the editor — not via the `code`/`cursor` CLI, not via `vscode://command:`
URIs, not via terminal OSC escape sequences. The only supported path is the
extension Terminal API: `vscode.window.terminals[*].show()`. So cc-notify ships
this minimal extension.

## How it works

It registers a URI handler. cc-notify's click handler runs:

```
open "vscode://farishijazi.cc-notify-focus/focus?pids=<pid,pid,...>"
```

The `pids` are the ancestor PID chain of the Claude Code hook. One of them is the
terminal's shell PID (`Terminal.processId`). The extension finds that terminal and
calls `.show()`. PIDs are unique per live process, so an ancestor PID can only match
the terminal Claude actually runs in.

## Install

```bash
../bin/cc-install-editor-extension
```

Then **reload the window** (Cmd+Shift+P → "Developer: Reload Window") in each editor.
The installer symlinks this folder into `~/.vscode/extensions/` and
`~/.cursor/extensions/` (whichever editors are present).
