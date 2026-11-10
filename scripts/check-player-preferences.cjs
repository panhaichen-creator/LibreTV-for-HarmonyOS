const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
let disk='';const types=fs.readFileSync('entry/src/main/ets/model/Types.ets','utf8');
const defaults=types.slice(types.indexOf('export const DEFAULT_SETTINGS:')).split('\n};')[0]+'\n};';
const raw=fs.readFileSync('entry/src/main/ets/data/SettingsStore.ets','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'');
function fresh(){return vm.runInNewContext(ts.transpile(defaults.replace('export ','')+'\n'+raw,{target:ts.ScriptTarget.ES2020})+'\nSettingsStore.shared()',{Store:{shared:()=>({getJson:()=>disk,putJson:(k,v)=>disk=v})},EventBus:{emit:()=>{}},Events:{SETTINGS_CHANGED:'settings'}})}
let store=fresh();assert.equal(store.get().rememberSpeed,false);assert.equal(store.get().longPressSpeed,3);assert.equal(store.get().playerRotation,'landscape');
store.update({rememberSpeed:true,lastSpeed:1.5,longPressSpeed:2,playerRotation:'auto'});
store=fresh();assert.equal(store.get().lastSpeed,1.5);assert.equal(store.get().longPressSpeed,2);assert.equal(store.get().playerRotation,'auto');
store.update({lastSpeed:99,longPressSpeed:99,playerRotation:'bad'});assert.equal(store.get().lastSpeed,1.5);assert.equal(store.get().longPressSpeed,2);assert.equal(store.get().playerRotation,'auto');
disk='{"defaultSpeed":1.25}';store=fresh();assert.equal(store.get().defaultSpeed,1.25);assert.equal(store.get().rememberSpeed,false);
console.log('PASS: player preferences survive restart, old settings migrate and invalid values are rejected.');
