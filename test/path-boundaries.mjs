import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const baseline = process.argv.includes('--baseline');
const editorArg = process.argv.indexOf('--editor');
const editor = editorArg < 0 ? path.join(repo, 'scripts/lib/asar-edit.mjs') : process.argv[editorArg+1];
const fixture = fs.mkdtempSync(path.join(process.env.TEMP || repo, 'rtl-path-evidence-'));
const root = path.join(fixture, 'staging'), outside = path.join(fixture, 'outside');
fs.mkdirSync(root); fs.mkdirSync(outside);
const raw = Buffer.concat([Buffer.from('fixture-onlydL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'), Buffer.from([1,8]), Buffer.from('00001000tail')]);
const cases = [];
function run(name, target, physical, reject) {
  fs.writeFileSync(physical, raw);
  const r = spawnSync(process.execPath, [editor, 'fuseoff', target, '--root', root], {encoding:'utf8', timeout:10000});
  if (r.error) throw r.error;
  const unchanged = raw.equals(fs.readFileSync(physical));
  cases.push({name, exit:r.status, unchanged});
  assert.equal(r.status === 0, !reject, name + ': exit');
  assert.equal(unchanged, reject, name + ': outside sentinel');
}
const victim = path.join(outside, 'fixture.bin');
run('direct outside rejected', victim, victim, true);
run('ordinary inside changes one byte', path.join(root,'normal.bin'), path.join(root,'normal.bin'), false);
const junction = path.join(root, 'junction'); fs.symlinkSync(outside, junction, 'junction');
run('junction ancestor', path.join(junction,'fixture.bin'), victim, !baseline);
const hard = path.join(root,'hard.bin'); fs.linkSync(victim,hard);
run('hardlinked binary', hard, victim, !baseline);
// Minimal valid archive. No app binaries or third-party code are needed.
function archive() {
  const html = Buffer.from('<html><script type="module" src="./assets/main-a.js"></script></html>');
  const json = Buffer.from(JSON.stringify({files:{webview:{files:{'index.html':{size:html.length,offset:'0'}}}}}));
  const pad = (4-json.length%4)%4, header = Buffer.alloc(16+json.length+pad);
  header.writeUInt32LE(4,0); header.writeUInt32LE(8+json.length+pad,4);
  header.writeUInt32LE(4+json.length+pad,8); header.writeUInt32LE(json.length,12); json.copy(header,16);
  return Buffer.concat([header,html]);
}
const patch = path.join(fixture,'patch.js'); fs.writeFileSync(patch,'/* fixture */');
const asarOutside = path.join(outside,'app.asar'); fs.writeFileSync(asarOutside,archive());
function inject(name, target, tail, reject, physical=target) {
  const before=fs.readFileSync(physical);
  const r=spawnSync(process.execPath,[editor,'inject',target,patch,...tail],{encoding:'utf8',timeout:10000});
  if(r.error)throw r.error;
  assert.equal(r.status===0,!reject,name+': exit');
  assert.equal(before.equals(fs.readFileSync(physical)),reject,name+': target preservation');
  cases.push({name,exit:r.status,unchanged:before.equals(fs.readFileSync(physical))});
}
inject('ASAR injection through junction',path.join(junction,'app.asar'),['--no-bak'],!baseline,asarOutside);
if(!baseline){
  const ordinary=path.join(root,'app.asar');fs.writeFileSync(ordinary,archive());
  inject('backup destination under junction',ordinary,[path.join(junction,'backup.asar')],true);
  assert.equal(fs.existsSync(path.join(outside,'backup.asar')),false);
  // The legacy predictable .tmp name must neither be opened nor overwritten.
  const sentinel=path.join(outside,'tmp-sentinel');fs.writeFileSync(sentinel,'keep');
  fs.linkSync(sentinel,ordinary+'.tmp');
  inject('ordinary ASAR succeeds without touching hostile legacy temp',ordinary,['--no-bak'],false);
  assert.equal(fs.readFileSync(sentinel,'utf8'),'keep');
}
console.log(JSON.stringify({mode:baseline?'BEFORE: vulnerability reproduced':'AFTER: regression passed', platform:process.platform, node:process.version, fixture, cases, limitations:'Synthetic full Node CLI. No installer run or concurrent path replacement. Fixture retained.'},null,2));
