import json,subprocess,urllib.request,time,pathlib
out=(pathlib.Path(__file__).resolve().parents[1]/'Verification'/'Phase3')
data={'timestamp':time.time(),'note':'System-wide readings include other applications. RSS is not unified-memory footprint.'}
for key,cmd in [('swap',['sysctl','vm.swapusage']),('vm',['vm_stat']),('thermal',['pmset','-g','therm']),('processes',['ps','-ax','-o','pid=,%cpu=,rss=,comm='])]:
 r=subprocess.run(cmd,text=True,capture_output=True);value=r.stdout
 if key=='processes':value='\n'.join(x for x in value.splitlines() if any(a in x.lower() for a in ['mewpon','ollama','webkit.webcontent','pid']))
 data[key]=value
try:data['resident_models']=json.load(urllib.request.urlopen('http://127.0.0.1:11434/api/ps',timeout=5))
except Exception as e:data['ollama_error']=str(e)
(out/'system-after.json').write_text(json.dumps(data,indent=2))
print(json.dumps(data,indent=2))
