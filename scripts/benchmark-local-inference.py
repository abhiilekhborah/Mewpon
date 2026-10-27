#!/usr/bin/env python3
"""Controlled loopback benchmark; never downloads models or executes tool calls."""
import urllib.request,json,time,pathlib,sys
output=pathlib.Path(sys.argv[1]);output.parent.mkdir(parents=True,exist_ok=True)
def request(path,body=None):
    data=None if body is None else json.dumps(body).encode()
    return urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:11434/'+path,data=data,headers={'Content-Type':'application/json'}),timeout=120)
models=json.load(request('api/tags'))
resident=json.load(request('api/ps'))
model='qwen3:4b-instruct'
assert any(m['name']==model for m in models['models'])
# Avoid benchmarking multiple resident models on a 16 GB Mac.
assert all(m['name']==model for m in resident['models']), 'Another model is resident; no model was unloaded.'
rows=[]
tools=[{'type':'function','function':{'name':'open_application','description':'Open an installed application','parameters':{'type':'object','properties':{'application':{'type':'string'}},'required':['application']}}}]
for i in range(25):
    tool=i>=20
    prompt='Open Safari.' if tool else 'Explain a binary search in exactly two short sentences.'
    body={'model':model,'messages':[{'role':'system','content':'You are Mewpon. Answer briefly. Use tools only for explicit actions.'},{'role':'user','content':prompt}], 'stream':True,'think':False,'keep_alive':'300s','options':{'num_ctx':4096,'num_predict':128,'temperature':0}}
    if tool:body['tools']=tools
    start=time.perf_counter();first=None;content='';calls=[]
    with request('api/chat',body) as response:
        for line in response:
            chunk=json.loads(line);message=chunk.get('message',{})
            if first is None and (message.get('content') or message.get('tool_calls')):first=(time.perf_counter()-start)*1000
            content+=message.get('content','');calls+=message.get('tool_calls',[])
            if chunk.get('done'):break
    elapsed=(time.perf_counter()-start)*1000
    row={'sample':i,'cold':i==0 and not resident['models'],'tool_probe':tool,'first_ms':first,'full_ms':elapsed,'load_ms':chunk.get('load_duration',0)/1e6,'tokens':chunk.get('eval_count',0),'tps':chunk.get('eval_count',0)/max(1,chunk.get('eval_duration',1))*1e9,'tool_correct':len(calls)==1 and calls[0].get('function',{}).get('name')=='open_application' and calls[0].get('function',{}).get('arguments')=={'application':'Safari'} if tool else None,'calls':calls,'content':content}
    rows.append(row)
    output.write_text(json.dumps({'models':models,'resident_before':resident,'resident_after':json.load(request('api/ps')),'records':rows},indent=2))
    print('Completed inference sample',i+1,flush=True)
