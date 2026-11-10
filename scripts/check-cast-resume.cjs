const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const state={PLAYBACK_STATE_PLAY:2,PLAYBACK_STATE_PAUSE:3,PLAYBACK_STATE_COMPLETED:8};
const avSession={PlaybackState:state,AVCastCategory:{CATEGORY_REMOTE:1}};
let disk='',timeout;let dlnaRead=async()=>{throw Error('no DLNA fixture')};
const store={getJson:()=>disk,putJson:(k,v)=>disk=v,remove:()=>disk=''};
const globals={console,DlnaProbe:{read:(...args)=>dlnaRead(...args)},Store:{shared:()=>store},AppStorage:{setOrCreate:()=>{}},avSession,setTimeout:fn=>{timeout=fn;return 1},clearTimeout:()=>{}};
const raw=fs.readFileSync('entry/src/main/ets/common/CastResume.ets','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'');
const compiled=ts.transpile(raw,{target:ts.ScriptTarget.ES2020})+'\nCastResume';
const C=vm.runInNewContext(compiled,{...globals});
const last={deviceId:'tv1',deviceName:'TV',assetId:'libretv:source:film:0',mediaUri:'https://example.com/video',record:{sourceKey:'source',vodId:'film',episode:0,positionMs:600000}};
async function run(){
 C.save(last);
 const reboot=vm.runInNewContext(compiled,{...globals});assert.equal(reboot.load().record.positionMs,600000);
 const controller={getCurrentItem:async()=>({description:{mediaUri:last.mediaUri}}),getAVPlaybackState:async()=>({state:2,position:{elapsedTime:900000},duration:3600000})};
 assert.equal((await reboot.read(controller,reboot.load(),'tv1')).position.elapsedTime,900000);
 await assert.rejects(()=>C.read(controller,last,'tv2'));
 const foreign={...controller,getCurrentItem:async()=>({description:{mediaUri:'https://example.com/other',assetId:'different'}})};
 await assert.rejects(()=>C.read(foreign,last,'tv1'));
 await assert.rejects(()=>C.read({...controller,getCurrentItem:async()=>({})},last,'tv1'));
 await assert.rejects(()=>C.read({...controller,getAVPlaybackState:async()=>({state:6,position:{elapsedTime:0}})},last,'tv1'));
 const hung=C.read({...controller,getCurrentItem:()=>new Promise(()=>{})},last,'tv1');timeout();await assert.rejects(()=>hung);
 const s=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
 const method=s.slice(s.indexOf('  private async connectRemote('),s.indexOf('  private rememberCast('));
 const P=vm.runInNewContext(ts.transpile('class P {\n'+method+'\n}',{target:ts.ScriptTarget.ES2020})+'\nP',{console,SleepTimer:{selectedMinutes:()=>-999},NativeCastControl:class {constructor(value){return value}},DlnaProbe:{read:async()=>{throw Error('not direct in this fixture')}},CastResume:reboot,avSession,Utils:{formatTime:()=>''}});
 let stops=0,starts=0,remoteChanged;
 function player(){const p=new P();p.endPress=()=>{};p.releasePiP=()=>{};p.clearPauseHint=()=>{};p.castGeneration=0;p.released=false;p.offlineDir='';p.restoreCast=true;p.castController=null;p.localResumePending=true;
 p.player={pause:()=>{}};
 for(const k of ['applyCastRotation','clearPressTimer','endAdjust','clearWatchdog','clearLoadingTimer','clearResync','clearStall','rememberCast','dropScreen','toast','startCastPolling'])p[k]=()=>{};
 p.applySeekUi=ms=>p.positionMs=ms;p.startRemotePlayback=async()=>{starts++;return true};return p;}
 const session={getAVCastController:async()=>({...controller,on:(name,filter,callback)=>{if(name==='playbackStateChange')remoteChanged=callback;}}),stopCasting:async()=>stops++};
 const device={devices:[{castCategory:1,deviceId:'tv1',deviceName:'TV'}]};
 const p=player();await p.connectRemote(session,device);assert.equal(p.restoreCast,false);assert.equal(p.positionMs,900000);assert.equal(p.playing,true);assert.equal(starts,0);assert.equal(stops,0);
 p.castDisconnecting=true;p.completePlayback=()=>{throw Error('must not advance during disconnect')};
 remoteChanged({state:8,position:{elapsedTime:0},duration:0});assert.equal(p.positionMs,900000);assert.equal(p.durationMs,3600000);p.castDisconnecting=false;
 const automatic=player();automatic.restoreCast=false;automatic.sourceKey='source';automatic.vodId='film';automatic.currentEp=0;
 await automatic.connectRemote(session,device);assert.equal(automatic.positionMs,900000);assert.equal(starts,0);assert.equal(stops,0);
 const mismatch=player();await mismatch.connectRemote({...session,getAVCastController:async()=>({...foreign,on:()=>{}})},device);
 assert.equal(mismatch.restoreCast,true);assert.equal(mismatch.castController,null);assert.equal(starts,0);assert.equal(stops,0);
 dlnaRead=async()=>({mediaUri:last.mediaUri,state:{state:2,position:{elapsedTime:1200000},duration:2267000}});
 const uncached={...controller,getCurrentItem:async()=>{throw Error('system cache empty')}};
 assert.equal((await C.read(uncached,last,'tv1')).position.elapsedTime,1200000);
 assert.equal((await C.read(uncached,last,'changed-id','TV')).position.elapsedTime,1200000);
 let pos=0,reads=0,seeks=0;
 C.current=async()=>({state:2,position:{elapsedTime:(pos+=1000)},duration:++reads<3?0:2267000});
 const timerSave=globals.setTimeout; // synchronize waits use the test timer; explicitly release each retry.
 const syncing=C.synchronize({sendControlCommand:async command=>{assert.equal(command.command,'seek');pos=command.parameter;seeks++;}},last.mediaUri,last.assetId,'TV',600000,()=>true);
 for(let i=0;i<60;i++){await new Promise(r=>setImmediate(r));if(timeout)timeout();}
 const synced=await syncing;assert.ok(synced.position.elapsedTime>=600000);assert.equal(synced.duration,2267000);assert.equal(seeks,1);
 const positions=[0,1000,600000,600000,0,1000,1000,2000,600000,601000,602000];let sample=0,retries=0;
 C.current=async()=>({state:2,position:{elapsedTime:positions[Math.min(sample++,positions.length-1)]},duration:2267000});
 const delayed=C.synchronize({sendControlCommand:async()=>{retries++;}},last.mediaUri,last.assetId,'TV',600000,()=>true);
 for(let i=0;i<60;i++){await new Promise(r=>setImmediate(r));if(timeout)timeout();}
 const confirmed=await delayed;assert.equal(confirmed.position.elapsedTime,602000);assert.equal(retries,2);assert.equal(sample,11);
 const loading=[0,0,0,600000,600000,600000,600000,0,0,1000,600000,601000,602000];let loadingRead=0,lateSeeks=0;
 C.current=async()=>({state:2,position:{elapsedTime:loading[Math.min(loadingRead++,loading.length-1)]},duration:2267000});
 const loadingSync=C.synchronize({sendControlCommand:async()=>{lateSeeks++;assert.ok(loadingRead>=10,'wait for actual playback before seeking');}},last.mediaUri,last.assetId,'TV',600000,()=>true);
 for(let i=0;i<60;i++){await new Promise(r=>setImmediate(r));if(timeout)timeout();}
 assert.equal((await loadingSync).position.elapsedTime,602000);assert.equal(lateSeeks,1);
 C.current=async()=>({state:2,position:{elapsedTime:1000},duration:2267000});
 const manual=await C.synchronize({sendControlCommand:async()=>{throw Error('must not override manual control')}},last.mediaUri,last.assetId,'TV',600000,()=>true,()=>false);
 assert.equal(manual.position.elapsedTime,1000);
 assert.equal(await C.synchronize({},last.mediaUri,last.assetId,'TV',600000,()=>false),null);
 C.clear();assert.equal(reboot.load(),null);disk='broken';assert.equal(C.load(),null);
 console.log('PASS: persisted cast survives a new process; reattach adopts TV progress without start/stop; wrong device/content, missing state, corrupt storage and timeout fail safely.');
}
run().catch(e=>{console.error(e);process.exitCode=1});
