// asar-edit.mjs — surgical, dependency-free in-place editor for an Electron ASAR.
//
// Codex's custom "owl-electron" runtime loads resources\app.asar only (it does
// NOT fall back to an unpacked app\ folder), so we must keep app.asar and edit
// its contents. Rather than fully repack, we APPEND new bytes to the data
// section and rewrite only the header. Existing file offsets are relative to the
// data-section start, so they stay valid; only the two touched entries change.
//
// Usage:  node asar-edit.mjs <path-to-app.asar> <path-to-codex-rtl-patch.js>
//
// Effect: adds <renderer>/assets/codex-rtl-patch.js and injects a <script> tag
// into the renderer index.html. Writes a .bak of the original next to the asar.

import fs from "node:fs";

const [, , asarPath, patchJsPath] = process.argv;
if (!asarPath || !patchJsPath) {
  console.error("usage: node asar-edit.mjs <app.asar> <codex-rtl-patch.js>");
  process.exit(2);
}

const raw = fs.readFileSync(asarPath);
const headerBufLen = raw.readUInt32LE(4);
const jsonLen = raw.readUInt32LE(12);
const header = JSON.parse(raw.toString("utf8", 16, 16 + jsonLen));
const dataStart = 8 + headerBufLen;
const dataSection = raw.subarray(dataStart);

function ensureDir(parts) {
  let n = header;
  for (const p of parts) {
    if (!n.files) n.files = {};
    if (!n.files[p]) n.files[p] = { files: {} };
    n = n.files[p];
  }
  return n;
}

// Find the renderer index.html (the one that references ./assets/index-*.js).
function findIndexHtml() {
  const stack = [{ node: header, path: [] }];
  while (stack.length) {
    const { node, path } = stack.pop();
    if (!node.files) continue;
    for (const [name, child] of Object.entries(node.files)) {
      const cp = [...path, name];
      if (name === "index.html" && child.size != null) {
        const txt = dataSection.toString("utf8", Number(child.offset), Number(child.offset) + child.size);
        if (txt.includes("./assets/index-")) return { parts: cp, text: txt };
      } else if (child.files) {
        stack.push({ node: child, path: cp });
      }
    }
  }
  return null;
}

const idx = findIndexHtml();
if (!idx) { console.error("renderer index.html not found in asar"); process.exit(3); }
const rendererParts = idx.parts.slice(0, -1); // e.g. ["webview"]

const appended = [];
let cursor = dataSection.length;
function addOrReplace(parts, buf) {
  const dir = ensureDir(parts.slice(0, -1));
  dir.files[parts[parts.length - 1]] = { size: buf.length, offset: String(cursor) };
  appended.push(buf);
  cursor += buf.length;
}

// 1) the patch script alongside the renderer bundle
addOrReplace([...rendererParts, "assets", "codex-rtl-patch.js"], fs.readFileSync(patchJsPath));

// 2) the <script> tag in index.html (idempotent)
let html = idx.text;
if (!html.includes("codex-rtl-patch.js")) {
  const tag = '<script type="module" crossorigin src="./assets/codex-rtl-patch.js"></script>';
  html = html.replace(/(<script type="module"[^>]*src="\.\/assets\/index-)/, tag + "$1");
}
addOrReplace([...rendererParts, "index.html"], Buffer.from(html, "utf8"));

// Rebuild the asar header pickle.
const jsonOut = Buffer.from(JSON.stringify(header), "utf8");
const len = jsonOut.length;
const pad = (4 - (len % 4)) % 4;
const payloadSize = 4 + len + pad;
const hLen = 4 + payloadSize;
const head = Buffer.alloc(16 + len + pad);
head.writeUInt32LE(4, 0);
head.writeUInt32LE(hLen, 4);
head.writeUInt32LE(payloadSize, 8);
head.writeUInt32LE(len, 12);
jsonOut.copy(head, 16);

if (!fs.existsSync(asarPath + ".bak")) fs.writeFileSync(asarPath + ".bak", raw);
const fd = fs.openSync(asarPath, "w");
fs.writeSync(fd, head);
fs.writeSync(fd, dataSection);
for (const b of appended) fs.writeSync(fd, b);
fs.closeSync(fd);

console.log(`OK: patched ${asarPath} under "${rendererParts.join("/")}/" (+${cursor - dataSection.length} bytes)`);
