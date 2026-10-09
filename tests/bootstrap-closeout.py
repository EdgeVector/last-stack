#!/usr/bin/env python3
"""Explicit bootstrap phases under retained raw23 and component authority."""
import argparse
import base64
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('factory_cases', ROOT / 'tests/factory-repair.py')
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t); f = t.f
import factory_bootstrap as b
from factory_bootstrap import BootstrapController, BOOTSTRAP_KEYS

ORIGINAL_SURFACES = ['test/board-cards-reap-column-only.test.ts']
SURFACES_REFUSAL = b'kanban: Surfaces must be bounded explicit repo-relative file paths or path globs without traversal or bare directory patterns.\n'

class Effects:
    def __init__(self, entry):
        self.entry = entry; self.calls = []; self.fail = False; self.accepted = False
        self.value = t.card(entry['card']); self.value.update(repo=entry['repo'], body='## END STATE\nThe installed component passes.\n',
            column=entry['initial_column'], assignee=entry['initial_owner'], surfaces=[] if entry['repo'] == 'EdgeVector/loom' else list(ORIGINAL_SURFACES))
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

# This is a private grammar adapter, not an installed Mini attestation.
# It runs BootstrapRuntime.write and refuses every argv outside the finite path.
PRIVATE_CLI = r'''#!/usr/bin/env python3
import hashlib, json, sys
from pathlib import Path
root = Path(__file__).resolve().parent
args = sys.argv[1:]
with (root / 'argv.jsonl').open('a') as stream:
    stream.write(json.dumps(args) + '\n')
def refuse(message, rc=79):
    print(message, file=sys.stderr); sys.exit(rc)
def digest(data): return hashlib.sha256(data).hexdigest()
if '--surfaces' in args and args[args.index('--surfaces') + 1] == '':
    refuse('kanban: Surfaces must be bounded explicit repo-relative file paths or path globs without traversal or bare directory patterns.', 1)
if len(args) < 6 or args[-1] != '--json' or args.count('--guard-snapshot') != 1 or args.count('--snapshot-sha256') != 1:
    refuse('unexpected private guarded CLI argv')
index = args.index('--guard-snapshot')
front, suffix = args[:index], args[index:]
owner = None
if suffix[:1] != ['--guard-snapshot'] or suffix[2:3] != ['--snapshot-sha256']:
    refuse('unexpected private guard order')
if suffix[4:] == ['--json']:
    pass
elif len(suffix) == 7 and suffix[4] == '--expect-assignee' and suffix[6] == '--json':
    owner = suffix[5]
else:
    refuse('unexpected private guarded owner argv')
path = Path(suffix[1])
if path.parent.resolve() != root or not path.is_file() or path.stat().st_size > 1048576:
    refuse('unexpected private witness path')
raw = path.read_bytes(); witness = json.loads(raw)
if digest(raw) != suffix[3] or not raw.endswith(b'\n') or set(witness) != {'version', 'schema_hash', 'fields'}:
    refuse('private witness bytes differ')
fields = json.loads((root / 'canonical.json').read_text()); slug = fields['slug']
mode = (root / 'mode').read_text().strip() if (root / 'mode').exists() else 'ok'
if mode == 'refuse-promote':
    if front != ['move', slug, 'todo', '--from', 'backlog']: refuse('unexpected private refusal route')
    refuse('private promote refusal', 1)
if witness['fields'] != fields: refuse('private canonical guard conflict')
if owner is not None and owner != fields['assignee']: refuse('private owner conflict')
if fields['block_status'] not in ('', 'none') or fields['block_reason']:
    refuse('private human hold')
if front == ['move', slug, 'todo', '--from', 'backlog']:
    if owner != '' or fields['column'] != 'backlog': refuse('private promotion scope')
    fields['column'] = 'todo'
elif len(front) == 6 and front[:4] == ['pickup', 'claim-v2', '--only-card', slug] and front[4] == '--worker':
    if owner is not None or not front[5] or fields['assignee'] != '' or fields['column'] != 'todo':
        refuse('private claim scope')
    fields.update(column='doing', assignee=front[5])
elif len(front) == 3 and front[:2] == ['mark', slug]:
    if owner != fields['assignee'] or not owner or fields['column'] != 'doing' or not front[2].startswith('PROOF: END STATE met PASS bootstrap-action='):
        refuse('private marker scope')
    fields['body'] += '\n' + front[2] + '\n'
elif len(front) == 6 and front[:3] == ['set', slug, '--pr-url'] and front[4] == '--branch':
    if not owner or fields['column'] != 'doing' or not front[3].startswith('https://github.com/EdgeVector/fkanban/pull/') or not front[5].startswith('kanban/'):
        refuse('private PR scope')
    fields.update(pr_url=front[3], branch=front[5])
elif front == ['move', slug, 'done', '--from', 'doing']:
    if not owner or fields['column'] != 'doing': refuse('private terminal scope')
    fields['column'] = 'done'
else:
    refuse('unexpected private finite command')
fields['updated_at'] = '2026-10-09T00:00:00.' + str(len((root / 'argv.jsonl').read_text().splitlines())).zfill(3) + 'Z'
(root / 'canonical.json').write_text(json.dumps(fields) + '\n')
with (root / 'writes.jsonl').open('a') as stream: stream.write(json.dumps(front) + '\n')
text = json.dumps({'version': 1, 'schema_hash': witness['schema_hash'], 'fields': fields}) + '\n'
print(json.dumps({'result': 'claimed' if front[0] == 'pickup' else 'updated',
    'durability': 'durable', 'contract_sha256': (root / 'writer-contract').read_text().strip(), 'guard_snapshot_sha256': suffix[3],
    'next_snapshot_json': text, 'next_snapshot_sha256': digest(text.encode())}))
'''

class PrivateRuntime(Effects):
    def __init__(self, entry, config, directory):
        super().__init__(entry)
        self.directory = directory
        self.witness = t.item(self.value)
        self.binary = directory / 'private-kanban'
        self.binary.write_text(PRIVATE_CLI); self.binary.chmod(0o755)
        f.atomic_json(directory / 'canonical.json', self.value)
        (directory / 'writer-contract').write_text(config['fkanban_authority']['contract_sha256'])
        with patch.object(b, 'verify_fk', return_value=self.binary):
            self.runtime = b.BootstrapRuntime(directory, config, directory)
    def card(self, entry):
        self.value = f.read_json(self.directory / 'canonical.json')
        return copy.deepcopy(self.witness) if self.value == f.validate_snapshot(self.witness, entry['card'])['fields'] else t.item(self.value)
    def write(self, state, operation):
        self.calls.append(operation)
        result = self.runtime.write(state, operation)
        self.value = f.read_json(self.directory / 'canonical.json')
        self.witness = {'slug': self.entry['card'], 'snapshot_json': result['next_snapshot_json'],
                        'snapshot_sha256': result['next_snapshot_sha256']}
        return result

def runtime_state(c):
    c.once()
    state = f.read_json(c.path)
    state['write_intent'] = {'operation': 'surfaces', 'witness_sha256': state['witness']['snapshot_sha256'], 'attempt': '1' * 32}
    return state

def public_empty_surfaces_refusal():
    # Synthetic grammar proof only. The current runtime has no surfaces route.
    c, e, directory = fixture(); e = PrivateRuntime(e.entry, c.config, directory)
    state = runtime_state(c); item = f.validate_snapshot(state['witness'], c.entry['card'])
    witness = directory / ('bootstrap-witness-' + item['sha256'] + '.json'); witness.write_bytes(item['text'].encode())
    args = ['set', c.entry['card'], '--surfaces', '', '--guard-snapshot', str(witness), '--snapshot-sha256',
            item['sha256'], '--expect-assignee', '', '--json']
    before = (directory / 'canonical.json').read_bytes()
    result = subprocess.run([str(e.binary), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    argv = f.strict_json((directory / 'argv.jsonl').read_text().strip())
    t.check(not (directory / 'writes.jsonl').exists() and (directory / 'canonical.json').read_bytes() == before,
            'empty surfaces adapter issued a Card write')
    t.check(argv == args, 'empty surfaces did not reach the exact guarded public argv')
    t.check(result.returncode == 1 and result.stdout == b'' and result.stderr == SURFACES_REFUSAL,
            'empty surfaces adapter lost the actual refusal capture')

def runtime_nonzero_diagnostic():
    c, e, directory = fixture(); e = PrivateRuntime(e.entry, c.config, directory)
    state = runtime_state(c); state['write_intent']['operation'] = 'promote'
    (directory / 'mode').write_text('refuse-promote')
    before = (directory / 'canonical.json').read_bytes(); error = None
    try: e.write(state, 'promote')
    except (f.Refusal, ValueError) as caught: error = caught
    prefix = directory / ('bootstrap-public-' + state['write_intent']['attempt'])
    capture = f.read_json(prefix.with_suffix('.capture.json'))
    argv = f.strict_json((directory / 'argv.jsonl').read_text().strip())
    t.check(not (directory / 'writes.jsonl').exists() and (directory / 'canonical.json').read_bytes() == before,
            'runtime nonzero refusal issued a Card write')
    t.check(argv == ['move', c.entry['card'], 'todo', '--from', 'backlog', '--guard-snapshot',
        str(directory / ('bootstrap-witness-' + state['witness']['snapshot_sha256'] + '.json')), '--snapshot-sha256',
        state['witness']['snapshot_sha256'], '--expect-assignee', '', '--json'],
        'runtime nonzero did not reach supported promotion argv')
    t.check(capture['rc'] == 1 and prefix.with_suffix('.out').read_bytes() == b'' and prefix.with_suffix('.err').read_bytes() == b'private promote refusal\n',
            'runtime lost the nonzero capture')
    t.check(error is not None and 'rc=1' in str(error) and 'private promote refusal' in str(error),
            'runtime omitted rc and exact stderr before JSON parse')

def runtime_accepted_held():
    c, e, directory = fixture(); e = PrivateRuntime(e.entry, c.config, directory)
    state = runtime_state(c); state['write_intent']['operation'] = 'claim'
    original = state['witness']; fields = f.validate_snapshot(original, c.entry['card'])['fields']
    fields.update(column='todo'); state['witness'] = t.item(fields)
    before = state['witness']; fields = copy.deepcopy(fields)
    fields.update(column='doing', assignee=state['owner'], position='1791510000000', updated_at='2026-10-09T02:00:00.000Z',
        tags=['first_doing_at:2026-10-09T02:00:00.000Z'], block_status='needs_human', block_reason=f.synthetic_claim_reason(state['owner']))
    held = t.item(fields)
    reply = {'result': 'error', 'code': 'claim_recovery_pending', 'accepted_held': {'version': 1, 'stage': 'accepted-held',
        'durability': 'durable', 'contract_sha256': '6' * 64, 'guard_snapshot_sha256': before['snapshot_sha256'],
        'snapshot_json': held['snapshot_json'], 'snapshot_sha256': held['snapshot_sha256']}}
    f.validate_claim_stage_one(before, held, state['owner'])
    calls = []
    def captured(argv, timeout):
        calls.append(argv)
        return 1, (json.dumps(reply) + '\n').encode(), b'private claim clear refusal\n'
    result = None
    with patch.object(b, 'bounded_call', side_effect=captured):
        try: result = e.runtime.write(state, 'claim')
        except f.Refusal: pass
    t.check(result == reply and len(calls) == 1 and calls[0][1:7] ==
        ['pickup', 'claim-v2', '--only-card', c.entry['card'], '--worker', state['owner']],
        'runtime lost the nonzero durable accepted-held receipt')



# Direct source admission uses the real Runtime parser and private metadata.
# verify_fk isolates the already-tested artifact verification boundary. No CLI runs.
def runtime_source_fixture():
    directory = Path(tempfile.mkdtemp(prefix='bootstrap-runtime-source-fixture-'))
    binary = directory / 'private-kanban'; binary.write_bytes(b'private source fixture only\n')
    policy = copy.deepcopy(b.RECOVERY_POLICY)
    artifact = {'source_commit': policy['writer_source_oid'], 'contract_sha256': policy['writer_contract_sha256'],
                'source_manifest_sha256': policy['source_manifest_sha256'],
                'source_manifest': [{'path': path, 'sha256': digest} for path, digest in policy['source_files'].items()]}
    path = directory / 'guarded-contract.json'; f.atomic_json(path, artifact)
    return {'directory': directory, 'binary': binary, 'policy': policy, 'artifact': artifact, 'path': path,
            'config': {'fkanban_authority': {'private_fixture': 'source-authority'}}, 'calls': []}

def runtime_source_check(case):
    def verified(authority):
        case['calls'].append(('verify_fk', copy.deepcopy(authority)))
        return case['binary']
    def forbidden(*args, **kwargs):
        case['calls'].append(('public-command', args, kwargs))
        raise AssertionError('runtime source check issued a public command')
    before = {p: p.read_bytes() for p in (case['binary'], case['path'])}
    error = None; accepted = False
    with patch.object(b, 'verify_fk', side_effect=verified), patch.object(b, 'bounded_call', side_effect=forbidden):
        runtime = b.BootstrapRuntime(case['directory'], case['config'], case['directory'])
        try:
            runtime.check_refusal_source(case['policy']); accepted = True
        except (f.Refusal, ValueError, TypeError, KeyError) as caught: error = caught
    t.check(all(p.read_bytes() == data for p, data in before.items()) and
            all(call[0] == 'verify_fk' for call in case['calls']),
            'runtime source check changed private bytes or issued a public effect')
    t.check(all(call[1] == case['config']['fkanban_authority'] for call in case['calls']),
            'runtime source check replaced the retained writer authority')
    return accepted, error

def runtime_source_positive():
    case = runtime_source_fixture(); accepted, error = runtime_source_check(case)
    t.check(accepted and error is None and len(case['calls']) == 2,
            'runtime source rejected the complete exact parser authority')

def runtime_source_refused(change, label, reason):
    case = runtime_source_fixture(); change(case); f.atomic_json(case['path'], case['artifact'])
    accepted, error = runtime_source_check(case)
    # Admission loss is checked before the diagnostic. A different downstream
    # error cannot prove this property's guard accepts the defect.
    t.check(not accepted, 'runtime source ' + label + ' was accepted')
    t.check(isinstance(error, f.Refusal) and str(error) == reason,
            'runtime source ' + label + ' reached an unrelated refusal')

RUNTIME_SOURCE_NEGATIVES = {
    'policy': (lambda c: c['policy'].update(writer_source_oid='f' * 40), 'bootstrap-recovery-source-policy'),
    'policy_boolean': (lambda c: c['policy'].update(version=True), 'bootstrap-recovery-source-policy'),
    'oid': (lambda c: c['artifact'].update(source_commit='f' * 40), 'bootstrap-recovery-source-authority'),
    'contract': (lambda c: c['artifact'].update(contract_sha256='f' * 64), 'bootstrap-recovery-source-authority'),
    'identity': (lambda c: c['artifact'].update(source_manifest_sha256='f' * 64), 'bootstrap-recovery-source-authority'),
    'missing': (lambda c: c['artifact']['source_manifest'].pop(), 'bootstrap-recovery-source-parser'),
    'duplicate': (lambda c: c['artifact']['source_manifest'].append(copy.deepcopy(c['artifact']['source_manifest'][0])), 'bootstrap-recovery-source-parser'),
    'hash': (lambda c: c['artifact']['source_manifest'][0].update(sha256='f' * 64), 'bootstrap-recovery-source-parser'),
    'list_type': (lambda c: c['artifact'].update(source_manifest={'wrong': 'nonempty'}), 'bootstrap-recovery-source-manifest'),
    'empty': (lambda c: c['artifact'].update(source_manifest=[]), 'bootstrap-recovery-source-manifest'),
    'cap': (lambda c: c['artifact']['source_manifest'].extend({'path': 'private-extra-' + str(i), 'sha256': 'a' * 64} for i in range(508)), 'bootstrap-recovery-source-manifest'),
    'entry_type': (lambda c: c['artifact']['source_manifest'].append('wrong-nonempty'), 'bootstrap-recovery-source-manifest'),
    'path_type': (lambda c: c['artifact']['source_manifest'].append({'path': 7, 'sha256': 'a' * 64}), 'bootstrap-recovery-source-manifest'),
    'sha_type': (lambda c: c['artifact']['source_manifest'].append({'path': 'private-extra', 'sha256': 7}), 'bootstrap-recovery-source-manifest'),
}


def fixture(loom=False):
    directory = Path(tempfile.mkdtemp(prefix='bootstrap-fixture-'))
    entries = []
    for key in sorted(BOOTSTRAP_KEYS):
        entry = {'card': key, 'configured': True, 'repo': 'EdgeVector/loom' if 'scoped' in key else 'EdgeVector/fkanban', 'base': 'main',
                 'initial_column': 'doing' if 'scoped' in key else 'backlog', 'initial_owner': 'loom:original' if 'scoped' in key else '',
                 'owner': 'loom:original' if 'scoped' in key else 'loom:factory-bootstrap-fkanban',
                 'target_surfaces': [] if 'scoped' in key else list(ORIGINAL_SURFACES),
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
    if not loom: e = PrivateRuntime(e.entry, c.config, directory); c.effects = e
    original_surfaces = list(e.value['surfaces'])
    for _ in range(12):
        result = c.once()
        if result.get('phase') == 'completed': break
    t.check(e.value['surfaces'] == original_surfaces and 'surfaces' not in e.calls, 'bootstrap changed original surfaces or issued a surfaces write')
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
    c, e, directory = fixture(); c.once(); c.once(); e.fail = True
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
    c, e, directory = fixture(); c.once(); c.once(); c.once()
    state = f.read_json(c.path); state['write_receipts'][0]['guard_snapshot_sha256'] = 'f' * 64
    f.atomic_json(c.path, state); before = list(e.calls)
    t.refused(c.once, 'wrong active guard chain authorized bootstrap write')
    t.check(e.calls == before, 'wrong active guard chain reached a shared effect')

def retained_chain_cap():
    c, e, directory = fixture(); c.once(); c.once()
    t.check(f.read_json(c.path)['phase'] == 'promote', 'receipt cap fixture did not reach a public write phase')
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

# Exact observed failed-state bytes; the test never reads live STATE.
OLD_STATE_BYTES = base64.b64decode("""
eyJjb25maWdfc2hhMjU2IjoiNDEzNTM5NDEwYzk1NDE4ZjUyMDgzMzU0MTVjMWI3YmMwYWZjMjAz
MDljMzVhNmVhOGVmNWZjNjc1NmU2Zjk4YSIsImNvbnRyYWN0X3NoYTI1NiI6IjQ1MjliZTMxODMx
YjA5NzU0YjgzNWEyNTFhNGUzNDI0MDhjMDFlNDQ0NDY0OGRlZDhhYjZkMjY1ZThmZGFlMTciLCJl
bnRyeSI6eyJhcnRpZmFjdF9hdXRob3JpdHkiOnsiYXBwIjoiZmthbmJhbiIsImNvbnRyYWN0X3No
YTI1NiI6ImJlYThhNDk1ODM5MzkwMTUzYjc4ZDQ4MjdiMWY5ZTk5NmRmZjAzNzg0MWRmODU3ODNm
NDlhZGJkZDgyNDExMjgiLCJjdXJyZW50Ijoifi8uaG9zdC10cmFjay9hcHBzL2ZrYW5iYW4vY3Vy
cmVudCIsIm1hbmlmZXN0X2ZpbGVfc2hhMjU2IjoiM2FmMjNkZjgwZjcwMjBjNzkzNzEwZjJjYWQ5
NTBkNzJiMjg0NTdlNDA1YzAzYTg2NmQwYjIzODExNGI0YWViNiIsIm1hbmlmZXN0X3BhdGgiOiJ+
Ly5sYXN0Z2l0L2FydGlmYWN0cy9tYW5pZmVzdHMvODk5ZTViOTg1NTc0YjYwNmVlMThhZjI5NDUz
MDAwNmUyMTIwMDFmYzc3MDQ4Mjg4N2ZjNzBlM2ExNTdlNGNjMi5qc29uIiwibWFuaWZlc3Rfc2hh
MjU2IjoiODk5ZTViOTg1NTc0YjYwNmVlMThhZjI5NDUzMDAwNmUyMTIwMDFmYzc3MDQ4Mjg4N2Zj
NzBlM2ExNTdlNGNjMiIsInJvb3QiOiJ+Ly5ob3N0LXRyYWNrL2FwcHMvZmthbmJhbi92ZXJzaW9u
cy84OTllNWI5ODU1NzRiNjA2ZWUxOGFmMjk0NTMwMDA2ZTIxMjAwMWZjNzcwNDgyODg3ZmM3MGUz
YTE1N2U0Y2MyIiwic291cmNlX29pZCI6ImU4MDc2OTg1NzhlMGQwNWFjMDllZGUzMjk0MWM1MmJl
YjE1MzdhMWQifSwiYmFzZSI6Im1haW4iLCJicmFuY2giOiJrYW5iYW4vZmFjdG9yeS1ndWFyZGVk
LWNsb3Nlb3V0LTIwMjYxMDA4IiwiY2FyZCI6ImZhY3RvcnktZ3VhcmRlZC1jbG9zZW91dC0yMDI2
MTAwOCIsImNvbmZpZ3VyZWQiOnRydWUsImluaXRpYWxfY29sdW1uIjoiYmFja2xvZyIsImluaXRp
YWxfb3duZXIiOiIiLCJvcmlnaW5hbF9ib2R5X3NoYTI1NiI6Ijk1MzdiZjQzNTI5NDhmMGI3NDJj
ZDVhMjk5NzNjNWZhNDgyNmQxOTBiODg3NjI5NWZhMmFjYTQ2N2E5NDEwZmYiLCJvcmlnaW5hbF9z
bmFwc2hvdF9zaGEyNTYiOiJkMjQ1NWNhMTk2MWQ0MGFkNjFjY2IwYjE5Nzk0MzU5MDRkZGFlMTM2
MmMwNmJjMmYzM2UwODRhOTBhNDk2OTE4Iiwib3duZXIiOiJsb29tOmZhY3RvcnktYm9vdHN0cmFw
LWZrYW5iYW4iLCJwcl9tZXJnZV9vaWQiOiIzYTg5OWFlZGViOGZmNWE2YTk3ZGQ0Y2U5NzBlZjgx
ZmE3NTEzNGQyIiwicHJfdXJsIjoiaHR0cHM6Ly9naXRodWIuY29tL0VkZ2VWZWN0b3IvZmthbmJh
bi9wdWxsLzE5NSIsInByb29mIjp7ImFydGlmYWN0Ijp7ImNsaV9zaGEyNTYiOiI5ODYxOTA5ZWI5
ZjU4MzA5ODA1NThmMjgyZmE2YzJlYjFhNDQzYmI0NDRjZGU2NTM0ZDI4OTg4NjMxYmUwNThmIiwi
Y29udHJhY3Rfc2hhMjU2IjoiYmVhOGE0OTU4MzkzOTAxNTNiNzhkNDgyN2IxZjllOTk2ZGZmMDM3
ODQxZGY4NTc4M2Y0OWFkYmRkODI0MTEyOCIsIm1jcF9zaGEyNTYiOiI0OGZiZjMwOGUyOGIwMGIw
NjE4ZjcyZGVjZjFkNzcxY2NmYTk2OWE3OGFjODQ0YzI0NDQzODdkZDU2OTQ1N2MyIiwic291cmNl
X2NvbW1pdCI6ImU4MDc2OTg1NzhlMGQwNWFjMDllZGUzMjk0MWM1MmJlYjE1MzdhMWQifSwiYnVp
bGQiOiIwLjIzLjMtMjY5My1nYjcwNDE4OTY3IiwiY2hlY2tzIjo0MCwia2luZCI6ImZrYW5iYW4t
aW5zdGFsbGVkLXB1YmxpYy12MSIsIm9ic2VydmF0aW9ucyI6MjksInBhdGgiOiJ+Ly5sb2NhbC9z
dGF0ZS9sYXN0LXN0YWNrL2ZhY3RvcnktYm9vdHN0cmFwLXByb29mcy8yMDI2MTAwOS9ma2FuYmFu
LXN1Y2Nlc3Nvci9ldmlkZW5jZS5qc29uIiwicHJvZHVjZXJfcGF0aCI6In4vLmxvY2FsL3N0YXRl
L2xhc3Qtc3RhY2svZmFjdG9yeS1ib290c3RyYXAtcHJvb2ZzLzIwMjYxMDA5L2ZrYW5iYW4tc3Vj
Y2Vzc29yL3Byb2R1Y2VyLnRzIiwicHJvZHVjZXJfc2hhMjU2IjoiNTAzMTRhMjE4NmE0ZjAyNjUw
YjA0MzExOGE4NmY0MzkzMzBmOWJiODdkNGFmNWQ2Nzk1YTMzZTVmNjdiNjc5NSIsInJlc3RhcnQi
OnsiYWJzZW50X2Rlc3RpbmF0aW9ucyI6MjUsImNhcmRzIjozOSwiZGVzdGluYXRpb25zIjoxNywi
cGFzc2VkIjp0cnVlfSwicmVzdWx0IjoicGFzc2VkIiwic2hhMjU2IjoiNjkwNzI1NmFmZTg0OWM0
ZjJlZGViMDZkMDY4MTYzY2U1ZDA0MmQxYTk4YjIwOTk4MzU3MjhhNTEyODMzMzM5YiIsInZlcnNp
b24iOjF9LCJyZXBvIjoiRWRnZVZlY3Rvci9ma2FuYmFuIiwidGFyZ2V0X3N1cmZhY2VzIjpbXX0s
ImludGVudCI6eyJhdHRlbXB0IjoiOThkMjA0YTc1OWU5NGE4NDkwYWYzODkwZWQ1YTNjOWQiLCJj
b21wb25lbnRfcmVjZWlwdF9zaGEyNTYiOiI2OTA3MjU2YWZlODQ5YzRmMmVkZWIwNmQwNjgxNjNj
ZTVkMDQyZDFhOThiMjA5OTgzNTcyOGE1MTI4MzMzMzliIiwiaW5pdGlhbF9zbmFwc2hvdF9zaGEy
NTYiOiJkMjQ1NWNhMTk2MWQ0MGFkNjFjY2IwYjE5Nzk0MzU5MDRkZGFlMTM2MmMwNmJjMmYzM2Uw
ODRhOTBhNDk2OTE4IiwicHJvZHVjZXJfc2hhMjU2IjoiNTAzMTRhMjE4NmE0ZjAyNjUwYjA0MzEx
OGE4NmY0MzkzMzBmOWJiODdkNGFmNWQ2Nzk1YTMzZTVmNjdiNjc5NSJ9LCJvd25lciI6Imxvb206
ZmFjdG9yeS1ib290c3RyYXAtZmthbmJhbiIsInBoYXNlIjoicmVzZXJ2ZWQiLCJ2ZXJzaW9uIjox
LCJ3aXRuZXNzIjp7InNsdWciOiJmYWN0b3J5LWd1YXJkZWQtY2xvc2VvdXQtMjAyNjEwMDgiLCJz
bmFwc2hvdF9qc29uIjoie1widmVyc2lvblwiOjEsXCJzY2hlbWFfaGFzaFwiOlwiYmM5NDFkYmM2
MzBmMTI3ODg0NTZkNWY1OTY0MzgzZGVjN2EyZDY0ZDZmMWUxYjkxZDMyNzNhZTZlMzJlN2FhMVwi
LFwiZmllbGRzXCI6e1wiYXNzaWduZWVcIjpcIlwiLFwiYmFzZVwiOlwibWFpblwiLFwiYmxvY2tf
cmVhc29uXCI6XCJcIixcImJsb2NrX3N0YXR1c1wiOlwiXCIsXCJib2FyZFwiOlwiZGVmYXVsdFwi
LFwiYm9keVwiOlwiUmVwbzogRWRnZVZlY3Rvci9ma2FuYmFuXFxuS2luZDogcHJcXG5Xb3JrLWNs
YXNzOiByZXBhaXJcXG5EaWZmaWN1bHR5OiBoYXJkXFxuQmFzZTogbWFpblxcbk5vcnRoIFN0YXI6
IG5vcnRoLXN0YXItcG9ydGFibGUtcm91dGluZS1mbGVldFxcbk1pbGVzdG9uZTogbXMtZmFjdG9y
eS1oZWFsLXZpYS1zdGF0ZS1tYWNoaW5lXFxuXFxuIyMgR09BTFxcbkdpdmUgdGhlIGFwcHJvdmVk
IHNlcmlhbCBmYWN0b3J5IGEgcHVibGljIENhcmQgd3JpdGUgcGF0aCB0aGF0IHJlZnVzZXMgY2hh
bmdlZCBvd25lciwgY29sdW1uLCBodW1hbiBob2xkLCBib2R5LCBvciByZWNvcmQgdGltZXN0YW1w
IGJlZm9yZSBhbiBhdG9taWMgdXBkYXRlLiBUaGUgY3VycmVudCBvd25lci1vbmx5IHBhdGggY2Fu
IGVyYXNlIGEgc2FtZS1vd25lciBodW1hbiBob2xkLlxcblxcblRoZSBleGFjdCBjbGFpbSBjdXJy
ZW50bHkgdXNlcyBhIGNvbHVtbi1vbmx5IGd1YXJkLiBJdCBjYW4gb3ZlcndyaXRlIGFuIG93bmVy
LCBib2R5LCBvciBodW1hbiBob2xkIGFmdGVyIGFkbWlzc2lvbi4gSXRzIHJlY292ZXJ5LWhvbGQg
Y2xlYXIgdXNlcyBhbiBvd25lci1vbmx5IGd1YXJkLiBUaGUgc2FtZSByZXBhaXIgbXVzdCBndWFy
ZCBib3RoIHN0YWdlcy5cXG5cXG4jIyBFTkQgU1RBVEVcXG5UaGUgaW5zdGFsbGVkIHB1YmxpYyBD
TEkgY2FuIGFwcGVuZCBhbiBleGFjdCBwcm9vZiBtYXJrZXIsIHN0YW1wIHRoZSBhcHByb3ZlZCBQ
UiBhbmQgYnJhbmNoLCBhbmQgY2xvc2UgYW4gdW5oZWxkIGRvaW5nIENhcmQgdW5kZXIgYSBwcm92
ZWQgY29tcG91bmQgc25hcHNob3QgZ3VhcmQuIEEgY2hhbmdlZCBvd25lciwgY29sdW1uLCBibG9j
ayBzdGF0dXMsIGJsb2NrIHJlYXNvbiwgYm9keSwgb3IgdXBkYXRlZF9hdCByZWplY3RzIHRoZSBl
bnRpcmUgQ2FyZCBhbmQgZGVzdGluYXRpb24gQm9hcmRDYXJkcyBiYXRjaC4gTm8gcGFydGlhbCBk
ZXN0aW5hdGlvbiwgdW5ndWFyZGVkIHJldHJ5LCBvd25lciBjaGFuZ2UsIGZvcmNlLCBvciBob2xk
IGNsZWFyIG9jY3Vycy4gVGhlIHByaW9yIHJlY292ZXJ5IEFQSXMgcHJlc2VydmUgdGhlaXIgc3Vw
cG9ydGVkIGJlaGF2aW9yIHdpdGggc3Ryb25nZXIgZ3VhcmRzLiBVbmtub3duIG5vZGUgYnVpbGRz
IHJlZnVzZSB3cml0ZXMuIFNvdXJjZSBhbmQgcHJvZHVjdGlvbiB3cmFwcGVyIGNoZWNrcyBwcm92
ZSB2YWxpZCBhcHBlbmQgYW5kIHRlcm1pbmFsIGNsb3NlLCBhbGwgbmVnYXRpdmUgcmFjZXMsIGR1
cmFibGUgcmVjZWlwdHMsIGFuZCBwcm9jZXNzIHJlc3RhcnQgb24gYSBmcmVzaCBzeW50aGV0aWMg
TWluaS4gVGhlIHByaW1hcnkgTWluaSByZW1haW5zIHVuY2hhbmdlZC4gVGhlIG9mZmljaWFsIGlu
c3RhbGxlZCBDTEkgcGFzc2VzIGEgYm91bmRlZCBjb250cmFjdCBjaGVjayBiZWZvcmUgdGhlIG5l
eHQgc2VyaWFsIHNvdXJjZSBjaGFuZ2UuXFxuXFxuIyMgU0NPUEVcXG5SZXVzZSB0aGUgZXhpc3Rp
bmcgYXRvbWljIHVwZGF0ZSBiYXRjaCBhbmQgY2hlY2tlZCBzY2hlbWEgYmluZGluZ3MuIE1pbmky
NDMzNCBzdXBwb3J0cyBzZXZlcmFsIGNvbmRpdGlvbmFsIG5vLW9wIHVwZGF0ZXMgb24gb25lIGNh
bm9uaWNhbCBDYXJkIGtleSBwbHVzIHRoZSBmaW5hbCBDYXJkIGFuZCBkZXN0aW5hdGlvbiBCb2Fy
ZENhcmRzIHVwZGF0ZS4gVGhlIGZyZXNoIHdpcmUgYXV0aG9yIGNsb2NrIHByZXZlbnRzIG9yZGlu
YXJ5IHJlcXVlc3QgY2FjaGUgcmV1c2UuIEV4cG9zZSBuYXJyb3cgb3B0LWluIGd1YXJkZWQgbWFy
aywgYXBwcm92ZWQgUFIvYnJhbmNoIG1ldGFkYXRhLCBhbmQgdGVybWluYWwgZG9pbmctdG8tZG9u
ZSB3cml0ZXMgZm9yIGZhY3RvcnkgY2xvc2VvdXQuIEtlZXAgZ2VuZXJpYyBiZWhhdmlvci4gRG8g
bm90IGJ5cGFzcyBsaWZlY3ljbGUgb3IgbWVyZ2UvcHJvb2YgZ2F0ZXMuIFRoZSBMYXN0U3RhY2sg
c3RyaWN0IGNsb3Nlb3V0IGhlbHBlciByZW1haW5zIHRoZSBwcm9vZiBhdXRob3JpdHkgYW5kIG11
c3QgdXNlIHRoZXNlIHB1YmxpYyBndWFyZGVkIEFQSXMuXFxuXFxuIyMgVkFMSURBVElPTlxcblVz
ZSBmaWx0ZXJlZCBmaXh0dXJlcyBhbmQgdGFyZ2V0ZWQgUkVEIHByb2Jlcy4gVGhlIHByb2R1Y3Rp
b24gd3JhcHBlciB1c2VzIGEgZnJlc2ggc3ludGhldGljIGhvbWUsIGFjdHVhbCBwdWJsaXNoZWQg
Q2FyZCBhbmQgQm9hcmRDYXJkcyBzY2hlbWEgaWRlbnRpdGllcywgZXhhY3QgTWluaSBidWlsZCwg
YW5kIGV4YWN0IHByb2Nlc3Mgc3RvcCBjaGVja3MuIEl0IHRlc3RzIGEgZmluYWwgYXBwZW5kZWQg
Ym9keSB0aGF0IGRpZmZlcnMgZnJvbSB0aGUgbm8tb3AgYm9keSBndWFyZCwgc2FtZS1vd25lciBo
dW1hbiBob2xkL3N0YXR1cy9yZWFzb24gcmFjZXMsIGZvcmVpZ24gb3duZXIsIGNvbHVtbiwgYm9k
eSwgdXBkYXRlZF9hdCwgcmV0cnksIGR1cmFibGUgcmVjZWlwdCwgYW5kIHJlc3RhcnQuIENvbGxl
Y3QgaW5kZXBlbmRlbnQgc2V0dXAgd3JpdGVzIGFuZCBmaW5hbCByZWFkIGtleXMgaW50byBuYXRp
dmUgYmF0Y2hlcy4gUmVjb3JkIHRoZSByYWNlIHNjaGVkdWxlIGxpbWl0IGhvbmVzdGx5Llxcblxc
biMjIERFU1RJTkFUSU9OIENPTlRSQUNUXFxuXFxuVGhlIGxpdmUgQm9hcmRDYXJkcyBrZXkgdXNl
cyBib2FyZCBwbHVzIGNvbHVtbiNwb3NpdGlvbiNzbHVnLiBBIHRlcm1pbmFsIG1vdmUgdGFyZ2V0
cyBhbiBhYnNlbnQgZGVzdGluYXRpb24ga2V5LiBUaGUgYWNjZXB0ZWQgYXRvbWljIHVwZGF0ZSBj
YW4gY3JlYXRlIHRoYXQgZXhhY3QgbWVtYmVyc2hpcCBiZWhpbmQgYWxsIGNhbm9uaWNhbCBDYXJk
IGd1YXJkcy4gSXQgY2Fubm90IGNyZWF0ZSB0aGUgY2Fub25pY2FsIENhcmQuIE5vIHNlcGFyYXRl
IGNyZWF0ZSBjb21tYW5kLCBkZWxldGUsIHVuZ3VhcmRlZCByZXRyeSwgb3IgZmFsbGJhY2sgb2Nj
dXJzLiBUaGUgcHJvb2YgY2hlY2tzIHRoZSBhYnNlbnQgZGVzdGluYXRpb24gYmVmb3JlIHRoZSB3
cml0ZSwgaXRzIGZ1bGwgYWNjZXB0ZWQgcGF5bG9hZCBhZnRlciB0aGUgd3JpdGUsIGFuZCBubyBk
ZXN0aW5hdGlvbiBhZnRlciBlYWNoIHJlamVjdGVkIHJhY2UuIEl0IHVzZXMgdGhlIHB1Ymxpc2hl
ZCBsaXZlIHNjaGVtYSBpZGVudGl0aWVzLiBJdCBkb2VzIG5vdCBjaGFuZ2UgYSBzY2hlbWEga2V5
IGxheW91dC5cXG5cXG4jIyBQVUJMSUMgU05BUFNIT1QgQ09OVFJBQ1RcXG5cXG5UaGUgcHVibGlj
IGd1YXJkZWQtc25hcHNob3QgY29tbWFuZCByZXR1cm5zIHRoZSBleGFjdCByYXcgMjMgZmllbGRz
IGFuZCBjYW5vbmljYWwgc2NoZW1hIGhhc2guIEVhY2ggZ3VhcmRlZCB3cml0ZSByZWNlaXZlcyBh
IGJvdW5kZWQgc25hcHNob3QgZmlsZSwgaXRzIGV4YWN0IGJ5dGUgU0hBLCBhbmQgdGhlIGV4cGVj
dGVkIG93bmVyLiBNQ1AgcmVjZWl2ZXMgdGhlIHNhbWUgSlNPTiBieXRlcyBhbmQgU0hBLiBUaGUg
Y2xpZW50IGNvbXBhcmVzIHRoZSBzdXBwbGllZCB3aXRuZXNzIHdpdGggb25lIGN1cnJlbnQgY2Fu
b25pY2FsIHJlYWQuIEl0IGd1YXJkcyB0aGUgc3VwcGxpZWQgdmFsdWVzIHRocm91Z2ggYWxsIGxh
dGVyIGdhdGVzIGFuZCB0aGUgYXRvbWljIGJhdGNoLiBJdCBuZXZlciByZXBsYWNlcyB0aGUgc3Vw
cGxpZWQgd2l0bmVzcyB3aXRoIGEgZnJlc2ggc25hcHNob3QuIEVhY2ggYWNjZXB0ZWQgZHVyYWJs
ZSB3cml0ZSByZXR1cm5zIHRoZSBpbnRlbmRlZCBuZXh0IHNuYXBzaG90IGFuZCBieXRlIFNIQS4g
VGhlIG5leHQgY29tbWFuZCB1c2VzIHRob3NlIGV4YWN0IGJ5dGVzLlxcblxcbkFsbG93IG9ubHkg
bmFycm93IGFwcGVuZCwgYXBwcm92ZWQgUFIvYnJhbmNoIG1ldGFkYXRhLCB1bmFzc2lnbmVkIGJh
Y2tsb2ctdG8tdG9kbyBwcm9tb3Rpb24sIGFuZCBvd25lZCBkb2luZy10by10ZXJtaW5hbCB0cmFu
c2l0aW9ucy4gUHJlc2VydmUgYWxsIGN1cnJlbnQgYWRtaXNzaW9uLCBTaXR1YXRpb24sIGRlcGVu
ZGVuY3ksIGFuZCBsaWZlY3ljbGUgZ2F0ZXMuIFRoZSBleGFjdCBjbGFpbSByZXRhaW5zIGl0cyBh
ZG1pc3Npb24gd2l0bmVzcy4gSXRzIGZpbmFsIGhvbGQgY2xlYXIgYWNjZXB0cyBvbmx5IHRoZSBn
ZW5lcmF0ZWQgcmVjb3ZlcnkgaG9sZCB1bmRlciB0aGUgYWNjZXB0ZWQgY2xhaW0gd2l0bmVzcy4g
QSBmb3JlaWduIG93bmVyIG9yIGEgbmV3IGh1bWFuIGhvbGQgcmVmdXNlcy4gQSBib2R5IG9yIEdP
QUwgY2hhbmdlIGJldHdlZW4gYWRtaXNzaW9uIGFuZCBjbGFpbSwgb3IgYmV0d2VlbiBzZXF1ZW50
aWFsIGNsb3Nlb3V0IHdyaXRlcywgcmVmdXNlcy5cXG5cXG4jIyBCT09UU1RSQVAgU1RBVEVcXG5c
XG5UaGlzIG9wZXJhdGlvbmFsIHJlcGFpciBzdGFydHMgZnJvbSBiYWNrbG9nLiBUaGUgY3VycmVu
dCBjbGFpbSBwYXRoIGNhbm5vdCBzYWZlbHkgcGxhY2UgaXQgaW4gZG9pbmcuIFRoZSBzb3VyY2Ug
c2xvdCBiZWNvbWVzIGFjdGl2ZSBvbmx5IGFmdGVyIHRoZSBwcmVjZWRpbmcgTG9vbSBpbnN0YWxs
ZWQgcHJvb2YuIFRoZSByZXBhaXJlZCBpbnN0YWxsZWQgY2xpZW50IHRoZW4gcHJvdmlkZXMgdGhl
IHNhZmUgY2xhaW0uIFRoZSBzdHJpY3QgTGFzdFN0YWNrIGhlbHBlciBjbG9zZXMgdGhlIHJlcGFp
ciBDYXJkIGFmdGVyIHBvc2l0aXZlIHByb29mLiBObyB1bnNhZmUgQ2FyZCB0cmFuc2l0aW9uIHN1
YnN0aXR1dGVzIGZvciB0aGUgZ3VhcmQgcmVwYWlyLlxcblxcbkF1dGhvcml0eTogZGVjaXNpb24t
MjAyNi0xMC0wOC1mYWN0b3J5LXJlcGFpci1zbG90LWFuZC1ib3VuZGVkLXByb29mXFxuUHJvdG9j
b2wgcHJvb2Y6IC9wcml2YXRlL3RtcC9ma2FuYmFuLWNvbXBvdW5kLXByb2JlLTdtY1JuZC9ldmlk
ZW5jZS5qc29uXFxuXFxuIyMgREVDSVNJT04tQ0hFQ0tcXG5kYXRlOiAyMDI2LTEwLTA5VDAwOjE5
OjA0WlxcbnZlcmRpY3Q6IGNsZWFyXFxuc2x1Z3M6IG5vbmVcIixcImJyYW5jaFwiOlwiXCIsXCJj
b2x1bW5cIjpcImJhY2tsb2dcIixcImNyZWF0ZWRfYXRcIjpcIjIwMjYtMTAtMDlUMDA6MTk6MTEu
MDU1WlwiLFwiY3JlYXRlZF9ieVwiOlwiY29kZXg6MDFhMTE3MzEtYjhiMy03YzUzLWI4MmItOTc4
YWU1NmI5NjllXCIsXCJkYlwiOlwiXCIsXCJkZXBzXCI6W10sXCJraW5kXCI6XCJwclwiLFwibWls
ZXN0b25lXCI6XCJtcy1mYWN0b3J5LWhlYWwtdmlhLXN0YXRlLW1hY2hpbmVcIixcIm5vcnRoX3N0
YXJcIjpcIm5vcnRoLXN0YXItcG9ydGFibGUtcm91dGluZS1mbGVldFwiLFwicG9zaXRpb25cIjpc
IjE3OTE1MDUxNTEwNTVcIixcInByX3VybFwiOlwiXCIsXCJyZXBvXCI6XCJFZGdlVmVjdG9yL2Zr
YW5iYW5cIixcInNsdWdcIjpcImZhY3RvcnktZ3VhcmRlZC1jbG9zZW91dC0yMDI2MTAwOFwiLFwi
c3VyZmFjZXNcIjpbXCJ0ZXN0L2JvYXJkLWNhcmRzLXJlYXAtY29sdW1uLW9ubHkudGVzdC50c1wi
XSxcInRhZ3NcIjpbXCJwMVwiXSxcInRpdGxlXCI6XCJHdWFyZCBmYWN0b3J5IGNsYWltcyBhbmQg
Y2xvc2VvdXQgd2l0aCBleGFjdCBDYXJkIHNuYXBzaG90c1wiLFwidXBkYXRlZF9hdFwiOlwiMjAy
Ni0xMC0wOVQwMDoxOToxMS4wNTVaXCJ9fVxuIiwic25hcHNob3Rfc2hhMjU2IjoiZDI0NTVjYTE5
NjFkNDBhZDYxY2NiMGIxOTc5NDM1OTA0ZGRhZTEzNjJjMDZiYzJmMzNlMDg0YTkwYTQ5NjkxOCJ9
LCJ3cml0ZV9pbnRlbnQiOnsiYXR0ZW1wdCI6IjBjOTBkNmQ4YTMwNjRmNmRiOThmZjI3NTI2MWI4
NzAzIiwib3BlcmF0aW9uIjoic3VyZmFjZXMiLCJ3aXRuZXNzX3NoYTI1NiI6ImQyNDU1Y2ExOTYx
ZDQwYWQ2MWNjYjBiMTk3OTQzNTkwNGRkYWUxMzYyYzA2YmMyZjMzZTA4NGE5MGE0OTY5MTgifSwi
d3JpdGVfcmVjZWlwdHMiOltdfQo=
""")
OLD_CAPTURE_BYTES = b'{"operation":"surfaces","rc":1,"stderr_sha256":"0b5b420b174f086b70a3ca5ccb4bbd2d08e5491f8f540ff4b5e7a40457f713f2","stdout_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","version":1,"witness_sha256":"d2455ca1961d40ad61ccb0b1979435904ddae1362c06bc2f33e084a90a496918"}\n'

class RecoveryEffects(Effects):
    def __init__(self, entry, config, old):
        super().__init__(entry)
        self.value = f.validate_snapshot(old['witness'], entry['card'])['fields']
        self.original_value = copy.deepcopy(self.value); self.original_witness = copy.deepcopy(old['witness'])
        self.expected_entry = copy.deepcopy(old['entry']); self.expected_entry['target_surfaces'] = list(ORIGINAL_SURFACES)
        self.expected_writer = copy.deepcopy(config['fkanban_authority'])
        self.config = config; self.source_error = False
    def check_authority(self, entry):
        self.calls.append('authority')
        f.require(entry == self.expected_entry and self.config['fkanban_authority'] == self.expected_writer,
                  'bootstrap-recovery-fixture-authority-drift')
    def check_refusal_source(self, policy):
        self.calls.append('source')
        f.require(not self.source_error and policy == b.RECOVERY_POLICY, 'bootstrap-recovery-fixture-source-drift')
    def card(self, entry):
        self.calls.append('card')
        return copy.deepcopy(self.original_witness) if self.value == self.original_value else t.item(self.value)
    def write(self, state, operation):
        result = super().write(state, operation)
        if result.get('durability'): result['contract_sha256'] = self.expected_writer['contract_sha256']
        return result

def recovery_fixture():
    directory = Path(tempfile.mkdtemp(prefix='bootstrap-recovery-fixture-'))
    old = f.strict_json(OLD_STATE_BYTES)
    t.check(f.sha(OLD_STATE_BYTES) == '014a270ae0cfd4df8a54f272b8610a0d6f7190222b1a3d0033a629ddc902747d',
            'retained failed state byte fixture changed')
    t.check(f.sha(OLD_CAPTURE_BYTES) == '712cc6b08765bedcc01dc549a2c5905d36d9492fa3a208c6d3c7d4ff9692cd8a',
            'retained failed capture byte fixture changed')
    config = f.read_json(ROOT / 'config/factory-bootstrap-closeout.json')
    config['refusal_recovery'] = copy.deepcopy(b.RECOVERY_POLICY)
    entry = next(e for e in config['entries'] if e['card'] == old['entry']['card'])
    entry['target_surfaces'] = list(ORIGINAL_SURFACES)
    state_path = directory / ('bootstrap-' + entry['card'] + '.json'); state_path.write_bytes(OLD_STATE_BYTES)
    prefix = directory / ('bootstrap-public-' + old['write_intent']['attempt'])
    files = {state_path: OLD_STATE_BYTES, prefix.with_suffix('.capture.json'): OLD_CAPTURE_BYTES,
             prefix.with_suffix('.out'): b'', prefix.with_suffix('.err'): SURFACES_REFUSAL}
    for path, data in files.items(): path.write_bytes(data)
    (directory / 'retained-original-state.json').write_bytes(OLD_STATE_BYTES)
    effects = RecoveryEffects(entry, config, old)
    return {'directory': directory, 'old': old, 'config': config, 'effects': effects, 'files': files,
            'state_path': state_path, 'prefix': prefix, 'contract': 'c' * 64}

def recovery_controller(case):
    return BootstrapController(case['config'], case['directory'], case['effects'], case['contract'], case['old']['entry']['card'])

def recover_positive(case=None):
    case = recovery_fixture() if case is None else case
    before = copy.deepcopy(case['effects'].value)
    controller = recovery_controller(case); result = controller.recover_prewrite_refusal()
    state = f.read_json(case['state_path']); history = state.get('recovery_history', [])
    t.check(not any(v not in ('authority', 'source', 'card') for v in case['effects'].calls) and case['effects'].value == before,
            'prewrite recovery issued a public Card write')
    t.check(len(history) == 1 and state['phase'] == 'promote' and not state.get('write_intent') and state['write_receipts'] == [],
            'prewrite recovery did not create one explicit promote transition')
    receipt = history[0]
    t.check(receipt['prior_state_json'].encode() == OLD_STATE_BYTES and receipt['capture_json'].encode() == OLD_CAPTURE_BYTES and
            receipt['stdout'] == '' and receipt['stderr'].encode() == SURFACES_REFUSAL and receipt['card_write'] is False and
            receipt['accepted_write_receipts'] == 0,
            'prewrite recovery did not retain the complete failed state and streams')
    t.check(state['owner'] == case['old']['owner'] and state['intent'] == case['old']['intent'] and state['witness'] == case['old']['witness'] and
            state['entry'] == controller.entry and state['config_sha256'] == controller.config_sha and state['contract_sha256'] == case['contract'],
            'prewrite recovery changed original reservation or retained the old authority')
    t.check((case['directory'] / 'retained-original-state.json').read_bytes() == OLD_STATE_BYTES and
            all(p.read_bytes() == data for p, data in case['files'].items() if p != case['state_path']),
            'prewrite recovery changed retained originals')
    controller.once()
    t.check(case['effects'].calls.count('promote') == 1 and case['effects'].value['surfaces'] == ORIGINAL_SURFACES,
            'recovered bootstrap could not use its supported next phase')
    return case

def recovery_refused(change, label, expected_reason):
    case = recovery_fixture(); change(case)
    before = {p: p.read_bytes() for p in case['files']}; card_before = copy.deepcopy(case['effects'].value)
    error = None
    try: recovery_controller(case).recover_prewrite_refusal()
    except f.Refusal as caught: error = caught
    t.check(case['effects'].value == card_before and not any(v not in ('authority', 'source', 'card') for v in case['effects'].calls),
            label + ' reached a public Card write')
    t.check(all(p.read_bytes() == data for p, data in before.items()), label + ' changed a latched state or capture')
    t.check(error is not None and str(error) == expected_reason, label + ' was not refused by the exact recovery gate')

def change_state(case, change):
    value = f.read_json(case['state_path']); change(value); f.atomic_json(case['state_path'], value)

def change_capture(case, change):
    path = case['prefix'].with_suffix('.capture.json'); value = f.read_json(path); change(value); f.atomic_json(path, value)

def change_canonical(case, field, value): case['effects'].value[field] = value

def recovery_history_drift(completed=False, strip=False):
    case = recover_positive(); controller = recovery_controller(case)
    if completed:
        for _ in range(12):
            if controller.once().get('phase') == 'completed': break
    state = f.read_json(case['state_path'])
    if strip: del state['recovery_history']
    else:
        receipt = state['recovery_history'][0]; prior = f.strict_json(receipt['prior_state_json']); prior['intent']['attempt'] = 'f' * 32
        receipt['prior_state_json'] = json.dumps(prior) + '\n'; receipt['prior_state_sha256'] = f.sha(receipt['prior_state_json'].encode())
        receipt['receipt_sha256'] = f.value_sha({k: v for k, v in receipt.items() if k != 'receipt_sha256'})
    if completed:
        state['completion'] = b.completion_value(state); state['completion_sha256'] = f.value_sha(state['completion'])
    f.atomic_json(case['state_path'], state); before = case['state_path'].read_bytes(); calls = list(case['effects'].calls)
    error = None
    try: controller.once()
    except f.Refusal as caught: error = caught
    label = ('completed' if completed else 'active') + (' stripped' if strip else ' self-hashed') + ' recovery history'
    t.check(case['effects'].calls == calls and case['state_path'].read_bytes() == before,
            label + ' reached an effect or changed its state')
    t.check(error is not None and str(error) == ('bootstrap-recovery-history-size' if strip else 'bootstrap-recovery-history-receipt'),
            label + ' was accepted or reached an unrelated gate')

def recovery_repeat_unknown_phase(phase='unexpected-phase'):
    case = recover_positive(); controller = recovery_controller(case); controller.once()
    state = f.read_json(case['state_path'])
    t.check(state['phase'] == 'proof-mark' and case['effects'].value['column'] == 'doing' and
            case['effects'].value['assignee'] == state['owner'], 'unknown-phase fixture did not reach a valid owned doing chain')
    state['phase'] = phase; f.atomic_json(case['state_path'], state)
    before = case['state_path'].read_bytes(); card_before = copy.deepcopy(case['effects'].value)
    calls = list(case['effects'].calls); error = None
    try: controller.recover_prewrite_refusal()
    except f.Refusal as caught: error = caught
    t.check(case['effects'].value == card_before and case['state_path'].read_bytes() == before and
            not any(v not in ('authority', 'source', 'card') for v in case['effects'].calls[len(calls):]),
            'unexpected recovery phase reached a Card write or state change')
    t.check(error is not None and str(error) == 'bootstrap-recovery-active-phase',
            'explicit recovery accepted an unexpected active phase')

def recovery_repeat_positive():
    case = recover_positive(); controller = recovery_controller(case)
    before = case['state_path'].read_bytes(); calls = list(case['effects'].calls)
    result = controller.recover_prewrite_refusal()
    t.check(result['result'] == 'noop' and result['reason'] == 'prewrite-refusal-already-recovered' and
            case['state_path'].read_bytes() == before and
            not any(v not in ('authority', 'source', 'card') for v in case['effects'].calls[len(calls):]),
            'repeat checked recovery repeated a Card write or state transition')

def recovery_without_original():
    case = recovery_fixture(); case['state_path'].rename(case['directory'] / 'absent-original-preserved.json')
    error = None
    try: recovery_controller(case).once()
    except f.Refusal as caught: error = caught
    t.check(not case['state_path'].exists() and case['effects'].calls == [],
            'configured recovery reserved a fresh Card without its original state')
    t.check(error is not None and str(error) == 'bootstrap-recovery-original-state-required',
            'configured recovery accepted an absent original state')


def recovery_loom_not_permitted():
    case = recovery_fixture()
    key = next(key for key in BOOTSTRAP_KEYS if key != case['old']['entry']['card'])
    controller = BootstrapController(case['config'], case['directory'], case['effects'], case['contract'], key)
    controller.path.write_bytes(OLD_STATE_BYTES)
    before = {p: p.read_bytes() for p in (*case['files'], controller.path)}
    card_before = copy.deepcopy(case['effects'].value); error = None
    try: controller.recover_prewrite_refusal()
    except f.Refusal as caught: error = caught
    t.check(case['effects'].calls == [] and case['effects'].value == card_before and
            all(p.read_bytes() == data for p, data in before.items()),
            'foreign recovery key reached an effect or changed retained files')
    # Other guards also refuse this key. This names the explicit early scope
    # refusal, not a claim that its removal admits a Card write.
    t.check(error is not None and str(error) == 'bootstrap-recovery-not-permitted',
            'foreign recovery key lost its explicit permission refusal')

def recovery_history_extra_field():
    case = recover_positive(); controller = recovery_controller(case)
    state = f.read_json(case['state_path']); receipt = state['recovery_history'][0]
    receipt['extra_field'] = 'wrong-nonempty'
    receipt['receipt_sha256'] = f.value_sha({k: v for k, v in receipt.items() if k != 'receipt_sha256'})
    f.atomic_json(case['state_path'], state)
    before = case['state_path'].read_bytes(); calls = list(case['effects'].calls)
    card_before = copy.deepcopy(case['effects'].value); error = None
    try: controller.once()
    except f.Refusal as caught: error = caught
    t.check(case['effects'].calls == calls and case['effects'].value == card_before and
            case['state_path'].read_bytes() == before,
            'extra self-hashed recovery receipt reached an effect or changed its state')
    t.check(error is not None and str(error) == 'bootstrap-recovery-history-shape',
            'extra self-hashed recovery receipt reached an unrelated refusal')

def recovery_busy(peer=False):
    case = recovery_fixture(); controller = recovery_controller(case)
    if peer:
        entry = next(e for e in case['config']['entries'] if e['card'] != controller.entry['card'])
        value = {'version': 1, 'phase': 'reserved', 'entry': copy.deepcopy(entry), 'owner': entry['owner'],
                 'config_sha256': f.value_sha(case['config']), 'contract_sha256': case['contract'], 'write_receipts': []}
        path = case['directory'] / ('bootstrap-' + entry['card'] + '.json')
        reason = 'bootstrap-completion-binding'; label = 'active peer recovery'
    else:
        value = {'version': 1, 'phase': 'execution'}; path = case['directory'] / 'slot.json'
        reason = 'bootstrap-active-count-retained'; label = 'active count recovery'
    f.atomic_json(path, value)
    before = {p: p.read_bytes() for p in (*case['files'], path)}
    card_before = copy.deepcopy(case['effects'].value); error = None
    try: controller.recover_prewrite_refusal()
    except f.Refusal as caught: error = caught
    t.check(case['effects'].calls == [] and case['effects'].value == card_before and
            all(p.read_bytes() == data for p, data in before.items()),
            label + ' reached an effect or changed retained files')
    t.check(error is not None and str(error) == reason, label + ' reached an unrelated refusal')


CASES = {'fkanban_positive': complete, 'loom_owner': lambda: complete(True), 'hold': hold, 'changed_body': changed_body,
         'foreign_owner': foreign_owner, 'uncertain': uncertain, 'busy_count': busy_count, 'busy_peer': busy_peer, 'completion_drift': completion_drift,
         'malformed_count_complete': malformed_count_complete, 'malformed_peer_complete': malformed_peer_complete}
CASES['public_empty_surfaces_refusal'] = public_empty_surfaces_refusal
CASES['runtime_nonzero_diagnostic'] = runtime_nonzero_diagnostic
CASES['runtime_accepted_held'] = runtime_accepted_held
CASES['runtime_source_positive'] = runtime_source_positive
for name, (change, reason) in RUNTIME_SOURCE_NEGATIVES.items():
    CASES['runtime_source_' + name] = lambda change=change, name=name, reason=reason: runtime_source_refused(change, name, reason)
CASES['recovery_positive'] = recover_positive
CASES['recovery_repeat_positive'] = recovery_repeat_positive
CASES['recovery_repeat_unknown_phase'] = recovery_repeat_unknown_phase
CASES['recovery_repeat_reserved_phase'] = lambda: recovery_repeat_unknown_phase('reserved')
CASES['recovery_without_original'] = recovery_without_original
CASES['recovery_loom_not_permitted'] = recovery_loom_not_permitted
CASES['recovery_history_extra_field'] = recovery_history_extra_field
CASES['recovery_count_busy'] = recovery_busy
CASES['recovery_peer_busy'] = lambda: recovery_busy(True)
CASES['accepted_held'] = accepted_held
CASES['accepted_hold_changed'] = lambda: accepted_held(True)
CASES['completion_guard'] = lambda: completion_receipt_drift('guard_snapshot_sha256')
CASES['completion_next'] = lambda: completion_receipt_drift('next_snapshot_sha256')
CASES['retained_intent_drift'] = retained_intent_drift
CASES['retained_chain_drift'] = retained_chain_drift
CASES['retained_chain_cap'] = retained_chain_cap

RECOVERY_NEGATIVES = {
    'state_bytes': lambda c: c['state_path'].write_bytes(OLD_STATE_BYTES + b'\n'),
    'state_config': lambda c: change_state(c, lambda s: s.update(config_sha256='f' * 64)),
    'state_runtime': lambda c: change_state(c, lambda s: s.update(contract_sha256='f' * 64)),
    'state_operation': lambda c: change_state(c, lambda s: s['write_intent'].update(operation='claim')),
    'state_owner': lambda c: change_state(c, lambda s: s.update(owner='loom:foreign')),
    'state_receipts': lambda c: change_state(c, lambda s: s['write_receipts'].append({'durability': 'durable'})),
    'capture_bytes': lambda c: c['prefix'].with_suffix('.capture.json').write_bytes(OLD_CAPTURE_BYTES + b'\n'),
    'capture_operation': lambda c: change_capture(c, lambda s: s.update(operation='claim')),
    'capture_timeout': lambda c: change_capture(c, lambda s: s.update(rc=124)),
    'capture_success': lambda c: change_capture(c, lambda s: s.update(rc=0)),
    'stdout_receipt': lambda c: c['prefix'].with_suffix('.out').write_bytes(b'{"durability":"durable"}\n'),
    'stderr': lambda c: c['prefix'].with_suffix('.err').write_bytes(b'private timeout\n'),
    'policy': lambda c: c['config']['refusal_recovery'].update(writer_source_oid='f' * 40),
    'policy_source': lambda c: c['config']['refusal_recovery']['source_files'].update({'src/cli.ts': 'f' * 64}),
    'source': lambda c: setattr(c['effects'], 'source_error', True),
    'target': lambda c: next(e for e in c['config']['entries'] if e['card'] == c['old']['entry']['card']).update(target_surfaces=[]),
    'target_type': lambda c: next(e for e in c['config']['entries'] if e['card'] == c['old']['entry']['card']).update(target_surfaces='wrong-nonempty'),
    'target_entry_type': lambda c: next(e for e in c['config']['entries'] if e['card'] == c['old']['entry']['card']).update(target_surfaces=[7]),
    'authority': lambda c: c['config']['fkanban_authority'].update(source_oid='f' * 40),
    'new_config': lambda c: c['config'].update(unreviewed_field='wrong'),
    'new_runtime_old': lambda c: c.update(contract=b.RECOVERY_POLICY['from_contract_sha256']),
    'new_runtime_invalid': lambda c: c.update(contract='wrong-nonempty'),
    'canonical_owner': lambda c: change_canonical(c, 'assignee', 'peer'),
    'canonical_column': lambda c: change_canonical(c, 'column', 'doing'),
    'canonical_hold': lambda c: change_canonical(c, 'block_status', 'needs_human'),
    'canonical_reason': lambda c: change_canonical(c, 'block_reason', 'Tom hold'),
    'canonical_body': lambda c: change_canonical(c, 'body', c['effects'].value['body'] + '\nHuman GOAL edit\n'),
    'canonical_timestamp': lambda c: change_canonical(c, 'updated_at', '2026-10-09T13:50:00Z'),
    'canonical_surfaces': lambda c: change_canonical(c, 'surfaces', ['src/foreign.ts']),
    'canonical_deps': lambda c: change_canonical(c, 'deps', ['foreign-dependency']),
    'canonical_tags': lambda c: change_canonical(c, 'tags', ['p0']),
}
RECOVERY_REASONS = {name: 'bootstrap-recovery-original-state-bytes' for name in RECOVERY_NEGATIVES}
for name in ('capture_bytes', 'capture_operation', 'capture_timeout', 'capture_success', 'stdout_receipt', 'stderr'):
    RECOVERY_REASONS[name] = 'bootstrap-recovery-capture-bytes'
for name in ('policy', 'policy_source'): RECOVERY_REASONS[name] = 'bootstrap-recovery-policy'
RECOVERY_REASONS.update(source='bootstrap-recovery-fixture-source-drift', target='bootstrap-recovery-original-witness',
                        target_type='bootstrap-original-witness', target_entry_type='bootstrap-original-witness',
                        authority='bootstrap-recovery-config-transition', new_config='bootstrap-recovery-config-transition',
                        new_runtime_old='bootstrap-recovery-new-local-authority', new_runtime_invalid='bootstrap-recovery-new-local-authority')
for name in RECOVERY_NEGATIVES:
    if name.startswith('canonical_'): RECOVERY_REASONS[name] = 'bootstrap-retained-witness-changed'
for name, change in RECOVERY_NEGATIVES.items():
    CASES['recovery_' + name] = lambda change=change, name=name: recovery_refused(change, 'recovery ' + name, RECOVERY_REASONS[name])
CASES['recovery_history_active'] = recovery_history_drift
CASES['recovery_history_completed'] = lambda: recovery_history_drift(True)
CASES['recovery_history_stripped_active'] = lambda: recovery_history_drift(False, True)
CASES['recovery_history_stripped_completed'] = lambda: recovery_history_drift(True, True)

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=CASES); args = p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
