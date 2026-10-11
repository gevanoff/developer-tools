import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';

export function normalizeUsage(result) {
  const rateLimits = result?.rateLimitsByLimitId?.codex ?? result?.rateLimits;
  if (!rateLimits || (rateLimits.limitId && rateLimits.limitId !== 'codex')) throw new Error('Invalid Codex usage response.');
  for (const window of [rateLimits.primary, rateLimits.secondary]) {
    if (window && ['usedPercent', 'windowDurationMins', 'resetsAt'].some(key => window[key] != null && !Number.isFinite(window[key]))) throw new Error('Invalid usage window.');
  }
  const count = result.rateLimitResetCredits?.availableCount;
  if (count != null && (!Number.isInteger(count) || count < 0)) throw new Error('Invalid reset count.');
  // Deliberately omit account IDs, purchased-credit details, and reset identifiers.
  return {
    checkedAt:new Date().toISOString(),
    rateLimits:{primary:rateLimits.primary ?? null, secondary:rateLimits.secondary ?? null},
    availableResets:count ?? null,
    ordinaryUsageAllowed:typeof result.ordinaryUsageAllowed === 'boolean' ? result.ordinaryUsageAllowed : null,
  };
}

export function readUsage(executable='codex', args=['app-server','--listen','stdio://'], timeoutMs=25000) {
  return new Promise(resolve => {
    const child=spawn(executable,args,{windowsHide:true,stdio:['pipe','pipe','pipe']});
    let settled=false;
    const finish=value=>{
      if(settled)return;
      settled=true;clearTimeout(timer);
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
    createInterface({input:child.stdout}).on('line',line=>{
      if(settled)return;
      let msg;try{msg=JSON.parse(line);}catch{return;}
      if(msg.id===1){
        if(msg.error)return finish({error:'Could not initialize the Codex usage reader.'});
        send({method:'initialized'});
        send({id:2,method:'account/rateLimits/read',params:{excludeResetCreditDetails:true}});
      }
      if(msg.id===2){
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
