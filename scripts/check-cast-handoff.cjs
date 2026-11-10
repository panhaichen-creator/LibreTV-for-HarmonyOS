const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./test-typescript.cjs');
const source = fs.readFileSync('entry/src/main/ets/common/CastHandoff.ets', 'utf8').replace(/^import .*;$/gm, '').replace(/export /g, '');
const storage = new Map();
let saves = 0, destroyed = 0, stopped = 0, bgStopped = 0, snapshot=null;
let selectedMinutes=15;
const sleepTimer={cancel:()=>{selectedMinutes=-999;},completed:()=>false,selectedMinutes:()=>selectedMinutes};
const C = vm.runInNewContext(ts.transpile(source, {target: ts.ScriptTarget.ES2020}) + '\nCastHandoff', {
  SleepTimer:sleepTimer,
  CastBackgroundTask:{stop:async()=>{bgStopped++;}},
  CastResume: {save:value=>snapshot=value,clear:()=>snapshot=null},
  AppStorage: {setOrCreate: (k,v) => storage.set(k,v)}, console, Date,
  SettingsStore: {shared: () => ({get: () => ({playHistoryEnabled:true, autoNext:false})})},
  HistoryStore: {shared: () => ({saveProgress: () => saves++})},
  avSession: {AVCastCategory:{CATEGORY_REMOTE:1}, ConnectionState:{STATE_DISCONNECTED:0},PlaybackState:{PLAYBACK_STATE_PLAY:2, PLAYBACK_STATE_COMPLETED:6}}
});
const handlers = {};
const controller = {sendControlCommand: async command => {assert.equal(command.command, 'stop');}, off:k=>delete handlers[k], on:(k,...args)=>handlers[k]=args.at(-1)};
const session = {off:k=>delete handlers[k], on:(k,fn)=>handlers[k]=fn, destroy:async()=>destroyed++,stopCasting:async()=>stopped++};
const value = {device:{devices:[{castCategory:1,deviceId:'tv',deviceName:'TV'}]},mediaUri:'https://example.com/v',session,controller,deviceName:'TV',record:{positionMs:0,durationMs:10000},episodes:[]};
async function run() {
  C.park(value);
  handlers.playbackStateChange({position:{elapsedTime:5000},volume:25});
  assert.equal(value.record.positionMs,5000); assert.equal(value.volume,25);
  assert.equal(storage.get('activeCastLabel'),'TV');
  assert.equal(C.take(),value); assert.equal(destroyed,0); assert.equal(stopped,0);
  assert.equal(selectedMinutes,15);assert.equal(bgStopped,0);assert.ok(sleepTimer.action);
  assert.equal(storage.get('activeCastLabel'),'');
  C.park(value);
  handlers.outputDeviceChange(0,{devices:[]});
  await new Promise(setImmediate);
  assert.equal(C.peek(),null); assert.equal(destroyed,1); assert.ok(saves>=2);
  assert.equal(selectedMinutes,-999);assert.equal(sleepTimer.action,null);assert.equal(bgStopped,1);
  selectedMinutes=15;
  C.park(value); await C.stop();
  assert.equal(stopped,1); assert.equal(bgStopped,2); assert.equal(C.peek(),null);assert.equal(snapshot,null);
  selectedMinutes=15;
  C.park(value);handlers.error({code:6600001});await new Promise(setImmediate);assert.equal(C.peek(),null);assert.equal(storage.get('activeCastLabel'),'');assert.ok(snapshot);
  assert.equal(selectedMinutes,-999);assert.equal(sleepTimer.action,null);assert.equal(bgStopped,3);
  selectedMinutes=15;
  C.park(value);const original=controller.sendControlCommand;
  controller.sendControlCommand=async()=>{throw Error('stop rejected')};
  await assert.rejects(()=>C.stop());assert.equal(C.peek(),value);assert.ok(snapshot);
  assert.equal(bgStopped,3);assert.equal(selectedMinutes,15);assert.ok(sleepTimer.action);
  await C.leaveRemotePlaying();assert.equal(C.peek(),null);assert.ok(snapshot);controller.sendControlCommand=original;
  assert.equal(selectedMinutes,-999);assert.equal(sleepTimer.action,null);assert.equal(bgStopped,4);
  C.park(value);selectedMinutes=-999;controller.sendControlCommand=async()=>{throw Error('timer stop rejected')};
  await assert.rejects(()=>sleepTimer.action());assert.equal(bgStopped,5);assert.equal(C.peek(),value);
  controller.sendControlCommand=original;
  const destroy=session.destroy;session.destroy=async()=>{throw Error('destroy rejected')};
  await assert.rejects(()=>C.leaveRemotePlaying());assert.equal(bgStopped,6);assert.equal(C.peek(),null);
  session.destroy=destroy;
  console.log('PASS: parked session keeps progress, resume transfers ownership without disconnecting, remote disconnect and explicit stop clean up');
}
run().catch(e=>{console.error(e);process.exitCode=1});
