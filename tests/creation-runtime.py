#!/usr/bin/env python3
"""Actual public filing argv with private contract and durable Card receipts."""
import argparse
import copy
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reconcile_cases', ROOT / 'tests/reconcile-finite.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
f = t.f


def fixture(mode='ok'):
    reconciler, effects, directory = t.fixture()
    root = reconciler.root; bindir = root / 'bin'; bindir.mkdir()
    shutil.copy2(ROOT / 'bin/last-stack-kanban-file-pr', bindir / 'last-stack-kanban-file-pr')
    shutil.copy2(ROOT / 'config/factory-create-only-contract.json', root / 'config/factory-create-only-contract.json')
    policy = f.read_json(root / 'config/factory-create-only-contract.json')
    config = copy.deepcopy(reconciler.config)
    config['creation_authority']['contract_sha256'] = policy['contract_sha256']
    receipt = effects.file(b'private brief')
    receipt['contract_sha256'] = policy['contract_sha256']
    f.atomic_json(directory / 'receipt.json', receipt)
    f.atomic_json(directory / 'policy.json', policy)
    common = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['PRIVATE_CREATION_ROOT']);args=sys.argv[1:];mode=os.environ['PRIVATE_CREATION_MODE']
with (root/'calls.jsonl').open('a') as stream:stream.write(json.dumps([Path(sys.argv[0]).name,args])+'\\n')
'''
    gate = common + "(root/'selected-brain.txt').write_text(os.environ.get('BRAIN_BIN',''))\nif mode=='inherited-retired-brain' and Path(os.environ.get('BRAIN_BIN','')).name!='brain':sys.exit('private gate selected retired backend')\nsys.stdout.write(sys.stdin.read())\n"
    admission = common + "sys.stdin.read()\n"
    kanban = common + '''
if args==['create-only-contract','--json']:
    value=json.loads((root/'policy.json').read_text())
    if mode=='wrong-contract':value['guard_payload_identity']='cached-content'
    if mode=='boolean-version':value['version']=True
    if mode=='float-cap':value['max_batch_operations']=26.0
    print(json.dumps(value));sys.exit(0)
if args[:2]==['milestone','show']:
    print(json.dumps({'state':'active','north_star':'north-star-portable-routine-fleet'}));sys.exit(0)
if not args or args[0]!='add':sys.exit('unexpected private public argv')
sys.stdin.read()
value=json.loads((root/'receipt.json').read_text())
if mode=='malformed-json':print('{} trailing');sys.exit(0)
print(json.dumps(value));sys.stderr.write('private creation diagnostic\\n')
sys.exit(1 if mode=='unknown' else 0)
'''
    for name, source in (('last-stack-feature-portfolio-admission', admission), ('last-stack-kanban-decision-check', gate), ('kanban', kanban)):
        path = bindir / name; path.write_text(source); path.chmod(0o755)
    runtime = t.ReconcileRuntime.__new__(t.ReconcileRuntime)
    runtime.root = root; runtime.config = config; runtime.kanban = bindir / 'kanban'; runtime.capture = directory
    runtime.brain = str(bindir / 'brain')
    environment = {'HOME': str(directory), 'PRIVATE_CREATION_ROOT': str(directory), 'PRIVATE_CREATION_MODE': mode}
    if mode == 'inherited-retired-brain': environment['BRAIN_BIN'] = 'gbrain'
    return runtime, effects.value['body'].encode(), environment, directory


def calls(directory):
    return [json.loads(line) for line in (directory / 'calls.jsonl').read_text().splitlines()]


def positive():
    runtime, brief, environment, directory = fixture()
    with patch.dict(os.environ, environment): result = runtime.file(brief)
    recorded = calls(directory); adds = [args for name, args in recorded if name == 'kanban' and args[0] == 'add']
    t.t.check(len(adds) == 1 and adds[0][1] == f.COUNT_CARD and adds[0].count('--create-only') == 1 and adds[0].count('--json') == 1,
              'actual Runtime.file did not use one exact public create-only JSON add')
    t.t.check(recorded[0] == ['kanban', ['create-only-contract', '--json']] and
              next(i for i, row in enumerate(recorded) if row[0] == 'last-stack-kanban-decision-check') <
              next(i for i, row in enumerate(recorded) if row[0] == 'kanban' and row[1][0] == 'add'),
              'creation bypassed its public contract or standard decision gate')
    t.t.check(result == f.read_json(directory / 'filing-receipt.json') and f.strict_json((directory / 'file.out').read_bytes()) == result and
              b'private creation diagnostic' in (directory / 'file.err').read_bytes(), 'accepted creation bytes or separate error capture changed')


def contract_refusal(mode):
    runtime, brief, environment, directory = fixture(mode)
    with patch.dict(os.environ, environment): t.t.refused(lambda: runtime.file(brief), mode + ' creation contract admitted an add')
    t.t.check(not any(name == 'kanban' and args[0] == 'add' for name, args in calls(directory)), mode + ' reached a public Card add')

def inherited_retired_brain():
    runtime, brief, environment, directory = fixture('inherited-retired-brain')
    with patch.dict(os.environ, environment): runtime.file(brief)
    t.t.check((directory / 'selected-brain.txt').read_text() == runtime.brain,
              'finite creation selected the inherited retired Brain backend')
    t.t.check(sum(name == 'kanban' and args[0] == 'add' for name, args in calls(directory)) == 1,
              'finite Brain override changed the exact public creation route')


def outcome_refusal(mode):
    runtime, brief, environment, directory = fixture(mode)
    with patch.dict(os.environ, environment):
        try: runtime.file(brief)
        except (f.Refusal, ValueError): pass
        else: raise AssertionError(mode + ' creation outcome became an accepted receipt')
    t.t.check(len([1 for name, args in calls(directory) if name == 'kanban' and args[0] == 'add']) == 1 and
              (directory / 'file.out').is_file() and (directory / 'file.err').is_file() and
              not (directory / 'filing-receipt.json').exists(), mode + ' creation lost its exact outcome capture')


def receipt_refusal(field, value):
    runtime, brief, environment, directory = fixture()
    receipt = f.read_json(directory / 'receipt.json'); receipt[field] = value
    t.t.refused(lambda: f.validate_created_receipt(receipt, runtime.config), 'creation receipt ' + field + ' drift accepted')


def witness_refusal(field, value):
    runtime, brief, environment, directory = fixture()
    receipt = f.read_json(directory / 'receipt.json'); raw = f.strict_json(receipt['next_snapshot_json']); raw['fields'][field] = value
    receipt['next_snapshot_json'] = f.encoded(raw).decode(); receipt['next_snapshot_sha256'] = f.sha(receipt['next_snapshot_json'].encode())
    t.t.refused(lambda: f.validate_created_receipt(receipt, runtime.config), 'created Card ' + field + ' drift accepted')


CASES = {'positive': positive, 'wrong-contract': lambda: contract_refusal('wrong-contract'),
    'inherited-retired-brain': inherited_retired_brain,
    'boolean-version': lambda: contract_refusal('boolean-version'), 'float-cap': lambda: contract_refusal('float-cap'),
    'unknown': lambda: outcome_refusal('unknown'), 'malformed-json': lambda: outcome_refusal('malformed-json'),
    'absence': lambda: receipt_refusal('absence_guard', 'one-field-absent'),
    'creation-contract': lambda: receipt_refusal('contract_sha256', '9' * 64),
    'guarded-contract': lambda: receipt_refusal('card_guarded_contract_sha256', '9' * 64),
    'queued': lambda: receipt_refusal('durability', 'queued'),
    'owned': lambda: witness_refusal('assignee', 'peer'), 'held': lambda: witness_refusal('block_status', 'needs_human'),
    'todo': lambda: witness_refusal('column', 'todo'), 'pr': lambda: witness_refusal('pr_url', 'https://github.com/EdgeVector/loom/pull/1')}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('case', nargs='?', choices=CASES); args = parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
