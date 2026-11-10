const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('./test-typescript.cjs');
const s=fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets','utf8');
const rotation=s.slice(s.indexOf('  private applyCastRotation('),s.indexOf('  @Builder',s.indexOf('  private applyCastRotation(')));
const controls=s.slice(s.indexOf('  private dismissPlayerControls()'),s.indexOf('  private onSurfaceReady('));
const area=s.slice(s.indexOf('.onAreaChange((oldValue: Area, newValue: Area) => {')+'.onAreaChange((oldValue: Area, newValue: Area) => {'.length,s.indexOf('\n      })\n      .gesture(',s.indexOf('.onAreaChange((oldValue: Area, newValue: Area) => {')));
const click=s.slice(s.indexOf('  private handleVideoTap()'),s.indexOf('  private togglePlay()'));
const lockCondition=s.match(/if \((!this.localResumePending && !this.restoreCast && this.castDeviceName === '' && !this.pipActive && this.canvasW > this.canvasH && this.controlsVisible)\)/)[1];
let timers=[],applied=[];
const orientation={AUTO_ROTATION:5,AUTO_ROTATION_RESTRICTED:8,LANDSCAPE:2,PORTRAIT:1};
const P=vm.runInNewContext(ts.transpile('class Player {\n'+rotation+controls+'\n resize(newValue) {'+area+'}\n'+click+'\n tap() {this.handleVideoTap()}\n lockVisible(){return '+lockCondition+'}\n}',{target:ts.ScriptTarget.ES2020})+'\nPlayer',{
 DevicePolicy:{},window:{Orientation:orientation,getLastWindow:async()=>({setPreferredOrientation:async x=>applied.push(x)})},setTimeout:fn=>{timers.push(fn);return timers.length},clearTimeout:()=>{}
});
async function run(){
 const p=new P();p.syncTopPad=()=>{};p.getUIContext=()=>({getHostContext:()=>({})});p.castDeviceName='TV';p.released=false;
 for(const [mode,expected] of [['system',8],['auto',5],['landscape',2],['portrait',1]]){
  p.applyCastRotation(mode);await Promise.resolve();assert.equal(applied.at(-1),expected);assert.equal(p.rotationMode,mode);
 }
 p.applyCastRotation('auto');p.applyCastRotation('portrait');await Promise.resolve();assert.equal(applied.at(-1),1);
 p.castDeviceName='';
 for(const [mode,expected] of [['system',8],['auto',5],['landscape',2],['portrait',1]]){
  p.applyLocalRotation(mode);await Promise.resolve();assert.equal(applied.at(-1),expected);assert.equal(p.rotationMode,mode);
 }
 p.applyLocalRotation('auto');await Promise.resolve();p.castDeviceName='TV';p.applyCastRotation();await Promise.resolve();assert.equal(applied.at(-1),5);
 p.castDeviceName='';p.applyLocalRotation();await Promise.resolve();assert.equal(applied.at(-1),5);
 p.canvasW=800;p.canvasH=400;p.controlsVisible=true;p.pipActive=false;assert.equal(p.lockVisible(),true);
 p.screenLocked=true;p.playing=false;p.controlsVisible=false;p.tap();assert.equal(p.controlsVisible,true);assert.equal(p.screenLocked,true);
 timers.at(-1)();assert.equal(p.controlsVisible,false);
 p.endPress=()=>{};p.areaNumber=Number;p.updateSurfaceSize=()=>{};p.resize({width:400,height:800});
 assert.equal(p.screenLocked,false);assert.equal(p.lockVisible(),false);assert.equal(p.controlsVisible,true);
 p.canvasW=800;p.canvasH=400;p.pipActive=true;assert.equal(p.lockVisible(),false);
 let toggles=0;p.player={toggle:()=>toggles++};p.pipActive=false;p.castController=null;
 p.controlsVisible=false;p.playing=true;
 p.handleVideoDoubleTap();assert.equal(toggles,1);assert.equal(p.controlsVisible,false);assert.equal(p.pauseHintVisible,true);
 for(const flag of ['screenLocked','restoreCast','localResumePending','pipActive','released']){
  p[flag]=true;p.handleVideoDoubleTap();assert.equal(toggles,1);p[flag]=false;
 }
 p.suppressTap=true;p.handleVideoDoubleTap();assert.equal(toggles,1);
 p.playing=false;p.handleVideoDoubleTap();assert.equal(toggles,2);assert.equal(p.controlsVisible,false);assert.equal(p.pauseHintVisible,false);
 p.controlsVisible=true;p.handleVideoDoubleTap();assert.equal(p.controlsVisible,true);
 assert.match(s,/GestureGroup\(GestureMode.Exclusive,[\s\S]*?TapGesture\(\{ count: 2 \}\)[\s\S]*?TapGesture\(\{ count: 1 \}\)/);
 console.log('PASS: system/independent/manual orientations map correctly; stale requests are ignored; lock appears only in landscape, can be summoned while locked and unlocks in portrait.');
}
run().catch(e=>{console.error(e);process.exitCode=1});
