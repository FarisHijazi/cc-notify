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
  //       the ACTIVE terminal (no terminal-id variant exists — see LESSONS #17).
  //       Single source of truth = the .tab file on disk. Two triggers re-assert a
  //       tab's name, neither calls show() (which would raise the window):
  //         • a .tab file changes (fs.watch) → rename if its terminal is active now
  //         • a terminal becomes active (onDidChangeActiveTerminal = "you opened
  //           the session") → re-assert its name from disk. This is the self-heal:
  //           a background terminal whose .tab changed while it was inactive gets
  //           the right title the instant you focus it. ─────────────────────────

  async function renameIfActiveMatches(wantedPids, name) {
    const active = vscode.window.activeTerminal;
    if (!active || !name) return;
    let pid;
    try { pid = await active.processId; } catch (e) { return; }
    if (!pid || !wantedPids.has(pid)) return;
    if (active.name !== name) {
      await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name });
      breadcrumb(`renamed pid=${pid} → ${name}`);
    }
  }

  // A .tab file changed → rename now if its terminal is the active one. If it's a
  // background terminal, reapplyActiveTab lands it the moment that terminal is focused.
  async function applyTab(file) {
    let data;
    try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return; }
    const wantedPids = new Set((data.pids || []).filter(Boolean));
    if (!data.name || !wantedPids.size) return;
    await renameIfActiveMatches(wantedPids, data.name);
  }

  // A terminal became active ("you opened the session") → re-assert its name from
  // whichever .tab file owns its pid. Keeps the title correct on every focus and
  // self-heals a rename that was deferred (target was inactive) or missed.
  async function reapplyActiveTab() {
    const active = vscode.window.activeTerminal;
    if (!active) return;
    let pid;
    try { pid = await active.processId; } catch (e) { return; }
    if (!pid) return;
    let files;
    try { files = fs.readdirSync(STATE_DIR).filter((f) => f.endsWith('.tab')); } catch (e) { return; }
    for (const f of files) {
      let data;
      try { data = JSON.parse(fs.readFileSync(`${STATE_DIR}/${f}`, 'utf8')); } catch (e) { continue; }
      if (!data.name || !(data.pids || []).includes(pid)) continue;
      if (active.name !== data.name) {
        await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name: data.name });
        breadcrumb(`reapplied(focus) pid=${pid} → ${data.name}`);
      }
      return;
    }
  }
  context.subscriptions.push(vscode.window.onDidChangeActiveTerminal(() => reapplyActiveTab()));

  // ── 3. Sweep: cycle through every terminal in THIS window so each one's .tab
  //       name gets applied (renameWithArg/reapplyActiveTab only act on the ACTIVE
  //       terminal). We step with `workbench.action.terminal.focusNext` — the exact
  //       native command bound to Alt+Up, so it's instant — N times, which wraps
  //       back to where it started. Each step fires onDidChangeActiveTerminal →
  //       reapplyActiveTab(), so no explicit rename here. Triggered by touching
  //       /tmp/cc-notify/.sweep — EVERY window's extension watches that file, so all
  //       windows sweep their own terminals IN PARALLEL (no per-window waiting, no
  //       keystroke injection, no accessibility perms, no frontmost requirement). ──
  let sweeping = false;
  async function sweepThisWindow() {
    if (sweeping) return;
    sweeping = true;
    try {
      const n = vscode.window.terminals.length;
      if (!n) return;
      const original = vscode.window.activeTerminal; // remember where we started
      for (let i = 0; i < n; i++) {
        await vscode.commands.executeCommand('workbench.action.terminal.focusNext');
        await new Promise((r) => setTimeout(r, 10)); // let onDidChangeActiveTerminal land
      }
      if (original) original.show(false); // deterministically land back on the start tab (kills focusNext off-by-one)
      breadcrumb(`swept ${n} terminals (focusNext), back to ${original ? original.name : 'n/a'}`);
    } finally {
      sweeping = false;
    }
  }

  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const timers = new Map();
    const watcher = fs.watch(STATE_DIR, (_ev, fn) => {
      if (!fn) return;
      if (fn === '.sweep') { sweepThisWindow(); return; } // parallel across windows
      if (!fn.endsWith('.tab')) return;
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
