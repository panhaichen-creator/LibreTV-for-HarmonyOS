const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const source=fs.readFileSync('entry/src/main/ets/common/CastBackgroundTask.ets','utf8').replace(/^import .*;$/gm,'').replace('export class','class');
let release,failStop=false,starts=0,stops=0;const events=[];
const context={abilityInfo:{bundleName:'com.example.upstream',name:'CustomAbility'}};
const C=vm.runInNewContext(ts.transpile(source,{target:ts.ScriptTarget.ES2020})+'\nCastBackgroundTask',{
 wantAgent:{getWantAgent:async info=>{assert.equal(info.wants[0].bundleName,context.abilityInfo.bundleName);assert.equal(info.wants[0].abilityName,context.abilityInfo.name);return {};},OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1}},
 backgroundTaskManager:{BackgroundMode:{AUDIO_PLAYBACK:2},startBackgroundRunning:async()=>{starts++;events.push('start');await new Promise(resolve=>release=resolve);},stopBackgroundRunning:async()=>{stops++;events.push('stop');if(failStop)throw Error('stop failed');}}
});
(async()=>{
 const start=C.start(context),stop=C.stop();await new Promise(setImmediate);assert.equal(stops,0);release();await Promise.all([start,stop]);assert.deepEqual(events,['start','stop']);
 const a=C.start(context),b=C.start(context);await new Promise(setImmediate);release();await Promise.all([a,b]);assert.equal(starts,2);
 failStop=true;await assert.rejects(()=>C.stop());failStop=false;await C.stop();assert.equal(stops,3);
 await C.stop();assert.equal(stops,3);
 const retry=C.start(context);await new Promise(setImmediate);release();await retry;await C.stop();
 console.log('PASS: background task uses actual app identity, serializes start/stop, deduplicates starts and permits stop retry.');
})().catch(e=>{console.error(e);process.exitCode=1});
