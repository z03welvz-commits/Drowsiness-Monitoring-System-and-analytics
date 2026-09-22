#!/usr/bin/env node
// ============================================================================
// DDS — index.html syntax check
// ----------------------------------------------------------------------------
// index.html is one big HTML file with inlined <script> blocks (a small
// head theme-flash-prevention block, plus the main app block — external CDN
// <script src=...> tags carry no inline code to check, so they're skipped).
// This has been verified by hand with `node --check` on an extracted copy of
// each block throughout development; this script just makes that a real,
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

const blocks = [];
let searchFrom = 0;
while (true) {
  const start = html.indexOf(openTag, searchFrom);
  if (start === -1) break;
  const end = html.indexOf(closeTag, start + openTag.length);
  if (end === -1) {
    console.error(`Unclosed <script> tag starting at offset ${start} in ${indexPath}`);
    process.exit(1);
  }
  blocks.push(html.slice(start + openTag.length, end));
  searchFrom = end + closeTag.length;
}

if (blocks.length === 0) {
  console.error(`Could not find an inline <script>...</script> block in ${indexPath}`);
  process.exit(1);
}

let failed = false;
blocks.forEach((script, i) => {
  const scratchPath = path.join(root, `.check-syntax-extracted-${i}.js`);
  writeFileSync(scratchPath, script);
  try {
    execFileSync(process.execPath, ['--check', scratchPath], { stdio: 'inherit' });
    console.log(`OK — inline <script> block ${i + 1}/${blocks.length} (${script.split('\n').length} lines) parses cleanly.`);
  } catch (err) {
    console.error(`FAILED — inline <script> block ${i + 1}/${blocks.length} has a syntax error (see above).`);
    failed = true;
  } finally {
    unlinkSync(scratchPath);
  }
});

if (failed) process.exitCode = 1;
