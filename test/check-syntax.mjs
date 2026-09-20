#!/usr/bin/env node
// ============================================================================
// DDS — index.html syntax check
// ----------------------------------------------------------------------------
// index.html is one big HTML file with a single inlined <script> block (plus
// external CDN <script src=...> tags, which carry no inline code to check).
// This has been verified by hand with `node --check` on an extracted copy of
// that block throughout development; this script just makes that a real,
// reusable, CI-runnable check instead of a manual step.
//
// Usage: node test/check-syntax.mjs
// ============================================================================
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = path.join(root, 'index.html');
const html = readFileSync(indexPath, 'utf8');

const openTag = '<script>';
const closeTag = '</script>';
const start = html.indexOf(openTag);
const end = html.lastIndexOf(closeTag);

if (start === -1 || end === -1 || end <= start) {
  console.error(`Could not find an inline <script>...</script> block in ${indexPath}`);
  process.exit(1);
}

const script = html.slice(start + openTag.length, end);
const scratchPath = path.join(root, '.check-syntax-extracted.js');
writeFileSync(scratchPath, script);

try {
  execFileSync(process.execPath, ['--check', scratchPath], { stdio: 'inherit' });
  console.log(`OK — inline <script> block (${script.split('\n').length} lines) parses cleanly.`);
} catch (err) {
  console.error('FAILED — the inline <script> block has a syntax error (see above).');
  process.exitCode = 1;
} finally {
  unlinkSync(scratchPath);
}
