import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readUsage,normalizeUsage} from '../read-usage.mjs';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

test('uses Codex bucket, preserves unknowns, omits account identifiers',()=>{
 const data=normalizeUsage({accountId:'private',rateLimits:{primary:{usedPercent:90}},rateLimitsByLimitId:{codex:{primary:{usedPercent:25},secondary:null}},rateLimitResetCredits:{availableCount:0,credits:['private']}});
 assert.equal(data.rateLimits.primary.usedPercent,25);
 assert.equal(data.availableResets,0);
 assert.equal(data.ordinaryUsageAllowed,null);
 assert.ok(!JSON.stringify(data).includes('private'));
 assert.equal(normalizeUsage({rateLimits:{}}).availableResets,null);
});
test('rejects malformed usage without treating it as zero',()=>{
 for(const result of [null,{}, {rateLimits:{limitId:'other'}},{rateLimits:{primary:{usedPercent:'bad'}}},{rateLimits:{},rateLimitResetCredits:{availableCount:-1}}]) assert.throws(()=>normalizeUsage(result));
});
test('missing executable reports an actionable error',async()=>{
 assert.match((await readUsage('nonexistent-codex-meter-executable')).error,/could not be started/);
});
test('real stdio handshake only reads usage, including paths with spaces',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'codex meter test '));
 const file=join(dir,'fake server.mjs');
 try{
  await writeFile(file,`import {createInterface} from 'node:readline';
let phase=0;
createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);
 if(phase===0 && m.method==='initialize'){phase++;console.log(JSON.stringify({id:1,result:{}}));}
 else if(phase===1 && m.method==='initialized'){phase++;}
 else if(phase===2 && m.method==='account/rateLimits/read' && m.params.excludeResetCreditDetails===true){phase++;console.log(JSON.stringify({id:2,result:{rateLimits:{primary:{usedPercent:42,windowDurationMins:10080,resetsAt:1900000000}},rateLimitResetCredits:{availableCount:3},ordinaryUsageAllowed:true}}));}
 else process.exit(2);
});`);
  const data=await readUsage(process.execPath,[file]);
  assert.equal(data.rateLimits.primary.usedPercent,42);
  assert.equal(data.availableResets,3);
  assert.equal(data.ordinaryUsageAllowed,true);
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('timeouts, backend errors, malformed responses, and early exits settle',async()=>{
 assert.match((await readUsage(process.execPath,['-e','setInterval(()=>{},1000)'],200)).error,/timed out/);
 assert.match((await readUsage(process.execPath,['-e','process.exit(0)'])).error,/closed/);
 for(const response of [{id:2,error:{message:'private error'}},{id:2,result:null}]){
  const code=`require('node:readline').createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);if(m.id===1)console.log(JSON.stringify({id:1,result:{}}));if(m.id===2)console.log(${JSON.stringify(JSON.stringify(response))});});`;
  const data=await readUsage(process.execPath,['-e',code]);
  assert.ok(data.error);assert.ok(!data.error.includes('private'));
 }
});


test('legacy app-servers retry invalid options exactly once with null params',async()=>{
 for(const errorCode of [-32600,-32602]){
  for(const fallbackError of [false,true]){
   const code=`import {createInterface} from 'node:readline';
let phase=0;
createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);
 if(phase===0 && m.id===1 && m.method==='initialize'){phase++;console.log(JSON.stringify({id:m.id,result:{}}));}
 else if(phase===1 && m.method==='initialized'){phase++;}
 else if(phase===2 && m.id===2 && m.method==='account/rateLimits/read' && m.params.excludeResetCreditDetails===true){phase++;console.log(JSON.stringify({id:m.id,error:{code:${errorCode},message:'private backend detail'}}));}
 else if(phase===3 && m.id===3 && m.method==='account/rateLimits/read' && m.params===null){phase++;console.log(JSON.stringify(${fallbackError ? `{id:m.id,error:{code:${errorCode},message:'private backend detail'}}` : `{id:m.id,result:{rateLimits:{primary:{usedPercent:42}}}}`}));}
 else {console.log(JSON.stringify({id:3,result:null}));process.exit(2);}
});`;
   const data=await readUsage(process.execPath,['--input-type=module','-e',code],3000);
   if(fallbackError) assert.match(data.error,/Usage unavailable/);
   else {assert.equal(data.rateLimits.primary.usedPercent,42);assert.equal(data.availableResets,null);}
   assert.ok(!JSON.stringify(data).includes('private'));
  }
 }
});

test('non-compatibility backend errors fail without retrying',async()=>{
 const code=`import {createInterface} from 'node:readline';
createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);
 if(m.id===1)console.log(JSON.stringify({id:m.id,result:{}}));
 if(m.id===2)console.log(JSON.stringify({id:m.id,error:{code:-32603,message:'private'}}));
 if(m.id===3)console.log(JSON.stringify({id:m.id,result:{rateLimits:{}}}));
});`;
 assert.match((await readUsage(process.execPath,['--input-type=module','-e',code])).error,/Usage unavailable/);
});

 test('window fields are allowlisted and malformed envelopes are ignored',async()=>{
 const result=normalizeUsage({rateLimits:{primary:{usedPercent:10,accountId:'private',resetId:'private',nested:{secret:'private'}},secondary:{resetsAt:1900000000,credits:'private'}}});
 assert.deepEqual(result.rateLimits,{primary:{usedPercent:10},secondary:{resetsAt:1900000000}});
 for(const primary of [true,10,'bad',[]])assert.throws(()=>normalizeUsage({rateLimits:{primary}}));
 const code=`require('node:readline').createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);console.log('null');console.log('[]');console.log('not json');if(m.id===1)console.log(JSON.stringify({id:1,result:{}}));if(m.id===2)console.log(JSON.stringify({id:2,result:{rateLimits:{}}}));});`;
 assert.equal((await readUsage(process.execPath,['-e',code],3000)).availableResets,null);
});

test('rejects unsafe window values and reset counts before rendering',()=>{
 for(const primary of [{windowDurationMins:-1},{windowDurationMins:0.5},{resetsAt:1e100},{resetsAt:253402300800},{resetsAt:-62135596801},{resetsAt:1.5}])assert.throws(()=>normalizeUsage({rateLimits:{primary}}));
 for(const rateLimits of [true,1,'bad',[]])assert.throws(()=>normalizeUsage({rateLimits}));
 assert.throws(()=>normalizeUsage({rateLimits:{},rateLimitResetCredits:{availableCount:1e20}}));
 assert.equal(normalizeUsage({rateLimits:{primary:{usedPercent:101}}}).rateLimits.primary.usedPercent,101);
 for(const resetsAt of [-62135596800,253402300799])assert.equal(normalizeUsage({rateLimits:{primary:{resetsAt}}}).rateLimits.primary.resetsAt,resetsAt);
});

test('oversized child output fails without retaining or exposing it',async()=>{
 const code="process.stdout.write('x'.repeat(2*1024*1024));setInterval(()=>{},1000);";
 assert.match((await readUsage(process.execPath,['-e',code],3000)).error,/oversized/);
});

test('unsolicited and duplicate responses do not restart reads or retries',async()=>{
 const code=`import {createInterface} from 'node:readline';
let reads=0;
console.log(JSON.stringify({id:2,result:{rateLimits:{primary:{usedPercent:99}}}}));
createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);
 if(m.id===1){console.log(JSON.stringify({id:1,result:{}}));console.log(JSON.stringify({id:1,result:{}}));}
 if(m.method==='account/rateLimits/read'){
  reads++;
  if(reads===1 && m.id===2){console.log(JSON.stringify({id:2,error:{code:-32602}}));console.log(JSON.stringify({id:2,error:{code:-32602}}));}
  else if(reads===2 && m.id===3 && m.params===null)console.log(JSON.stringify({id:3,result:{rateLimits:{primary:{usedPercent:42}}}}));
  else console.log(JSON.stringify({id:3,result:null}));
 }
});`;
 assert.equal((await readUsage(process.execPath,['--input-type=module','-e',code],3000)).rateLimits.primary.usedPercent,42);
});
