const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const source=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const method=source.slice(source.indexOf('  private async initCastSession()'),source.indexOf('  private bindCastSession('));
let calls=[],fail=false;
const session={setAVMetadata:async()=>{calls.push('metadata');if(fail)throw Error('metadata failure')},setExtras:async()=>calls.push('extras'),setAVPlaybackState:async state=>{calls.push('state');assert.equal(state.state,3);assert.equal(state.position.elapsedTime,10000)},activate:async()=>calls.push('activate'),destroy:async()=>calls.push('destroy')};
const P=vm.runInNewContext(ts.transpile('class P{'+method+'}',{target:ts.ScriptTarget.ES2020})+'\nP',{console,avSession:{createAVSession:async()=>session,ProtocolType:{TYPE_CAST_PLUS_STREAM:1,TYPE_DLNA:2},PlaybackState:{PLAYBACK_STATE_PAUSE:3,PLAYBACK_STATE_PLAY:2}}});
function player(){const p=new P();p.castSession=null;p.released=false;p.title='test';p.vodId='test';p.positionMs=10000;p.durationMs=0;p.restoreCast=true;p.getUIContext=()=>({getHostContext:()=>({})});p.bindCastSession=()=>calls.push('listen');p.autoRestoreCast=()=>{};return p;}
(async()=>{const p=player();await p.initCastSession();assert.deepEqual(calls,['metadata','extras','listen','state','activate']);assert.equal(p.castSessionReady,true);
 calls=[];fail=true;const bad=player();await bad.initCastSession();assert.equal(bad.castSession,null);assert.equal(bad.castSessionReady,false);assert.ok(calls.includes('destroy'));assert.ok(bad.castRestoreStatus.includes('重试'));
 console.log('PASS: restore-only session publishes paused playback before activation; picker is enabled only after success; failed initialization cleans up and permits retry.');
})().catch(e=>{console.error(e);process.exitCode=1});
