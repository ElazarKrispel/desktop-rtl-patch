// asar-edit.mjs - surgical, dependency-free editor + verifier for an Electron ASAR.
// App-agnostic for the ASAR profiles (Codex and OpenCode). Run by Codex's bundled
// node, or by the app's own Electron exe as node (ELECTRON_RUN_AS_NODE=1 + ELECTRON_NO_ASAR=1 -
// the second is REQUIRED or Electron's fs shim reads app.asar as an archive).
//
// The Electron runtime loads resources\app.asar (it does NOT fall back to an unpacked
// app\ folder), so we keep app.asar and edit its contents. Rather than fully repack,
// we APPEND new bytes to the data section and rewrite only the header. Existing file
// offsets are relative to the data-section start, so they stay valid; only the touched
// entries change.
//
// Usage:
//   node asar-edit.mjs inject <app.asar> <patch.js> [--config <config.js>] [bakArg]
//   node asar-edit.mjs config <app.asar> <config.js> [bakArg]
//   node asar-edit.mjs verify <app.asar>
//   node asar-edit.mjs fusestate <app.exe>   (read-only asar-integrity fuse check)
//
// Back-compat: if the first arg looks like a path to an .asar (not a subcommand),
// it is treated as "inject" with the old positional arguments.
//
// inject:  adds <renderer>/assets/<payload> and a <script> tag in the renderer
//          index.html, before the app's own module bundle (appBundleMatch finds
//          index-/main-/any hashed ./assets/*.js, excluding our payload). Structurally
//          idempotent and self-correcting; writes a .bak of the original unless "--no-bak".
// verify:  re-opens the asar, confirms the header parses, the payload entry exists,
//          and the <script> tag precedes the app bundle. Prints a single JSON line.
// fusestate: reads FuseV1Options idx 4 (EnableEmbeddedAsarIntegrityValidation) from the
//          exe's fuse wire. Exit 0 = off/not-wired (patchable), 20 = ON, 21 = unreadable.
//
// Exit codes: 0 ok; 2 usage; 3 renderer not found; 4 bad asar header; 5 verify failed.
// Payload/config file names come from RTL_PAYLOAD_NAME / RTL_CONFIG_NAME env (defaults below).

import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";

const PAYLOAD_NAME = process.env.RTL_PAYLOAD_NAME || "desktop-rtl-patch.js";
const CONFIG_NAME = process.env.RTL_CONFIG_NAME || "desktop-rtl-config.js";

// @electron/fuses wire markers (see doFuseState). Declared up here (not next to the
// function) so the top-level command dispatch can call doFuseState without hitting a
// temporal-dead-zone error on these consts.
const FUSE_SENTINEL = Buffer.from("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX", "latin1");
const FUSE_ASAR_INTEGRITY_INDEX = 4;

/* --------------------------------- args ---------------------------------- */

const argv = process.argv.slice(2);
let cmd = argv[0];
let rest = argv.slice(1);
// Back-compat: "node asar-edit.mjs <app.asar> <patch.js> [bak]" implies inject.
if (cmd && /\.asar$/i.test(cmd)) { rest = argv; cmd = "inject"; }

if (cmd === "inject") {
  const [asarPath, patchJsPath, ...tail] = rest;
  if (!asarPath || !patchJsPath) usage();
  const opt = parseTail(tail);
  doInject(asarPath, patchJsPath, opt.bak, opt.configJs);
} else if (cmd === "config") {
  const [asarPath, configJsPath, ...tail] = rest;
  if (!asarPath || !configJsPath) usage();
  const opt = parseTail(tail);
  doConfig(asarPath, configJsPath, opt.bak);
} else if (cmd === "verify") {
  const [asarPath] = rest;
  if (!asarPath) usage();
  doVerify(asarPath);
} else if (cmd === "fusestate") {
  const [exePath] = rest;
  if (!exePath) usage();
  doFuseState(exePath);
} else if (cmd === "fuseoff") {
  const [binPath, rootFlag, root] = rest;
  if (!binPath || rootFlag !== "--root" || !root) usage();
  doFuseOff(binPath, root);
} else {
  usage();
}

// Trailing options shared by inject/config: an optional "--config <file>" (inject
// only) and a backup selector ("--no-bak", or a bak path).
function parseTail(tokens) {
  let configJs = null, bak = null;
  for (let i = 0; i < tokens.length; i += 1) {
    if (tokens[i] === "--config") { configJs = tokens[i + 1]; i += 1; }
    else if (tokens[i] === "--no-bak") { bak = "--no-bak"; }
    else if (tokens[i]) { bak = tokens[i]; }
  }
  return { configJs, bak };
}

function usage() {
  console.error("usage: node asar-edit.mjs inject <app.asar> <patch.js> [--config <config.js>] [--no-bak|bakPath]");
  console.error("       node asar-edit.mjs config <app.asar> <config.js> [--no-bak|bakPath]");
  console.error("       node asar-edit.mjs verify <app.asar>");
  console.error("       node asar-edit.mjs fusestate <app.exe>");
  console.error("       node asar-edit.mjs fuseoff <binary> --root <copy-or-staging-dir>");
  process.exit(2);
}

/* -------------------------------- fuse off ------------------------------- */

// Turn the EnableEmbeddedAsarIntegrityValidation fuse OFF in OUR COPY's binary (never the
// original): a single in-place byte write, '1' -> '0', at fuse index 4. Verified live on
// Codex 26.901 (owl runtime, wire in chrome.dll): with the fuse ON an injected asar aborts
// at startup with "Integrity check failed for asar archive"; with this one byte flipped the
// injected copy launches normally, and no exe/hash surgery is needed. Every invariant is
// checked BEFORE the write, and the result is re-read and diffed AFTER:
//   21 unreadable; 22 target not under --root; 23 unexpected fuse structure; 24 verify failed.
// Being already off is a no-op success (exit 0). Refuses any path outside --root, so the
// original install can never be written even if a wrong path is passed.
function doFuseOff(binPath, root) {
  const abs = path.resolve(binPath);
  const rootAbs = path.resolve(root);
  const underRoot = abs.toLowerCase() === rootAbs.toLowerCase() ||
    abs.toLowerCase().startsWith(rootAbs.toLowerCase() + path.sep);
  if (!underRoot) { console.error("fuseoff refused: " + abs + " is not under --root " + rootAbs); process.exit(22); }
  try { assertSafeMutationPath(abs); }
  catch (e) { console.error(e.message); process.exit(22); }
  let buf;
  try { buf = fs.readFileSync(abs); }
  catch (e) { console.error("cannot read binary: " + (e && e.message)); process.exit(21); }
  const at = buf.indexOf(FUSE_SENTINEL);
  if (at < 0) { console.error("fuseoff: fuse sentinel not found"); process.exit(23); }
  if (buf.indexOf(FUSE_SENTINEL, at + 1) >= 0) { console.error("fuseoff: more than one fuse sentinel; refusing"); process.exit(23); }
  const version = buf[at + FUSE_SENTINEL.length];
  const count = buf[at + FUSE_SENTINEL.length + 1];
  if (version !== 1) { console.error("fuseoff: unexpected fuse wire version " + version); process.exit(23); }
  if (FUSE_ASAR_INTEGRITY_INDEX >= count) { console.error("fuseoff: fuse index out of range (count=" + count + ")"); process.exit(23); }
  const pos = at + FUSE_SENTINEL.length + 2 + FUSE_ASAR_INTEGRITY_INDEX;
  const cur = String.fromCharCode(buf[pos]);
  if (cur === "0") { console.log("fuseoff: asar-integrity already disabled (no change)"); process.exit(0); }
  if (cur !== "1") { console.error("fuseoff: fuse byte is '" + cur + "', not '0'/'1'; refusing"); process.exit(23); }
  const fd = fs.openSync(abs, "r+");
  try {
    // Check the opened file too: a hardlink must never turn an in-place fuse edit
    // into an edit of another path. Ancestor checks do not eliminate rename races.
    assertSafeMutationPath(abs);
    if (fs.fstatSync(fd).nlink !== 1) throw Error('[SAFETY] hardlinked fuse binary');
    fs.writeSync(fd, Buffer.from("0", "latin1"), 0, 1, pos);
  } finally { fs.closeSync(fd); }
  const after = fs.readFileSync(abs);
  const onlyThatByteChanged = after.length === buf.length && after[pos] === 0x30 &&
    Buffer.compare(after.subarray(0, pos), buf.subarray(0, pos)) === 0 &&
    Buffer.compare(after.subarray(pos + 1), buf.subarray(pos + 1)) === 0;
  if (!onlyThatByteChanged) { console.error("fuseoff: post-write verification failed"); process.exit(24); }
  console.log("fuseoff: asar-integrity disabled (1 byte @" + pos + ", length " + after.length + " unchanged)");
  process.exit(0);
}

/* ------------------------------ fuse state ------------------------------- */

// Read-only: report whether an Electron exe has the EnableEmbeddedAsarIntegrityValidation
// fuse ON. The @electron/fuses wire is: the sentinel string, then a version byte, a
// fuse-count byte, then one ASCII char per fuse ('0'=disabled, '1'=enabled, 'r'=removed).
// FuseV1Options index 4 is EnableEmbeddedAsarIntegrityValidation (stable enum). We only
// READ one byte, so no dependency is needed. Exit 0 = off / not wired (patchable);
// 20 = ON (the copy-only method cannot patch this build); 21 = exe unreadable.
function doFuseState(exePath) {
  let buf;
  try { buf = fs.readFileSync(exePath); }
  catch (e) { console.error("cannot read exe: " + (e && e.message)); process.exit(21); }
  const at = buf.indexOf(FUSE_SENTINEL);
  if (at < 0) { console.log("fuse: sentinel not found (not wired)"); process.exit(0); }
  const wireStart = at + FUSE_SENTINEL.length + 2; // skip version + count bytes
  const count = buf[at + FUSE_SENTINEL.length + 1];
  if (FUSE_ASAR_INTEGRITY_INDEX >= count) { console.log("fuse: index out of range (count=" + count + ")"); process.exit(0); }
  const state = String.fromCharCode(buf[wireStart + FUSE_ASAR_INTEGRITY_INDEX]);
  const on = state === "1";
  console.log("fuse: asar-integrity=" + (on ? "ENABLED" : "disabled") + " (count=" + count + ")");
  process.exit(on ? 20 : 0);
}

/* ------------------------------ asar parsing ----------------------------- */

// Parse and structurally validate the asar header. Fails clearly (exit 4) if the
// on-disk pickle does not match the format we know how to rewrite, rather than
// silently corrupting a bundle whose layout changed.
function parseAsar(asarPath) {
  const raw = fs.readFileSync(asarPath);
  if (raw.length < 16) fail4("file too small to be an asar");
  const sizeField = raw.readUInt32LE(0);
  const headerBufLen = raw.readUInt32LE(4);
  const payloadSize = raw.readUInt32LE(8);
  const jsonLen = raw.readUInt32LE(12);
  if (sizeField !== 4) fail4(`unexpected size field ${sizeField} (want 4)`);
  if (headerBufLen !== 4 + payloadSize) fail4("header length / payload size mismatch");
  const pad = payloadSize - 4 - jsonLen;
  if (pad < 0 || pad > 3) fail4("json length inconsistent with payload size");
  if (16 + jsonLen > raw.length) fail4("declared json length exceeds file size");
  let header;
  try {
    header = JSON.parse(raw.toString("utf8", 16, 16 + jsonLen));
  } catch (e) {
    fail4("header JSON did not parse: " + e.message);
  }
  const dataStart = 8 + headerBufLen;
  return { raw, header, jsonLen, dataStart, dataSection: raw.subarray(dataStart) };
}

function fail4(msg) { console.error("bad asar header: " + msg); process.exit(4); }

function ensureDir(header, parts) {
  let n = header;
  for (const p of parts) {
    if (!n.files) n.files = {};
    if (!n.files[p]) n.files[p] = { files: {} };
    n = n.files[p];
  }
  return n;
}

function getEntry(header, parts) {
  let n = header;
  for (const p of parts) {
    if (!n.files || !n.files[p]) return null;
    n = n.files[p];
  }
  return n;
}

// Rank every index.html and pick the renderer's: the one whose markup actually
// loads its bundle as an ES module from ./assets/index-*.js. Deprioritize files
// under node_modules / test / fixtures. Deterministic tie-break (shallowest path,
// then lexicographic) so repeated runs always choose the same file.
function findRendererIndex(header, dataSection) {
  const candidates = [];
  const stack = [{ node: header, path: [] }];
  while (stack.length) {
    const { node, path } = stack.pop();
    if (!node.files) continue;
    for (const [name, child] of Object.entries(node.files)) {
      const cp = [...path, name];
      if (name === "index.html" && child.size != null && child.offset != null) {
        const start = Number(child.offset);
        const txt = dataSection.toString("utf8", start, start + child.size);
        candidates.push({ parts: cp, text: txt });
      } else if (child.files) {
        stack.push({ node: child, path: cp });
      }
    }
  }
  const scored = candidates.map((c) => {
    const p = c.parts.join("/").toLowerCase();
    let score = 0;
    if (appBundleMatch(c.text)) score += 100;
    else if (/\.\/assets\/[^"']+\.js/.test(c.text)) score += 50;
    if (/node_modules|[\\/](test|tests|fixtures?)[\\/]/.test(p)) score -= 40;
    score -= c.parts.length; // prefer shallower
    return { ...c, score };
  }).filter((c) => c.score > 0);
  if (!scored.length) return null;
  scored.sort((a, b) => b.score - a.score || a.parts.join("/").localeCompare(b.parts.join("/")));
  return scored[0];
}

// Build a regex matching a <script ...src="...NAME"...></script> tag.
function scriptTagRe(name, flags) {
  return new RegExp('<script[^>]*src=["\'][^"\']*' + name + '["\'][^>]*>\\s*</script>', flags);
}

// Locate the app's own entry bundle: a <script type="module"> loading a hashed .js
// from ./assets/. Bundlers differ on the entry name (Codex: index-<hash>.js,
// OpenCode: main-<hash>.js), so match any name and just exclude our own injected
// payload/config assets. Returns { index, match, src } of the first real bundle.
function appBundleMatch(html) {
  const re = /<script[^>]*type=["']module["'][^>]*src=["'](\.\/assets\/[^"']+\.js)["'][^>]*>/ig;
  let m;
  while ((m = re.exec(html)) !== null) {
    const src = m[1];
    if (src.endsWith(PAYLOAD_NAME) || src.endsWith(CONFIG_NAME)) continue;
    return { index: m.index, match: m[0], src };
  }
  return null;
}

// Insert a classic (non-module) config <script> so window.__codexRtlConfig is set
// before the module payload runs. Strips any existing config tag first (single tag,
// self-correcting) and anchors before the payload tag, else before </head>/</body>.
function ensureConfigTag(html) {
  html = html.replace(scriptTagRe(CONFIG_NAME, "ig"), "");
  const cfgTag = '<script src="./assets/' + CONFIG_NAME + '"></script>';
  const pm = html.match(scriptTagRe(PAYLOAD_NAME, "i"));
  if (pm) return html.replace(pm[0], cfgTag + pm[0]);
  if (/<\/head>/i.test(html)) return html.replace(/<\/head>/i, cfgTag + "</head>");
  if (/<\/body>/i.test(html)) return html.replace(/<\/body>/i, cfgTag + "</body>");
  return cfgTag + html;
}

/* -------------------------------- inject --------------------------------- */

function doInject(asarPath, patchJsPath, bakArg, configJsPath) {
  const { raw, header, dataSection } = parseAsar(asarPath);

  const idx = findRendererIndex(header, dataSection);
  if (!idx) { console.error("renderer index.html not found in asar"); process.exit(3); }
  const rendererParts = idx.parts.slice(0, -1); // e.g. ["webview"]
  const payloadParts = [...rendererParts, "assets", PAYLOAD_NAME];

  // Structural idempotency: decide from the HEADER (not a substring scan) whether
  // the payload entry and the <script> tag already exist, and repair either half.
  const hasPayloadEntry = !!getEntry(header, payloadParts);
  const hadTag = scriptTagRe(PAYLOAD_NAME, "i").test(idx.text);
  let html = idx.text;
  // Always strip any existing tag first, then re-insert exactly once. This repairs
  // a duplicated or mis-placed tag from a partial prior run.
  html = html.replace(scriptTagRe(PAYLOAD_NAME, "ig"), "");
  const tag = '<script type="module" crossorigin src="./assets/' + PAYLOAD_NAME + '"></script>';
  const bundle = appBundleMatch(html);
  if (bundle) {
    html = html.slice(0, bundle.index) + tag + html.slice(bundle.index);
  } else {
    // No app bundle tag to anchor to; inject before </head> (or </body>).
    if (/<\/head>/i.test(html)) html = html.replace(/<\/head>/i, tag + "</head>");
    else if (/<\/body>/i.test(html)) html = html.replace(/<\/body>/i, tag + "</body>");
    else html = tag + html;
  }
  if (configJsPath) html = ensureConfigTag(html);

  // Append the payload (+ optional config) file and the rewritten index.html.
  // Appending keeps existing offsets valid; only the touched header entries change.
  const appended = [];
  let cursor = dataSection.length;
  const addOrReplace = (parts, buf) => {
    const dir = ensureDir(header, parts.slice(0, -1));
    dir.files[parts[parts.length - 1]] = { size: buf.length, offset: String(cursor) };
    appended.push(buf);
    cursor += buf.length;
  };
  addOrReplace(payloadParts, fs.readFileSync(patchJsPath));
  if (configJsPath) addOrReplace([...rendererParts, "assets", CONFIG_NAME], fs.readFileSync(configJsPath));
  addOrReplace([...rendererParts, "index.html"], Buffer.from(html, "utf8"));

  const head = buildHeader(header);
  writeAsarAtomic(asarPath, head, dataSection, appended, raw, bakArg);

  const note = hasPayloadEntry && hadTag ? "already injected, refreshed"
             : hasPayloadEntry ? "repaired: added missing tag"
             : hadTag ? "repaired: added missing payload"
             : "injected";
  console.log(`OK (${note}${configJsPath ? "+config" : ""}): ${asarPath} under "${rendererParts.join("/")}/" (+${cursor - dataSection.length} bytes)`);
}

/* -------------------------------- config --------------------------------- */

// Update ONLY the config asset (and its tag), leaving the payload untouched. Used
// to apply settings changes live without re-injecting the whole bundle.
function doConfig(asarPath, configJsPath, bakArg) {
  const { raw, header, dataSection } = parseAsar(asarPath);
  const idx = findRendererIndex(header, dataSection);
  if (!idx) { console.error("renderer index.html not found in asar"); process.exit(3); }
  const rendererParts = idx.parts.slice(0, -1);
  const html = ensureConfigTag(idx.text);

  const appended = [];
  let cursor = dataSection.length;
  const addOrReplace = (parts, buf) => {
    const dir = ensureDir(header, parts.slice(0, -1));
    dir.files[parts[parts.length - 1]] = { size: buf.length, offset: String(cursor) };
    appended.push(buf);
    cursor += buf.length;
  };
  addOrReplace([...rendererParts, "assets", CONFIG_NAME], fs.readFileSync(configJsPath));
  addOrReplace([...rendererParts, "index.html"], Buffer.from(html, "utf8"));

  const head = buildHeader(header);
  writeAsarAtomic(asarPath, head, dataSection, appended, raw, bakArg);
  console.log(`OK (config): ${asarPath} under "${rendererParts.join("/")}/" (+${cursor - dataSection.length} bytes)`);
}

// Rebuild the asar header pickle (same format we validated on read).
function buildHeader(header) {
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
  return head;
}

// Atomic write: build the full new image in a sibling .tmp, fsync, then rename over
// the target so a crash mid-write can never leave a torn asar in staging.
function writeAsarAtomic(asarPath, head, dataSection, appended, raw, bakArg) {
  assertSafeMutationPath(asarPath);
  if (bakArg !== "--no-bak") {
    const bakPath = bakArg && bakArg.length ? bakArg : asarPath + ".bak";
    assertSafeMutationPath(bakPath);
    if (!fs.existsSync(bakPath)) fs.writeFileSync(bakPath, raw, {flag: 'wx'});
  }
  const tmp = asarPath + '.' + crypto.randomBytes(12).toString('hex') + '.tmp';
  assertSafeMutationPath(tmp);
  const fd = fs.openSync(tmp, "wx");
  try {
    fs.writeSync(fd, head);
    fs.writeSync(fd, dataSection);
    for (const b of appended) fs.writeSync(fd, b);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  assertSafeMutationPath(asarPath);
  assertSafeMutationPath(tmp);
  fs.renameSync(tmp, asarPath);
}

// Reject links in every existing component, including the selected root itself.
// lstat observes dangling links; walking up also covers not-yet-created children.
// This is fail-closed preflight, not protection from a same-user rename race.
function assertSafeMutationPath(target) {
  const absolute = path.resolve(target);
  if (process.platform === 'win32' && (absolute.startsWith('\\\\') || absolute.slice(2).includes(':'))) {
    throw Error('[SAFETY] device, network or alternate-stream mutation path');
  }
  for (let cursor = absolute; ; cursor = path.dirname(cursor)) {
    let stat;
    try { stat = fs.lstatSync(cursor); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (stat?.isSymbolicLink()) throw Error('[SAFETY] reparse/link mutation path: ' + cursor);
    if (stat?.isFile() && stat.nlink !== 1) throw Error('[SAFETY] hardlinked mutation path: ' + cursor);
    if (path.dirname(cursor) === cursor) break;
  }
}

/* -------------------------------- verify --------------------------------- */

// Confirm the patched asar is structurally sound and actually carries our payload.
// Prints one JSON line and exits 0 on success, or exits 5 with {ok:false,reason}.
function doVerify(asarPath) {
  let parsed;
  try { parsed = parseAsar(asarPath); }
  catch (e) { return verifyFail("header parse threw: " + (e && e.message)); }
  const { raw, header, dataSection } = parsed;

  const idx = findRendererIndex(header, dataSection);
  if (!idx) return verifyFail("renderer index.html not found");
  const rendererParts = idx.parts.slice(0, -1);
  const payloadParts = [...rendererParts, "assets", PAYLOAD_NAME];

  const entry = getEntry(header, payloadParts);
  if (!entry || entry.size == null || entry.offset == null) return verifyFail("payload entry missing from header");
  const size = Number(entry.size);
  const offset = Number(entry.offset);
  if (!(size > 0) || offset < 0 || offset + size > dataSection.length) return verifyFail("payload entry offset/size out of range");

  const tagRe = new RegExp('<script[^>]*src=["\'][^"\']*' + PAYLOAD_NAME + '["\'][^>]*>', "i");
  if (!tagRe.test(idx.text)) return verifyFail("payload <script> tag missing from index.html");
  // The payload tag must precede the app bundle so the global is set in time.
  const tagPos = idx.text.search(tagRe);
  const bundle = appBundleMatch(idx.text);
  const bundlePos = bundle ? bundle.index : -1;
  if (bundlePos >= 0 && tagPos > bundlePos) return verifyFail("payload tag is after the app bundle");

  const payloadBuf = dataSection.subarray(offset, offset + size);
  const payloadSha256 = crypto.createHash("sha256").update(payloadBuf).digest("hex");
  const asarSha256 = crypto.createHash("sha256").update(raw).digest("hex");
  process.stdout.write(JSON.stringify({
    ok: true,
    renderer: rendererParts.join("/"),
    payloadBytes: size,
    payloadSha256,
    asarSha256
  }) + "\n");
  process.exit(0);
}

function verifyFail(reason) {
  process.stdout.write(JSON.stringify({ ok: false, reason }) + "\n");
  process.exit(5);
}
