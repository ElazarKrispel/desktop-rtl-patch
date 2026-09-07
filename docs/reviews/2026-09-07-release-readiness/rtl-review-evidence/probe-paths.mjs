import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rtl-audit-'));
const script = path.join(here, 'fuseoff-extracted.mjs');
const sentinel = Buffer.from('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX', 'latin1');
const raw = Buffer.concat([Buffer.from('fixture-only'), sentinel, Buffer.from([1,8]), Buffer.from('00001000'), Buffer.from('fixture-tail')]);
let evidence;
try {
  const root = path.join(tmp, 'staging');
  const outside = path.join(tmp, 'outside');
  fs.mkdirSync(root); fs.mkdirSync(outside);
  const victim = path.join(outside, 'fixture.bin');
  fs.writeFileSync(victim, raw);
  const direct = spawnSync(process.execPath, [script, victim, root], {encoding:'utf8', timeout:10000});
  if (direct.error) throw direct.error;
  const directUnchanged = fs.readFileSync(victim).equals(raw);
  fs.symlinkSync(outside, path.join(root, 'link'), 'dir');
  const linkedPath = path.join(root, 'link', 'fixture.bin');
  const linked = spawnSync(process.execPath, [script, linkedPath, root], {encoding:'utf8', timeout:10000});
  if (linked.error) throw linked.error;
  const after = fs.readFileSync(victim);
  evidence = {
    repositoryCommit: '02cc70a8b750de4bc88b740cf8a64f292a5c0325',
    source: 'scripts/lib/asar-edit.mjs:doFuseOff (extracted function)',
    environment: `${process.platform}; Node ${process.version}; synthetic temporary data only`,
    limitations: 'This is not the full PowerShell pipeline and not a Windows junction end-to-end test.',
    directOutside: {exitCode:direct.status, unchanged:directUnchanged},
    symlinkWithinRoot: {exitCode:linked.status, physicalTargetOutsideRoot:true, outsideFileModified:!after.equals(raw), changedOffsets:[...raw.keys()].filter(i=>raw[i]!==after[i]), stdout:linked.stdout.trim()},
    verdict: linked.status===0 && !after.equals(raw) ? 'Lexical root guard does not enforce physical path containment.' : 'Not reproduced'
  };
  fs.writeFileSync(path.join(here, 'path-probe.json'), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence, null, 2));
} finally { fs.rmSync(tmp, {recursive:true, force:true}); }
