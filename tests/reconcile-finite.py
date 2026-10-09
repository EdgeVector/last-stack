#!/usr/bin/env python3
"""Finite reconciliation, absence creation, retained witnesses, and holds."""
import argparse
import copy
import importlib.util
import sys
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('factory_cases', ROOT / 'tests/factory-repair.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
f = t.f
from factory_reconcile import Reconciler, ReconcileRuntime, queue_keys

class Effects:
    def __init__(self, body):
        self.value = t.card(); self.value.update(body=body, column='backlog', surfaces=[])
        self.calls = []; self.missing = False; self.fail_file = False; self.race = False; self.fixed = False
    def snapshot(self):
        return {'version': 1, 'ok': True, 'method': 'status-keyed papercut index', 'discovered': 2,
                'quarantined': [], 'rows': [{'slug': f.COUNT_PAPERCUT, 'status': 'open'}, {'slug': 'papercut-unrelated', 'status': 'open'}]}
    def record(self): return {'slug': f.COUNT_PAPERCUT, 'status': 'open', 'body': 'old report; keep the claim open'}
    def records(self, keys):
        self.calls.append('batch-records')
        return [{'slug': key, 'status': 'open', 'body': 'old report; keep the claim open', 'duplicate_of': '', 'symptom_hash': key} for key in keys]
    def cards(self, keys):
        self.calls.append('batch-cards')
        return [({'slug': key, 'missing': True} if self.missing else t.item(self.value)) if key == f.COUNT_CARD else
                {'slug': key, 'missing': True} for key in keys]
    def lifecycle(self, record):
        self.calls.append('lifecycle')
        return {'ok': True, 'errors': [], 'fixed': [{'slug': f.COUNT_PAPERCUT}] if self.fixed else []}
    def bootstrap_ready(self): self.calls.append('bootstrap-ready')
    def card(self):
        self.calls.append('card')
        return {'slug': f.COUNT_CARD, 'missing': True} if self.missing else t.item(self.value)
    def tracked_surfaces(self, entry):
        self.calls.append('tracked')
        if self.race: self.value.update(block_status='needs_human', block_reason='new same-owner hold')
    def creation_ready(self): self.calls.append('creation-ready')
    def file(self, brief):
        self.calls.append('file')
        if self.fail_file: raise f.Refusal('filing-attempt-unknown-retained')
        self.missing = False
        witness = t.item(self.value)
        return {'slug': f.COUNT_CARD, 'action': 'created', 'board': 'default', 'column': 'backlog',
            'contract_sha256': '66a7b83a453388e09223721fb08f686339db419e29edc84a2b474de232c358e8',
            'card_guarded_contract_sha256': '6' * 64, 'absence_guard': 'all23-absent', 'durability': 'durable',
            'next_snapshot_json': witness['snapshot_json'], 'next_snapshot_sha256': witness['snapshot_sha256'], 'membership_cleanup': 'deferred'}
    def guarded(self, item, action):
        self.calls.append(action)
        f.require(item['snapshot_sha256'] == t.item(self.value)['snapshot_sha256'], 'fixture witness changed')
        if action == 'surfaces': self.value['surfaces'] = ['src/runner.rs', 'src/storage.rs', 'release/factory-dispatch-contract.json']
        elif action == 'promote': self.value['column'] = 'todo'
        return t.item(self.value)
    def finish(self, receipt, buckets, reason):
        t.check(sum(map(len, buckets.values())) == receipt['discovered'], 'classification lost a queue key')
        return {'reason': reason, 'details': receipt.get('finite_review'), **buckets}

def fixture():
    controller, original, directory = t.controller_fixture()
    root = directory / 'artifact'; (root / 'config').mkdir(parents=True)
    body = original.value['body']; (root / 'config/brief.md').write_text(body)
    config = copy.deepcopy(controller.config); config['admitted'][0]['brief_path'] = 'config/brief.md'
    config['lifecycle_reviewed_keys'] = [f.COUNT_PAPERCUT]
    config['creation_authority'] = {'configured': True, 'contract_sha256': '66a7b83a453388e09223721fb08f686339db419e29edc84a2b474de232c358e8',
        'card_guarded_contract_sha256': '6' * 64}
    effects = Effects(body)
    return Reconciler(root, config, directory, effects, '5' * 64), effects, directory

def admission():
    r, e, directory = fixture(); result = r.once()
    t.check(result['reconciled'] == [f.COUNT_PAPERCUT] and result['deferred'] == ['papercut-unrelated'], 'finite admission changed unrelated classification')
    t.check(e.calls.count('surfaces') == 1 and e.calls.count('promote') == 1 and e.value['column'] == 'todo', 'finite guarded admission did not finish')

def held():
    r, e, directory = fixture(); e.value.update(block_status='needs_human', block_reason='Tom hold')
    result = r.once()
    t.check('lifecycle' in e.calls and 'surfaces' not in e.calls and 'promote' not in e.calls and len(result['deferred']) == 2,
            'hold skipped classification or changed a Card')

def owned():
    r, e, directory = fixture(); e.value['assignee'] = 'peer'
    r.once(); t.check('surfaces' not in e.calls and 'promote' not in e.calls, 'existing owner was overwritten')

def missing():
    r, e, directory = fixture(); e.missing = True
    r.once(); t.check(e.calls.count('file') == 1 and e.calls.index('tracked') < e.calls.index('file') and e.value['column'] == 'todo', 'standard missing-key file path failed')

def uncertain():
    r, e, directory = fixture(); e.missing = True; e.fail_file = True
    first = r.once(); second = r.once()
    t.check(e.calls.count('file') == 1 and first['failed'] == [f.COUNT_PAPERCUT] and second['reason'] == 'filing-attempt-retained', 'unknown create was re-filed')

def unknown_created_key():
    r, e, directory = fixture(); e.missing = True
    def uncertain(brief):
        e.calls.append('file'); e.missing = False; raise f.Refusal('filing-attempt-unknown-retained')
    e.file = uncertain; first = r.once(); second = r.once()
    t.check(first['failed'] and second['failed'] and e.calls.count('file') == 1 and not any(a in e.calls for a in ('surfaces', 'promote')),
            'unknown created key adopted a fresh admission witness')

def created_witness_drift():
    r, e, directory = fixture(); e.missing = True; original = e.file
    def changed(brief):
        receipt = original(brief); e.value['tags'].append('human-added'); return receipt
    e.file = changed; first = r.once(); second = r.once()
    t.check(first['failed'] and second['failed'] and e.calls.count('file') == 1 and e.value['tags'][-1] == 'human-added' and
            not any(a in e.calls for a in ('surfaces', 'promote')), 'later human edit replaced the accepted creation witness')

def filing_boolean_version():
    r, e, directory = fixture(); e.missing = True; e.fail_file = True
    r.once(); path = directory / 'filing-intent.json'; intent = f.read_json(path); intent['version'] = True; f.atomic_json(path, intent)
    result = r.once()
    t.check(result['failed'] and result['reason'] == 'filing-intent-drift' and e.calls.count('file') == 1,
            'boolean filing intent version accepted')

def admission_boolean_version():
    r, e, directory = fixture()
    intent = {'version': True, 'card': f.COUNT_CARD, 'config_sha256': f.value_sha(r.config),
              'contract_sha256': r.contract, 'witness': t.item(e.value), 'phase': 'surfaces'}
    f.atomic_json(directory / 'admission-intent.json', intent); before = list(e.calls)
    # Supply a complete checkpoint without an unknown write. The version
    # guard must independently refuse before any guarded Card operation.
    result = r.once()
    t.check(result['failed'] and not any(call in ('surfaces', 'promote') for call in e.calls[len(before):]),
            'boolean admission intent version reached a Card effect')

def divergent():
    r, e, directory = fixture(); e.value['body'] += '\nchanged scope\n'
    result = r.once(); t.check(result['failed'] == [f.COUNT_PAPERCUT] and 'surfaces' not in e.calls and 'file' not in e.calls, 'divergent existing Card was freshened')

def race():
    r, e, directory = fixture(); e.race = True
    result = r.once(); retained = f.read_json(directory / 'admission-intent.json')
    t.check(result['failed'] == [f.COUNT_PAPERCUT] and e.value['block_reason'] == 'new same-owner hold' and retained['phase'] == 'surfaces', 'concurrent hold replaced retained witness')

def occupied():
    r, e, directory = fixture(); f.atomic_json(directory / 'slot.json', {'phase': 'execution'})
    result = r.once(); t.check(result['reason'] == 'controller-slot-retained' and 'card' not in e.calls, 'occupied shared slot admitted another Card')

def lifecycle():
    r, e, directory = fixture(); e.fixed = True
    result = r.once(); t.check(result['already_handled'] == [f.COUNT_PAPERCUT] and 'card' not in e.calls, 'labeled merged repair still filed a Card')

def incomplete():
    r, e, directory = fixture(); receipt = e.snapshot(); receipt['quarantined'] = [{'slug': 'bad'}]
    t.refused(lambda: queue_keys(receipt), 'incomplete queue supplied classification authority')

def boolean_version():
    r, e, directory = fixture(); receipt = e.snapshot(); receipt['version'] = True
    t.refused(lambda: queue_keys(receipt), 'boolean queue version accepted')

def fair_lifecycle():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = [f.COUNT_PAPERCUT, 'papercut-unrelated']
    selected = []
    def lifecycle(record):
        selected.append(record['slug']); return {'ok': True, 'errors': [], 'fixed': []}
    e.lifecycle = lifecycle
    for _ in range(3): r.once()
    t.check(selected == [f.COUNT_PAPERCUT, 'papercut-unrelated', f.COUNT_PAPERCUT], 'reviewed lifecycle keys did not make fair finite progress')
    t.check(e.calls.count('batch-records') == 3, 'reviewed lifecycle did not use one collected-key batch per tick')

def partial_lifecycle():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = [f.COUNT_PAPERCUT, 'papercut-unrelated']
    e.records = lambda keys: [{'slug': f.COUNT_PAPERCUT, 'status': 'open', 'body': 'partial', 'duplicate_of': '', 'symptom_hash': 'count'}]
    result = r.once()
    t.check(set(result['failed']) == {f.COUNT_PAPERCUT, 'papercut-unrelated'} and 'lifecycle' not in e.calls and 'card' not in e.calls,
            'partial reviewed-key batch caused a lifecycle or Card effect')

def stale_verified():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = ['papercut-unrelated', f.COUNT_PAPERCUT]
    e.records = lambda keys: [{'slug': key, 'status': 'verified' if key == 'papercut-unrelated' else 'open', 'body': 'canonical', 'duplicate_of': '', 'symptom_hash': key} for key in keys]
    result = r.once()
    t.check(result['already_handled'] == ['papercut-unrelated'] and result['reconciled'] == [f.COUNT_PAPERCUT] and 'promote' in e.calls,
            'stale verified queue membership starved finite admission')

def canonical_partial():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = ['papercut-unrelated', f.COUNT_PAPERCUT]
    e.records = lambda keys: [{'slug': key, 'status': 'partial' if key == 'papercut-unrelated' else 'open', 'body': 'canonical', 'duplicate_of': '', 'symptom_hash': key} for key in keys]
    result = r.once()
    t.check(result['deferred'] == ['papercut-unrelated'] and result['reconciled'] == [f.COUNT_PAPERCUT] and not result['failed'] and 'promote' in e.calls,
            'canonical partial record failed or closed the reviewed batch')

def bounded_duplicate():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = [f.COUNT_PAPERCUT, 'papercut-unrelated']
    e.records = lambda keys: [{'slug': key, 'status': 'open', 'body': 'canonical', 'duplicate_of': '', 'symptom_hash': 'same'} for key in keys]
    result = r.once()
    t.check(result['details']['reviewed_claims'][f.COUNT_PAPERCUT]['same_symptom_reviewed_keys'] == ['papercut-unrelated'] and
            'lifecycle' not in e.calls and not any(a in e.calls for a in ('file', 'surfaces', 'promote')),
            'reviewed symptom duplicate authorized lifecycle or Count admission')

def canonical_duplicate_target():
    r, e, directory = fixture()
    e.records = lambda keys: [{'slug': key, 'status': 'open', 'body': 'canonical', 'duplicate_of': 'papercut-canonical', 'symptom_hash': 'same'} for key in keys]
    result = r.once()
    t.check(result['details']['reviewed_claims'][f.COUNT_PAPERCUT]['duplicate_of'] == 'papercut-canonical' and
            'lifecycle' not in e.calls and 'promote' not in e.calls, 'canonical duplicate target authorized a new Count unit')

def finite_card_hold_facts():
    r, e, directory = fixture()
    original = e.cards
    def cards(keys):
        values = original(keys)
        for i, key in enumerate(keys):
            if key == 'factory-scoped-dispatch-20261008':
                value = t.card(key); value.update(column='backlog', assignee='peer', block_status='needs_human', block_reason='Tom hold')
                values[i] = t.item(value)
        return values
    e.cards = cards; result = r.once()
    facts = result['details']['finite_cards']['factory-scoped-dispatch-20261008']
    t.check(e.calls.count('batch-cards') == 1 and facts == {'column': 'backlog', 'owner': 'peer', 'held': True, 'admission': 'deferred'},
            'finite Card batch omitted backlog owner and hold facts')

def reviewed_absent_duplicate():
    r, e, directory = fixture(); absent = 'papercut-reviewed-verified'
    r.config['lifecycle_reviewed_keys'] = [f.COUNT_PAPERCUT, absent]
    requested = []
    def records(keys):
        requested.append(keys)
        return [{'slug': key, 'status': 'verified' if key == absent else 'open', 'body': 'canonical',
                 'duplicate_of': '', 'symptom_hash': 'same'} for key in keys]
    e.records = records; result = r.once()
    t.check(requested == [[f.COUNT_PAPERCUT, absent]] and absent not in result['already_handled'] and
            result['details']['reviewed_claims'][f.COUNT_PAPERCUT]['same_symptom_reviewed_keys'] == [absent] and
            not any(a in e.calls for a in ('lifecycle', 'file', 'surfaces', 'promote')),
            'reviewed canonical duplicate outside open membership authorized Count work')

def create_only_unavailable():
    r, e, directory = fixture(); runtime = ReconcileRuntime.__new__(ReconcileRuntime)
    runtime.root = r.root; runtime.config = r.config; runtime.kanban = 'private-kanban'; runtime.capture = directory
    policy = (ROOT / 'config/factory-create-only-contract.json').read_bytes()
    (runtime.root / 'config/factory-create-only-contract.json').write_bytes(policy)
    runtime.config['creation_authority'].update(configured=False, contract_sha256=f.strict_json(policy)['contract_sha256'])
    calls = []; reason = None
    def command(*args, **kwargs): calls.append(args); return 0, policy, b''
    with patch.object(f, 'bounded_call', side_effect=command):
        try: runtime.creation_ready()
        except f.Refusal as error: reason = str(error)
    # The valid private policy reaches the public metadata command if this
    # admission fence is removed. Assert the effect boundary before the reason.
    t.check(not calls, 'missing public create-only capability reached a public command')
    t.check(reason == 'public-create-only-capability-unavailable', 'unproved public create-only route accepted')

def bootstrap_hold(reason):
    r, e, directory = fixture(); e.missing = True
    def unavailable(): raise f.Refusal(reason)
    e.bootstrap_ready = unavailable
    result = r.once()
    t.check('lifecycle' in e.calls and not any(call in e.calls for call in ('card', 'file', 'surfaces', 'promote')) and result['failed'] == [f.COUNT_PAPERCUT],
            reason + ' allowed Count creation or promotion')

def lifecycle_intent_unknown():
    r, e, directory = fixture(); r.config['lifecycle_reviewed_keys'] = ['papercut-unrelated', f.COUNT_PAPERCUT]
    e.records = lambda keys: [{'slug': key, 'status': 'verified' if key == 'papercut-unrelated' else 'open', 'body': 'canonical', 'duplicate_of': '', 'symptom_hash': key} for key in keys]
    f.atomic_json(directory / 'lifecycle-close-intent.json', {'version': 1, 'status': 'pending', 'config_sha256': f.value_sha(r.config), 'contract_sha256': r.contract})
    result = r.once()
    t.check(result['failed'] and not any(call in e.calls for call in ('lifecycle', 'card', 'file', 'surfaces', 'promote')),
            'unknown lifecycle intent released a shared effect')

def admission_intent_unknown():
    r, e, directory = fixture(); original = e.guarded
    def uncertain(item, action):
        e.calls.append(action); raise f.Refusal('unknown public guarded write')
    e.guarded = uncertain; first = r.once(); before = e.calls.count('surfaces'); e.guarded = original; second = r.once()
    t.check(first['failed'] and second['failed'] and e.calls.count('surfaces') == before and 'promote' not in e.calls and
            f.read_json(directory / 'admission-intent.json').get('write_intent'), 'unknown admission write was repeated')

CASES = {n: globals()[n] for n in ('admission', 'held', 'owned', 'missing', 'uncertain', 'divergent', 'race', 'occupied', 'lifecycle', 'incomplete', 'boolean_version', 'fair_lifecycle', 'partial_lifecycle')}
CASES['stale_verified'] = stale_verified
CASES['canonical_partial'] = canonical_partial
for reason in ('bootstrap-active', 'bootstrap-missing', 'bootstrap-invalid'):
    CASES[reason] = lambda reason=reason: bootstrap_hold(reason)
CASES['lifecycle_intent_unknown'] = lifecycle_intent_unknown
CASES['admission_intent_unknown'] = admission_intent_unknown
CASES['bounded_duplicate'] = bounded_duplicate
CASES['canonical_duplicate_target'] = canonical_duplicate_target
CASES['finite_card_hold_facts'] = finite_card_hold_facts
CASES['reviewed_absent_duplicate'] = reviewed_absent_duplicate
CASES['create_only_unavailable'] = create_only_unavailable
CASES['unknown_created_key'] = unknown_created_key
CASES['created_witness_drift'] = created_witness_drift
CASES['filing_boolean_version'] = filing_boolean_version
CASES['admission_boolean_version'] = admission_boolean_version
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=CASES); args = p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
