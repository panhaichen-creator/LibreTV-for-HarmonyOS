const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const raw=fs.readFileSync('entry/src/main/ets/common/CastControl.ets','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'');
let uri='https://example.com/first',state=2,timers=[],commands=[],offline=false;
const D=vm.runInNewContext(ts.transpile(raw,{target:ts.ScriptTarget.ES2020})+'\nDlnaControl',{
 console,setTimeout:fn=>{timers.push(fn);return timers.length},clearTimeout:()=>{},avSession:{PlaybackState:{PLAYBACK_STATE_STOP:6,PLAYBACK_STATE_COMPLETED:8}},
 DlnaProbe:{read:async()=>{if(offline)throw Error('offline');return {mediaUri:uri,state:{state,position:{elapsedTime:5000},duration:10000}}},command:async(name,command,param,media)=>{commands.push({command,param});if(command==='load')uri=media}}
});
(async()=>{
 const c=new D('TV',uri,'film:0');assert.equal(commands.length,0);
 const item=await c.getCurrentItem();assert.equal(item.description.duration,10000);
 await c.sendControlCommand({command:'seek',parameter:7000});assert.equal(commands.at(-1).param,7000);
 await c.sendControlCommand({command:'pause'});assert.equal(commands.at(-1).command,'pause');
 uri='https://example.com/other';await assert.rejects(()=>c.sendControlCommand({command:'seek',parameter:1000}));assert.equal(commands.length,2);
 const ep={description:{mediaUri:'https://example.com/next',assetId:'film:1'}};await c.prepare(ep);assert.equal(commands.length,2);
 await c.start(ep);assert.deepEqual(commands.slice(-2).map(x=>x.command),['load','play']);
 let events=0;c.on('playbackStateChange','all',()=>events++);await timers.at(-1)();assert.equal(events,1);
 const queued=timers.at(-1);c.off('playbackStateChange');await queued();assert.equal(events,1);
 let errors=0;c.on('error',error=>{assert.equal(error.code,6600001);errors++});
 c.on('playbackStateChange','all',()=>events++);offline=true;
 await timers.at(-1)();await timers.at(-1)();assert.equal(errors,0);
 offline=false;await timers.at(-1)();offline=true;
 await timers.at(-1)();await timers.at(-1)();assert.equal(errors,0);
 await timers.at(-1)();assert.equal(errors,1);
 const count=timers.length;await timers.at(-1)();assert.equal(errors,1);assert.equal(timers.length,count);
 console.log('PASS: reattached controller sends real seek/pause, verifies content before commands, loads episodes only on explicit start and stops callbacks after release.');
})().catch(e=>{console.error(e);process.exitCode=1});
