"""Explicit finite bootstrap closeout; never a generic exclusion bypass."""
import fcntl
import re
import shutil
import uuid
from pathlib import Path
from factory_repair import (Refusal, require, version1, HEX, OID, sha, value_sha, read_json, read_bytes,
    file_sha, atomic_json, validate_snapshot, public_card_batch, verify_fk, verify_loom, json_call, bounded_call, strict_json, validate_claim_stage_one)

BOOTSTRAP_KEYS = {'factory-scoped-dispatch-20261008', 'factory-guarded-closeout-20261008'}

def validate_config(config):
    require(isinstance(config, dict) and version1(config.get('version')), 'bootstrap-config-version')
    entries = config.get('entries')
    require(isinstance(entries, list) and len(entries) == 2 and {e.get('card') for e in entries} == BOOTSTRAP_KEYS,
            'bootstrap-fixed-keys')
    for entry in entries:
        require(type(entry.get('configured')) is bool, 'bootstrap-configured-shape')
        if not entry['configured']: continue
        key = entry['card']; loom = key == 'factory-scoped-dispatch-20261008'
        require(entry.get('repo') == ('EdgeVector/loom' if loom else 'EdgeVector/fkanban') and entry.get('base') == 'main', 'bootstrap-repo-base')
        require(entry.get('initial_column') == ('doing' if loom else 'backlog') and isinstance(entry.get('initial_owner'), str) and
                (bool(entry['initial_owner']) if loom else entry['initial_owner'] == '') and
                entry.get('owner') == (entry['initial_owner'] if loom else 'loom:factory-bootstrap-fkanban'), 'bootstrap-original-owner')
        require(isinstance(entry.get('pr_url'), str) and entry['pr_url'].startswith('https://github.com/' + entry['repo'] + '/pull/') and
                OID.fullmatch(entry.get('pr_merge_oid', '')), 'bootstrap-original-pr-pin')
        require(all(isinstance(entry.get(k), str) and HEX.fullmatch(entry[k]) for k in ('original_body_sha256', 'original_snapshot_sha256')) and
                isinstance(entry.get('target_surfaces'), list) and (loom or entry['target_surfaces'] == []), 'bootstrap-original-witness')
    return config

def completion_value(state):
    return {k: state[k] for k in ('config_sha256', 'contract_sha256', 'entry', 'owner', 'intent', 'witness', 'write_receipts')}

def validate_retained_chain(state, entry, writer_contract):
    intent = state.get('intent', {})
    require(isinstance(intent.get('attempt'), str) and re.fullmatch(r'[a-f0-9]{32}', intent['attempt']) and
            intent.get('initial_snapshot_sha256') == entry['original_snapshot_sha256'] and
            intent.get('component_receipt_sha256') == entry['proof']['sha256'] and intent.get('producer_sha256') == entry['proof']['producer_sha256'], 'bootstrap-completion-intent')
    receipts = state.get('write_receipts'); require(isinstance(receipts, list) and len(receipts) <= 16, 'bootstrap-receipt-chain-size')
    previous_sha = intent['initial_snapshot_sha256']
    item = state['witness'] if not receipts else None
    accepted = None
    for receipt in receipts:
        require(isinstance(receipt, dict), 'bootstrap-receipt-chain-shape')
        accepted = receipt.get('accepted_held') if receipt.get('code') == 'claim_recovery_pending' else None
        metadata = accepted if accepted else receipt
        require(isinstance(metadata, dict) and metadata.get('durability') == 'durable' and metadata.get('contract_sha256') == writer_contract and
                metadata.get('guard_snapshot_sha256') == previous_sha, 'bootstrap-receipt-chain-authority')
        if accepted:
            require(version1(accepted.get('version')) and accepted.get('stage') == 'accepted-held', 'bootstrap-receipt-chain-held-stage')
        item = {'slug': entry['card'], 'snapshot_json': metadata.get('snapshot_json' if accepted else 'next_snapshot_json'),
                'snapshot_sha256': metadata.get('snapshot_sha256' if accepted else 'next_snapshot_sha256')}
        validate_snapshot(item, entry['card']); previous_sha = item['snapshot_sha256']
    validate_snapshot(state['witness'], entry['card'])
    require(previous_sha == state['witness']['snapshot_sha256'] and item == state['witness'], 'bootstrap-final-witness-chain')
    return accepted

def validate_completion(state, config_sha256, contract_sha256, entry, writer_contract):
    require(version1(state.get('version')) and state.get('phase') == 'completed' and state.get('config_sha256') == config_sha256 and
            state.get('contract_sha256') == contract_sha256 and state.get('entry') == entry and state.get('owner') == entry['owner'] and
            state.get('completion') == completion_value(state) and state.get('completion_sha256') == value_sha(state['completion']), 'bootstrap-completion-binding')
    require(not state.get('write_intent') and state.get('write_receipts'), 'bootstrap-completion-pending-write')
    require(not validate_retained_chain(state, entry, writer_contract), 'bootstrap-completion-held-stage')
    fields = validate_snapshot(state['witness'], entry['card'])['fields']
    require(fields['column'] == 'done' and fields['assignee'] == entry['owner'] and fields['block_status'] in ('', 'none') and
            fields['block_reason'] == '' and state['write_receipts'][-1].get('durability') == 'durable', 'bootstrap-final-done-receipt')

class BootstrapController:
    def __init__(self, config, directory, effects, contract_sha256, card):
        self.config = validate_config(config); self.directory = Path(directory); self.effects = effects
        self.contract = contract_sha256; self.config_sha = value_sha(config)
        require(card in BOOTSTRAP_KEYS, 'bootstrap-card-not-permitted')
        self.entry = next(e for e in config['entries'] if e['card'] == card)
        require(self.entry['configured'], 'bootstrap-receipts-not-reviewed')
        self.path = self.directory / ('bootstrap-' + card + '.json')

    def ensure(self, state, done=False):
        item = self.effects.card(self.entry); fields = validate_snapshot(item, self.entry['card'])['fields']
        require(item['snapshot_sha256'] == state['witness']['snapshot_sha256'], 'bootstrap-retained-witness-changed')
        require(fields['repo'] == self.entry['repo'] and fields['base'] == 'main', 'bootstrap-card-scope-or-hold')
        if state['phase'] != 'claim-recovery-pending':
            require(fields['block_status'] in ('', 'none') and fields['block_reason'] == '', 'bootstrap-card-scope-or-hold')
        else:
            require(state.get('accepted_held') and fields['column'] == 'doing' and fields['assignee'] == state['owner'], 'bootstrap-accepted-held-owner')
        expected_owner = self.entry['initial_owner'] if state['phase'] in ('reserved', 'surfaces', 'promote', 'claim') else state['owner']
        require(fields['assignee'] == expected_owner and (not done or fields['column'] == 'done'), 'bootstrap-owner-or-column')
        return fields

    def write(self, state, operation, next_phase):
        require(len(state['write_receipts']) < 16, 'bootstrap-receipt-chain-size')
        state['write_intent'] = {'operation': operation, 'witness_sha256': state['witness']['snapshot_sha256'], 'attempt': uuid.uuid4().hex}
        atomic_json(self.path, state)
        receipt = self.effects.write(state, operation)
        if operation in ('claim', 'resume-claim') and receipt.get('code') == 'claim_recovery_pending':
            accepted = receipt.get('accepted_held', {})
            require(version1(accepted.get('version')) and accepted.get('stage') == 'accepted-held' and accepted.get('durability') == 'durable' and
                accepted.get('contract_sha256') == self.config['fkanban_authority']['contract_sha256'] and
                accepted.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'bootstrap-accepted-held-authority')
            item = {'slug': self.entry['card'], 'snapshot_json': accepted.get('snapshot_json'), 'snapshot_sha256': accepted.get('snapshot_sha256')}
            validate_claim_stage_one(state['witness'], item, state['owner'])
            state.update(witness=item, accepted_held=accepted, phase='claim-recovery-pending'); state['write_receipts'].append(receipt)
            del state['write_intent']; atomic_json(self.path, state); return
        require(receipt.get('durability') == 'durable' and receipt.get('contract_sha256') == self.config['fkanban_authority']['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'bootstrap-write-not-durable')
        item = {'slug': self.entry['card'], 'snapshot_json': receipt.get('next_snapshot_json'), 'snapshot_sha256': receipt.get('next_snapshot_sha256')}
        validate_snapshot(item, self.entry['card'])
        state['witness'] = item; state['write_receipts'].append(receipt); del state['write_intent']; state['phase'] = next_phase
        atomic_json(self.path, state)

    def once(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'slot.lock').open('a') as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return {'version': 1, 'result': 'noop', 'reason': 'shared-slot-busy'}
            if self.path.exists():
                current = read_json(self.path)
                if current.get('phase') == 'completed':
                    validate_completion(current, self.config_sha, self.contract, self.entry, self.config['fkanban_authority']['contract_sha256']); self.ensure(current, done=True)
                    return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': self.entry['card']}
            count = self.directory / 'slot.json'
            require(not count.exists(), 'bootstrap-active-count-retained')
            for key in BOOTSTRAP_KEYS - {self.entry['card']}:
                peer = self.directory / ('bootstrap-' + key + '.json')
                if peer.exists():
                    other_entry = next(e for e in self.config['entries'] if e['card'] == key)
                    validate_completion(read_json(peer), self.config_sha, self.contract, other_entry, self.config['fkanban_authority']['contract_sha256'])
            if not self.path.exists():
                self.effects.check_authority(self.entry)
                item = self.effects.card(self.entry); fields = validate_snapshot(item, self.entry['card'])['fields']
                require(item['snapshot_sha256'] == self.entry['original_snapshot_sha256'] and sha(fields['body'].encode()) == self.entry['original_body_sha256'] and
                        fields['assignee'] == self.entry['initial_owner'] and fields['column'] == self.entry['initial_column'] and
                        fields['repo'] == self.entry['repo'] and fields['base'] == 'main' and fields['block_status'] in ('', 'none') and
                        fields['block_reason'] == '', 'bootstrap-initial-card-drift')
                state = {'version': 1, 'phase': 'reserved', 'entry': self.entry, 'owner': self.entry['owner'], 'witness': item,
                         'config_sha256': self.config_sha, 'contract_sha256': self.contract,
                         'intent': {'attempt': uuid.uuid4().hex, 'initial_snapshot_sha256': item['snapshot_sha256'],
                                    'component_receipt_sha256': self.entry['proof']['sha256'], 'producer_sha256': self.entry['proof']['producer_sha256']},
                         'write_receipts': []}
                atomic_json(self.path, state)
            else:
                state = read_json(self.path)
                require(version1(state.get('version')) and state.get('config_sha256') == self.config_sha and
                        state.get('contract_sha256') == self.contract and state.get('entry') == self.entry and state.get('owner') == self.entry['owner'], 'bootstrap-retained-authority-drift')
                require(not state.get('write_intent'), 'bootstrap-unknown-write-retained')
                validate_retained_chain(state, self.entry, self.config['fkanban_authority']['contract_sha256'])
                if state['phase'] == 'completed':
                    validate_completion(state, self.config_sha, self.contract, self.entry, self.config['fkanban_authority']['contract_sha256']); self.ensure(state, done=True)
                    return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': self.entry['card']}
                fields = self.ensure(state)
                self.effects.check_authority(self.entry)
                phase = state['phase']
                if phase == 'reserved':
                    if self.entry['initial_owner']:
                        state['phase'] = 'proof-mark'; atomic_json(self.path, state)
                    elif fields['surfaces'] != self.entry['target_surfaces']:
                        self.write(state, 'surfaces', 'promote')
                    else:
                        state['phase'] = 'promote'; atomic_json(self.path, state)
                elif phase == 'promote': self.write(state, 'promote', 'claim')
                elif phase == 'claim': self.write(state, 'claim', 'proof-mark')
                elif phase == 'claim-recovery-pending': self.write(state, 'resume-claim', 'proof-mark')
                elif phase == 'proof-mark': self.write(state, 'proof-mark', 'pr-metadata')
                elif phase in ('pr-metadata', 'close'):
                    evidence = self.effects.parse(fields, self.entry['pr_url'])
                    require(evidence.get('verdict') == 'positive' and evidence.get('signal') and not evidence.get('done_when') and
                            not evidence.get('reopened_same_signal'), 'bootstrap-latest-positive-end-state')
                    if phase == 'pr-metadata':
                        state['evidence_signal'] = evidence['signal']; self.write(state, 'pr-metadata', 'close')
                    else:
                        require(evidence['signal'] == state['evidence_signal'], 'bootstrap-latest-evidence-drift')
                        self.write(state, 'close', 'done-readback')
                elif phase == 'done-readback':
                    self.ensure(state, done=True); state['phase'] = 'completed'; state['completion'] = completion_value(state)
                    state['completion_sha256'] = value_sha(state['completion']); atomic_json(self.path, state)
                else: raise Refusal('bootstrap-unknown-phase')
            return {'version': 1, 'result': 'ok', 'phase': state['phase'], 'card': self.entry['card']}

def verify_component(entry):
    proof = entry['proof']; require(file_sha(Path(proof['path']).expanduser()) == proof['sha256'] and
        file_sha(Path(proof['producer_path']).expanduser()) == proof['producer_sha256'], 'bootstrap-component-bytes-changed')
    value = read_json(Path(proof['path']).expanduser())
    if proof['kind'] == 'fkanban-installed-public-v1':
        authority = entry['artifact_authority']; binary = verify_fk(authority); artifact = read_json(binary.parent / 'guarded-contract.json')
        require(version1(value.get('version')) and value.get('result') == 'passed' and value.get('source_unchanged') is True and
                value.get('program_sha256') == proof['producer_sha256'] and value.get('artifact') == artifact and
                value.get('build') == proof['build'], 'bootstrap-fkanban-component-result')
        cases = value.get('cases'); require(isinstance(cases, list) and len(cases) == proof['checks'] + proof['observations'] and
            sum(case.get('passed') is True for case in cases) == proof['checks'] and
            all(isinstance(case, dict) and ('passed' not in case or case['passed'] is True) for case in cases), 'bootstrap-fkanban-component-cases')
        restart = value.get('restart'); require(restart == proof['restart'] and restart.get('passed') is True and
            all(type(restart.get(k)) is int for k in ('cards', 'destinations', 'absent_destinations')), 'bootstrap-fkanban-restart')
        stops = value.get('stop_checks'); require(isinstance(stops, list) and len(stops) == 2 and
            all(s.get('argv_verified') is True and type(s.get('pid')) is int and s['pid'] > 0 and s.get('signal') in ('SIGKILL', 'SIGTERM') for s in stops), 'bootstrap-fkanban-synthetic-stop')
    elif proof['kind'] == 'loom-reviewed-decision-component-v1':
        root = verify_loom(entry['artifact_authority'])
        require(version1(value.get('version')) and value.get('kind') == proof['kind'] and value.get('result') == 'positive' and
                value.get('source_unchanged') is True and value.get('primary_effects') is False and value.get('compiled_contract_verified') is True and
                value.get('producer_sha256') == proof['producer_sha256'] and type(value.get('definition_version')) is int and value['definition_version'] == 5 and
                value.get('runner_sha256') == file_sha(root / 'dist/loom') and
                all(value.get(k) == entry['artifact_authority'][k] for k in ('source_oid', 'manifest_sha256', 'contract_sha256')) and
                value.get('cases') == proof['required_cases'], 'bootstrap-loom-component-result')
    else: raise Refusal('bootstrap-unknown-component-proof')

class BootstrapRuntime:
    def __init__(self, root, config, directory):
        self.root = Path(root); self.config = config; self.directory = Path(directory)
        self.binary = verify_fk(config['fkanban_authority'])
    def check_authority(self, entry):
        self.binary = verify_fk(self.config['fkanban_authority']); verify_component(entry)
        gh = shutil.which('gh'); require(gh is not None, 'bootstrap-github-cli-unavailable')
        pr = json_call([gh, 'pr', 'view', entry['pr_url'], '-R', entry['repo'], '--json', 'url,state,mergedAt,baseRefName,headRefName,mergeCommit'], 30)
        require(pr.get('url') == entry['pr_url'] and pr.get('state') == 'MERGED' and pr.get('mergedAt') and
                pr.get('baseRefName') == entry['base'] and pr.get('headRefName') == entry['branch'] and
                pr.get('mergeCommit', {}).get('oid') == entry['pr_merge_oid'], 'bootstrap-original-merged-pr')
        original = entry['pr_merge_oid']; installed = entry['artifact_authority']['source_oid']
        comparison = json_call([gh, 'api', 'repos/' + entry['repo'] + '/compare/' + original + '...' + installed], 30)
        require(comparison.get('status') in ('ahead', 'identical') and comparison.get('base_commit', {}).get('sha') == original and
                comparison.get('merge_base_commit', {}).get('sha') == original, 'bootstrap-installed-source-not-descendant')
    def card(self, entry): return public_card_batch(self.binary, [entry['card']])['items'][0]
    def parse(self, fields, pr):
        from closeout_evidence import parse_card_evidence
        return parse_card_evidence(fields, pr)
    def write(self, state, operation):
        entry = state['entry']; item = validate_snapshot(state['witness'], entry['card'])
        path = self.directory / ('bootstrap-witness-' + item['sha256'] + '.json')
        if not path.exists(): path.write_bytes(item['text'].encode())
        require(file_sha(path) == item['sha256'], 'bootstrap-retained-witness-file')
        if operation == 'surfaces': args = ['set', entry['card'], '--surfaces', ','.join(entry['target_surfaces'])]
        elif operation == 'promote': args = ['move', entry['card'], 'todo', '--from', 'backlog']
        elif operation in ('claim', 'resume-claim'): args = ['pickup', 'claim-v2', '--only-card', entry['card'], '--worker', state['owner']]
        elif operation == 'proof-mark': args = ['mark', entry['card'], 'PROOF: END STATE met PASS bootstrap-action=' + state['intent']['attempt'] + ' component-sha256=' + entry['proof']['sha256']]
        elif operation == 'pr-metadata': args = ['set', entry['card'], '--pr-url', entry['pr_url'], '--branch', entry['branch']]
        elif operation == 'close': args = ['move', entry['card'], 'done', '--from', 'doing']
        else: raise Refusal('bootstrap-write-operation')
        owner = '' if operation in ('surfaces', 'promote') else state['owner']
        guard = ['--guard-snapshot', str(path), '--snapshot-sha256', item['sha256']]
        if operation not in ('claim', 'resume-claim'): guard += ['--expect-assignee', owner]
        prefix = self.directory / ('bootstrap-public-' + state['write_intent']['attempt'])
        rc, out, err = bounded_call([str(self.binary), *args, *guard, '--json'], 60)
        prefix.with_suffix('.out').write_bytes(out); prefix.with_suffix('.err').write_bytes(err)
        atomic_json(prefix.with_suffix('.capture.json'), {'version': 1, 'rc': rc, 'operation': operation,
            'witness_sha256': item['sha256'], 'stdout_sha256': sha(out), 'stderr_sha256': sha(err)})
        receipt = strict_json(out)
        require(rc == 0 or operation in ('claim', 'resume-claim') and receipt.get('result') == 'error' and
                receipt.get('code') == 'claim_recovery_pending', 'bootstrap-public-write-refused')
        return receipt

def require_bootstraps_complete(root, directory, contract_sha256, binary):
    config = validate_config(read_json(Path(root) / 'config/factory-bootstrap-closeout.json'))
    require(all(e['configured'] for e in config['entries']), 'bootstrap-receipts-not-reviewed')
    entries = config['entries']; keys = [e['card'] for e in entries]
    states = [read_json(Path(directory) / ('bootstrap-' + key + '.json')) for key in keys]
    for state, entry in zip(states, entries): validate_completion(state, value_sha(config), contract_sha256, entry, config['fkanban_authority']['contract_sha256'])
    items = public_card_batch(binary, keys)['items']
    require(all(item.get('missing') is not True and item['snapshot_sha256'] == state['witness']['snapshot_sha256'] for item, state in zip(items, states)), 'bootstrap-final-canonical-drift')
