const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),dgram=require('node:dgram');
const ts=require('./test-typescript.cjs');
const live=process.argv.includes('--live');const control=process.argv.includes('--control');let actions=[];
const socket={constructUDPSocketInstance:()=>{const udp=dgram.createSocket('udp4');return {
 bind:address=>new Promise((r,j)=>{udp.once('error',j);udp.bind(address.port,address.address,r)}),
 on:(event,fn)=>udp.on('message',(buf)=>fn({message:buf.buffer.slice(buf.byteOffset,buf.byteOffset+buf.byteLength)})),
 send:options=>new Promise((r,j)=>udp.send(options.data,options.address.port,options.address.address,e=>e?j(e):r())),close:()=>new Promise(r=>udp.close(r))
}}};
const http={RequestMethod:{POST:'POST'},createHttp:()=>({destroy:()=>{},request:async(endpoint,options)=>{
 const action=options.header.SOAPAction;actions.push(action);assert.match(action,/#(GetPositionInfo|GetTransportInfo|Seek|Pause|Play|SetVolume|SetAVTransportURI)"$/);
 if(live){const r=await fetch(endpoint,{method:'POST',headers:options.header,body:options.extraData});return{responseCode:r.status,result:await r.text()};}
 return {responseCode:200,result:action.includes('GetPositionInfo')?'<TrackURI>https://example.com/v?a=1&amp;b=2</TrackURI><TrackDuration>0:37:47</TrackDuration><RelTime>0:12:30</RelTime>':'<CurrentTransportState>PLAYING</CurrentTransportState>'};
}})};
const text=fs.readFileSync('entry/src/main/ets/common/DlnaProbe.ets','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'');
const Probe=vm.runInNewContext(ts.transpile(text,{target:ts.ScriptTarget.ES2020})+'\nDlnaProbe',{console,socket,http,util:{TextDecoder:class { constructor(encoding){this.decoder=new TextDecoder(encoding)} decodeToString(bytes){return this.decoder.decode(bytes)} }},HttpClient:{getText:async uri=>{const r=await fetch(uri);return{ok:r.ok,text:await r.text()}}},avSession:{PlaybackState:{PLAYBACK_STATE_PLAY:2,PLAYBACK_STATE_PAUSE:3}},setTimeout,Date});
(async()=>{
 assert.equal(Probe.time('0:37:47'),2267000);assert.equal(Probe.time('NOT_IMPLEMENTED'),0);
 if(!live)Probe.endpoints.set('test','http://localhost/control');
 const result=await Probe.read(live?'LibreTV Mac Test 2':'test');
 if(!live){assert.equal(result.state.position.elapsedTime,750000);assert.equal(result.state.duration,2267000);assert.equal(result.mediaUri,'https://example.com/v?a=1&b=2');}
 assert.equal(actions.length,2);
 if(control){
   const before=result.state.position.elapsedTime;const target=Math.min(before+5000,result.state.duration-3000);
   try {
     await Probe.command('LibreTV Mac Test 2','seek',target);
     await new Promise(r=>setTimeout(r,700));const after=await Probe.read('LibreTV Mac Test 2');
     assert.ok(Math.abs(after.state.position.elapsedTime-target)<5000,'Mac must acknowledge the new position');
     await Probe.command('LibreTV Mac Test 2','pause');const paused=await Probe.read('LibreTV Mac Test 2');assert.equal(paused.state.state,3);
   } finally {
     await Probe.command('LibreTV Mac Test 2','seek',before);
     if(result.state.state===2)await Probe.command('LibreTV Mac Test 2','play');
   }
   console.log('PASS: live Mac seek and pause commands acknowledged; original position/play state restored.');
 }
 console.log('PASS: read-only DLNA '+(live?'discovery and live Mac receiver':'SOAP parser')+'; position='+result.state.position.elapsedTime+' duration='+result.state.duration);
})().catch(e=>{console.error(e.message);process.exitCode=1});
