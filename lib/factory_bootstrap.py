"""Explicit finite bootstrap closeout; never a generic exclusion bypass."""
import copy
import fcntl
import re
import shutil
import uuid
from pathlib import Path
from factory_repair import (Refusal, require, version1, HEX, OID, sha, value_sha, read_json, read_bytes,
    file_sha, atomic_json, validate_snapshot, public_card_batch, verify_fk, verify_historical_loom_component, json_call, bounded_call, strict_json, validate_claim_stage_one, validate_claim_success)

BOOTSTRAP_KEYS = {'factory-scoped-dispatch-20261008', 'factory-guarded-closeout-20261008'}
RECOVERY_POLICY = {
    'version': 1, 'kind': 'bootstrap-prewrite-refusal-recovery-v1',
    'card': 'factory-guarded-closeout-20261008',
    'from_state_sha256': '014a270ae0cfd4df8a54f272b8610a0d6f7190222b1a3d0033a629ddc902747d',
    'from_config_sha256': '413539410c95418f5208335415c1b7bc0afc20309c35a6ea8ef5fc6756e6f98a',
    'from_contract_sha256': '4529be31831b09754b835a251a4e342408c01e4444648ded8ab6d265e8fdae17',
    'reservation_attempt': '98d204a759e94a8490af3890ed5a3c9d',
    'write_attempt': '0c90d6d8a3064f6db98ff275261b8703',
    'witness_sha256': 'd2455ca1961d40ad61ccb0b1979435904ddae1362c06bc2f33e084a90a496918',
    'capture_sha256': '712cc6b08765bedcc01dc549a2c5905d36d9492fa3a208c6d3c7d4ff9692cd8a',
    'stdout_sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'stderr_sha256': '0b5b420b174f086b70a3ca5ccb4bbd2d08e5491f8f540ff4b5e7a40457f713f2',
    'stderr_bytes': 127,
    'writer_contract_sha256': 'bea8a495839390153b78d4827b1f9e996dff037841df85783f49adbdd8241128',
    'writer_source_oid': 'e807698578e0d05ac09ede32941c52beb1537a1d',
    'source_manifest_sha256': '99b9aac7e823f7a2d22e06d6f6579e448790a977710bc3d049a85463620968a5',
    'source_files': {
        'src/cli.ts': 'd439ac1b6f144d2056d1453560b38badfa2c4a8f0606e9f6caff481b02466d73',
        'src/commands/set.ts': '6c1fb1811d6660d79fa0bfdefcc30c58e7ff43bdb529c67a8eaa8caae2bfcb8c',
        'src/context.ts': 'c9a7f773be789062d357da26df624d83ccd8e67ce7d7e93b3ffb13866116fe48',
        'src/guarded-factory.ts': '7adfa5748ba33b44db082bc0d5220f4ddd0128d49c4daa86a5d572df7ee34ebf',
        'src/mcp/server.ts': 'df3c724ae7602e3506f0c6dd14a6e3344c2fb316ac2901dafd2c77e44e82b583',
    },
}
# Original failed writer. This is historical evidence, never the active writer.
RECOVERY_WRITER_AUTHORITY = {
    "app": "fkanban",
    "contract_sha256": "bea8a495839390153b78d4827b1f9e996dff037841df85783f49adbdd8241128",
    "current": "~/.host-track/apps/fkanban/current",
    "manifest_file_sha256": "3af23df80f7020c793710f2cad950d72b28457e405c03a866d0b238114b4aeb6",
    "manifest_path": "~/.lastgit/artifacts/manifests/899e5b985574b606ee18af294530006e212001fc770482887fc70e3a157e4cc2.json",
    "manifest_sha256": "899e5b985574b606ee18af294530006e212001fc770482887fc70e3a157e4cc2",
    "root": "~/.host-track/apps/fkanban/versions/899e5b985574b606ee18af294530006e212001fc770482887fc70e3a157e4cc2",
    "source_oid": "e807698578e0d05ac09ede32941c52beb1537a1d"
}

RECOVERY_STDERR = ('kanban: Surfaces must be bounded explicit repo-relative file paths or path globs '
                   'without traversal or bare directory patterns.\n')

def validate_config(config):
    require(isinstance(config, dict) and version1(config.get('version')), 'bootstrap-config-version')
    if 'refusal_recovery' in config:
        require(config['refusal_recovery'] == RECOVERY_POLICY and value_sha(config['refusal_recovery']) == value_sha(RECOVERY_POLICY),
                'bootstrap-recovery-policy')
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
                isinstance(entry.get('target_surfaces'), list) and all(isinstance(p, str) for p in entry['target_surfaces']), 'bootstrap-original-witness')
    return config

def completion_value(state):
    keys = ('config_sha256', 'contract_sha256', 'entry', 'owner', 'intent', 'witness', 'write_receipts')
    if 'recovery_history' in state: keys += ('recovery_history',)
    return {k: state[k] for k in keys}

def validate_refusal_capture(capture_text, stdout, stderr):
    require(isinstance(capture_text, str) and sha(capture_text.encode()) == RECOVERY_POLICY['capture_sha256'] and
            isinstance(stdout, str) and stdout == '' and sha(stdout.encode()) == RECOVERY_POLICY['stdout_sha256'] and
            isinstance(stderr, str) and stderr == RECOVERY_STDERR and len(stderr.encode()) == RECOVERY_POLICY['stderr_bytes'] and
            sha(stderr.encode()) == RECOVERY_POLICY['stderr_sha256'], 'bootstrap-recovery-capture-bytes')
    capture = strict_json(capture_text)
    require(capture == {'version': 1, 'rc': 1, 'operation': 'surfaces',
            'witness_sha256': RECOVERY_POLICY['witness_sha256'], 'stdout_sha256': RECOVERY_POLICY['stdout_sha256'],
            'stderr_sha256': RECOVERY_POLICY['stderr_sha256']} and version1(capture.get('version')) and
            type(capture.get('rc')) is int, 'bootstrap-recovery-capture-refusal')

def recovery_original(config, prior_text):
    require(config.get('refusal_recovery') == RECOVERY_POLICY and value_sha(config['refusal_recovery']) == value_sha(RECOVERY_POLICY), 'bootstrap-recovery-policy')
    require(isinstance(prior_text, str) and len(prior_text.encode()) <= 1024 * 1024 and
            sha(prior_text.encode()) == RECOVERY_POLICY['from_state_sha256'], 'bootstrap-recovery-original-state-bytes')
    prior = strict_json(prior_text)
    require(version1(prior.get('version')) and prior.get('phase') == 'reserved' and prior.get('write_receipts') == [] and
            'recovery_history' not in prior and prior.get('config_sha256') == RECOVERY_POLICY['from_config_sha256'] and
            prior.get('contract_sha256') == RECOVERY_POLICY['from_contract_sha256'], 'bootstrap-recovery-original-authority')
    require(prior.get('write_intent') == {'operation': 'surfaces', 'witness_sha256': RECOVERY_POLICY['witness_sha256'],
            'attempt': RECOVERY_POLICY['write_attempt']} and prior.get('intent', {}).get('attempt') == RECOVERY_POLICY['reservation_attempt'],
            'bootstrap-recovery-original-intent')
    entry = next(e for e in config['entries'] if e['card'] == RECOVERY_POLICY['card'])
    old_config = copy.deepcopy(config); del old_config['refusal_recovery']
    old_config['fkanban_authority'] = copy.deepcopy(RECOVERY_WRITER_AUTHORITY)
    old_entry = next(e for e in old_config['entries'] if e['card'] == RECOVERY_POLICY['card']); old_entry['target_surfaces'] = []
    require(value_sha(old_config) == RECOVERY_POLICY['from_config_sha256'] and prior.get('entry') == old_entry and
            prior.get('owner') == entry['owner'], 'bootstrap-recovery-config-transition')
    require(RECOVERY_WRITER_AUTHORITY['contract_sha256'] == RECOVERY_POLICY['writer_contract_sha256'] and
            RECOVERY_WRITER_AUTHORITY['source_oid'] == RECOVERY_POLICY['writer_source_oid'], 'bootstrap-recovery-writer-authority')
    fields = validate_snapshot(prior['witness'], entry['card'])['fields']
    require(prior['witness']['snapshot_sha256'] == entry['original_snapshot_sha256'] == RECOVERY_POLICY['witness_sha256'] and
            sha(fields['body'].encode()) == entry['original_body_sha256'] and fields['surfaces'] == entry['target_surfaces'] and
            fields['assignee'] == entry['initial_owner'] == '' and fields['column'] == entry['initial_column'] == 'backlog' and
            fields['repo'] == entry['repo'] == 'EdgeVector/fkanban' and fields['base'] == 'main' and
            fields['block_status'] in ('', 'none') and fields['block_reason'] == '', 'bootstrap-recovery-original-witness')
    validate_retained_chain(prior, old_entry, RECOVERY_WRITER_AUTHORITY['contract_sha256'])
    return prior, entry

def validate_recovery_history(state, config, contract_sha256):
    needed = state.get('entry', {}).get('card') == RECOVERY_POLICY['card'] and config is not None and 'refusal_recovery' in config
    if not needed and 'recovery_history' not in state: return
    require(needed, 'bootstrap-recovery-history-policy')
    require(state.get('phase') in ('promote', 'claim', 'claim-recovery-pending', 'proof-mark',
            'pr-metadata', 'close', 'done-readback', 'completed'), 'bootstrap-recovery-active-phase')
    history = state.get('recovery_history')
    require(isinstance(history, list) and len(history) == 1 and isinstance(history[0], dict), 'bootstrap-recovery-history-size')
    receipt = history[0]
    require(set(receipt) == {'version', 'kind', 'policy', 'prior_state_json', 'prior_state_sha256', 'capture_json', 'stdout', 'stderr',
            'to_config_sha256', 'to_contract_sha256', 'to_entry_sha256', 'phase', 'card_write', 'accepted_write_receipts', 'receipt_sha256'},
            'bootstrap-recovery-history-shape')
    require(version1(receipt.get('version')) and receipt.get('kind') == RECOVERY_POLICY['kind'] and receipt.get('policy') == RECOVERY_POLICY and
            value_sha(receipt.get('policy')) == value_sha(RECOVERY_POLICY) and
            receipt.get('prior_state_sha256') == RECOVERY_POLICY['from_state_sha256'] and receipt.get('phase') == 'promote' and
            receipt.get('card_write') is False and type(receipt.get('accepted_write_receipts')) is int and receipt['accepted_write_receipts'] == 0 and
            receipt.get('receipt_sha256') == value_sha({k: v for k, v in receipt.items() if k != 'receipt_sha256'}), 'bootstrap-recovery-history-receipt')
    prior, entry = recovery_original(config, receipt['prior_state_json'])
    validate_refusal_capture(receipt['capture_json'], receipt['stdout'], receipt['stderr'])
    require(receipt['to_config_sha256'] == state.get('config_sha256') == value_sha(config) and
            receipt['to_contract_sha256'] == state.get('contract_sha256') == contract_sha256 and
            receipt['to_entry_sha256'] == value_sha(entry) and state.get('entry') == entry and
            state.get('owner') == prior['owner'] and state.get('intent') == prior['intent'], 'bootstrap-recovery-history-conservation')

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
        if receipt.get('result') == 'claimed' or 'claim_chain' in receipt:
            require(item is not None, 'bootstrap-claim-chain-previous-snapshot')
            item = validate_claim_success(item, receipt, entry['owner'], writer_contract)
            previous_sha = item['snapshot_sha256']
            continue
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

def validate_completion(state, config_sha256, contract_sha256, entry, writer_contract, config=None):
    validate_recovery_history(state, config, contract_sha256)
    require(version1(state.get('version')) and state.get('phase') == 'completed' and state.get('config_sha256') == config_sha256 and
            state.get('contract_sha256') == contract_sha256 and state.get('entry') == entry and state.get('owner') == entry['owner'] and
            state.get('completion') == completion_value(state) and state.get('completion_sha256') == value_sha(state['completion']), 'bootstrap-completion-binding')
    require(not state.get('write_intent') and state.get('write_receipts'), 'bootstrap-completion-pending-write')
    require(not validate_retained_chain(state, entry, writer_contract), 'bootstrap-completion-held-stage')
    fields = validate_snapshot(state['witness'], entry['card'])['fields']
    require(fields['column'] == 'done' and fields['assignee'] == entry['owner'] and fields['surfaces'] == entry['target_surfaces'] and fields['block_status'] in ('', 'none') and
            fields['block_reason'] == '' and state['write_receipts'][-1].get('durability') == 'durable', 'bootstrap-final-done-receipt')

class BootstrapController:
    def __init__(self, config, directory, effects, contract_sha256, card):
        self.config = validate_config(config); self.directory = Path(directory); self.effects = effects
        self.contract = contract_sha256; self.config_sha = value_sha(config)
        require(card in BOOTSTRAP_KEYS, 'bootstrap-card-not-permitted')
        self.entry = next(e for e in config['entries'] if e['card'] == card)
        require(self.entry['configured'], 'bootstrap-receipts-not-reviewed')
        self.path = self.directory / ('bootstrap-' + card + '.json')

    def recover_prewrite_refusal(self):
        require(self.entry['card'] == RECOVERY_POLICY['card'] and self.config.get('refusal_recovery') == RECOVERY_POLICY,
                'bootstrap-recovery-not-permitted')
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'slot.lock').open('a') as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return {'version': 1, 'result': 'noop', 'reason': 'shared-slot-busy'}
            require(self.path.exists(), 'bootstrap-recovery-original-state-required')
            raw = read_bytes(self.path, 1024 * 1024); state = strict_json(raw)
            if 'recovery_history' in state:
                validate_recovery_history(state, self.config, self.contract)
                require(not state.get('write_intent'), 'bootstrap-unknown-write-retained')
                validate_retained_chain(state, self.entry, self.config['fkanban_authority']['contract_sha256'])
                if state.get('phase') == 'completed':
                    validate_completion(state, self.config_sha, self.contract, self.entry,
                        self.config['fkanban_authority']['contract_sha256'], self.config)
                self.effects.check_authority(self.entry); self.effects.check_refusal_source(RECOVERY_POLICY)
                self.ensure(state, done=state.get('phase') == 'completed')
                return {'version': 1, 'result': 'noop', 'reason': 'prewrite-refusal-already-recovered',
                        'phase': state['phase'], 'card': self.entry['card'],
                        'recovery_receipt_sha256': state['recovery_history'][0]['receipt_sha256']}
            require(not (self.directory / 'slot.json').exists(), 'bootstrap-active-count-retained')
            for key in BOOTSTRAP_KEYS - {self.entry['card']}:
                peer = self.directory / ('bootstrap-' + key + '.json')
                if peer.exists():
                    other = next(e for e in self.config['entries'] if e['card'] == key)
                    validate_completion(read_json(peer), self.config_sha, self.contract, other,
                        self.config['fkanban_authority']['contract_sha256'], self.config)
            prior, entry = recovery_original(self.config, raw.decode('utf-8'))
            require(self.contract != RECOVERY_POLICY['from_contract_sha256'] and isinstance(self.contract, str) and HEX.fullmatch(self.contract),
                    'bootstrap-recovery-new-local-authority')
            prefix = self.directory / ('bootstrap-public-' + RECOVERY_POLICY['write_attempt'])
            capture = read_bytes(prefix.with_suffix('.capture.json'), 65536).decode('utf-8')
            stdout = read_bytes(prefix.with_suffix('.out'), 65536).decode('utf-8')
            stderr = read_bytes(prefix.with_suffix('.err'), 65536).decode('utf-8')
            validate_refusal_capture(capture, stdout, stderr)
            self.effects.check_authority(entry); self.effects.check_refusal_source(RECOVERY_POLICY)
            self.ensure(prior)
            receipt = {'version': 1, 'kind': RECOVERY_POLICY['kind'], 'policy': copy.deepcopy(RECOVERY_POLICY),
                'prior_state_json': raw.decode('utf-8'), 'prior_state_sha256': sha(raw), 'capture_json': capture,
                'stdout': stdout, 'stderr': stderr, 'to_config_sha256': self.config_sha, 'to_contract_sha256': self.contract,
                'to_entry_sha256': value_sha(entry), 'phase': 'promote', 'card_write': False, 'accepted_write_receipts': 0}
            receipt['receipt_sha256'] = value_sha(receipt)
            state = copy.deepcopy(prior); state.update(entry=copy.deepcopy(entry), config_sha256=self.config_sha,
                contract_sha256=self.contract, phase='promote', recovery_history=[receipt]); del state['write_intent']
            validate_recovery_history(state, self.config, self.contract)
            require(sha(read_bytes(self.path, 1024 * 1024)) == RECOVERY_POLICY['from_state_sha256'], 'bootstrap-recovery-state-changed')
            atomic_json(self.path, state)
            return {'version': 1, 'result': 'ok', 'phase': 'promote', 'card': entry['card'], 'card_write': False,
                    'recovery_receipt_sha256': receipt['receipt_sha256']}

    def ensure(self, state, done=False):
        item = self.effects.card(self.entry); fields = validate_snapshot(item, self.entry['card'])['fields']
        require(item['snapshot_sha256'] == state['witness']['snapshot_sha256'], 'bootstrap-retained-witness-changed')
        require(fields['repo'] == self.entry['repo'] and fields['base'] == 'main' and
                fields['surfaces'] == self.entry['target_surfaces'], 'bootstrap-card-scope-or-hold')
        if state['phase'] != 'claim-recovery-pending':
            require(fields['block_status'] in ('', 'none') and fields['block_reason'] == '', 'bootstrap-card-scope-or-hold')
        else:
            require(state.get('accepted_held') and fields['column'] == 'doing' and fields['assignee'] == state['owner'], 'bootstrap-accepted-held-owner')
        expected_owner = self.entry['initial_owner'] if state['phase'] in ('reserved', 'promote', 'claim') else state['owner']
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
        if operation in ('claim', 'resume-claim'):
            item = validate_claim_success(state['witness'], receipt, state['owner'], self.config['fkanban_authority']['contract_sha256'])
        else:
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
                    validate_completion(current, self.config_sha, self.contract, self.entry, self.config['fkanban_authority']['contract_sha256'], self.config); self.ensure(current, done=True)
                    return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': self.entry['card']}
            count = self.directory / 'slot.json'
            require(not count.exists(), 'bootstrap-active-count-retained')
            for key in BOOTSTRAP_KEYS - {self.entry['card']}:
                peer = self.directory / ('bootstrap-' + key + '.json')
                if peer.exists():
                    other_entry = next(e for e in self.config['entries'] if e['card'] == key)
                    validate_completion(read_json(peer), self.config_sha, self.contract, other_entry, self.config['fkanban_authority']['contract_sha256'], self.config)
            if not self.path.exists():
                require(self.entry['card'] != RECOVERY_POLICY['card'] or 'refusal_recovery' not in self.config, 'bootstrap-recovery-original-state-required')
                self.effects.check_authority(self.entry)
                item = self.effects.card(self.entry); fields = validate_snapshot(item, self.entry['card'])['fields']
                require(item['snapshot_sha256'] == self.entry['original_snapshot_sha256'] and sha(fields['body'].encode()) == self.entry['original_body_sha256'] and
                        fields['assignee'] == self.entry['initial_owner'] and fields['column'] == self.entry['initial_column'] and
                        fields['repo'] == self.entry['repo'] and fields['base'] == 'main' and fields['block_status'] in ('', 'none') and
                        fields['block_reason'] == '' and fields['surfaces'] == self.entry['target_surfaces'], 'bootstrap-initial-card-drift')
                state = {'version': 1, 'phase': 'reserved', 'entry': self.entry, 'owner': self.entry['owner'], 'witness': item,
                         'config_sha256': self.config_sha, 'contract_sha256': self.contract,
                         'intent': {'attempt': uuid.uuid4().hex, 'initial_snapshot_sha256': item['snapshot_sha256'],
                                    'component_receipt_sha256': self.entry['proof']['sha256'], 'producer_sha256': self.entry['proof']['producer_sha256']},
                         'write_receipts': []}
                atomic_json(self.path, state)
            else:
                state = read_json(self.path)
                validate_recovery_history(state, self.config, self.contract)
                require(version1(state.get('version')) and state.get('config_sha256') == self.config_sha and
                        state.get('contract_sha256') == self.contract and state.get('entry') == self.entry and state.get('owner') == self.entry['owner'], 'bootstrap-retained-authority-drift')
                require(not state.get('write_intent'), 'bootstrap-unknown-write-retained')
                validate_retained_chain(state, self.entry, self.config['fkanban_authority']['contract_sha256'])
                if state['phase'] == 'completed':
                    validate_completion(state, self.config_sha, self.contract, self.entry, self.config['fkanban_authority']['contract_sha256'], self.config); self.ensure(state, done=True)
                    return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': self.entry['card']}
                fields = self.ensure(state)
                self.effects.check_authority(self.entry)
                phase = state['phase']
                if phase == 'reserved':
                    require(fields['surfaces'] == self.entry['target_surfaces'], 'bootstrap-preserved-surfaces-drift')
                    if self.entry['initial_owner']:
                        state['phase'] = 'proof-mark'; atomic_json(self.path, state)
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
        authority = entry['artifact_authority']; binary = verify_fk(authority, current=False); artifact = read_json(binary.parent / 'guarded-contract.json')
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
        root = verify_historical_loom_component(entry['artifact_authority'])
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
        self.binary = verify_fk(config['fkanban_authority'], require_claim_chain=True)
    def check_authority(self, entry):
        self.binary = verify_fk(self.config['fkanban_authority'], require_claim_chain=True); verify_component(entry)
        gh = shutil.which('gh'); require(gh is not None, 'bootstrap-github-cli-unavailable')
        pr = json_call([gh, 'pr', 'view', entry['pr_url'], '-R', entry['repo'], '--json', 'url,state,mergedAt,baseRefName,headRefName,mergeCommit'], 30)
        require(pr.get('url') == entry['pr_url'] and pr.get('state') == 'MERGED' and pr.get('mergedAt') and
                pr.get('baseRefName') == entry['base'] and pr.get('headRefName') == entry['branch'] and
                pr.get('mergeCommit', {}).get('oid') == entry['pr_merge_oid'], 'bootstrap-original-merged-pr')
        original = entry['pr_merge_oid']; installed = entry['artifact_authority']['source_oid']
        comparison = json_call([gh, 'api', 'repos/' + entry['repo'] + '/compare/' + original + '...' + installed], 30)
        require(comparison.get('status') in ('ahead', 'identical') and comparison.get('base_commit', {}).get('sha') == original and
                comparison.get('merge_base_commit', {}).get('sha') == original, 'bootstrap-installed-source-not-descendant')
    def check_refusal_source(self, policy):
        require(policy == RECOVERY_POLICY and value_sha(policy) == value_sha(RECOVERY_POLICY), 'bootstrap-recovery-source-policy')
        binary = verify_fk(RECOVERY_WRITER_AUTHORITY, current=False); artifact = read_json(binary.parent / 'guarded-contract.json')
        require(artifact.get('source_commit') == policy['writer_source_oid'] and artifact.get('contract_sha256') == policy['writer_contract_sha256'] and
                artifact.get('source_manifest_sha256') == policy['source_manifest_sha256'], 'bootstrap-recovery-source-authority')
        sources = artifact.get('source_manifest')
        require(isinstance(sources, list) and 1 <= len(sources) <= 512 and all(isinstance(item, dict) and
                isinstance(item.get('path'), str) and isinstance(item.get('sha256'), str) for item in sources), 'bootstrap-recovery-source-manifest')
        indexed = {item['path']: item['sha256'] for item in sources}
        require(len(indexed) == len(sources) and all(indexed.get(path) == digest for path, digest in policy['source_files'].items()),
                'bootstrap-recovery-source-parser')
    def card(self, entry): return public_card_batch(self.binary, [entry['card']])['items'][0]
    def parse(self, fields, pr):
        from closeout_evidence import parse_card_evidence
        return parse_card_evidence(fields, pr)
    def write(self, state, operation):
        entry = state['entry']; item = validate_snapshot(state['witness'], entry['card'])
        path = self.directory / ('bootstrap-witness-' + item['sha256'] + '.json')
        if not path.exists(): path.write_bytes(item['text'].encode())
        require(file_sha(path) == item['sha256'], 'bootstrap-retained-witness-file')
        if operation == 'promote': args = ['move', entry['card'], 'todo', '--from', 'backlog']
        elif operation in ('claim', 'resume-claim'): args = ['pickup', 'claim-v2', '--only-card', entry['card'], '--worker', state['owner']]
        elif operation == 'proof-mark': args = ['mark', entry['card'], 'PROOF: END STATE met PASS bootstrap-action=' + state['intent']['attempt'] + ' component-sha256=' + entry['proof']['sha256']]
        elif operation == 'pr-metadata': args = ['set', entry['card'], '--pr-url', entry['pr_url'], '--branch', entry['branch']]
        elif operation == 'close': args = ['move', entry['card'], 'done', '--from', 'doing']
        else: raise Refusal('bootstrap-write-operation')
        owner = '' if operation == 'promote' else state['owner']
        guard = ['--guard-snapshot', str(path), '--snapshot-sha256', item['sha256']]
        if operation not in ('claim', 'resume-claim'): guard += ['--expect-assignee', owner]
        prefix = self.directory / ('bootstrap-public-' + state['write_intent']['attempt'])
        rc, out, err = bounded_call([str(self.binary), *args, *guard, '--json'], 60)
        prefix.with_suffix('.out').write_bytes(out); prefix.with_suffix('.err').write_bytes(err)
        atomic_json(prefix.with_suffix('.capture.json'), {'version': 1, 'rc': rc, 'operation': operation,
            'witness_sha256': item['sha256'], 'stdout_sha256': sha(out), 'stderr_sha256': sha(err)})
        if rc != 0:
            # A nonzero public operation stays unknown unless it returns the
            # existing typed durable accepted-held claim receipt.
            try: receipt = strict_json(out) if operation in ('claim', 'resume-claim') else None
            except (ValueError, Refusal): receipt = None
            if not (isinstance(receipt, dict) and receipt.get('result') == 'error' and receipt.get('code') == 'claim_recovery_pending'):
                detail = err[:4096].decode('utf-8', errors='replace')
                if len(err) > 4096: detail += '\n[stderr excerpt; full bytes retained]'
                raise Refusal('bootstrap-public-write-refused: rc=' + str(rc) + ' capture=' + str(prefix) +
                    ' stderr_sha256=' + sha(err) + ' stderr=' + detail)
        else:
            receipt = strict_json(out)
        return receipt

def require_bootstraps_complete(root, directory, contract_sha256, binary):
    config = validate_config(read_json(Path(root) / 'config/factory-bootstrap-closeout.json'))
    require(all(e['configured'] for e in config['entries']), 'bootstrap-receipts-not-reviewed')
    entries = config['entries']; keys = [e['card'] for e in entries]
    states = [read_json(Path(directory) / ('bootstrap-' + key + '.json')) for key in keys]
    for state, entry in zip(states, entries): validate_completion(state, value_sha(config), contract_sha256, entry, config['fkanban_authority']['contract_sha256'], config)
    items = public_card_batch(binary, keys)['items']
    require(all(item.get('missing') is not True and item['snapshot_sha256'] == state['witness']['snapshot_sha256'] for item, state in zip(items, states)), 'bootstrap-final-canonical-drift')
