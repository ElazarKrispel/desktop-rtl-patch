// Extracted verbatim function + constants from asar-edit.mjs at 02cc70a8b750de4bc88b740cf8a64f292a5c0325.
// This file is used ONLY with a synthetic temporary binary for a defensive review.
import fs from "node:fs";
import path from "node:path";
const FUSE_SENTINEL = Buffer.from("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX", "latin1");
const FUSE_ASAR_INTEGRITY_INDEX = 4;
function doFuseOff(binPath, root) {
  const abs = path.resolve(binPath);
  const rootAbs = path.resolve(root);
  const underRoot = abs.toLowerCase() === rootAbs.toLowerCase() ||
    abs.toLowerCase().startsWith(rootAbs.toLowerCase() + path.sep);
  if (!underRoot) { console.error("fuseoff refused: " + abs + " is not under --root " + rootAbs); process.exit(22); }
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
  try { fs.writeSync(fd, Buffer.from("0", "latin1"), 0, 1, pos); } finally { fs.closeSync(fd); }
  const after = fs.readFileSync(abs);
  const onlyThatByteChanged = after.length === buf.length && after[pos] === 0x30 &&
    Buffer.compare(after.subarray(0, pos), buf.subarray(0, pos)) === 0 &&
    Buffer.compare(after.subarray(pos + 1), buf.subarray(pos + 1)) === 0;
  if (!onlyThatByteChanged) { console.error("fuseoff: post-write verification failed"); process.exit(24); }
  console.log("fuseoff: asar-integrity disabled (1 byte @" + pos + ", length " + after.length + " unchanged)");
  process.exit(0);
}
doFuseOff(process.argv[2], process.argv[3]);
