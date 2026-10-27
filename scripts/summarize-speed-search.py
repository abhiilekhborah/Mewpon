#!/usr/bin/env python3
"""Summarize recorded trials without inventing before-data or sparse percentiles."""
import json,math,statistics,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
folder=root/'Verification/SpeedSearch'
def read(name):return json.loads((folder/(name+'.json')).read_text())
def stats(values,unit='ms'):
    values=sorted(values)
    return {'n':len(values),'unit':unit,'p50':statistics.median(values),'p95':values[math.ceil(.95*len(values))-1] if len(values)>=20 else None}
summary={}
for phase in ['before','after']:
    rows=read('speed-'+phase)
    summary['routing-'+phase]=stats([x['ms'] for x in rows])
    summary['decisions-'+phase]={x['input']:x['decision'] for x in rows if x['sample']==0}
    rows=read('native-'+phase)
    summary['native-'+phase]={name:stats([x['milliseconds'] for x in rows if x['operation']==name]) for name in sorted({x['operation'] for x in rows})}
for name in ['search-after','search-final']:
    rows=read(name)
    summary[name]=stats([x['ms'] for x in rows if x['operation']=='fts_search'])
    summary[name+'-initial-index']=rows[0]
rows=read('native-tasks')
summary['native-tasks']={text:{key:stats([x[key] for x in rows if x['input']==text]) for key in ['routing_to_dispatch_ms','native_end_to_end_ms']} for text in sorted({x['input'] for x in rows})}
inference=read('inference-warm')
warm=[x for x in inference['records'] if not x['tool_probe'] and not x['cold']]
summary['inference-warm']={key:stats([x[key] for x in warm],unit='tokens/s' if key=='tps' else 'ms') for key in ['first_ms','full_ms','load_ms','tps']}
summary['inference-warm']['correct_tool_probes']=sum(x['tool_correct'] for x in inference['records'] if x['tool_probe'])
summary['inference-warm']['tool_probe_count']=sum(x['tool_probe'] for x in inference['records'])
summary['inference-warm']['resident']=inference['resident_after']
summary['inference-cold-single-sample']=read('inference')['records'][0]
summary['note']='Debug Swift tests on this Mac; repeated warm trials. p95 omitted for n<20. Tiny fixtures and repeated prompts do not establish broad-library, cold-app, display-paint or general model quality guarantees.'
(folder/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if not k.startswith('decisions')},indent=2))
