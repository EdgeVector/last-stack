#!/usr/bin/env python3
"""Exact shim argv against one private public CLI and retained witness."""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('adapter_cases', ROOT / 'tests/factory-repair.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t); f = t.f
loader = importlib.machinery.SourceFileLoader('factory_adapter', str(ROOT / 'bin/last-stack-factory-repair-kanban-adapter'))
spec = importlib.util.spec_from_loader(loader.name, loader); a = importlib.util.module_from_spec(spec); loader.exec_module(a)

def fixture(mode='ok'):
    controller, effects, directory = t.controller_fixture(); controller.once(); state = f.read_json(directory / 'slot.json'); state['phase'] = 'dispatch-pending'
    root = directory / 'artifact'; (root / 'config').mkdir(parents=True)
    f.atomic_json(root / 'config/factory-repair-slot.json', controller.config)
    state['receipt_path'] = str(directory / ('claim-' + state['intent']['attempt'] + '.json'))
    f.atomic_json(directory / 'dispatch-intent.json', state)
    (directory / 'raw.json').write_text(state['witness']['snapshot_json'])
    supplied = directory / 'kickoff-witness.json'; supplied.write_text(state['witness']['snapshot_json'])
    binary = directory / 'private-kanban'
    binary.write_text('''#!/usr/bin/env python3
import hashlib,json,os,sys
from pathlib import Path
root=Path(os.environ['PRIVATE_ADAPTER_ROOT']);mode=os.environ['PRIVATE_ADAPTER_MODE'];args=sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream:stream.write(json.dumps(args)+'\\n')
raw=(root/'raw.json').read_bytes();fields=json.loads(raw)['fields']
if args[:1]==['guarded-snapshot']:
    if mode=='read-drift':fields['title']='changed title';raw=(json.dumps({'version':1,'schema_hash':'a'*64,'fields':fields})+'\\n').encode()
    sys.stdout.buffer.write(raw);sys.exit(0)
if args[:1]!=['pickup']:sys.exit('unexpected private CLI argv')
path=Path(args[args.index('--guard-snapshot')+1]);digest=args[args.index('--snapshot-sha256')+1]
if path.read_bytes()!=raw or hashlib.sha256(raw).hexdigest()!=digest:sys.exit('private guard mismatch')
owner=args[args.index('--worker')+1];fields.update(column='doing',assignee=owner)
if mode in ('held','held-body','held-reason'):
    fields.update(position='1791510000000',updated_at='2026-10-09T02:00:00.000Z',tags=['first_doing_at:2026-10-09T02:00:00.000Z'],block_status='needs_human',
        block_reason='claim recovery pending for worker "'+owner+'": do not work this card until the claim completes')
    if mode=='held-body':fields['body']+='foreign body'
    if mode=='held-reason':fields['block_reason']='human hold'
text=json.dumps({'version':1,'schema_hash':'a'*64,'fields':fields})+'\\n';next_sha=hashlib.sha256(text.encode()).hexdigest()
meta={'durability':'durable','contract_sha256':'6'*64,'guard_snapshot_sha256':digest}
if mode.startswith('held'):
    print(json.dumps({'result':'error','code':'claim_recovery_pending','accepted_held':{'version':1,'stage':'accepted-held',**meta,'snapshot_json':text,'snapshot_sha256':next_sha}}));sys.exit(1)
print(json.dumps({'result':'claimed',**meta,'next_snapshot_json':text,'next_snapshot_sha256':next_sha}))
'''); binary.chmod(0o755)
    return controller, state, directory, root, binary, supplied

def invoke(mode, argv_builder, change=None):
    controller, state, directory, root, binary, supplied = fixture(mode)
    if change: change(supplied, state, directory)
    args = argv_builder(state, supplied); out = io.BytesIO(); err = io.BytesIO(); stream = io.TextIOWrapper(out, encoding='utf8'); error_stream = io.TextIOWrapper(err, encoding='utf8')
    with patch.object(a, 'ROOT', root), patch.object(a, 'validate_local', return_value={'contract_sha256': controller.contract_sha256}), \
         patch.object(a, 'verify_fk', return_value=binary), patch.object(a.sys, 'argv', ['adapter', *args]), \
         patch.dict(os.environ, {'LAST_STACK_FACTORY_INTENT': str(directory / 'dispatch-intent.json'), 'PRIVATE_ADAPTER_ROOT': str(directory), 'PRIVATE_ADAPTER_MODE': mode}), \
         contextlib.redirect_stdout(stream), contextlib.redirect_stderr(error_stream):
        rc = a.main(); stream.flush(); error_stream.flush(); stdout = out.getvalue(); stderr = err.getvalue().decode()
    calls = [f.strict_json(line) for line in (directory / 'calls.jsonl').read_text().splitlines()] if (directory / 'calls.jsonl').exists() else []
    return rc, stdout, stderr, calls, state, directory

def claim_args(state, supplied):
    return ['pickup', 'claim', '--claim-v2', '--only-card', state['card'], '--worker', state['owner'], '--json',
            '--guard-snapshot', str(supplied), '--snapshot-sha256', state['witness']['snapshot_sha256']]

def read_positive():
    rc, out, err, calls, state, directory = invoke('ok', lambda s, p: ['guarded-snapshot', s['card'], '--json'])
    t.check(rc == 0 and out.decode() == state['witness']['snapshot_json'] and len(calls) == 1, 'exact public raw snapshot lost retained bytes')

def claim_positive():
    rc, out, err, calls, state, directory = invoke('ok', claim_args)
    t.check(rc == 0 and len(calls) == 1 and calls[0][:8] == claim_args(state, Path('unused'))[:8], 'supplied witness claim did not reach exact public argv')
    t.check(f.read_json(Path(state['receipt_path']))['result'] == 'claimed', 'exact durable claim receipt was not retained')

def wrong_witness():
    rc, out, err, calls, state, directory = invoke('ok', claim_args, lambda p, s, d: p.write_text(p.read_text() + ' '))
    t.check(rc != 0 and calls == [], 'fresh replacement witness reached a public claim')

def other_key():
    def valid_recovery(path, state, directory):
        fields = f.validate_snapshot(state['original_witness'], state['card'])['fields']
        fields.update(column='doing', assignee=state['owner'], position='1791510000000', updated_at='2026-10-09T02:00:00.000Z',
            tags=[v for v in fields['tags'] if not v.startswith(('done_at:', 'first_doing_at:'))] + ['first_doing_at:2026-10-09T02:00:00.000Z'],
            block_status='needs_human', block_reason=f.synthetic_claim_reason(state['owner']))
        state.update(phase='claim-recovery-pending', witness=t.item(fields))
        state['accepted_held'] = {'version': 1, 'stage': 'accepted-held', 'durability': 'durable', 'contract_sha256': '6' * 64,
            'guard_snapshot_sha256': state['original_witness']['snapshot_sha256'],
            'snapshot_json': state['witness']['snapshot_json'], 'snapshot_sha256': state['witness']['snapshot_sha256']}
        # Keep the independent recovery fence valid. Only the requested argv
        # names a foreign key, so its command fence must refuse before a call.
        f.validate_claim_stage_one(state['original_witness'], state['witness'], state['owner'])
        f.atomic_json(directory / 'dispatch-intent.json', state)
        (directory / 'raw.json').write_text(state['witness']['snapshot_json'])
    rc, out, err, calls, state, directory = invoke('ok', lambda s, p: ['guarded-snapshot', 'another-card', '--json'], valid_recovery)
    t.check(rc != 0 and calls == [], 'forbidden shim command reached the public CLI')

def read_drift():
    rc, out, err, calls, state, directory = invoke('read-drift', lambda s, p: ['guarded-snapshot', s['card'], '--json'])
    t.check(rc != 0 and len(calls) == 1 and not Path(state['receipt_path']).exists(), 'shim adopted a fresh changed snapshot')

def held(mode='held'):
    rc, out, err, calls, state, directory = invoke(mode, claim_args)
    if mode == 'held':
        t.check(rc == 1 and f.read_json(Path(state['receipt_path']))['code'] == 'claim_recovery_pending', 'shim lost exact durable accepted-held receipt')
    else:
        t.check(rc != 0 and not Path(state['receipt_path']).exists(), mode + ' was retained as a valid synthetic hold')

CASES = {'read_positive': read_positive, 'claim_positive': claim_positive, 'wrong_witness': wrong_witness, 'other_key': other_key, 'read_drift': read_drift,
         'held': held, 'held_body': lambda: held('held-body'), 'held_reason': lambda: held('held-reason')}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('case', nargs='?', choices=CASES); args = parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
