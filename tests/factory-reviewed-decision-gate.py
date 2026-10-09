#!/usr/bin/env python3
"""Filtered public decision gate cases. All clients and files are private."""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import factory_repair as f
import factory_reconcile as r

TITLE = 'Count canonical active Loom executions once'
SLUG = 'factory-canonical-active-counts-20261008'
DECISION = 'decision-20260907-approve-lastdb-memory-footprint-guard-design'

def check(value, message):
    if not value: raise AssertionError(message)

def fixture():
    home = Path(tempfile.mkdtemp(prefix='factory-reviewed-gate-'))
    artifact = home / 'artifact'; binary = artifact / 'bin'; binary.mkdir(parents=True)
    (artifact / 'lib').mkdir(); (artifact / 'config').mkdir(); (home / '.local/bin').mkdir(parents=True)
    for name in ('last-stack-kanban-decision-check', 'last-stack-kanban-file-pr'):
        shutil.copy2(ROOT / 'bin' / name, binary / name)
    shutil.copy2(ROOT / 'lib/factory_repair.py', artifact / 'lib/factory_repair.py')
    shutil.copy2(ROOT / 'config/factory-reviewed-decision.json', artifact / 'config/factory-reviewed-decision.json')
    policy = json.loads((artifact / 'config/factory-reviewed-decision.json').read_text())
    record = {'type': 'decision', **policy['decision']}
    (home / 'record.json').write_text(json.dumps(record))
    brain = home / '.local/bin/brain'
    brain.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
home=Path(os.environ['HOME'])
with (home/'brain-calls.jsonl').open('a') as stream:stream.write(json.dumps(sys.argv[1:])+'\\n')
a=sys.argv[1:];mode=os.environ.get('PRIVATE_MODE','ok')
if a[0] in ('ask','search'):print('[]');sys.exit(0)
if a != ['get','decision-20260907-approve-lastdb-memory-footprint-guard-design','--type','decision','--json']:sys.exit(98)
if mode=='error':print((home/'record.json').read_text());sys.exit(1)
if mode=='timeout':time.sleep(21)
value=(home/'record.json').read_text()
if mode=='malformed':value='{'
if mode=='duplicate':value=value[:-1]+',"type":"decision"}'
if mode=='large':value+=' '*65536
print(value)
'''); brain.chmod(0o755)
    admission = binary / 'last-stack-feature-portfolio-admission'
    admission.write_text('#!/bin/sh\nexit 0\n'); admission.chmod(0o755)
    board = binary / 'kanban'
    board.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
home=Path(os.environ['HOME']);a=sys.argv[1:]
with (home/'board-calls.jsonl').open('a') as stream:stream.write(json.dumps(a)+'\\n')
if a[:2]==['milestone','show']:print(json.dumps({'state':'active','north_star':'north-star-portable-routine-fleet'}));sys.exit(0)
if a[0]!='add':sys.exit(99)
(home/'filed-body.md').write_text(sys.stdin.read())
print(json.dumps({'result':'created','version':1,'durability':'durable'}))
'''); board.chmod(0o755)
    environment = {k:v for k,v in os.environ.items() if k not in ('BRAIN_BIN','LAST_STACK_BRAIN_CONFIG','LAST_STACK_DECISION_FIXTURE','LAST_STACK_ADMISSION_FIXTURE')}
    environment.update(HOME=str(home), PYTHONDONTWRITEBYTECODE='1', PATH=str(home/'.local/bin')+':'+os.environ.get('PATH','/usr/bin:/bin'))
    return home, artifact, environment

def calls(home, name):
    path = home / (name + '-calls.jsonl')
    return [json.loads(v) for v in path.read_text().splitlines()] if path.exists() else []

def decision(home, artifact, environment, extra=(), body=None, generic=False):
    argv = [sys.executable, str(artifact / 'bin/last-stack-kanban-decision-check'), '--title', TITLE, '--kind', 'pr', '--column', 'backlog', '--inject']
    if not generic: argv.append('--factory-reviewed-decision')
    result = subprocess.run([*argv,*extra], input=body if body is not None else (ROOT/'config/factory-canonical-active-counts.md').read_bytes(),
                            capture_output=True, env=environment, timeout=27)
    return result

def positive():
    home, artifact, env = fixture(); result = decision(home,artifact,env)
    check(result.returncode==0, 'reviewed named gate refused: '+result.stderr.decode())
    text=result.stdout.decode()
    check('verdict: honor\nslugs: '+DECISION+'\nstore: brain\nread: brain get '+DECISION in text, 'reviewed named honor stamp missing')
    check(calls(home,'brain')==[['get',DECISION,'--type','decision','--json']], 'reviewed gate did not use one exact typed read')
    f.validate_admitted_body(text, {'card':SLUG,'repo':'EdgeVector/loom','base':'main','brief_sha256':f.sha((ROOT/'config/factory-canonical-active-counts.md').read_bytes())})

def generic():
    home,artifact,env=fixture(); result=decision(home,artifact,env,generic=True)
    check(result.returncode==0 and b'verdict: clear\nslugs: none' in result.stdout,'ordinary generic search behavior changed')
    try:f.validate_admitted_body(result.stdout.decode(),{'card':SLUG,'repo':'EdgeVector/loom','base':'main','brief_sha256':f.sha((ROOT/'config/factory-canonical-active-counts.md').read_bytes())})
    except f.Refusal as error:check(str(error)=='reviewed-decision-clearance','legacy boundary refused for another reason');return
    raise AssertionError('legacy search clear unexpectedly met named authority')

def baseline():
    home,artifact,env=fixture(); result=decision(home,artifact,env,generic=True)
    check(result.returncode==0,'old public generic gate did not execute')
    try:f.validate_admitted_body(result.stdout.decode(),{'card':SLUG,'repo':'EdgeVector/loom','base':'main','brief_sha256':f.sha((ROOT/'config/factory-canonical-active-counts.md').read_bytes())})
    except f.Refusal as error:raise AssertionError('actual standard clear/none fails the fixed named policy: '+str(error))

def refused(case, extra=(), mode='ok', body=None, env_change=None, field=None, policy_change=False):
    home,artifact,env=fixture();env['PRIVATE_MODE']=mode
    if env_change:env.update(env_change(home))
    if field:
        path=home/'record.json'; value=json.loads(path.read_text());value[field]='wrong' if field!='type' else 'design';path.write_text(json.dumps(value))
    if policy_change:
        path=artifact/'config/factory-reviewed-decision.json';value=json.loads(path.read_text());value['max_receipt_bytes']=65535;path.write_text(json.dumps(value))
    result=decision(home,artifact,env,extra,body)
    check(result.returncode!=0 and not result.stdout, case+' accepted')

def invariant():
    home,artifact,env=fixture();path=artifact/'bin/last-stack-kanban-decision-check';text=path.read_text()
    anchor='INVARIANTS = (\n';check(text.count(anchor)==1,'private invariant anchor')
    path.write_text(text.replace(anchor,anchor+'    {"slug": "'+DECISION+'", "kind_forbid": ("pr",), "reason": "private invariant"},\n'))
    result=decision(home,artifact,env)
    check(result.returncode==2 and not result.stdout,'reviewed mode bypassed existing invariants')

def file_args(artifact):
    return ['bash',str(artifact/'bin/last-stack-kanban-file-pr'),SLUG,'--title',TITLE,'--repo','EdgeVector/loom','--base','main',
            '--north-star','north-star-portable-routine-fleet','--milestone','ms-factory-heal-via-state-machine','--kind','pr','--column','backlog',
            '--work-class','repair','--difficulty','hard','--no-derive-surfaces','--board-cli',str(artifact/'bin/kanban'),
            '--create-only','--json','--factory-reviewed-decision']

def file_case(case='positive', change=None, mode='ok', env_change=None):
    home,artifact,env=fixture();env['PRIVATE_MODE']=mode
    if env_change:env.update(env_change(home))
    argv=file_args(artifact)
    if change:change(argv)
    result=subprocess.run(argv,input=(ROOT/'config/factory-canonical-active-counts.md').read_bytes(),capture_output=True,env=env,timeout=27)
    board=calls(home,'board')
    if case=='positive':
        check(result.returncode==0,'reviewed public file-pr refused: '+result.stderr.decode())
        check(calls(home,'brain')==[['get',DECISION,'--type','decision','--json']],'file-pr did not forward reviewed gate')
        check(json.loads(result.stdout)=={'result':'created','version':1,'durability':'durable'},'reviewed file-pr JSON changed')
        check('verdict: honor' in (home/'filed-body.md').read_text(),'file-pr lost reviewed stamp')
    else:
        check(not board, case+' reached a Board or Milestone call')
        check(result.returncode!=0 and not result.stdout,case+' accepted')

def set_arg(argv,name,value):argv[argv.index(name)+1]=value
def remove_arg(argv,name):argv.remove(name)

def runtime_mode():
    home=Path(tempfile.mkdtemp(prefix='factory-gate-runtime-')); capture=home/'capture';capture.mkdir()
    runtime=r.ReconcileRuntime.__new__(r.ReconcileRuntime)
    runtime.root=ROOT;runtime.config={'admitted':[{'surfaces':['src/runner.rs','src/storage.rs','release/factory-dispatch-contract.json']}]};runtime.directory=home;runtime.capture=capture;runtime.kanban=home/'kanban';runtime.brain=str(home/'.local/bin/brain')
    seen=[]
    def bounded(argv,*a,**kw):seen.append(argv);return 0,b'{"result":"created"}',b''
    with patch.object(runtime,'creation_ready',return_value=None),patch.object(r,'bounded_call',bounded),patch.object(r,'validate_created_receipt',return_value=None):
        runtime.file(b'private brief')
    check(len(seen)==1 and seen[0].count('--factory-reviewed-decision')==1,'reconciler did not request reviewed gate')

# The public file scope has independent generic body/creation and exact helper
# fences. Combined probes remove only those repeated checks for one property.
CASES={'positive':positive,'generic':generic,'invariant':invariant,'file_forwarding':lambda:file_case(),'runtime_mode':runtime_mode,
       'policy_sha':lambda:refused('changed policy',policy_change=True),
       'kind':lambda:refused('wrong kind',extra=('--kind','validation')),
       'column':lambda:refused('wrong column',extra=('--column','todo')),
       'title':lambda:refused('wrong title',extra=('--title','Other title')),
       'body':lambda:refused('wrong brief',body=(ROOT/'config/factory-canonical-active-counts.md').read_bytes()+b'Human clause\n'),
       'existing_stamp':lambda:refused('existing stamp',body=(ROOT/'config/factory-canonical-active-counts.md').read_bytes()+b'\n## DECISION-CHECK\ndate: 2026-10-09T00:00:00Z\nverdict: clear\nslugs: none\n'),
       'fixture':lambda:refused('fixture option',extra=('--fixture-dir','/private/absent')),
       'env_fixture':lambda:refused('fixture environment',env_change=lambda h:{'LAST_STACK_DECISION_FIXTURE':str(h)}),
       'brain_option':lambda:refused('Brain option',extra=('--brain','/private/other-brain')),
       'brain_env':lambda:refused('Brain environment',env_change=lambda h:{'BRAIN_BIN':'/private/other-brain'}),
       'brain_config':lambda:refused('Brain config environment',env_change=lambda h:{'LAST_STACK_BRAIN_CONFIG':str(h/'old.json')}),
       'read_error':lambda:refused('failed named read',mode='error'),'timeout':lambda:refused('named read timeout',mode='timeout'),
       'response_cap':lambda:refused('oversize named response',mode='large'),'malformed':lambda:refused('malformed named response',mode='malformed'),
       'duplicate_json':lambda:refused('duplicate named response',mode='duplicate')}
for field in ('type','slug','title','status','body'):CASES['record_'+field]=lambda field=field:refused('changed record '+field,field=field)
for name,value in (('slug','other-card'),('repo','EdgeVector/other'),('base','other'),('kind','validation'),('column','todo'),('work-class','proof')):
    if name=='slug': change=lambda a:a.__setitem__(2,'other-card')
    else: change=lambda a,name=name,value=value:set_arg(a,'--'+name,value)
    CASES['file_'+name.replace('-','_')]=lambda name=name,change=change:file_case('file '+name,change)
CASES.update({'file_create':lambda:file_case('file create',lambda a:remove_arg(a,'--create-only')),
 'file_json':lambda:file_case('file JSON',lambda a:remove_arg(a,'--json')),
 'file_skip':lambda:file_case('file skip',lambda a:a.append('--skip-decision-check')),
 'file_fixture':lambda:file_case('file fixture',lambda a:a.extend(['--decision-fixture','/private/absent'])),
 'file_env_fixture':lambda:file_case('file env fixture',env_change=lambda h:{'LAST_STACK_DECISION_FIXTURE':str(h)}),
 'file_gate_error':lambda:file_case('failed repair gate',mode='error'),
 'file_ensure':lambda:file_case('file milestone option',lambda a:a.append('--ensure-milestone')),
 'file_dry':lambda:file_case('file dry option',lambda a:a.append('--dry-run')),
 'file_admission_fixture':lambda:file_case('file admission fixture',lambda a:a.extend(['--admission-fixture','/private/absent'])),
 'file_env_admission_fixture':lambda:file_case('file admission env fixture',env_change=lambda h:{'LAST_STACK_ADMISSION_FIXTURE':str(h)})})
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('case',nargs='?',choices=[*CASES,'baseline']);args=parser.parse_args()
    names=[args.case] if args.case else list(CASES)
    for name in names:
        try:(baseline if name=='baseline' else CASES[name])()
        except Exception as error:print('FAIL: '+name+': '+str(error),file=sys.stderr);sys.exit(1)
        print('PASS: '+name)
