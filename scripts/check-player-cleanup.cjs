const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const s=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const part=(a,b)=>s.slice(s.indexOf(a),s.indexOf(b,s.indexOf(a)));
const methods=part('  private resumePlayback(', '  /**\n   * 交还窗口状态')+
 part('  private release():', '  private clearLoadingTimer(')+
 part('  private dismissPlayerControls()', '  private onSurfaceDestroy(')+
 part('  private selectSpeed(', '  private async runSpeedTest(');
let id=0;const timers=new Map();
const P=vm.runInNewContext(ts.transpile('class P{'+methods+'}',{target:ts.ScriptTarget.ES2020})+'\nP',{console,AppLifecycle:{},CastHandoff:{peek:()=>null},SleepTimer:{cancel:()=>{}},setTimeout:fn=>{timers.set(++id,fn);return id},clearTimeout:key=>timers.delete(key)});
function player(){const p=new P();p.settings={rememberSpeed:false};p.released=false;p.pipBrowsing=false;p.castController=null;p.controlsVisible=true;p.playing=true;
 p.hideTimer=-1;p.resumeTimer=-1;p.holderFile=null;p.showSpeeds=false;p.showEpisodes=false;p.showSources=false;
 p.player={release:()=>{},setSpeed:()=>{}};p.xController={getXComponentSurfaceId:()=>''};
 for(const key of ['clearPauseHint','unwatchPlayerInsets','dropScreen','clearPressTimer','clearResync','clearBgTimer','releasePiP'])p[key]=()=>{};
 return p;}
const p=player();p.resumePlayback(3);const pending=p.resumeTimer;const late=timers.get(pending);assert.ok(late);
p.release();assert.equal(timers.has(pending),false);p.xController.getXComponentSurfaceId=()=>{throw Error('released player must not read surface')};late();
p.applyWindowFullScreen=()=>{throw Error('must not change window after exit')};p.applyLocalRotation=p.applyWindowFullScreen;p.onSurfaceReady('late');
const pip=player();pip.pipBrowsing=true;pip.applyWindowFullScreen=p.applyWindowFullScreen;pip.onSurfaceReady('pip');
const panel=player();panel.scheduleHideControls();panel.showSpeeds=true;const old=panel.hideTimer;timers.get(old)();timers.delete(old);
panel.selectSpeed(1.5);assert.equal(panel.showSpeeds,false);assert.ok(timers.has(panel.hideTimer));timers.get(panel.hideTimer)();assert.equal(panel.controlsVisible,false);
for(const flag of ['showSources','showEpisodes']){panel.controlsVisible=true;panel[flag]=true;panel.closePlayerPanels();assert.equal(panel[flag],false);assert.ok(timers.has(panel.hideTimer));}
console.log('PASS: exit cancels playback retries; late surfaces cannot touch window; closing player panels restarts auto-hide.');
