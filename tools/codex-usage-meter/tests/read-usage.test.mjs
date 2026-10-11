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
  const code=`console.log(${JSON.stringify(JSON.stringify(response))});setInterval(()=>{},1000);`;
  const data=await readUsage(process.execPath,['-e',code]);
  assert.ok(data.error);assert.ok(!data.error.includes('private'));
 }
});
