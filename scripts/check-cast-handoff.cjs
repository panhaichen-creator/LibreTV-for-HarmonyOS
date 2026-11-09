const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./test-typescript.cjs');
const source = fs.readFileSync('entry/src/main/ets/common/CastHandoff.ets', 'utf8').replace(/^import .*;$/gm, '').replace(/export /g, '');
const storage = new Map();
let saves = 0, destroyed = 0, stopped = 0, snapshot=null;
const C = vm.runInNewContext(ts.transpile(source, {target: ts.ScriptTarget.ES2020}) + '\nCastHandoff', {
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
  assert.equal(storage.get('activeCastLabel'),'');
  C.park(value);
  handlers.outputDeviceChange(0,{devices:[]});
  assert.equal(C.peek(),null); assert.equal(destroyed,1); assert.ok(saves>=2);
  C.park(value); await C.stop();
  assert.equal(stopped,1); assert.equal(C.peek(),null);assert.equal(snapshot,null);
  C.park(value);handlers.error({code:6600001});assert.equal(C.peek(),null);assert.equal(storage.get('activeCastLabel'),'');assert.ok(snapshot);
  console.log('PASS: parked session keeps progress, resume transfers ownership without disconnecting, remote disconnect and explicit stop clean up');
}
run().catch(e=>{console.error(e);process.exitCode=1});
