const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const source=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const method=source.slice(source.indexOf('  private async setNavigationIndicatorVisible('),source.indexOf('  private setLandscape('));
let resolveWindow,calls=[];
const win={setSpecificSystemBarEnabled:async(...args)=>calls.push(args)};
const P=vm.runInNewContext(ts.transpile('class P{'+method+'}',{target:ts.ScriptTarget.ES2020})+'\nP',{console,window:{getLastWindow:()=>new Promise(resolve=>resolveWindow=resolve)}});
(async()=>{
 const p=new P();p.win=win;await p.setNavigationIndicatorVisible(false);await p.setNavigationIndicatorVisible(true);
 assert.deepEqual(calls.map(x=>[...x]),[['navigationIndicator',false,false],['navigationIndicator',true,false]]);
 p.win=null;p.getUIContext=()=>({getHostContext:()=>({})});const pending=p.setNavigationIndicatorVisible(false);
 p.win=win;await p.setNavigationIndicatorVisible(true);resolveWindow(win);await pending;
 assert.equal(calls.length,3);assert.equal(calls.at(-1)[1],true);
 assert.match(source,/private restoreWindowState\(\): void \{\s*this.setNavigationIndicatorVisible\(true\)/);
 assert.match(source,/private applyWindowFullScreen\(on: boolean\): void \{\s*if \(this.released\) \{ return; \}\s*this.setNavigationIndicatorVisible\(!on\)/);
 console.log('PASS: playback hides the indicator; exit restores it; late window lookup cannot hide it again.');
})().catch(e=>{console.error(e);process.exitCode=1});
