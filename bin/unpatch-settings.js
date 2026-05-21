#!/usr/bin/env node
// Remove cc-notify hook entries from settings.json.

const fs = require('fs');
const settingsPath = process.argv[2];
if (!settingsPath || !fs.existsSync(settingsPath)) {
  console.error('settings.json not found:', settingsPath);
  process.exit(1);
}

const cfg = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
if (!cfg.hooks) { console.log('no hooks block, nothing to remove'); process.exit(0); }

function stripCC(arr) {
  return (arr || []).filter(group =>
    !(group.hooks || []).some(h => (h.command || '').includes('cc-notify.sh'))
  );
}

let changed = false;
for (const evt of ['Notification', 'Stop']) {
  if (!cfg.hooks[evt]) continue;
  const before = cfg.hooks[evt].length;
  cfg.hooks[evt] = stripCC(cfg.hooks[evt]);
  if (cfg.hooks[evt].length !== before) {
    changed = true;
    console.log(`  - removed cc-notify entry from ${evt}`);
  }
  if (cfg.hooks[evt].length === 0) delete cfg.hooks[evt];
}

if (changed) {
  const backup = `${settingsPath}.bak.${Date.now()}`;
  fs.copyFileSync(settingsPath, backup);
  fs.writeFileSync(settingsPath, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`  (backup: ${backup})`);
} else {
  console.log('  no cc-notify entries found');
}
