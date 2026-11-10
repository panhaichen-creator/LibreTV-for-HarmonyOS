// Regression checks for cast disconnect, page reuse and failed episode changes.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./test-typescript.cjs');
const source = fs.readFileSync('entry/src/main/ets/pages/PlayerPage.ets', 'utf8');
function method(start, end) { return source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start))); }
const methods = method('  private resetForReentry()', '  /**\n   * 用缓存节点') +
  method('  private saveProgress(', '  private release()') +
  method('  private selectEpisode(', '  private selectSpeed(') +
  method('  private async selectRemoteEpisode(', '  private castCommand(');
let saved, fail = false, finishStart, starts = 0;
const Player = vm.runInNewContext(ts.transpile('class Player {\n' + methods + '\n}', {target:ts.ScriptTarget.ES2020}) + '\nPlayer', {
  CastResume:{synchronize:async()=>null}, console, AppLifecycle:{}, Utils:{formatTime:()=>''},
  SettingsStore:{shared:()=>({get:()=>({defaultSpeed:1,playHistoryEnabled:true})})},
  HistoryStore:{shared:()=>({saveProgress:record=>saved=record})},
  SourceManager:{shared:()=>({getVodSource:()=>({name:'test'})})},
  PlayUrlResolver:{resolveSharePage:async()=>{if(fail)throw Error('offline');return 'https://example.com/video';}}
});
async function run() {
  const p = new Player();
  p.rememberCast = () => {};
  p.prepareCastRecovery = () => {};
  for (const key of ['bindSleepTimer','clearStall','clearWatchdog','clearResync','clearLoadingTimer','clearBgTimer','clearAdjustTimer','holdScreen','syncSystemVolume','initCastSession','resolvePic','dropScreen','toast']) p[key]=()=>{};
  p.recoverCast=()=>false; p.offlineDir='offline'; p.localResumePending=true;
  p.resetForReentry(); assert.equal(p.localResumePending,false);
  p.localResumePending=true;p.castController=null;p.positionMs=1800000;p.durationMs=3600000;
  p.player={isCreated:()=>true,currentTime:()=>120000,duration:()=>3600000};
  p.playableEpisode=()=>({name:'first',url:'https://example.com/first'});
  p.saveProgress();assert.equal(saved.positionMs,1800000);
  p.player.isCreated=()=>false;p.saveProgress();assert.equal(saved.positionMs,1800000);
  p.currentEp=0;p.episodes=[p.playableEpisode(),{name:'second',url:'https://example.com/second'}];
  p.ensureEpisodesLoaded=async()=>{};p.released=false;
  p.applySeekUi=ms=>{p.positionMs=ms;p.sliderValue=ms/1000};
  p.castController={prepare:async()=>{},start:async()=>{starts++;await new Promise(r=>finishStart=r)}};
  fail=true; await p.selectRemoteEpisode(1);
  assert.equal(p.currentEp,0);assert.equal(p.positionMs,1800000);assert.equal(starts,0);
  fail=false;const pending=p.selectRemoteEpisode(1);
  while(!finishStart)await new Promise(r=>setImmediate(r));
  assert.equal(p.currentEp,0);await p.selectRemoteEpisode(1);assert.equal(starts,1);
  finishStart();await pending;
  assert.equal(p.currentEp,1);assert.equal(p.positionMs,0);assert.equal(p.castSwitching,false);
  console.log('PASS: page reuse clears pending resume; disconnect keeps remote progress; episode changes commit only after successful start and reject duplicate taps.');
}
run().catch(e=>{console.error(e);process.exitCode=1});
