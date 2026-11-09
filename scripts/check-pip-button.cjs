const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./test-typescript.cjs');
const source = fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
function section(a,b){return source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));}
const methods=section('  private async enterPiP()', '  private releasePiP()')+
  section('  aboutToDisappear()', '  /** 清理动作逐个隔离')+
  section('  private onPiPStateChange(', '  private onPiPControlEvent(');
const lifecycle={};
const states={STARTED:1,ABOUT_TO_STOP:2,STOPPED:3,ABOUT_TO_RESTORE:4,ERROR:5};
const Player = vm.runInNewContext(ts.transpile('class Player {\n'+methods+'\n}',{target:ts.ScriptTarget.ES2020})+'\nPlayer',{console,AppLifecycle:lifecycle,PiPWindow:{PiPState:states}});
function player(){
  const p=new Player();p.calls=[];p.castController=null;p.released=false;p.offlineDir='';
  p.navPathStack={clear:animated=>p.calls.push('home')};
  p.player={pause:()=>p.calls.push('pause'),isPlaying:()=>true};
  for(const key of ['dismissPlayerControls','saveProgress','restoreWindowState','restoreBrightness','dropScreen','applyWindowFullScreen','setLandscape','applyLocalRotation','holdScreen','releaseCastSession','clearStall','clearWatchdog','clearAdjustTimer','clearPressTimer','endPress','resumeAfterPiPRestore','releasePiP'])p[key]=()=>p.calls.push(key);
  p.release=()=>{p.released=true;p.calls.push('release')};p.safeStep=(name,fn)=>fn();p.toast=()=>p.calls.push('toast');
  p.pipController={startPiP:async()=>{p.calls.push('start')}};
  return p;
}
async function run() {
  const p=player();let finish;
  p.pipController.startPiP=async()=>{p.calls.push('start');await new Promise(r=>finish=r)};
  const pending=p.enterPiP();await p.enterPiP();assert.deepEqual(p.calls,['start']);
  finish();await pending;assert.equal(p.pipStarting,false);assert.equal(p.pipBrowsing,true);
  assert.equal(p.calls.at(-1),'home');assert.equal(p.calls.includes('release'),false);
  p.aboutToDisappear();assert.equal(p.calls.includes('release'),false);
  assert.equal(typeof lifecycle.closeInAppPiP,'function');
  p.onPiPStateChange(states.ABOUT_TO_RESTORE,'panelActionRestore');
  assert.equal(p.pipBrowsing,false);assert.equal(lifecycle.closeInAppPiP,null);
  assert.ok(p.calls.includes('applyWindowFullScreen'));assert.ok(p.calls.includes('holdScreen'));
  p.onPiPStateChange(states.STOPPED,'panelActionRestore');assert.ok(p.calls.includes('resumeAfterPiPRestore'));
  const closed=player();await closed.enterPiP();closed.onPiPStateChange(states.STOPPED,'panelActionDelete');
  assert.equal(closed.released,true);assert.equal(closed.pipBrowsing,false);assert.equal(lifecycle.closeInAppPiP,null);
  const replaced=player();await replaced.enterPiP();lifecycle.closeInAppPiP();assert.equal(replaced.released,true);
  for(const field of ['castController','released','pipActive','pipStarting']){
    const blocked=player();blocked[field]=true;await blocked.enterPiP();assert.equal(blocked.calls.length,0);
  }
  const casting=player();casting.castController={};casting.onPiPStateChange(states.STARTED,'auto');assert.deepEqual(casting.calls,['releasePiP']);assert.ok(!casting.pipActive);
  const failed=player();failed.pipController.startPiP=async()=>{throw Error('unavailable')};
  await failed.enterPiP();assert.deepEqual(failed.calls,['toast']);assert.equal(failed.pipStarting,false);assert.ok(!failed.pipBrowsing);
  console.log('PASS: in-app PiP retains playback on home; restore reuses the page; close/replacement clean up; failure stays on player and duplicate starts are blocked.');
}
run().catch(e=>{console.error(e);process.exitCode=1});
