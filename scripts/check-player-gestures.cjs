const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./test-typescript.cjs');
const source = fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const methods = source.slice(source.indexOf('  private clearPressTimer()'), source.indexOf('  private pressSpeedLabel()')) +
  source.slice(source.indexOf('  private beginAdjust('),source.indexOf('  /** 抬手：浮层'));
let id=0;const timers=new Map();
const P=vm.runInNewContext(ts.transpile('class PlayerPage { static PRESS_DELAY_MS=600; static PRESS_SPEED=3; static SEEK_FULL_SPAN_MS=300000;\n'+methods+'\n}',{target:ts.ScriptTarget.ES2020})+'\nPlayerPage',{
  TouchType:{Down:0,Move:1,Up:2,Cancel:3},
  setTimeout:fn=>{timers.set(++id,fn);return id},clearTimeout:id=>timers.delete(id)
});
function create() {
  const p=new P();p.settings={longPressSpeed:3};p.castController=null;p.screenLocked=false;p.errorText='';p.canvasW=1000;p.durationMs=600000;p.playing=true;p.pressTimer=-1;
  p.seekPreviewTimer=-1;p.hideTimer=-1;p.controlsVisible=true;p.adjustKind='';p.speedValue=1;
  p.seeks=[];p.speeds=[];p.player={currentTime:()=>120000,seekTo:t=>p.seeks.push(t),setSpeed:s=>p.speeds.push(s)};
  p.dismissPlayerControls=()=>{p.controlsVisible=false;p.showSpeeds=false;p.showEpisodes=false;p.showSources=false};p.clearPauseHint=()=>{};p.applySeekUi=()=>{};p.hides=0;p.scheduleHideControls=()=>p.hides++;p.clearAdjustTimer=()=>{};
  p.currentBrightness=()=>0.5;p.applyBrightness=()=>{throw Error('horizontal gesture must not change brightness')};
  p.adjustRange=()=>500;
  return p;
}
function touch(p,type,x,y) {p.handlePressTouch({type,touches:[{x,y}]})}
for(const x of [50,500,950]) {
  const p=create();touch(p,0,x,100);touch(p,1,x+30,101);
  assert.equal(p.touchAxis,'horizontal');assert.equal(p.seekPreviewVisible,true);assert.equal(p.pressTimer,-1);
  p.beginAdjust(x);assert.equal(p.adjustKind,'');
  touch(p,1,x+30,250);assert.equal(p.touchAxis,'horizontal');
  touch(p,2,x+30,250);assert.equal(p.seeks.length,1);
}
const vertical=create();touch(vertical,0,50,100);touch(vertical,1,51,130);touch(vertical,1,150,131);touch(vertical,2,150,131);
assert.equal(vertical.hides,1);assert.equal(vertical.touchAxis,'vertical');assert.equal(vertical.seeks.length,0);assert.equal(vertical.pressTimer,-1);
const fast=create();touch(fast,0,50,100);const timer=timers.get(fast.pressTimer);timer();
assert.equal(fast.pressSpeed,true);assert.equal(fast.controlsVisible,false);touch(fast,1,150,250);fast.beginAdjust(50);assert.equal(fast.adjustKind,'');touch(fast,2,150,250);
assert.equal(fast.hides,0);assert.equal(fast.controlsVisible,false);assert.deepEqual(fast.speeds,[3,1]);assert.equal(fast.seeks.length,0);
const cancelled=create();touch(cancelled,0,950,100);touch(cancelled,1,900,100);touch(cancelled,3,900,100);assert.equal(cancelled.seeks.length,0);assert.equal(cancelled.hides,1);
const interrupted=create();interrupted.speedValue=1.5;touch(interrupted,0,50,100);timers.get(interrupted.pressTimer)();interrupted.endPress(true);assert.deepEqual(interrupted.speeds,[3,1.5]);assert.equal(interrupted.controlsVisible,false);
console.log('PASS: all screen regions seek horizontally; direction stays locked; long press and cancelled touches do not seek or adjust brightness/volume.');
