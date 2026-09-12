'use strict';

const { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync } = require('node:fs');
const { dirname, extname, join, resolve } = require('node:path');

const root = resolve(__dirname, '..');
const source = join(root, 'web');
const output = join(root, 'dist', 'web');
const assetTypes = new Set(['.html', '.css', '.js', '.svg', '.png', '.woff2', '.ttf', '.txt']);
const documents = [];

// Copy release assets; design previews stay local until approved.
rmSync(output, { recursive: true, force: true });
function copyAssets(directory, destination) {
  mkdirSync(destination, { recursive: true });
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || entry.name === 'tests') continue;
    const from = join(directory, entry.name);
    const to = join(destination, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Unexpected web asset symlink: ${from}`);
    if (entry.isDirectory()) copyAssets(from, to);
    else if (assetTypes.has(extname(entry.name))) {
      cpSync(from, to);
      if (['.html', '.css'].includes(extname(entry.name))) documents.push(to);
    }
  }
}
copyAssets(source, output);

// Validate local HTML/CSS references in the artifact, not only in the source tree.
for (const file of documents) {
  const text = readFileSync(file, 'utf8');
  const references = [
    ...text.matchAll(/(?:src|href)=["']([^"']+)["']|url\(["']?([^\s)"']+)["']?\)/g),
  ];
  for (const reference of references) {
    const target = (reference[1] || reference[2]).split(/[?#]/)[0];
    if (!target || /^(?:[a-z]+:|\/\/)/i.test(target)) continue;
    if (target.startsWith('/'))
      throw new Error(`Root-relative URL breaks project Pages: ${target}`);
    if (!existsSync(resolve(dirname(file), target))) {
      throw new Error(`Missing packaged asset: ${target} referenced by ${file}`);
    }
  }
}

// Native apps consume the same folder; missing entrypoints or notices fail CI.
for (const asset of [
  'native.html',
  'native.js',
  'mascot.js',
  'mascot.css',
  'LICENSE.txt',
  'NOTICE.txt',
]) {
  if (!existsSync(join(output, 'mascot', asset))) {
    throw new Error(`Missing shared renderer asset: ${asset}`);
  }
}
