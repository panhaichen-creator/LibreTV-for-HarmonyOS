const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const checks = fs.readdirSync(__dirname).filter(name => /^check-.*\.cjs$/.test(name)).sort();
let failures = 0;
for (const name of checks) {
  const result = spawnSync(process.execPath, [path.join(__dirname, name)], {
    cwd: root, encoding: 'utf8', timeout: 30000
  });
  const ok = result.status === 0;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  if (!ok) {
    failures++;
    process.stderr.write(result.stderr || result.stdout || String(result.error));
  }
}
console.log(`${checks.length} checks, ${failures} failures`);
process.exitCode = failures ? 1 : 0;
