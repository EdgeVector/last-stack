#!/usr/bin/env python3
"""Filtered retained official-chain fixtures; no public effect runs."""
import argparse
import copy
import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('factory_cases', ROOT / 'tests/factory-repair.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
f = t.f

def state_fixture():
    c, effects, directory = t.controller_fixture()
    for _ in range(4): c.once()
    return c, f.read_json(directory / 'slot.json'), effects

def bad_candidate(field, value):
    c, state, effects = state_fixture()
    state['candidate'][field] = value
    t.refused(lambda: c.validate_candidate(state), 'retained candidate ' + field + ' drift accepted')

def official_drift():
    c, state, effects = state_fixture()
    state['candidate']['official']['channel'] = 'stable'
    t.refused(lambda: c.validate_candidate(state), 'wrong official channel accepted')

def official_bool():
    c, state, effects = state_fixture()
    state['candidate']['official']['run_id'] = True
    t.refused(lambda: c.validate_candidate(state), 'boolean official run ID accepted')

def merge_drift():
    c, state, effects = state_fixture()
    state['candidate']['merge_receipt']['mergeCommit']['oid'] = '9' * 40
    t.refused(lambda: c.validate_candidate(state), 'candidate source differs from merged PR')

def contract_drift():
    c, state, effects = state_fixture()
    state['candidate']['source_contract_json'] += ' '
    t.refused(lambda: c.validate_candidate(state), 'candidate source contract bytes drift accepted')

def baseline_drift():
    c, state, effects = state_fixture()
    raw = f.strict_json(state['candidate']['baseline_contract_json']); raw['files'] = {}
    state['candidate']['baseline_contract_json'] = f.encoded(raw).decode()
    t.refused(lambda: c.validate_candidate(state), 'candidate replaced retained baseline contract')

def install_field(field, value):
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['installed'][field] = value
    t.refused(lambda: c.validate_install(state, receipt), 'installed ' + field + ' drift accepted')

def install_channel():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['official']['channel'] = 'stable'
    t.refused(lambda: c.validate_install(state, receipt), 'install substituted a channel')

def pending():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt.update(result='pending', installed=None, exact_match=False, soak={'required': True, 'status': 'pending'})
    t.check(c.validate_install(state, receipt) is False, 'valid pending result was not retained')
    receipt['installed'] = effects.install(state)['installed']
    t.refused(lambda: c.validate_install(state, receipt), 'pending receipt falsely supplied installed authority')

def soak():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['soak'] = {'required': True, 'status': 'pending'}
    t.refused(lambda: c.validate_install(state, receipt), 'pending soak accepted as complete')

def public_official_projection():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['official'].pop('app', None)
    t.check(c.validate_install(state, receipt) is True, 'actual public HostTrack official projection refused')

def public_complete_soak():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['soak'] = {'required': False, 'status': 'complete'}
    t.check(c.validate_install(state, receipt) is True, 'actual public completed soak refused')

def public_wrong_app():
    c, state, effects = state_fixture(); receipt = effects.install(state)
    receipt['requested']['app'] = 'fkanban'
    t.refused(lambda: c.validate_install(state, receipt), 'public requested app substitution accepted')

def install_before_write(phase):
    c, state, effects = state_fixture()
    for _ in range(5):
        if f.read_json(c.directory / 'slot.json')['phase'] == phase: break
        c.once()
    state = f.read_json(c.directory / 'slot.json')
    t.check(state['phase'] == phase, 'fixture did not reach ' + phase)
    state['install']['official']['source_oid'] = '9' * 40
    f.atomic_json(c.directory / 'slot.json', state); before = list(effects.calls)
    t.refused(c.once, 'wrong retained install authorized a ' + phase + ' Card write')
    t.check(not any(call in ('proof-mark', 'pr-metadata', 'close') for call in effects.calls[len(before):]),
            'wrong retained install reached a ' + phase + ' Card effect')

def dispatch_unknown():
    c, effects, directory = t.controller_fixture(); c.once(); state = f.read_json(directory / 'slot.json'); state['phase'] = 'dispatch-pending'
    root = directory / 'private-loom'; (root / 'scripts').mkdir(parents=True)
    script = root / 'scripts/loom-land-card-kickoff.sh'
    script.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys\np=Path(__file__).parent / "calls.txt"\nwith p.open("a") as s:s.write("attempt\\n")\nsys.exit(1)\n'); script.chmod(0o755)
    runtime = f.Runtime(directory, c.config, directory); runtime.loom = root
    t.refused(lambda: runtime.dispatch(state), 'unknown kickoff was accepted')
    t.refused(lambda: runtime.dispatch(state), 'unknown kickoff was repeated')
    t.check((root / 'scripts/calls.txt').read_text() == 'attempt\n', 'unknown dispatch call repeated a public kickoff')

def observed_dispatch():
    c, effects, directory = t.controller_fixture(); c.once(); state = f.read_json(directory / 'slot.json'); state['phase'] = 'dispatch-pending'
    key = 'card-' + state['card'] + '-20261008T191927Z'; ident = 'lx-20261008T191927.569-36821-1'
    original = {key: state[value] for key, value in (('card', 'card'), ('factory_card', 'card'), ('claim_worker', 'owner'), ('repo', 'repo'), ('base', 'base'))}
    original.update(factory_repair=True, factory_decision_receipt=state['intent']['factory_decision_receipt'])
    logs = directory / 'kickoff'; logs.mkdir(); (logs / 'factory-repair-slot.current').write_text(key + ' ' + state['card'] + ' 123 ' + json.dumps(original) + '\n')
    (logs / (key + '.log')).write_text(ident + '\n')
    effects.value.update(column='doing', assignee=state['owner']); witness = t.item(effects.value)
    f.atomic_json(directory / ('claim-' + state['intent']['attempt'] + '.json'), {'result': 'claimed', 'durability': 'durable',
        'contract_sha256': '6' * 64, 'guard_snapshot_sha256': state['intent']['witness_sha256'],
        'next_snapshot_json': witness['snapshot_json'], 'next_snapshot_sha256': witness['snapshot_sha256']})
    runtime = f.Runtime(directory, c.config, directory)
    result = runtime.dispatch(state)
    t.check(result['execution_id'] == ident and result['key'] == key and result['original_input'] == original,
            'direct current observation lost actual dotted execution or uppercase kickoff identity')

def retained_completed_reader():
    c, state, effects = state_fixture(); runtime = f.Runtime(c.root if hasattr(c, 'root') else c.directory, c.config, c.directory)
    witness = t.item(effects.value); calls = []
    def authority(pin, current=True): calls.append(current); return Path('/tmp/private-proved-kanban')
    with patch.object(f, 'verify_fk', side_effect=authority), patch.object(f, 'public_card_batch', return_value={'items': [witness]}) as read:
        t.check(runtime.completed_card() == witness and runtime.card() == witness and calls == [False, True],
                'completed reader changed current authority for a nonterminal Card route')
        t.check(all(call.args[1] == [f.COUNT_CARD] for call in read.call_args_list), 'completed reader changed the exact canonical Card key')

CASES = {'official_drift': official_drift, 'official_bool': official_bool, 'merge_drift': merge_drift,
         'contract_drift': contract_drift, 'baseline_drift': baseline_drift,
         'install_root': lambda: install_field('resolved_root', '/tmp/foreign-artifact'),
         'install_files': lambda: install_field('files', []), 'install_channel': install_channel,
         'pending': pending, 'soak': soak}
CASES['dispatch_unknown'] = dispatch_unknown
CASES['observed_dispatch'] = observed_dispatch
CASES['retained_completed_reader'] = retained_completed_reader
CASES['public_official_projection'] = public_official_projection
CASES['public_complete_soak'] = public_complete_soak
CASES['public_wrong_app'] = public_wrong_app
for phase in ('proof-mark', 'pr-metadata', 'close'):
    CASES['write_' + phase] = lambda phase=phase: install_before_write(phase)
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=CASES); args = p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
