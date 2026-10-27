import urllib.request,json,time,pathlib,sys
label=sys.argv[1];rows=[]
if not label.replace('-','').replace('_','').isalnum():raise SystemExit('Use an alphanumeric label')
for i in range(4):
 body={'model':'qwen3:4b-instruct','messages':[{'role':'user','content':'Explain recursion in two sentences.'}],'stream':True,'think':False,'keep_alive':'300s','options':{'num_ctx':4096,'num_predict':96,'temperature':0}}
 start=time.monotonic();first=None
 with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:11434/api/chat',json.dumps(body).encode(),{'Content-Type':'application/json'}),timeout=30) as response:
  for raw in response:
   c=json.loads(raw)
   if c.get('message',{}).get('content') and first is None:first=time.monotonic()-start
   if c.get('done'):break
 rows.append({'sample':i,'warmup':i==0,'first_visible_seconds':first,'total_seconds':time.monotonic()-start,'tokens_per_second':c.get('eval_count',0)/(c.get('eval_duration',1)/1e9),'load_ms':c.get('load_duration',0)/1e6})
p=(pathlib.Path(__file__).resolve().parents[1]/'Verification'/'Phase3')/('contention-'+label+'.json');p.write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
