import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../../../..');
const editor=path.join(repo,'scripts/lib/asar-edit.mjs');
if(!fs.existsSync(editor))throw Error('Product editor missing: '+editor);
const fixture=fs.mkdtempSync(path.join(here,'fixture-fuse-'));
const root=path.join(fixture,'staging'), outside=path.join(fixture,'outside');
fs.mkdirSync(root); fs.mkdirSync(outside);
const raw=Buffer.concat([Buffer.from('fixture-only'),Buffer.from('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'),Buffer.from([1,8]),Buffer.from('00001000'),Buffer.from('fixture-tail')]);
const cases=[];
function run(name,target,physical){
 fs.writeFileSync(physical,raw);
 const r=spawnSync(process.execPath,[editor,'fuseoff',target,'--root',root],{encoding:'utf8',timeout:10000});
 if(r.error)throw r.error;
 const after=fs.readFileSync(physical);
 cases.push({name,exit:r.status,physicalOutside:!physical.startsWith(root+path.sep),unchanged:raw.equals(after),changedOffsets:[...raw.keys()].filter(i=>raw[i]!==after[i]),stdout:r.stdout.trim(),stderr:r.stderr.trim().replaceAll(fixture,'<fixture>')});
}
const victim=path.join(outside,'fixture.bin');
run('direct-outside',victim,victim);
const normal=path.join(root,'normal.bin');run('normal-inside',normal,normal);
const junction=path.join(root,'junction');fs.symlinkSync(outside,junction,'junction');
run('junction-to-outside',path.join(junction,'fixture.bin'),victim);
const hard=path.join(root,'hard.bin');fs.linkSync(victim,hard);run('hard-link-to-outside',hard,victim);
const prefix=path.join(fixture,'staging-lookalike');fs.mkdirSync(prefix);run('prefix-lookalike',path.join(prefix,'fixture.bin'),path.join(prefix,'fixture.bin'));
let fileSymlink;
try {const link=path.join(root,'file-link.bin');fs.symlinkSync(victim,link,'file');run('file-symlink-to-outside',link,victim);fileSymlink='RUN';}catch(e){fileSymlink='BLOCKED: '+e.code;}
const result={source:'scripts/lib/asar-edit.mjs FULL CLI, no extraction',baseline:'02cc70a8b750de4bc88b740cf8a64f292a5c0325',environment:{platform:process.platform,node:process.version},isolation:'Only synthetic binaries and links within uniquely owned fixture; targets outside staging remain inside fixture. Fixtures retained, no recursive delete.',limitations:'Not installer E2E, not a real application, no TOCTOU simulation, no privilege escalation claim.',fileSymlink,cases};
fs.writeFileSync(path.join(here,'fuse-results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
if(cases.find(c=>c.name==='direct-outside').exit!==22 || cases.find(c=>c.name==='normal-inside').exit!==0)throw Error('Control cases failed; findings not established');
