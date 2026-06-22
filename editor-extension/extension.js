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
        // only acts on the ACTIVE terminal, so we reveal the pid-matched terminal
        // first with show(true) — `true` preserves keyboard focus (doesn't pull
        // you out of the editor), it just makes that terminal the active tab so
        // the rename targets it. Fired with `open -g`, so the editor window isn't
        // brought to the foreground either. This lets status badges update even on
        // terminals you're not currently looking at.
        if (/\/rename$/.test(uri.path) && wantedName) {
          for (const term of vscode.window.terminals) {
            try {
              const pid = await term.processId;
              if (pid && wantedPids.has(pid)) {
                term.show(true); // reveal as active tab, keep keyboard focus put
                await vscode.commands.executeCommand(
                  'workbench.action.terminal.renameWithArg',
                  { name: wantedName }
                );
                breadcrumb(`renamed pid=${pid} → ${wantedName}`);
                return;
              }
            } catch (e) {}
          }
          breadcrumb(`rename: no terminal matched pids=[${[...wantedPids].join(',')}]`);
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
