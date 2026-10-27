import json,time,urllib.request,pathlib
out=pathlib.Path(__file__).resolve().parents[1] / 'Verification/Phase3/thinking-comparison.json'
rows=[]
for think in [False,True]:
 body={'model':'qwen3:4b-instruct','messages':[{'role':'user','content':'What is 145 times 23? Give only the result.'}],'stream':True,'think':think,'keep_alive':'300s','options':{'num_ctx':4096,'num_predict':256,'temperature':0}}
 start=time.monotonic();first=None;content='';thinking=''
 with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:11434/api/chat',json.dumps(body).encode(),{'Content-Type':'application/json'}),timeout=60) as response:
  for raw in response:
   chunk=json.loads(raw);msg=chunk.get('message',{});text=msg.get('content','');content+=text;thinking+=msg.get('thinking','')
   if text and first is None:first=time.monotonic()-start
   if chunk.get('done'):break
 rows.append({'think':think,'total_seconds':time.monotonic()-start,'first_visible_seconds':first,'content':content,'thinking_characters':len(thinking),'load_ms':chunk.get('load_duration',0)/1e6,'eval_count':chunk.get('eval_count',0),'eval_seconds':chunk.get('eval_duration',0)/1e9})
 out.write_text(json.dumps(rows,indent=2))
print(json.dumps(rows,indent=2))
