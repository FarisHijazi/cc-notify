#!/usr/bin/env node
// Idempotently merge cc-notify hook entries into ~/.claude/settings.json.
// Usage: node patch-settings.js <path-to-settings.json>

const fs = require('fs');
const path = require('path');

const settingsPath = process.argv[2];
if (!settingsPath) {
  console.error('usage: patch-settings.js <settings.json path>');
  process.exit(1);
}

const NOTIFY_CMD = 'bash "$HOME/.claude/hooks/cc-notify.sh" notification';
const STOP_CMD = 'bash "$HOME/.claude/hooks/cc-notify.sh" stop';
const TIMEOUT = 5;

let cfg = {};
if (fs.existsSync(settingsPath)) {
  try {
    cfg = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    console.error(`ERROR: settings.json is not valid JSON: ${e.message}`);
    process.exit(1);
  }
} else {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
}

cfg.hooks = cfg.hooks || {};
cfg.hooks.Notification = cfg.hooks.Notification || [];
cfg.hooks.Stop = cfg.hooks.Stop || [];

function hasEntry(arr, cmd) {
  return arr.some(group =>
    (group.hooks || []).some(h => (h.command || '').includes('cc-notify.sh') && (h.command || '').endsWith(cmd.split(' ').pop()))
  );
}

function addEntry(arr, cmd) {
  arr.push({
    hooks: [
      { type: 'command', command: cmd, timeout: TIMEOUT }
    ]
  });
}

let changed = false;
if (!hasEntry(cfg.hooks.Notification, NOTIFY_CMD)) {
  addEntry(cfg.hooks.Notification, NOTIFY_CMD);
  changed = true;
  console.log('  + added Notification hook');
} else {
  console.log('  = Notification hook already present');
}

if (!hasEntry(cfg.hooks.Stop, STOP_CMD)) {
  addEntry(cfg.hooks.Stop, STOP_CMD);
  changed = true;
  console.log('  + added Stop hook');
} else {
  console.log('  = Stop hook already present');
}

if (changed) {
  // Back up before writing.
  if (fs.existsSync(settingsPath)) {
    const backup = `${settingsPath}.bak.${Date.now()}`;
    fs.copyFileSync(settingsPath, backup);
    console.log(`  (backup: ${backup})`);
  }
  fs.writeFileSync(settingsPath, JSON.stringify(cfg, null, 2) + '\n');
  console.log('  wrote', settingsPath);
} else {
  console.log('  no changes needed');
}
