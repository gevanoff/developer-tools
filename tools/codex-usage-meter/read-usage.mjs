import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';

export function normalizeUsage(result) {
  const rateLimits = result?.rateLimitsByLimitId?.codex ?? result?.rateLimits;
  if (!rateLimits || typeof rateLimits!=='object' || Array.isArray(rateLimits) || (rateLimits.limitId && rateLimits.limitId !== 'codex')) throw new Error('Invalid Codex usage response.');
  const normalizeWindow=window=>{
    if(window==null)return null;
    if(typeof window!=='object' || Array.isArray(window))throw new Error('Invalid usage window.');
    if (window && ['usedPercent', 'windowDurationMins', 'resetsAt'].some(key => window[key] != null && !Number.isFinite(window[key]))) throw new Error('Invalid usage window.');
    if(window.windowDurationMins!=null && (!Number.isSafeInteger(window.windowDurationMins) || window.windowDurationMins<0))throw new Error('Invalid usage duration.');
    if(window.resetsAt!=null && (!Number.isSafeInteger(window.resetsAt) || window.resetsAt<-62135596800 || window.resetsAt>253402300799))throw new Error('Invalid reset time.');
    return Object.fromEntries(['usedPercent','windowDurationMins','resetsAt'].filter(key=>window[key]!=null).map(key=>[key,window[key]]));
  };
  const count = result.rateLimitResetCredits?.availableCount;
  if (count != null && (!Number.isSafeInteger(count) || count < 0)) throw new Error('Invalid reset count.');
  // Deliberately omit account IDs, purchased-credit details, and reset identifiers.
  return {
    checkedAt:new Date().toISOString(),
    rateLimits:{primary:normalizeWindow(rateLimits.primary), secondary:normalizeWindow(rateLimits.secondary)},
    availableResets:count ?? null,
    ordinaryUsageAllowed:typeof result.ordinaryUsageAllowed === 'boolean' ? result.ordinaryUsageAllowed : null,
  };
}

export function readUsage(executable='codex', args=['app-server','--listen','stdio://'], timeoutMs=25000) {
  return new Promise(resolve => {
    const child=spawn(executable,args,{windowsHide:true,stdio:['pipe','pipe','pipe']});
    let settled=false;
    let expectedId=1;
    let lines;
    let outputBytes=0;
    const finish=value=>{
      if(settled)return;
      settled=true;clearTimeout(timer);
      lines?.close();
      child.stdin.end();
      child.kill();
      resolve(value);
    };
    const timer=setTimeout(()=>finish({error:'Usage refresh timed out. Retry shortly.'}),timeoutMs);
    const send=x=>{if(!settled)child.stdin.write(JSON.stringify(x)+'\n');};
    child.on('error',()=>finish({error:'Codex could not be started. Check installation and sign-in.'}));
    child.stdin.on('error',()=>finish({error:'Codex usage connection closed.'}));
    child.on('close',()=>finish({error:'Codex closed before returning usage.'}));
    child.stderr.on('data',()=>{}); // Never log local authentication or runtime diagnostics.
    child.stdout.on('data',chunk=>{
      outputBytes+=chunk.length;
      if(outputBytes>1024*1024)finish({error:'Codex returned an oversized usage response.'});
    });
    lines=createInterface({input:child.stdout});
    lines.on('line',line=>{
      if(settled)return;
      let msg;try{msg=JSON.parse(line);}catch{return;}
      if(!msg || typeof msg!=='object' || Array.isArray(msg) || msg.id!==expectedId)return;
      if(msg.id===1){
        if(msg.error)return finish({error:'Could not initialize the Codex usage reader.'});
        send({method:'initialized'});
        expectedId=2;
        send({id:2,method:'account/rateLimits/read',params:{excludeResetCreditDetails:true}});
      }
      if(msg.id===2 && [-32600,-32602].includes(msg.error?.code)){
        // Older app-servers accept the read method but reject its newer options.
        expectedId=3;
        send({id:3,method:'account/rateLimits/read',params:null});
        return;
      }
      if(msg.id===2 || msg.id===3){
        if(msg.error)return finish({error:'Usage unavailable. Check your Codex sign-in and connection.'});
        try{finish(normalizeUsage(msg.result));}catch{finish({error:'Codex returned an unsupported usage response.'});}
      }
    });
    send({id:1,method:'initialize',params:{clientInfo:{name:'codex_usage_meter',title:'Codex Usage Meter',version:'1.0.0'},capabilities:{experimentalApi:true}}});
  });
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href){
  const result=await readUsage(process.argv[2]);
  console.log(JSON.stringify(result));
  process.exitCode=result.error ? 1 : 0;
}
