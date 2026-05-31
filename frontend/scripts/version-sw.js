#!/usr/bin/env node
// Sets sw.js CACHE_VERSION to a short hash of the app-shell files, so the
// service worker re-installs (and refreshes its precache) whenever the
// frontend content changes. Run by the git pre-commit hook.
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const dir = path.join(__dirname, '..');
const SHELL = ['index.html', 'styles.css', 'script.js', 'manifest.json'];

const hash = crypto.createHash('sha256');
for (const f of SHELL) hash.update(fs.readFileSync(path.join(dir, f)));
const version = hash.digest('hex').slice(0, 8);

const swPath = path.join(dir, 'sw.js');
const sw = fs.readFileSync(swPath, 'utf8');
const updated = sw.replace(/const CACHE_VERSION = '[^']*';/, `const CACHE_VERSION = '${version}';`);

if (updated === sw) {
  console.log(`sw.js CACHE_VERSION already up to date (${version})`);
} else {
  fs.writeFileSync(swPath, updated);
  console.log(`sw.js CACHE_VERSION -> ${version}`);
}
