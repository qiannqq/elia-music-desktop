#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.resolve(__dirname, '..', 'electron');
const DEST = path.resolve(__dirname, '..', 'public', 'electron');

let copied = 0;
let skipped = 0;
let errors = 0;

function syncDir(src, dest) {
  if (!fs.existsSync(dest)) {
    fs.mkdirSync(dest, { recursive: true });
  }

  const entries = fs.readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      syncDir(srcPath, destPath);
    } else if (entry.isFile()) {
      const srcHash = getFileHash(srcPath);
      const destHash = getFileHash(destPath);

      if (srcHash === destHash) {
        skipped++;
      } else {
        fs.copyFileSync(srcPath, destPath);
        copied++;
      }
    }
  }
}

function getFileHash(filePath) {
  if (!fs.existsSync(filePath)) return null;
  try {
    const content = fs.readFileSync(filePath);
    return require('crypto').createHash('md5').update(content).digest('hex');
  } catch (e) {
    return null;
  }
}

console.log(`[sync] electron/ -> public/electron/`);

try {
  syncDir(SRC, DEST);
  console.log(`[sync] Done: ${copied} copied, ${skipped} unchanged, ${errors} errors`);
} catch (err) {
  console.error(`[sync] Failed: ${err.message}`);
  process.exit(1);
}
