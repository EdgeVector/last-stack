#!/usr/bin/env python3
"""Explicit bootstrap phases under retained raw23 and component authority."""
import argparse
import copy
import importlib.util
import sys
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('factory_cases', ROOT / 'tests/factory-repair.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t); f = t.f
from factory_bootstrap import BootstrapController, BOOTSTRAP_KEYS

class Effects:
    def __init__(self, entry):
        self.entry = entry; self.calls = []; self.fail = False; self.accepted = False
        self.value = t.card(entry['card']); self.value.update(repo=entry['repo'], body='## END STATE\nThe installed component passes.\n',
            column=entry['initial_column'], assignee=entry['initial_owner'], surfaces=['old.test'])
    def check_authority(self, entry): self.calls.append('authority')
    def card(self, entry): return t.item(self.value)
    def write(self, state, operation):
        self.calls.append(operation)
        if self.fail: raise f.Refusal('public-write-timeout')
        if operation == 'surfaces': self.value['surfaces'] = state['entry']['target_surfaces']
        if operation == 'promote': self.value['column'] = 'todo'
        if operation == 'claim': self.value.update(column='doing', assignee=state['owner'])
        if operation == 'claim' and self.accepted:
            self.accepted = False; self.value.update(position='1791510000000', updated_at='2026-10-09T02:00:00.000Z',
                tags=[v for v in self.value['tags'] if not v.startswith(('done_at:', 'first_doing_at:'))] + ['first_doing_at:2026-10-09T02:00:00.000Z'],
                block_status='needs_human', block_reason='claim recovery pending for worker "' + state['owner'] + '": do not work this card until the claim completes')
            witness = t.item(self.value)
            return {'result': 'error', 'code': 'claim_recovery_pending', 'accepted_held': {'version': 1, 'stage': 'accepted-held',
                    'durability': 'durable', 'contract_sha256': '6' * 64, 'guard_snapshot_sha256': state['witness']['snapshot_sha256'],
                    'snapshot_json': witness['snapshot_json'], 'snapshot_sha256': witness['snapshot_sha256']}}
        if operation == 'resume-claim': self.value.update(block_status='', block_reason='')
        if operation == 'proof-mark': self.value['body'] += '\nPROOF: END STATE met PASS bootstrap-action=' + state['intent']['attempt'] + '\n'
        if operation == 'pr-metadata': self.value.update(pr_url=state['entry']['pr_url'], branch=state['entry']['branch'])
        if operation == 'close': self.value['column'] = 'done'
        witness = t.item(self.value)
        return {'durability': 'durable', 'contract_sha256': '6' * 64, 'guard_snapshot_sha256': state['witness']['snapshot_sha256'],
                'next_snapshot_json': witness['snapshot_json'], 'next_snapshot_sha256': witness['snapshot_sha256']}
    def parse(self, fields, pr):
        from closeout_evidence import parse_card_evidence
        return parse_card_evidence(fields, pr)

def fixture(loom=False):
    directory = Path(tempfile.mkdtemp(prefix='bootstrap-fixture-'))
    entries = []
    for key in sorted(BOOTSTRAP_KEYS):
        entry = {'card': key, 'configured': True, 'repo': 'EdgeVector/loom' if 'scoped' in key else 'EdgeVector/fkanban', 'base': 'main',
                 'initial_column': 'doing' if 'scoped' in key else 'backlog', 'initial_owner': 'loom:original' if 'scoped' in key else '',
                 'owner': 'loom:original' if 'scoped' in key else 'loom:factory-bootstrap-fkanban', 'target_surfaces': [],
                 'pr_url': 'https://github.com/EdgeVector/' + ('loom/pull/11' if 'scoped' in key else 'fkanban/pull/195'),
                 'branch': 'kanban/' + key, 'pr_merge_oid': '1' * 40, 'artifact_authority': {}, 'proof': {'sha256': 'a' * 64, 'producer_sha256': 'b' * 64}}
        effects = Effects(entry); entry['original_body_sha256'] = f.sha(effects.value['body'].encode()); entry['original_snapshot_sha256'] = effects.card(entry)['snapshot_sha256']
        entries.append(entry)
    config = {'version': 1, 'entries': entries, 'fkanban_authority': {'contract_sha256': '6' * 64}}
    entry = next(e for e in entries if ('scoped' in e['card']) == loom)
    effects = Effects(entry)
    return BootstrapController(config, directory, effects, 'c' * 64, entry['card']), effects, directory

def complete(loom=False):
    c, e, directory = fixture(loom)
    for _ in range(12):
        result = c.once()
        if result.get('phase') == 'completed': break
    t.check(result.get('phase') == 'completed' and e.value['column'] == 'done', 'explicit bootstrap did not reach canonical done')
    t.check(e.calls.count('claim') == (0 if loom else 1), 'bootstrap changed the original Loom owner or repeated FK claim')
    before = list(e.calls); result = c.once()
    t.check(result['result'] == 'noop' and e.calls == before, 'bootstrap completion repeated a component effect')

def hold():
    c, e, directory = fixture(); c.once(); e.value.update(block_status='needs_human', block_reason='Tom hold')
    t.refused(c.once, 'bootstrap erased a new human hold')
    t.check(e.calls == ['authority'] and e.value['block_reason'] == 'Tom hold', 'bootstrap hold caused a Card mutation')

def changed_body():
    c, e, directory = fixture(); e.value['body'] += 'changed brief\n'
    t.refused(c.once, 'bootstrap accepted a changed initial body')
    t.check(not any(a in e.calls for a in ('claim', 'surfaces', 'close')), 'changed brief caused a write')

def foreign_owner():
    c, e, directory = fixture(True); e.value['assignee'] = 'peer'
    t.refused(c.once, 'bootstrap adopted a foreign owner')

def uncertain():
    c, e, directory = fixture(); c.once(); e.fail = True
    t.refused(c.once, 'bootstrap unknown write was accepted'); before = list(e.calls)
    t.refused(c.once, 'bootstrap repeated an unknown write')
    t.check(e.calls == before and f.read_json(c.path).get('write_intent'), 'unknown write did not retain its exact intent')

def busy_count():
    c, e, directory = fixture(); f.atomic_json(directory / 'slot.json', {'phase': 'execution'})
    t.refused(c.once, 'bootstrap crossed an active count slot')
    t.check(e.calls == [], 'active count caused a bootstrap effect')

def busy_peer():
    c, e, directory = fixture(); peer = next(k for k in BOOTSTRAP_KEYS if k != c.entry['card'])
    f.atomic_json(directory / ('bootstrap-' + peer + '.json'), {'phase': 'reserved'})
    t.refused(c.once, 'bootstrap crossed another retained bootstrap intent')

def malformed_count_complete():
    c, e, directory = fixture(); f.atomic_json(directory / 'slot.json', {'phase': 'completed'})
    t.refused(c.once, 'malformed count completion released bootstrap admission')
    t.check(e.calls == [], 'malformed count completion caused a Card effect')

def malformed_peer_complete():
    c, e, directory = fixture(); peer = next(k for k in BOOTSTRAP_KEYS if k != c.entry['card'])
    f.atomic_json(directory / ('bootstrap-' + peer + '.json'), {'phase': 'completed'})
    t.refused(c.once, 'malformed peer completion released bootstrap admission')
    t.check(e.calls == [], 'malformed peer completion caused a Card effect')

def completion_drift():
    c, e, directory = fixture()
    for _ in range(12):
        if c.once().get('phase') == 'completed': break
    state = f.read_json(c.path); state['completion']['owner'] = 'peer'; state['completion_sha256'] = f.value_sha(state['completion']); f.atomic_json(c.path, state)
    t.refused(c.once, 'self-hashed bootstrap completion released another owner')

def completion_receipt_drift(field):
    c, e, directory = fixture()
    for _ in range(12):
        if c.once().get('phase') == 'completed': break
    state = f.read_json(c.path)
    state['write_receipts'][-1][field] = 'f' * 64
    from factory_bootstrap import completion_value
    state['completion'] = completion_value(state); state['completion_sha256'] = f.value_sha(state['completion']); f.atomic_json(c.path, state)
    t.refused(c.once, 'self-hashed wrong ' + field + ' released bootstrap completion')

def retained_intent_drift():
    c, e, directory = fixture(); c.once()
    state = f.read_json(c.path); state['intent']['component_receipt_sha256'] = 'f' * 64
    f.atomic_json(c.path, state); before = list(e.calls)
    t.refused(c.once, 'changed retained component intent authorized bootstrap write')
    t.check(e.calls == before, 'changed retained component intent reached a shared effect')

def retained_chain_drift():
    c, e, directory = fixture(); c.once(); c.once()
    state = f.read_json(c.path); state['write_receipts'][0]['guard_snapshot_sha256'] = 'f' * 64
    f.atomic_json(c.path, state); before = list(e.calls)
    t.refused(c.once, 'wrong active guard chain authorized bootstrap write')
    t.check(e.calls == before, 'wrong active guard chain reached a shared effect')

def retained_chain_cap():
    c, e, directory = fixture(); c.once()
    state = f.read_json(c.path); witness = state['witness']
    receipt = {'durability': 'durable', 'contract_sha256': '6' * 64,
        'guard_snapshot_sha256': witness['snapshot_sha256'], 'next_snapshot_json': witness['snapshot_json'],
        'next_snapshot_sha256': witness['snapshot_sha256']}
    state['write_receipts'] = [copy.deepcopy(receipt) for _ in range(16)]
    f.atomic_json(c.path, state); before = list(e.calls)
    t.refused(c.once, 'bootstrap exceeded the finite receipt count before write')
    t.check(not any(a in e.calls[len(before):] for a in ('surfaces', 'promote', 'claim', 'close')), 'receipt cap reached a Card write')

def accepted_held(changed=False):
    c, e, directory = fixture(); e.accepted = True
    for _ in range(4): result = c.once()
    t.check(result.get('phase') == 'claim-recovery-pending', 'bootstrap lost the durable accepted-held receipt')
    state = f.read_json(c.path)
    t.check(state['witness']['snapshot_sha256'] == t.item(e.value)['snapshot_sha256'] and state['accepted_held']['durability'] == 'durable', 'bootstrap replaced accepted-held witness')
    if changed:
        e.value.update(block_reason='new same-owner human hold'); before = list(e.calls)
        t.refused(c.once, 'bootstrap cleared a later same-owner hold')
        t.check(e.calls == before and e.value['block_reason'] == 'new same-owner human hold', 'accepted-held drift reached a resume mutation')
    else:
        c.once(); t.check(e.calls.count('resume-claim') == 1 and e.value['block_reason'] == '', 'bootstrap did not use one explicit accepted-held resume')
        for _ in range(6):
            if c.once().get('phase') == 'completed': break
        t.check(e.value['column'] == 'done', 'accepted-held bootstrap could not finish')

CASES = {'fkanban_positive': complete, 'loom_owner': lambda: complete(True), 'hold': hold, 'changed_body': changed_body,
         'foreign_owner': foreign_owner, 'uncertain': uncertain, 'busy_count': busy_count, 'busy_peer': busy_peer, 'completion_drift': completion_drift,
         'malformed_count_complete': malformed_count_complete, 'malformed_peer_complete': malformed_peer_complete}
CASES['accepted_held'] = accepted_held
CASES['accepted_hold_changed'] = lambda: accepted_held(True)
CASES['completion_guard'] = lambda: completion_receipt_drift('guard_snapshot_sha256')
CASES['completion_next'] = lambda: completion_receipt_drift('next_snapshot_sha256')
CASES['retained_intent_drift'] = retained_intent_drift
CASES['retained_chain_drift'] = retained_chain_drift
CASES['retained_chain_cap'] = retained_chain_cap
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=CASES); args = p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
