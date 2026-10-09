#!/usr/bin/env python3
"""Filtered finite factory fixtures. All effects use private fixture files."""
import argparse
import copy
import hashlib
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import factory_repair as f


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def card(slug='factory-canonical-active-counts-20261008'):
    value = {key: '' for key in f.SCALARS}
    value.update({key: [] for key in f.ARRAYS})
    value.update(slug=slug, column='todo', repo='EdgeVector/loom', base='main',
                 kind='pr', board='default', body='## END STATE\nCurrent count is correct.\n')
    return value


def item(value):
    text = json.dumps({'version': 1, 'schema_hash': 'a' * 64, 'fields': value}) + '\n'
    return {'slug': value['slug'], 'snapshot_json': text,
            'snapshot_sha256': f.sha(text.encode())}


def reviewed_body():
    return (ROOT / 'config/factory-canonical-active-counts.md').read_text() + '\n## DECISION-CHECK\n' + \
        'date: 2026-10-09T00:00:00Z\nverdict: honor\nslugs: decision-20260907-approve-lastdb-memory-footprint-guard-design\n' + \
        'store: brain\nread: brain get decision-20260907-approve-lastdb-memory-footprint-guard-design\n'


def reviewed_receipt():
    return f.validate_admitted_body(reviewed_body(), {'card': f.COUNT_CARD, 'repo': 'EdgeVector/loom', 'base': 'main',
        'brief_sha256': 'a0bb3af8e773325e9a2e0e08e926a48efc1d89c73fa1e584396091242978d8bb'})


def raw23():
    value = card()
    got = f.validate_snapshot(item(value), value['slug'])
    check(got['fields'] == value, 'raw23 fields changed')
    check(got['text'].endswith('\n'), 'snapshot final newline lost')


def missing_field():
    value = card(); del value['body']
    try:
        f.validate_snapshot(item(value), value['slug'])
    except f.Refusal:
        return
    raise AssertionError('missing raw23 field accepted')


def wrong_sha():
    value = item(card()); value['snapshot_sha256'] = '0' * 64
    try:
        f.validate_snapshot(value, value['slug'])
    except f.Refusal:
        return
    raise AssertionError('wrong snapshot byte SHA accepted')


def reply_keys():
    value = card(); reply = {'version': 1, 'schema_hash': 'a' * 64, 'items': [item(value)]}
    check(f.validate_card_batch(reply, [value['slug']])[0]['slug'] == value['slug'], 'ordered reply failed')
    reply['items'].append(item(value))
    try:
        f.validate_card_batch(reply, [value['slug']])
    except f.Refusal:
        return
    raise AssertionError('duplicate or foreign batch key accepted')


def missing_item():
    reply = {'version': 1, 'schema_hash': 'a' * 64, 'items': [{'slug': 'absent', 'missing': True}]}
    check(f.validate_card_batch(reply, ['absent']) == reply['items'], 'explicit missing lost')


def count_duplicate():
    rows = [{'id': 'lx-a', 'status': 'running', 'state': 'IMPLEMENT', 'updated_at': 'x', 'definition_name': 'land-card'}]
    status = {'total': 1, 'by_status': {'running': 1}, 'by_definition': {'land-card': 1},
              'executions': [{**rows[0], 'definition_name': 'land-card'}]}
    check(f.compare_count(status, rows)['total'] == 1, 'count positive refused')
    status['executions'].append(status['executions'][0])
    try:
        f.compare_count(status, rows)
    except f.Refusal:
        return
    raise AssertionError('duplicate active execution accepted')


def count_terminal():
    row = {'id': 'lx-a', 'status': 'succeeded', 'state': 'DONE', 'updated_at': 'x', 'definition_name': 'land-card'}
    status = {'total': 1, 'by_status': {'succeeded': 1}, 'by_definition': {'land-card': 1}, 'executions': [row]}
    try:
        f.compare_count(status, [row])
    except f.Refusal:
        return
    raise AssertionError('terminal execution counted active')


def scope():
    original = {'factory_repair': True, 'factory_card': card()['slug'], 'card': card()['slug'],
                'claim_worker': 'loom:factory-repair', 'repo': 'EdgeVector/loom', 'base': 'main', 'factory_decision_receipt': reviewed_receipt()}
    state = {'card': original['card'], 'owner': original['claim_worker'], 'repo': original['repo'],
             'base': 'main', 'execution_id': 'lx-fixture', 'key': 'card-fixture', 'original_input': original,
             'intent': {'factory_decision_receipt': original['factory_decision_receipt']}}
    view = {'id': 'lx-fixture', 'idempotency_key': 'card-fixture', 'original_input': original,
            'context': dict(original), 'definition_name': 'land-card', 'definition_version': '0000000005',
            'status': 'succeeded', 'state': 'DONE', 'corrected_reads': 0,
            'nodes': [{'node_id': 'CLOSE_CARD', 'attempt': 1, 'status': 'succeeded',
                       'pending_effect': None, 'result': {'column': 'factory-proof-handoff', 'handoff': {
                           'contract': 1, 'status': 'awaiting-factory-proof', 'card': state['card'],
                           'claim_worker': state['owner'], 'repo': state['repo'], 'execution_id': 'lx-fixture',
                           'idempotency_key': 'card-fixture', 'pr_url': 'https://github.com/EdgeVector/loom/pull/1',
                           'card_column': 'doing', 'no_card_write': True}}}]}
    return state, view


def execution_padded_version():
    # runner::kickoff stores pad_version(&def.version); public Show preserves it.
    state, view = scope()
    check(view['definition_version'] == '0000000005' and f.validate_execution(view, state) is view,
          'public exact padded v5 execution refused')

def execution_version_refused(value):
    # Every other immutable identity and context field is valid. The version
    # alone is wrong, so the exact stored-version guard must refuse it.
    state, view = scope(); view['definition_version'] = value
    refused(lambda: f.validate_execution(view, state),
            'noncanonical execution definition version accepted: ' + repr(value))


def immutable_input():
    state, view = scope(); f.validate_execution(view, state)
    view['original_input'] = {**view['original_input'], 'card': 'other'}
    try:
        f.validate_execution(view, state)
    except f.Refusal:
        return
    raise AssertionError('wrong immutable execution input accepted')


def accepted_handoff():
    state, view = scope(); check(f.accepted_handoff(view, state)['no_card_write'], 'accepted CLOSE lost')
    view['nodes'][0]['status'] = 'failed'
    try:
        f.accepted_handoff(view, state)
    except f.Refusal:
        return
    raise AssertionError('merge context without accepted CLOSE authorized install')


def local_contract():
    with tempfile.TemporaryDirectory(prefix='factory-local-contract-') as name:
        root = Path(name); (root / 'config').mkdir(); (root / 'bin').mkdir()
        for relative in f.RUNTIME_REQUIRED:
            path = root / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('reviewed source\n')
        (root / 'bin/tool').write_text('reviewed source\n')
        config = {'version': 1, 'protected_card_keys': sorted(f.REQUIRED_KEYS), 'admitted': []}
        (root / 'config/factory-repair-slot.json').write_text(json.dumps(config))
        meta = {'version': 1, 'manifest_path': 'config/factory-repair-slot.json',
                'manifest_sha256': f.file_sha(root / 'config/factory-repair-slot.json'),
                'runtime_files': [{'path': p, 'sha256': f.file_sha(root / p)} for p in sorted(f.RUNTIME_REQUIRED | {'bin/tool'})]}
        (root / 'config/factory-repair-contract.json').write_text(json.dumps(meta))
        check(f.validate_local(root)['protected_card_keys'] == sorted(f.REQUIRED_KEYS), 'local contract positive refused')
        (root / 'bin/tool').write_text('changed source\n')
        try:
            f.validate_local(root)
        except f.Refusal:
            return
        raise AssertionError('changed runtime file accepted')


def local_contract_forge_dependency():
    # Keep the literal independently of RUNTIME_REQUIRED during a guard probe.
    dependency = 'lib/forge-token.sh'
    with tempfile.TemporaryDirectory(prefix='factory-forge-dependency-') as name:
        root = Path(name); (root / 'config').mkdir(); (root / 'bin').mkdir()
        paths = f.RUNTIME_REQUIRED | {dependency, 'bin/tool'}
        for relative in paths:
            path = root / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('reviewed source\n')
        config = {'version': 1, 'protected_card_keys': sorted(f.REQUIRED_KEYS), 'admitted': []}
        (root / 'config/factory-repair-slot.json').write_text(json.dumps(config))
        meta = {'version': 1, 'manifest_path': 'config/factory-repair-slot.json',
                'manifest_sha256': f.file_sha(root / 'config/factory-repair-slot.json'),
                'runtime_files': [{'path': p, 'sha256': f.file_sha(root / p)} for p in sorted(paths)]}
        contract = root / 'config/factory-repair-contract.json'; contract.write_text(json.dumps(meta))
        check(f.validate_local(root)['result'] == 'ok', 'full executed-module contract refused')
        meta['runtime_files'] = [entry for entry in meta['runtime_files'] if entry['path'] != dependency]
        contract.write_text(json.dumps(meta))
        try:
            f.validate_local(root)
        except f.Refusal as error:
            check(str(error) == 'runtime-dependencies-incomplete', 'wrong omitted-module refusal: ' + str(error))
            return
        raise AssertionError('omitted executed lib/forge-token.sh accepted')


def exclusion_required():
    try:
        f.validate_manifest({'version': 1, 'protected_card_keys': [], 'admitted': []})
    except f.Refusal:
        return
    raise AssertionError('missing protected keys accepted')


class Effects:
    def __init__(self):
        self.value = card(); self.calls = []; self.bad_proof = False; self.fail_close = False
        self.value['surfaces'] = ['src/runner.rs', 'src/storage.rs', 'release/factory-dispatch-contract.json']
        self.value['body'] = reviewed_body()

    def check_authority(self, state=None):
        self.calls.append('authority')

    def bootstrap_ready(self):
        self.calls.append('bootstrap-ready')

    def card(self):
        return item(self.value)

    def dispatch(self, state):
        self.calls.append('dispatch')
        self.value['assignee'] = state['owner']; self.value['column'] = 'doing'
        original = scope()[0]['original_input']; original['claim_worker'] = state['owner']
        return {'execution_id': 'lx-fixture', 'key': 'card-fixture', 'original_input': original,
                'witness': item(self.value), 'claim_receipt': {'durability': 'durable'}}

    def execution(self, state):
        _, view = scope(); view['original_input'] = state['original_input']; view['context'] = dict(state['original_input'])
        view['nodes'][0]['result']['handoff']['claim_worker'] = state['owner']
        return view

    def candidate(self, state):
        self.calls.append('candidate')
        baseline = fixture_contract(); reviewed = {**baseline, 'runner_source_sha256': 'b' * 64}
        text = f.encoded(reviewed).decode(); digest = f.sha(text.encode())
        manifest = {'source_oid': '1' * 40, 'app': 'loom', 'manifest_digest': '3' * 64,
                    'files': [{'path': p, 'sha256': h, 'size': 1} for p, h in reviewed['files'].items()] +
                    [{'path': 'release/factory-dispatch-contract.json', 'sha256': digest, 'size': len(text.encode())}]}
        manifest_text = f.encoded(manifest).decode()
        authority = {'app': 'loom', 'source_oid': '1' * 40, 'manifest_sha256': '3' * 64,
                     'manifest_file_sha256': f.sha(manifest_text.encode()), 'contract_sha256': digest,
                     'root': str(Path.home() / '.host-track/apps/loom/versions' / ('3' * 64)),
                     'current': str(Path.home() / '.host-track/apps/loom/current'),
                     'manifest_path': str(Path.home() / '.lastgit/artifacts/manifests' / ('3' * 64 + '.json'))}
        pr = {'url': state['handoff']['pr_url'], 'state': 'MERGED', 'mergedAt': '2026-10-09T00:00:00Z',
              'baseRefName': 'main', 'headRefName': 'factory/' + state['execution_id'] + '#IMPLEMENT',
              'mergeCommit': {'oid': '1' * 40}, 'body': 'Papercut: ' + f.COUNT_PAPERCUT +
              '\nKeep-open: papercut-loom-execution-status-backlog-sweep-pending-20260928\n'}
        return {'source_oid': '1' * 40, 'tree_oid': '2' * 40, 'manifest_sha256': '3' * 64,
                'contract_sha256': digest, 'official': {'status': 'promoted', 'oid': '1' * 40, 'tree_oid': '2' * 40,
                    'manifest_digest': '3' * 64, 'platform': 'darwin-arm64', 'channel': 'candidate', 'run_id': 1, 'artifact_id': 2},
                'authority': authority, 'manifest_json': manifest_text, 'source_contract_json': text,
                'baseline_contract_json': f.encoded(baseline).decode(), 'merge_receipt': pr,
                'intent_sha256': state['intent_sha256'], 'dispatch_authority_sha256': f.value_sha(state['dispatch_authority']),
                'completed_execution_sha256': state['completed_execution_sha256'], 'pr_url': state['handoff']['pr_url']}

    def install(self, state):
        self.calls.append('install')
        candidate = state['candidate']; manifest = f.strict_json(candidate['manifest_json'])
        return {'version': 1, 'result': 'installed', 'exact_match': True,
                'requested': {'app': 'loom', 'channel': 'candidate', 'source_oid': '1' * 40, 'manifest_sha256': '3' * 64},
                'official': {'repo': 'EdgeVector/loom', 'channel': 'candidate', 'platform': 'darwin-arm64',
                    'source_oid': '1' * 40, 'manifest_sha256': '3' * 64, 'tree_oid': '2' * 40, 'run_id': 1, 'artifact_id': 2},
                'installed': {'source_oid': '1' * 40, 'manifest_sha256': '3' * 64, 'tree_oid': '2' * 40,
                    'resolved_root': candidate['authority']['root'], 'files': [{k: row[k] for k in ('path', 'sha256')} for row in manifest['files']]},
                'soak': {'required': False, 'status': 'complete'}}

    def prove(self, state):
        self.calls.append('proof')
        result = {'version': 1, 'result': 'error' if self.bad_proof else 'positive',
                'intent_sha256': state['intent_sha256'], 'card': state['card'],
                'execution_id': state['execution_id'], 'action_attempt': state['proof_attempt'],
                'candidate_sha256': f.value_sha(state['candidate']),
                **{'candidate_' + k: state['candidate'][k] for k in ('source_oid', 'manifest_sha256', 'contract_sha256')}}
        result['signal'] = f.value_sha(result)
        return result

    def write(self, state, operation):
        self.calls.append(operation)
        if operation == 'close' and self.fail_close:
            raise f.Refusal('fixture close failure')
        if operation == 'proof-mark':
            self.value['body'] += '\nPROOF: END STATE met PASS factory-action=' + state['proof_attempt'] + '\n'
        elif operation == 'pr-metadata':
            self.value.update(pr_url=state['handoff']['pr_url'], branch='factory/lx-fixture#IMPLEMENT')
        elif operation == 'close':
            self.value['column'] = 'done'
        return {'contract_sha256': '6' * 64, 'durability': 'durable', 'next_snapshot_json': item(self.value)['snapshot_json'],
                'next_snapshot_sha256': item(self.value)['snapshot_sha256'], 'guard_snapshot_sha256': state['witness']['snapshot_sha256']}

    def parse(self, value, pr):
        return {'verdict': 'positive', 'signal': 'fixture-evidence', 'done_when': False,
                'reopened_same_signal': False, 'end_state_required': True}


def fixture_contract():
    return {'contract': 1, 'features': copy.deepcopy(f.FEATURES), 'definition_version': '5',
            'files': {'definitions/land-card.json': 'a' * 64, 'scripts/loom-card-brief.sh': 'c' * 64,
                      'release/factory-reviewed-decision.json': f.DECISION_POLICY_SHA},
            'runner_source_sha256': 'a' * 64, 'cli_source_sha256': 'b' * 64, 'supervisor_source_sha256': 'd' * 64,
            'budget_recovery_source_sha256': 'e' * 64}

def loom_public_contract(field):
    root = Path(tempfile.mkdtemp(prefix='factory-loom-contract-'))
    (root / 'release').mkdir(); (root / 'dist').mkdir(); (root / 'dist/loom').write_bytes(b'private runner')
    contract = fixture_contract(); contract['files'] = {'release/factory-reviewed-decision.json': f.DECISION_POLICY_SHA}
    (root / 'release/factory-reviewed-decision.json').write_bytes((ROOT / 'config/factory-reviewed-decision.json').read_bytes())
    if field == 'view': contract['features']['execution_view_json'] = 'show ID'
    else: contract['cli_source_sha256'] = 'wrong-nonempty-source-sha'
    path = root / 'release/factory-dispatch-contract.json'; path.write_bytes(f.encoded(contract))
    authority = {'contract_sha256': f.file_sha(path)}
    f.atomic_json(root / 'release/factory-dispatch-build.json', {'contract_sha256': authority['contract_sha256'], 'runner_sha256': f.file_sha(root / 'dist/loom')})
    with patch.object(f, 'verify_artifact', return_value=root):
        refused(lambda: f.verify_loom(authority), 'wrong public Loom ' + field + ' authority accepted')

def fkanban_guard_contract(field):
    root = Path(tempfile.mkdtemp(prefix='factory-fkanban-contract-')); (root / 'dist').mkdir()
    for name in ('kanban', 'kanban-mcp'): (root / 'dist' / name).write_bytes(b'private compiled CLI')
    contract = {'version': 1, 'snapshot_batch_shape': 'ordered-items-with-explicit-missing', 'max_snapshot_keys': 256,
        'durability': 'durable', 'card_fields': list(f.SCALARS + f.ARRAYS)}
    contract[field] = True if field == 'version' else 'legacy-flat-array'
    authority = {'source_oid': '1' * 40, 'contract_sha256': f.value_sha(contract)}
    f.atomic_json(root / 'dist/guarded-contract.json', {'source_commit': authority['source_oid'], 'contract_sha256': authority['contract_sha256'],
        'cli_sha256': f.file_sha(root / 'dist/kanban'), 'mcp_sha256': f.file_sha(root / 'dist/kanban-mcp'), 'contract': contract})
    with patch.object(f, 'verify_artifact', return_value=root):
        refused(lambda: f.verify_fk(authority), 'wrong guarded ' + field + ' authority accepted')

def controller_fixture():
    root = Path(tempfile.mkdtemp(prefix='factory-controller-case-'))
    effects = Effects()
    config = {'version': 1, 'authority_slug': f.AUTHORITY, 'protected_card_keys': sorted(f.REQUIRED_KEYS),
              'admitted': [{'card': f.COUNT_CARD, 'papercut': f.COUNT_PAPERCUT, 'repo': 'EdgeVector/loom', 'base': 'main',
                            'proof_action': 'canonical-active-counts-v1', 'surfaces': effects.value['surfaces'],
                            'brief_sha256': f.sha(effects.value['body'].split('\n## DECISION-CHECK\n')[0].encode())}],
              'dispatch_authority': {'fixture': 'retained', 'contract_sha256': f.sha(f.encoded(fixture_contract()))},
              'fkanban_authority': {'fixture': 'retained', 'contract_sha256': '6' * 64}}
    return f.Controller(config, root, effects, '5' * 64), effects, root


def e2e():
    controller, effects, root = controller_fixture()
    for _ in range(12):
        result = controller.once()
        if result.get('phase') == 'completed':
            break
    check(result.get('phase') == 'completed', 'finite positive path did not complete')
    check(effects.value['column'] == 'done', 'positive path lacks canonical done')
    check(effects.calls.count('dispatch') == 1 and effects.calls.count('proof') == 1, 'positive path repeated dispatch or proof')
    before = list(effects.calls); result = controller.once()
    check(result['result'] == 'noop' and effects.calls == before, 'completed receipt did not produce quiet noop')

def completed_lifecycle_hold():
    controller, effects, directory = controller_fixture()
    for _ in range(20):
        result = controller.once()
        if result.get('phase') == 'completed': break
    check(result.get('phase') == 'completed', 'finite completion fixture did not complete')
    f.atomic_json(directory / 'lifecycle-close-intent.json', {'version': 1, 'status': 'pending'})
    before = list(effects.calls); result = controller.once()
    check(result['result'] == 'noop' and effects.calls == before, 'retained lifecycle hold prevented validated quiet completion')



LIFECYCLE_PREDECESSOR = {
    'version': 1, 'status': 'complete',
    'config_sha256': '59ce8588aa428af6271c958d1918e739d8907908815ffebc2ddabd5bfcb287a2',
    'contract_sha256': '4529be31831b09754b835a251a4e342408c01e4444648ded8ab6d265e8fdae17',
    'slug': 'papercut-loom-active-summary-counts-terminal-duplicate-memberships-20261008',
    'record_sha256': '0332e871ac0405a04bede347ac29559f222ec853d31bce90113738ca392b09f2',
    'result_sha256': 'cc77cc0a425947d60589a57e761585893680c37ff58d17ee01cfd45fdf89f304',
}


def lifecycle_intent_fixture(value):
    directory = Path(tempfile.mkdtemp(prefix='finite-lifecycle-'))
    path = directory / 'lifecycle-close-intent.json'
    f.atomic_json(path, value)
    return directory, path


def lifecycle_current():
    value = {**LIFECYCLE_PREDECESSOR, 'contract_sha256': '7' * 64}
    directory, path = lifecycle_intent_fixture(value); before = path.read_bytes()
    f.require_lifecycle_intent_clear(directory, value['config_sha256'], value['contract_sha256'])
    check(path.read_bytes() == before, 'current complete lifecycle intent changed')


def lifecycle_predecessor():
    directory, path = lifecycle_intent_fixture(LIFECYCLE_PREDECESSOR); before = path.read_bytes()
    check(f.sha(before) == '55d438ce9b0429006af29297e8424c089f58db78e109d445f358114a38cecb29',
          'reviewed predecessor fixture bytes drift')
    f.require_lifecycle_intent_clear(directory, LIFECYCLE_PREDECESSOR['config_sha256'], '7' * 64)
    f.require_lifecycle_intent_clear(directory, LIFECYCLE_PREDECESSOR['config_sha256'], '8' * 64)
    check(path.read_bytes() == before, 'historical complete lifecycle intent changed')


def lifecycle_unknown():
    changes = {
        'pending': {'status': 'pending'},
        'failed': {'status': 'failed'},
        'foreign-config': {'config_sha256': '1' * 64},
        'unreviewed-runtime': {'contract_sha256': '2' * 64},
        'wrong-result': {'result_sha256': '3' * 64},
        'wrong-record': {'record_sha256': '4' * 64},
        'foreign-slug': {'slug': 'papercut-foreign'},
        'extra-field': {'foreign': True},
    }
    inputs = [(name, {**LIFECYCLE_PREDECESSOR, **delta}) for name, delta in changes.items()]
    current_changes = {
        'current-pending': {'status': 'pending'},
        'current-failed': {'status': 'failed'},
        'current-foreign-config': {'config_sha256': '1' * 64},
        'current-malformed-result': {'result_sha256': 'not-hex'},
        'current-malformed-version': {'version': True},
    }
    inputs.extend((name, {**LIFECYCLE_PREDECESSOR, 'contract_sha256': '7' * 64, **delta})
                  for name, delta in current_changes.items())
    for name, value in inputs:
        directory, path = lifecycle_intent_fixture(value); before = path.read_bytes()
        try:
            f.require_lifecycle_intent_clear(directory, LIFECYCLE_PREDECESSOR['config_sha256'], '7' * 64)
        except f.Refusal as error:
            check(str(error) == 'lifecycle-close-unknown-retained', 'wrong lifecycle refusal: ' + name)
        else:
            raise AssertionError('unreviewed lifecycle intent accepted: ' + name)
        check(path.read_bytes() == before, 'unknown lifecycle intent changed: ' + name)

    directory, path = lifecycle_intent_fixture(LIFECYCLE_PREDECESSOR)
    path.write_text(json.dumps(LIFECYCLE_PREDECESSOR, indent=2) + '\n'); before = path.read_bytes()
    try:
        f.require_lifecycle_intent_clear(directory, LIFECYCLE_PREDECESSOR['config_sha256'], '7' * 64)
    except f.Refusal as error:
        check(str(error) == 'lifecycle-close-unknown-retained', 'wrong raw-byte lifecycle refusal')
    else:
        raise AssertionError('noncanonical historical lifecycle bytes accepted')
    check(path.read_bytes() == before, 'noncanonical historical lifecycle bytes changed')

    path.write_text('[]\n'); before = path.read_bytes()
    try:
        f.require_lifecycle_intent_clear(directory, LIFECYCLE_PREDECESSOR['config_sha256'], '7' * 64)
    except f.Refusal as error:
        check(str(error) == 'lifecycle-close-unknown-retained', 'wrong lifecycle object refusal')
    else:
        raise AssertionError('nonobject lifecycle intent accepted')
    check(path.read_bytes() == before, 'nonobject lifecycle intent changed')


def hold():
    controller, effects, root = controller_fixture(); controller.once()
    effects.value['block_status'] = 'needs_human'; effects.value['block_reason'] = 'Tom hold'
    before = list(effects.calls)
    try:
        controller.once()
    except f.Refusal:
        pass
    check('dispatch' not in effects.calls and effects.value['block_reason'] == 'Tom hold', 'human hold caused a shared write')
    check(f.read_json(root / 'slot.json')['phase'] == 'reserved', 'human hold released slot')


def failed_proof():
    controller, effects, root = controller_fixture(); effects.bad_proof = True
    for _ in range(5):
        controller.once()
    try:
        controller.once()
    except f.Refusal:
        pass
    check(effects.value['column'] == 'doing' and 'proof-mark' not in effects.calls and 'close' not in effects.calls,
          'failed proof caused closeout')


def retry_close():
    controller, effects, root = controller_fixture(); effects.fail_close = True
    for _ in range(9):
        try:
            controller.once()
        except f.Refusal:
            break
    check(effects.value['column'] == 'doing', 'failed close released slot')
    effects.fail_close = False
    for _ in range(3):
        controller.once()
    check(effects.calls.count('proof') == 1, 'close retry executed a second proof')

def refused(call, message):
    try:call()
    except f.Refusal:return
    raise AssertionError(message)

def dispatch_grammar():
    controller,effects,directory=controller_fixture();controller.once();state=f.read_json(directory/'slot.json')
    state['phase']='dispatch-pending'
    logs=directory/'kickoff';logs.mkdir(); key='card-'+state['card']+'-20261008T191927Z'
    ident='lx-20261008T191927.569-36821-1'; original={**scope()[0]['original_input'],'claim_worker':state['owner']}
    (logs/'factory-repair-slot.current').write_text(key+' '+state['card']+' 123 '+json.dumps(original)+'\n')
    (logs/(key+'.log')).write_text(ident+'\n')
    effects.value.update(assignee=state['owner'],column='doing'); witness=item(effects.value)
    receipt={'result':'claimed','durability':'durable','contract_sha256':'6'*64,
             'guard_snapshot_sha256':state['intent']['witness_sha256'],'next_snapshot_json':witness['snapshot_json'],'next_snapshot_sha256':witness['snapshot_sha256']}
    f.atomic_json(directory/('claim-'+state['intent']['attempt']+'.json'),receipt)
    runtime=f.Runtime(directory,controller.config,directory);runtime.loom=directory
    result=runtime.dispatch(state)
    check(result['key']==key and result['execution_id']==ident,'actual uppercase kickoff key or fractional ID refused')
    check(not f.kickoff_key('../'+key,state['card']) and not f.EXEC_ID.fullmatch('lx-../../escape'),'identity accepted a path escape')

def native_membership_row(created='2026-10-08T19:19:27.569Z'):
    ident = 'lx-20261008T191927.569-36821-1'
    sort = 'land-card#' + created + '#' + ident
    return {'key': {'hash': 'running', 'range': sort},
            'fields': {'id': ident, 'definition_name': 'land-card', 'by_status_sort': sort}}


def native_membership_fixture(row=None, all_statuses=False):
    root=Path(tempfile.mkdtemp(prefix='native-ids-')); schema={'LoomExecution':'a'*64,'LoomExecutionByStatus':'b'*64}
    f.atomic_json(root/'hashes.json',schema); config={'schema_map':str(root/'hashes.json'),'loom_schemas':schema,'owner_socket':'PRIVATE'}
    row = copy.deepcopy(native_membership_row() if row is None else row)
    called=[]; saved=f.owner_query_page
    def reply(sock,hash_value,flt,fields,limit,offset=0):
        status=flt['HashKey']; called.append((status, list(fields), limit, offset))
        current = copy.deepcopy(row)
        if all_statuses: current['key']['hash'] = status
        return {'has_more':False,'results':[current] if all_statuses or status == 'running' else []}
    f.owner_query_page=reply
    try: return f.active_candidate_keys(config), called
    finally: f.owner_query_page=saved


def native_ids():
    try: keys, called = native_membership_fixture(all_statuses=True)
    except f.Refusal as error:
        raise AssertionError('real composite status range was refused: ' + str(error)) from error
    check(keys==['lx-20261008T191927.569-36821-1'] and {v[0] for v in called}==f.ACTIVE and len(called)==3,
          'native actual ID mix was refused')
    check(all(v[1:] == (['id','definition_name','by_status_sort'],1000,0) for v in called),
          'native membership did not request the supported identity fields')


def native_ids_offset():
    keys, _ = native_membership_fixture(native_membership_row('2026-10-08T19:19:27+00:00'))
    check(keys == ['lx-20261008T191927.569-36821-1'], 'valid RFC3339 composite range was refused')


def native_offset_minutes():
    for minute in ('60', '99'):
        row = native_membership_row('2026-10-08T19:19:27+00:' + minute)
        try: native_membership_fixture(row)
        except f.Refusal: continue
        raise AssertionError('native invalid UTC offset minute ' + minute + ' membership was accepted')


def native_membership_bad(name):
    row = native_membership_row(); fields = row['fields']; key = row['key']
    if name == 'plain_range': key['range'] = fields['by_status_sort'] = fields['id']
    elif name == 'foreign_hash': key['hash'] = 'foreign'
    elif name == 'sort_mismatch': fields['by_status_sort'] = key['range'].replace('27.569Z', '28.569Z')
    elif name == 'definition_mismatch': fields['definition_name'] = 'another-definition'
    elif name == 'id_suffix_mismatch': fields['id'] = 'lx-other'
    elif name == 'missing_definition': del fields['definition_name']
    elif name == 'missing_sort': del fields['by_status_sort']
    elif name == 'empty_definition':
        fields['definition_name'] = ''
        key['range'] = fields['by_status_sort'] = key['range'].removeprefix('land-card')
    elif name == 'timestamp_format':
        key['range'] = fields['by_status_sort'] = 'land-card#not-a-time#' + fields['id']
    elif name == 'timestamp_calendar':
        key['range'] = fields['by_status_sort'] = 'land-card#2026-02-31T19:19:27.569Z#' + fields['id']
    elif name == 'id_token':
        fields['id'] = 'lx-../../escape'
        key['range'] = fields['by_status_sort'] = 'land-card#2026-10-08T19:19:27.569Z#' + fields['id']
    elif name == 'sort_type': fields['by_status_sort'] = 7
    elif name == 'incomplete': row['unresolved'] = True
    else: raise AssertionError('unknown membership fixture')
    try: native_membership_fixture(row)
    except f.Refusal: return
    except Exception as error:
        raise AssertionError('native ' + name + ' lacked structured refusal: ' + type(error).__name__) from error
    raise AssertionError('native ' + name + ' membership was accepted')


def native_foreign():
    row={'key':{'hash':'foreign','range':None},'fields':{'id':'foreign','status':'running','state':'IMPLEMENT','updated_at':'r','definition_name':'land-card'}}
    refused(lambda:f.native_execution_rows([row],['lx-a']),'foreign canonical key accepted')

def native_missing():
    refused(lambda:f.native_execution_rows([],['lx-a']),'missing canonical key inferred inactive')

def strict_snapshot_version():
    value=item(card()); raw=json.loads(value['snapshot_json']);raw['version']=True;value['snapshot_json']=json.dumps(raw)+'\n';value['snapshot_sha256']=f.sha(value['snapshot_json'].encode())
    refused(lambda:f.validate_snapshot(value,value['slug']),'boolean raw23 contract version accepted')

def strict_batch_version():
    value=item(card()); reply={'version':1.0,'schema_hash':'a'*64,'items':[value]}
    refused(lambda:f.validate_card_batch(reply,[value['slug']]),'float batch contract version accepted')

def strict_manifest_version():
    refused(lambda:f.validate_manifest({'version':True,'protected_card_keys':sorted(f.REQUIRED_KEYS),'admitted':[]}),'boolean manifest version accepted')

def strict_summary_count():
    rows = [{'id': 'lx-a', 'status': 'running', 'state': 'IMPLEMENT', 'updated_at': 'x', 'definition_name': 'land-card'}]
    status = {'total': True, 'by_status': {'running': 1}, 'by_definition': {'land-card': 1}, 'executions': rows}
    refused(lambda: f.compare_count(status, rows), 'boolean active summary total accepted')

def wrong_signal():
    controller,effects,root=controller_fixture(); original=effects.prove
    def bad(state):return {**original(state),'signal':'f'*64}
    effects.prove=bad
    for _ in range(5):controller.once()
    refused(controller.once,'wrong nonempty proof signal authorized closeout')
    check('proof-mark' not in effects.calls,'wrong signal wrote Card proof')

def candidate_drift():
    controller,effects,root=controller_fixture(); original=effects.candidate
    effects.candidate=lambda state:{**original(state),'intent_sha256':'f'*64}
    for _ in range(3):controller.once()
    refused(controller.once,'candidate from another dispatch intent accepted')
    check('install' not in effects.calls,'drifted candidate reached install')

def completion_drift():
    controller,effects,root=controller_fixture()
    for _ in range(12):
        result=controller.once()
        if result.get('phase')=='completed':break
    state=f.read_json(root/'slot.json');state['completion']['execution_id']='lx-other';state['completion_sha256']=f.value_sha(state['completion']);f.atomic_json(root/'slot.json',state)
    refused(controller.once,'self-hashed stale completion became quiet noop')

def accepted_recovery(change=None):
    controller,effects,root=controller_fixture();controller.once();state=f.read_json(root/'slot.json');state['phase']='dispatch-pending'
    effects.value.update(column='doing',assignee=state['owner'],position='1791510000000',updated_at='2026-10-09T02:00:00.000Z',
        tags=[v for v in effects.value['tags'] if not v.startswith(('done_at:', 'first_doing_at:'))] + ['first_doing_at:2026-10-09T02:00:00.000Z'],
        block_status='needs_human',block_reason='claim recovery pending for worker "' + state['owner'] + '": do not work this card until the claim completes')
    if change: effects.value[change] = 'human changed ' + change
    witness=item(effects.value); accepted={'version':1,'stage':'accepted-held','durability':'durable','contract_sha256':'6'*64,
        'guard_snapshot_sha256':state['intent']['witness_sha256'],'snapshot_json':witness['snapshot_json'],'snapshot_sha256':witness['snapshot_sha256']}
    receipt={'result':'error','code':'claim_recovery_pending','accepted_held':accepted}
    f.atomic_json(root/('claim-'+state['intent']['attempt']+'.json'),receipt)
    runtime=f.Runtime(root,controller.config,root)
    if change:
        refused(lambda: runtime.recover_dispatch(state), 'foreign accepted-held ' + change + ' was adopted'); return
    recovered=runtime.recover_dispatch(state)
    check(recovered['phase']=='claim-recovery-pending' and recovered['witness']==witness,'durable accepted-held witness was lost')
    accepted['guard_snapshot_sha256']='f'*64;f.atomic_json(root/('claim-'+state['intent']['attempt']+'.json'),receipt)
    refused(lambda:runtime.recover_dispatch(state),'foreign accepted-held guard was adopted')

def real_parser_e2e():
    from closeout_evidence import parse_card_evidence
    controller,effects,root=controller_fixture();effects.parse=parse_card_evidence
    for _ in range(12):
        result=controller.once()
        if result.get('phase')=='completed':break
    check(result.get('phase')=='completed','real latest-evidence parser refused fixed positive controller path')

def slot_busy():
    import fcntl
    controller,effects,root=controller_fixture()
    with (root/'slot.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        result=controller.once()
    check(result.get('reason')=='shared-slot-busy' and effects.calls==[],'busy slot performed a public effect')

def bootstrap_required():
    controller, effects, root = controller_fixture()
    def pending(): raise f.Refusal('bootstrap not complete')
    effects.bootstrap_ready = pending
    refused(controller.once, 'count reserved before bootstrap completion')
    check(not (root / 'slot.json').exists() and 'dispatch' not in effects.calls, 'incomplete bootstrap created count authority')

def reviewed_encoding():
    directory = ROOT / 'tests/fixtures/factory-reviewed-decision'
    expected = f.read_json(directory / 'receipt.json'); body = f.read_bytes(directory / 'card-body.md', 65536).decode()
    actual = f.validate_admitted_body(body, {'card': f.COUNT_CARD, 'repo': 'EdgeVector/loom', 'base': 'main', 'brief_sha256': expected['brief_sha256']})
    check(actual == expected, 'controller receipt differs from the reviewed Loom canonical encoding')

def reviewed_stamp_changed():
    controller, effects, root = controller_fixture(); effects.value['body'] = effects.value['body'].replace('verdict: honor', 'verdict: clear')
    refused(controller.once, 'clear spoof replaced the exact reviewed named decision stamp')
    check(not (root / 'slot.json').exists() and 'dispatch' not in effects.calls, 'wrong named stamp created count authority')

def execution_receipt_changed():
    state, view = scope(); view['context'] = {**view['context'], 'factory_decision_receipt': {**view['context']['factory_decision_receipt'], 'authority_slug': 'another-authority'}}
    refused(lambda: f.validate_execution(view, state), 'mutable context replaced the retained decision receipt')

def execution_original_receipt_changed():
    state, view = scope(); original = copy.deepcopy(state['original_input'])
    original['factory_decision_receipt']['authority_slug'] = 'another-authority'
    state['original_input'] = original; view['original_input'] = copy.deepcopy(original); view['context'] = copy.deepcopy(original)
    refused(lambda: f.validate_execution(view, state), 'original execution replaced the retained decision receipt')

TEST_NAMES=('raw23','missing_field','wrong_sha','reply_keys','missing_item','count_duplicate','count_terminal',
    'immutable_input','accepted_handoff','local_contract','exclusion_required','e2e','hold','failed_proof','retry_close',
    'dispatch_grammar','native_ids','native_foreign','native_missing','strict_snapshot_version','strict_batch_version',
    'strict_manifest_version','wrong_signal','candidate_drift','completion_drift','accepted_recovery','real_parser_e2e','slot_busy','strict_summary_count','bootstrap_required')
CASES={name:globals()[name] for name in TEST_NAMES}
CASES['local_contract_forge_dependency'] = local_contract_forge_dependency
CASES['execution_padded_version'] = execution_padded_version
CASES['execution_bare_version'] = lambda: execution_version_refused('5')
CASES['execution_wrong_padded_version'] = lambda: execution_version_refused('0000000006')
CASES['execution_integer_version'] = lambda: execution_version_refused(5)
CASES['execution_boolean_version'] = lambda: execution_version_refused(True)
CASES['execution_float_version'] = lambda: execution_version_refused(5.0)
CASES['execution_null_version'] = lambda: execution_version_refused(None)
CASES['accepted_body_changed'] = lambda: accepted_recovery('body')
CASES['accepted_reason_changed'] = lambda: accepted_recovery('block_reason')
CASES['reviewed_encoding'] = reviewed_encoding
CASES['reviewed_stamp_changed'] = reviewed_stamp_changed
CASES['execution_receipt_changed'] = execution_receipt_changed
CASES['execution_original_receipt_changed'] = execution_original_receipt_changed
CASES['completed_lifecycle_hold'] = completed_lifecycle_hold
CASES['lifecycle_current'] = lifecycle_current
CASES['lifecycle_predecessor'] = lifecycle_predecessor
CASES['lifecycle_unknown'] = lifecycle_unknown
CASES['loom_view_capability'] = lambda: loom_public_contract('view')
CASES['loom_cli_source'] = lambda: loom_public_contract('cli')
CASES['fkanban_contract_version'] = lambda: fkanban_guard_contract('version')
CASES['fkanban_batch_shape'] = lambda: fkanban_guard_contract('snapshot_batch_shape')
CASES['native_ids_offset'] = native_ids_offset
CASES['native_offset_minutes'] = native_offset_minutes
for _name in ('plain_range','foreign_hash','sort_mismatch','definition_mismatch','id_suffix_mismatch',
              'missing_definition','missing_sort','empty_definition','timestamp_format','timestamp_calendar',
              'id_token','sort_type','incomplete'):
    CASES['native_' + _name] = lambda name=_name: native_membership_bad(name)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('case',nargs='?',choices=CASES);args=parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try:CASES[name]()
        except Exception as error:print('FAIL: '+name+': '+str(error),file=sys.stderr);sys.exit(1)
        print('PASS: '+name)
