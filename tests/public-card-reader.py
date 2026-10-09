#!/usr/bin/env python3
"""Private public-CLI reader fixtures. No primary socket or board access."""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

FAKE = '''#!/usr/bin/env python3
import fcntl, hashlib, json, os, sys
from pathlib import Path
args=sys.argv[1:]
if len(args)!=4 or args[:2]!=['guarded-snapshot','--slugs-file'] or args[-1]!='--json':
    sys.exit(79)
keys=json.loads(Path(args[2]).read_text())
with open(os.environ['CALLS'],'a') as stream:
    fcntl.flock(stream,fcntl.LOCK_EX); stream.write(json.dumps(keys)+'\\n')
mode=os.environ.get('MODE','ok')
if mode=='error': sys.exit(3)
schema='a'*64
items=[]
scalar='slug title body board column position assignee created_at created_by updated_at db repo base kind block_status block_reason north_star milestone pr_url branch'.split()
for key in keys:
    if mode=='missing' and key==keys[-1]: items.append({'slug':key,'missing':True}); continue
    fields={name:'' for name in scalar}; fields.update(slug=key,column='todo',body='stored bytes',tags=[],deps=[],surfaces=[])
    if mode=='null': fields['body']=None
    if mode=='absent-field': del fields['deps']
    raw=json.dumps({'version':True if mode=='bool-version' else 1,'schema_hash':schema,'fields':fields})+'\\n'
    items.append({'slug':key,'snapshot_json':raw,'snapshot_sha256':hashlib.sha256(raw.encode()).hexdigest()})
if mode=='partial': items=items[:-1]
if mode=='reorder': items=items[::-1]
if mode=='foreign': items[0]['slug']='foreign'
if mode=='wrong-sha': items[0]['snapshot_sha256']='b'*64
reply={'version':1,'schema_hash':schema,'items':items}
if mode=='schema-drift' and keys[0]=='c': reply['schema_hash']='c'*64
print(json.dumps(reply))
'''

def run(mode='ok', envelope=False, keys=('a','b'), chunk=256):
    directory=Path(tempfile.mkdtemp(prefix='public-card-reader-'))
    fake=directory/'kanban'; fake.write_text(FAKE); fake.chmod(0o755)
    calls=directory/'calls'; env={**os.environ,'MODE':mode,'CALLS':str(calls),'PYTHONDONTWRITEBYTECODE':'1'}
    args=[str(ROOT/'bin/last-stack-kanban-show-batch'),'--board-cli',str(fake),'--chunk',str(chunk)]
    if envelope: args.append('--snapshot-envelope')
    args.extend(keys)
    result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=10)
    return result, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

def check(value,message):
    if not value: raise AssertionError(message)

def positive():
    result,calls=run(); check(result.returncode==0,'public complete read refused')
    records=json.loads(result.stdout)
    check([v['slug'] for v in records]==['a','b'] and len(records[0])==23,'raw23 array changed shape')
    check(calls==[['a','b']],'reader used per-key calls or fallback')

def envelope():
    result,calls=run('missing',True)
    check(result.returncode==0,'explicit missing envelope refused')
    reply=json.loads(result.stdout)
    check(reply['items'][-1]=={'slug':'b','missing':True},'explicit missing was lost')
    check(reply['items'][0]['snapshot_json'].endswith('\n'),'exact newline witness was lost')

def missing():
    result,calls=run('missing'); check(result.returncode!=0 and result.stdout=='','missing key emitted partial raw array')

def chunks():
    result,calls=run(keys=('a','b','c','d','e'),chunk=2)
    check(result.returncode==0 and sorted(calls)==[['a','b'],['c','d'],['e']],'collected chunks were not native batches')
    check([v['slug'] for v in json.loads(result.stdout)]==['a','b','c','d','e'],'parallel chunks changed order')

# Requested order is checked in the batch item, snapshot identity, and raw23
# slug. The reorder probe removes those three checks for the same property.
def refusal(mode):
    result,calls=run(mode,True)
    check(result.returncode!=0 and result.stdout=='',mode+' emitted a successful or partial envelope')

def chunk_failure():
    result,calls=run('partial',True,('a','b','c','d'),2)
    check(result.returncode!=0 and result.stdout=='','incomplete chunk leaked stdout')

CASES={'positive':positive,'envelope':envelope,'missing':missing,'chunks':chunks,'chunk_failure':chunk_failure}
for mode in ('error','partial','reorder','foreign','wrong-sha','null','absent-field','bool-version'):
    CASES[mode]=lambda mode=mode:refusal(mode)
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('case',nargs='?',choices=CASES); args=parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: '+name+': '+str(error),file=sys.stderr);sys.exit(1)
        print('PASS: '+name)
