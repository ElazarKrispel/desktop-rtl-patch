// Isolated actual-payload validation. No installed app, profile, Registry or shortcut access.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../../..');
const source = path.join(root, 'src/desktop-rtl-patch.js');
const payload = fs.readFileSync(source, 'utf8');
const chrome = process.env.RTL_TEST_CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const userDir = fs.mkdtempSync(path.join(here, 'browser-profile-'));
const child = spawn(chrome, ['--headless=new','--no-first-run','--no-default-browser-check',
  '--disable-background-networking','--disable-component-update','--disable-sync',
  '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
  '--user-data-dir='+userDir,'about:blank'], {windowsHide:true, stdio:['ignore','ignore','pipe']});
let ws;
const report = {date: new Date().toISOString(), baseline:'02cc70a8b750de4bc88b740cf8a64f292a5c0325',
  source:'src/desktop-rtl-patch.js', sourceSha256:crypto.createHash('sha256').update(payload).digest('hex'),
  node:process.version, platform:process.platform, tests:[], limits:[
    'Synthetic about:blank DOM on an isolated Chrome profile. Actual payload executed unchanged.',
    'No real target apps, React runtime, clipboard, IME, undo, user profile or live install cycle tested.',
    'Native MutationObserver and requestAnimationFrame; no scheduling mocks. No performance benchmark.']};
try {
  const endpoint = await new Promise((resolve,reject)=>{
    let buf=''; const timer=setTimeout(()=>reject(new Error('Chrome endpoint timeout')),15000);
    child.stderr.on('data',data=>{buf+=data; const m=buf.match(/DevTools listening on (ws:\/\/[^\r\n]+)/); if(m){clearTimeout(timer);resolve(m[1]);}});
    child.on('error',reject);
  });
  ws = new WebSocket(endpoint);
  await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
  let next=1; const pending=new Map(); const errors=[];
  ws.onmessage=event=>{const m=JSON.parse(event.data); if(m.id){const p=pending.get(m.id); if(p){pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result);}} else if(m.method==='Runtime.exceptionThrown') errors.push(m.params.exceptionDetails);};
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=next++;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP timeout '+method));},15000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  report.browser=await send('Browser.getVersion');
  const settle='await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(r))));';
  async function test(id,config,html,before,body) {
    const {targetId}=await send('Target.createTarget',{url:'about:blank'});
    const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
    await send('Runtime.enable',{},sessionId);
    await send('Page.bringToFront',{},sessionId);
    async function evaluate(expression){const r=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},sessionId);if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
    await evaluate('window.__codexRtlConfig='+JSON.stringify(config)+';document.body.innerHTML='+JSON.stringify(html)+';'+before);
    await evaluate(payload);
    const result=await evaluate('(async()=>{'+settle+body+'})()');
    report.tests.push({id,...result});
    await send('Target.closeTarget',{targetId});
  }
  await test('F09-prose-toggle',{surfaces:{prose:false,math:false}},'<p id="p">שלום עולם</p><div id="d">שלום עולם</div><span id="s">שלום עולם</span><label id="l">שלום עולם</label>','',
    'return {expected:"No prose element redirected",actual:Object.fromEntries(["p","d","s","l"].map(id=>[id,document.getElementById(id).getAttribute("dir")])),status:document.getElementById("d").dir==="rtl"?"REPRODUCED":"NOT REPRODUCED"};');
  await test('F09-table-reuse',{},'<table id="t"><thead><tr><th id="h">שם</th><th>תפקיד</th></tr></thead><tbody><tr><td>דוגמה</td><td>בודק</td></tr></tbody></table>','',
    'const t=document.getElementById("t"); const initial=t.dir; t.querySelectorAll("th,td").forEach((c,i)=>c.firstChild.nodeValue=["Name","Role","Example","Tester"][i]);'+settle+
    'const afterCharacterData=t.dir;document.body.appendChild(t);'+settle+
    'return {expected:"English table loses patch RTL and restores previous direction",actual:{initial,afterCharacterData,afterTableRescan:t.dir,cells:[...t.querySelectorAll("th,td")].map(c=>c.getAttribute("dir")),marker:t.getAttribute("data-codex-rtl-table")},status:t.dir==="rtl"?"REPRODUCED":"NOT REPRODUCED"};');
  await test('F09-table-streaming',{},'<table id="t"><thead><tr><th>Name</th><th>Role</th></tr></thead><tbody><tr><td>Example</td><td>Tester</td></tr></tbody></table>','',
    'const t=document.getElementById("t");const initial=t.getAttribute("dir");t.querySelectorAll("th,td").forEach((c,i)=>c.firstChild.nodeValue=["שם","תפקיד","דוגמה","בודק"][i]);'+settle+
    'const afterCharacterData=t.getAttribute("dir");const cells=[...t.querySelectorAll("th,td")].map(c=>c.dir);document.body.appendChild(t);'+settle+
    'return {expected:"Ancestor table reacts to streamed cell text",actual:{initial,afterCharacterData,cells,afterTableRescan:t.dir},status:afterCharacterData===null&&t.dir==="rtl"?"REPRODUCED":"NOT REPRODUCED"};');
  await test('F09-dir-ownership',{surfaces:{math:false}},'<p id="p" dir="ltr">שלום עולם</p>','',
    'const p=document.getElementById("p");const initial=p.dir;p.firstChild.nodeValue="Hello world";'+settle+
    'return {expected:"Restore original dir=ltr",actual:{initial,after:p.getAttribute("dir"),owned:p.hasAttribute("data-codex-rtl")},status:p.getAttribute("dir")===null?"REPRODUCED":"NOT REPRODUCED"};');
  await test('F09-math-node-identity',{},'<p id="p">שלום 2 + 3 = 5 סוף</p>','window.original=document.getElementById("p").firstChild;window.originalText=window.original.nodeValue;',
    'const p=document.getElementById("p");const before=p.textContent;const originalConnected=window.original.isConnected;window.original.nodeValue="שלום 4 + 5 = 9 סוף";'+settle+
    'return {expected:"Character data writer holding original node still updates visible text",actual:{originalConnected,before,after:p.textContent,heldNodeValue:window.original.nodeValue,islands:p.querySelectorAll("[data-codex-rtl-island]").length,textPreservedInitially:before===window.originalText},status:!originalConnected && p.textContent===before?"REPRODUCED":"NOT REPRODUCED",scope:"Retained text-node simulation, NOT React or target app crash"};');
  await test('F09-positive-controls',{surfaces:{math:false}},'<p id="p">שלום עולם</p><pre id="pre"><code id="c">שלום const x = 1</code></pre><div contenteditable="true" id="edit">שלום</div>','',
    'const p=document.getElementById("p");const c=document.getElementById("c");const e=document.getElementById("edit");const initial=p.dir;const codeText=c.textContent;p.firstChild.nodeValue="English";e.textContent="English";e.dispatchEvent(new Event("input",{bubbles:true}));'+settle+
    'return {expected:"Prose clears owned RTL; code stays LTR and unchanged; input reacts",actual:{initial,proseAfter:p.getAttribute("dir"),codeDirection:getComputedStyle(c).direction,codeUnchanged:c.textContent===codeText,inputDirection:e.dir},status:initial==="rtl"&&!p.hasAttribute("dir")&&getComputedStyle(c).direction==="ltr"&&e.dir==="ltr"?"PASS":"FAIL"};');
  await test('F09-disabled', {enabled:false}, '<p id="p">שלום 2 + 3 = 5 סוף</p>','window.original=document.getElementById("p").firstChild;',
    'return {expected:"Disabled payload leaves content and DOM unchanged",actual:{dir:document.getElementById("p").getAttribute("dir"),originalConnected:window.original.isConnected,style:!!document.getElementById("codex-rtl-patch-styles")},status:window.original.isConnected&&!document.getElementById("codex-rtl-patch-styles")?"PASS":"FAIL"};');
  report.browserErrors=errors;
  await send('Browser.close');
} catch(error){report.error=String(error);process.exitCode=1;}
finally {
  if(ws)ws.close();
  await new Promise(resolve=>{if(child.exitCode!==null)resolve();else{child.once('exit',resolve);setTimeout(()=>{child.kill();resolve();},3000).unref();}});
  fs.writeFileSync(path.join(here,'renderer-results.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  // Keep generated unique profiles out of evidence via .gitignore. No recursive cleanup.
}
