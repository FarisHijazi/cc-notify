const vscode = require('vscode');
const fs = require('fs');
const os = require('os');

// Debug breadcrumb: records what the last focus request matched, so cc-notify
// can confirm the extension is loaded and matching the right terminal.
function breadcrumb(line) {
  try {
    fs.writeFileSync(
      `${os.tmpdir()}/cc-notify-focus.last`,
      `${new Date().toISOString()} ${line}\n`
    );
  } catch (e) {}
}

// cc-notify focus-terminal handler.
//
// Triggered by cc-focus.sh via:
//   open "vscode://farishijazi.cc-notify-focus/focus?pids=<pid,pid,...>[&name=<tab-name>]"
// (or cursor:// in Cursor).
//
// The `pids` are the ancestor PID chain of the Claude Code hook process. One of
// them is the integrated terminal's shell PID, which equals Terminal.processId.
// We match that terminal and call .show() to reveal + focus the exact pane.
// PIDs are unique per live process, so an ancestor PID can only ever match the
// terminal we actually came from — never a sibling terminal.

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        const params = new URLSearchParams(uri.query || '');
        const wantedPids = new Set(
          (params.get('pids') || params.get('pid') || '')
            .split(',')
            .map((s) => parseInt(s, 10))
            .filter((n) => Number.isFinite(n) && n > 0)
        );
        const wantedName = params.get('name') || '';

        // /rename path: set the tab name of the matching terminal. renameWithArg
        // only acts on the ACTIVE terminal, so to avoid stealing focus / renaming
        // the wrong tab we only rename when Claude's terminal is already active
        // (true at SessionStart/UserPromptSubmit/turn-end). Fired with `open -g`,
        // so the editor isn't brought forward.
        if (/\/rename$/.test(uri.path) && wantedName) {
          const active = vscode.window.activeTerminal;
          if (active) {
            try {
              const pid = await active.processId;
              if (pid && wantedPids.has(pid)) {
                await vscode.commands.executeCommand(
                  'workbench.action.terminal.renameWithArg',
                  { name: wantedName }
                );
                breadcrumb(`renamed pid=${pid} → ${wantedName}`);
                return;
              }
            } catch (e) {}
          }
          breadcrumb(`rename skipped (claude terminal not active) → ${wantedName}`);
          return;
        }

        // Match by shell pid first (precise), then by tab name (fallback).
        for (const term of vscode.window.terminals) {
          try {
            const pid = await term.processId;
            if (pid && wantedPids.has(pid)) {
              term.show(false); // false => take focus
              breadcrumb(`matched pid=${pid} name=${term.name}`);
              return;
            }
          } catch (e) {
            // processId rejected (terminal not started) — skip.
          }
        }
        if (wantedName) {
          const byName = vscode.window.terminals.find((t) => t.name === wantedName);
          if (byName) {
            byName.show(false);
            breadcrumb(`matched name=${wantedName}`);
            return;
          }
        }

        // No match: at least focus the terminal panel so the user lands close.
        vscode.commands.executeCommand('workbench.action.terminal.focus');
        breadcrumb(`no match; pids=[${[...wantedPids].join(',')}] terminals=${vscode.window.terminals.length}`);
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
