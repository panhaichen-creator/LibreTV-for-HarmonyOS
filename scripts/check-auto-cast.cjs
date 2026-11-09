const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const s=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const methods=s.slice(s.indexOf('  private prepareCastRecovery()'),s.indexOf('  private recoverCast()'));
const snapshot={deviceId:'tv',deviceName:'TV',mediaUri:'https://example.com/video',assetId:'film:8',record:{sourceKey:'s',vodId:'v',episode:8,positionMs:600000,durationMs:2000000}};
let remoteUri=snapshot.mediaUri,cleared=0,pendingRead=null;
const P=vm.runInNewContext(ts.transpile('class P{'+methods+'}',{target:ts.ScriptTarget.ES2020})+'\nP',{
 CastResume:{load:()=>snapshot,clear:()=>cleared++},DlnaProbe:{read:async()=>pendingRead !== null ? pendingRead : ({mediaUri:remoteUri})},DlnaControl:class{direct=true},Utils:{formatTime:String},console,
 avSession:{DeviceType:{DEVICE_TYPE_TV:2},AVCastCategory:{CATEGORY_REMOTE:1}}
});
function player(){const p=new P();p.offlineDir='';p.sourceKey='s';p.vodId='v';p.currentEp=0;p.castSession={};p.castGeneration=0;p.connectRemote=async(session,device,controller)=>{p.attached=controller};return p;}
(async()=>{
 const p=player();p.prepareCastRecovery();assert.equal(p.restoreCast,true);assert.equal(p.currentEp,8);assert.equal(p.durationMs,2000000);
 await p.autoRestoreCast();assert.equal(p.attached.direct,true);
 const other=player();other.vodId='other';other.prepareCastRecovery();assert.ok(!other.restoreCast);
 const offline=player();offline.offlineDir='download';offline.prepareCastRecovery();assert.ok(!offline.restoreCast);
 remoteUri='https://example.com/other';const mismatch=player();mismatch.prepareCastRecovery();await mismatch.autoRestoreCast();assert.ok(!mismatch.attached);assert.equal(mismatch.restoreCast,true);
 const phone=player();phone.prepareCastRecovery();phone.localResumePending=true;phone.resumePlayback=()=>{phone.started=true};
 phone.playOnPhone();assert.equal(phone.restoreCast,false);assert.equal(phone.localResumePending,false);assert.equal(phone.started,true);assert.equal(cleared,1);
 assert.match(s,/@State restoreCast: boolean = false/);
 // A late TV response must not reclaim playback after choosing the phone.
 let finishRead;pendingRead=new Promise(resolve=>finishRead=resolve);
 const late=player();late.prepareCastRecovery();late.resumePlayback=()=>{};
 const recovery=late.autoRestoreCast();late.playOnPhone();finishRead({mediaUri:snapshot.mediaUri});await recovery;
 assert.ok(!late.attached);assert.equal(late.restoreCast,false);pendingRead=null;
 const recast=s.slice(s.indexOf('  private confirmRecast()'),s.indexOf('  @Builder',s.indexOf('  private confirmRecast()')));
 const R=vm.runInNewContext(ts.transpile('class R{'+recast+'}',{target:ts.ScriptTarget.ES2020})+'\nR',{CastResume:{clear:()=>cleared++}});
 const r=new R();r.castSession={};r.castDevice={};r.castGeneration=0;r.restoreCast=true;
 r.getUIContext=()=>({getPromptAction:()=>({showDialog:async()=>({index:1})})});
 r.connectRemote=()=>{assert.equal(r.restoreCast,false);assert.equal(cleared,3);r.connected=true};
 r.confirmRecast();await Promise.resolve();assert.equal(r.connected,true);
 console.log('PASS: reopening the same movie restores its TV episode and duration, attaches controls without replay; other/offline movies stay local and foreign TV content is not taken over.');
})().catch(e=>{console.error(e);process.exitCode=1});
