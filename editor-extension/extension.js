const vscode = require('vscode');
const fs = require('fs');

const STATE_DIR = '/tmp/cc-notify'; // matches the hooks' state dir

// Debug breadcrumb (also where cc-notify-doctor / tests look).
function breadcrumb(line) {
  try {
    fs.writeFileSync(`${STATE_DIR}/focus.log`, `${new Date().toISOString()} ${line}\n`);
  } catch (e) {}
}

async function findTerminalByPid(wantedPids) {
  for (const term of vscode.window.terminals) {
    try {
      const pid = await term.processId;
      if (pid && wantedPids.has(pid)) return { term, pid };
    } catch (e) {}
  }
  return null;
}

function activate(context) {
  // ── 1. Click-to-focus (cc-focus.sh fires this via `open` on a real click, so
  //       activating the editor is desired here). ──────────────────────────────
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        const wantedPids = new Set(
          (new URLSearchParams(uri.query || '').get('pids') || '')
            .split(',')
            .map((s) => parseInt(s, 10))
            .filter((n) => Number.isFinite(n) && n > 0)
        );
        const hit = await findTerminalByPid(wantedPids);
        if (hit) {
          hit.term.show(false); // take focus — user clicked to get here
          breadcrumb(`focus matched pid=${hit.pid} name=${hit.term.name}`);
          return;
        }
        vscode.commands.executeCommand('workbench.action.terminal.focus');
        breadcrumb(`focus no-match pids=[${[...wantedPids].join(',')}]`);
      },
    })
  );

  // ── 2. Status tab rename, driven by /tmp/cc-notify/<sid>.tab files. File-based
  //       (NOT `open`) on purpose: `open <url>` activates the editor and yanks
  //       Aerospace focus across workspaces. renameWithArg renames a terminal
  //       WITHOUT raising the window, so there's no focus steal. It only acts on
  //       the ACTIVE terminal, so if the target isn't active we defer and apply
  //       it when that terminal next becomes active (never call show() — that
  //       would reveal/raise the window). ───────────────────────────────────────
  const pending = new Map(); // pid -> desired name

  async function renameActiveIfMatch(wantedPids, name) {
    const active = vscode.window.activeTerminal;
    if (!active) return false;
    let pid;
    try { pid = await active.processId; } catch (e) { return false; }
    if (!pid || !wantedPids.has(pid)) return false;
    if (active.name !== name) {
      await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name });
      breadcrumb(`renamed pid=${pid} → ${name}`);
    }
    return true;
  }

  async function applyTab(file) {
    let data;
    try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return; }
    const wantedPids = new Set((data.pids || []).filter(Boolean));
    const name = data.name;
    if (!name || !wantedPids.size) return;
    // Only rename if the target terminal exists in THIS window.
    const hit = await findTerminalByPid(wantedPids);
    if (!hit) return;
    if (!(await renameActiveIfMatch(wantedPids, name))) {
      pending.set(hit.pid, name); // target not active → apply when it activates
      breadcrumb(`deferred pid=${hit.pid} → ${name}`);
    }
  }

  async function flushPending() {
    if (!pending.size) return;
    const active = vscode.window.activeTerminal;
    if (!active) return;
    let pid;
    try { pid = await active.processId; } catch (e) { return; }
    if (pending.has(pid)) {
      const name = pending.get(pid);
      pending.delete(pid);
      if (active.name !== name) {
        await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name });
        breadcrumb(`renamed(deferred) pid=${pid} → ${name}`);
      }
    }
  }
  context.subscriptions.push(vscode.window.onDidChangeActiveTerminal(() => flushPending()));

  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const timers = new Map();
    const watcher = fs.watch(STATE_DIR, (_ev, fn) => {
      if (!fn || !fn.endsWith('.tab')) return;
      clearTimeout(timers.get(fn));
      timers.set(fn, setTimeout(() => applyTab(`${STATE_DIR}/${fn}`), 80)); // debounce
    });
    context.subscriptions.push({ dispose: () => watcher.close() });
    // Apply any tab files that already exist when the window loads.
    for (const f of fs.readdirSync(STATE_DIR)) {
      if (f.endsWith('.tab')) applyTab(`${STATE_DIR}/${f}`);
    }
    breadcrumb('watcher started');
  } catch (e) {
    breadcrumb(`watch error ${e}`);
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
