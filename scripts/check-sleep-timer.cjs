const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
let now=0,next=0,calls=0,labels=[];const timers=new Map();
const raw=fs.readFileSync('entry/src/main/ets/common/SleepTimer.ets','utf8').replace('export class','class');
const S=vm.runInNewContext(ts.transpile(raw,{target:ts.ScriptTarget.ES2020})+'\nSleepTimer',{Date:{now:()=>now},setTimeout:fn=>{timers.set(++next,fn);return next},clearTimeout:id=>timers.delete(id),AppStorage:{setOrCreate:(k,v)=>labels.push(v)}});
(async()=>{
 S.action=async()=>calls++;
 S.set(15);assert.equal(S.label(),'15 分钟后停止');assert.equal(S.selectedMinutes(),15);now=15*60000;S.check();await Promise.resolve();assert.equal(calls,1);S.check();assert.equal(calls,1);assert.equal(S.selectedMinutes(),-999);
 S.set(30);S.cancel();now+=60*60000;S.check();assert.equal(calls,1);
 S.set(-1);assert.equal(S.selectedMinutes(),-1);assert.equal(S.completed(),true);await Promise.resolve();assert.equal(calls,2);assert.equal(S.completed(),false);
 S.action=async()=>{throw Error('stop failed')};S.set(15);now+=15*60000;S.check();await Promise.resolve();await Promise.resolve();assert.equal(labels.at(-1),'停止失败，请返回遥控重试');
 console.log('PASS: sleep deadline fires once; cancellation, episode end and stop failure are handled.');
})().catch(e=>{console.error(e);process.exitCode=1});
