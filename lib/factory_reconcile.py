"""One finite admission; all other keyed queue entries stay classified and open."""
import concurrent.futures
import fcntl
import os
import re
import shutil
import uuid
from pathlib import Path
from factory_repair import (AUTHORITY, COUNT_CARD, COUNT_PAPERCUT, SLUG, Refusal, require,
    read_json, read_bytes, encoded, value_sha, sha, atomic_json, validate_manifest,
    validate_snapshot, public_card_batch, verify_fk, bounded_call, json_call, relative_file, validate_admitted_body, version1, strict_json, HEX,
    require_lifecycle_intent_clear, validate_local, validate_native_metadata, verify_creation_contract, validate_created_receipt)

PAPERCUT_FIELDS = ('slug', 'title', 'body', 'status', 'component', 'repo', 'severity', 'kind', 'symptom_hash',
                  'fixed_by', 'verified_by', 'duplicate_of', 'tags', 'created_at', 'updated_at')

def brain_papercut_batch(config, brain, keys):
    require(len(keys) <= 16 and len(keys) == len(set(keys)) and all(SLUG.fullmatch(key) for key in keys), 'reviewed-lifecycle-key-shape')
    if not keys: return []
    schema = config.get('brain_papercut_schema_hash', '')
    require(isinstance(schema, str) and HEX.fullmatch(schema), 'reviewed-brain-schema-pin')
    request = {'schema_name': schema, 'filter': {'HashRangeKeys': [[key, ''] for key in keys]},
               'fields': list(PAPERCUT_FIELDS), 'limit': len(keys), 'offset': 0}
    rc, out, err = bounded_call([brain, 'raw', 'POST', '/api/query', '-'], 30, cap=8 * 1024 * 1024, stdin=encoded(request))
    require(rc == 0, 'reviewed-lifecycle-batch-unavailable')
    reply = strict_json(out)
    require(isinstance(reply, dict) and reply.get('ok') is True and reply.get('has_more') is False and reply.get('next_cursor') is None and
            isinstance(reply.get('results'), list) and len(reply['results']) == len(keys), 'reviewed-lifecycle-batch-incomplete')
    validate_native_metadata(reply, 'reviewed-lifecycle-batch')
    require(not reply.get('error') and not reply.get('errors') and ('returned_count' not in reply or
            type(reply['returned_count']) is int and reply['returned_count'] == len(keys)) and
            (reply.get('total_count') is None or type(reply['total_count']) is int and reply['total_count'] == len(keys)), 'reviewed-lifecycle-batch-error')
    records = {}
    for row in reply['results']:
        require(isinstance(row, dict) and isinstance(row.get('key'), dict) and isinstance(row.get('fields'), dict), 'reviewed-lifecycle-record-shape')
        validate_native_metadata(row, 'reviewed-lifecycle', row=True)
        ident = row['key'].get('hash'); fields = row['fields']
        require(ident in keys and ident not in records and 'range' in row['key'] and row['key']['range'] is None and
                fields.get('slug') == ident and set(fields) == set(PAPERCUT_FIELDS) and
                all(isinstance(fields[key], str) for key in PAPERCUT_FIELDS if key != 'tags') and
                isinstance(fields['tags'], list) and all(isinstance(tag, str) for tag in fields['tags']), 'reviewed-lifecycle-record-key-or-fields')
        records[ident] = {**fields, '_typed': True}
    require(set(records) == set(keys), 'reviewed-lifecycle-record-missing')
    return [records[key] for key in keys]


def queue_keys(receipt):
    require(isinstance(receipt, dict) and version1(receipt.get('version')) and receipt.get('ok') is True and
            isinstance(receipt.get('method'), str) and 'status-keyed papercut index' in receipt['method'], 'queue-source-unavailable')
    rows = receipt.get('rows')
    require(isinstance(rows, list) and type(receipt.get('discovered')) is int and receipt['discovered'] == len(rows) and
            len(rows) <= 8192 and receipt.get('quarantined') == [], 'queue-incomplete')
    keys = [row.get('slug') for row in rows if isinstance(row, dict)]
    require(len(keys) == len(rows) and len(keys) == len(set(keys)) and all(isinstance(key, str) and
            key.startswith('papercut-') and SLUG.fullmatch(key) for key in keys) and
            all(row.get('status') == 'open' for row in rows), 'queue-key-or-status')
    return keys


def classify(keys, known, bucket):
    require(bucket in ('reconciled', 'deferred', 'already_handled', 'failed'), 'classification-bucket')
    result = {name: [] for name in ('reconciled', 'deferred', 'already_handled', 'failed')}
    for key in keys:
        result[bucket if key == known else 'deferred'].append(key)
    require(sum(map(len, result.values())) == len(keys) and len({key for values in result.values() for key in values}) == len(keys),
            'classification-not-conserved')
    return result


KNOWN_PROGRESS_SHA = '0d42b3ab999d1adcd9945464b66ce6f151a8e5ab94c7925432cbfc85368dfb2e'
KNOWN_PROGRESS_TARGET_CONFIG_SHA = '0b2bd4cda81c8c14471e3248a7f5c42ff79742b890282cec9d547338533d1f9b'

def lifecycle_progress_cursor(raw, config_sha, reviewed_count):
    """Keep the exact no-effect cursor across this one writer config change."""
    progress = strict_json(raw)
    known_no_effect = (sha(raw) == KNOWN_PROGRESS_SHA and
                       config_sha == KNOWN_PROGRESS_TARGET_CONFIG_SHA)
    require(isinstance(progress, dict) and version1(progress.get('version')) and
            (progress.get('config_sha256') == config_sha or known_no_effect) and
            type(progress.get('cursor')) is int and 0 <= progress['cursor'] < reviewed_count,
            'reviewed-lifecycle-progress-drift')
    return progress['cursor']


class Reconciler:
    def __init__(self, root, config, directory, effects, contract_sha256):
        self.root = Path(root); self.config = validate_manifest(config); self.directory = Path(directory)
        require(config.get('authority_slug') == AUTHORITY and len(config['admitted']) == 1, 'reconciler-finite-authority')
        self.entry = config['admitted'][0]; self.effects = effects; self.contract = contract_sha256

    def admission(self, item):
        filing_path = self.directory / 'filing-intent.json'
        if item.get('missing') is True:
            path = filing_path
            brief = read_bytes(relative_file(self.root, self.entry['brief_path']), 64 * 1024)
            identity = {'version': 1, 'card': COUNT_CARD, 'config_sha256': value_sha(self.config),
                        'contract_sha256': self.contract, 'brief_sha256': sha(brief)}
            if path.exists():
                intent = read_json(path)
                require(version1(intent.get('version')) and all(intent.get(k) == v for k, v in identity.items()), 'filing-intent-drift')
                # A previous unknown create is never retried as an upsert.
                return 'deferred', 'filing-attempt-retained'
            self.effects.creation_ready()
            self.effects.tracked_surfaces(self.entry)
            latest = self.effects.card()
            require(latest.get('slug') == COUNT_CARD and latest.get('missing') is True, 'create-key-no-longer-absent')
            intent = {**identity, 'phase': 'filing', 'attempt': uuid.uuid4().hex}
            atomic_json(path, intent)
            receipt = self.effects.file(brief); item = validate_created_receipt(receipt, self.config)
            intent.update(phase='filed', created_witness=item, receipt=receipt); atomic_json(path, intent)
            require(self.effects.card() == item, 'created-witness-canonical-drift')
        if filing_path.exists():
            retained_filing = read_json(filing_path)
            require(version1(retained_filing.get('version')) and retained_filing.get('config_sha256') == value_sha(self.config) and
                    retained_filing.get('contract_sha256') == self.contract and retained_filing.get('card') == COUNT_CARD and
                    retained_filing.get('phase') == 'filed', 'filing-attempt-unknown-retained')
            created = validate_created_receipt(retained_filing.get('receipt'), self.config)
            require(retained_filing.get('created_witness') == created, 'filing-receipt-witness-drift')
            journal_path = self.directory / 'admission-intent.json'
            if not journal_path.exists(): require(item == created, 'created-witness-canonical-drift')
        fields = validate_snapshot(item, COUNT_CARD)['fields']
        require(fields['repo'] == self.entry['repo'] and fields['base'] == self.entry['base'], 'finite-existing-card-scope')
        if fields['column'] == 'done':
            # Card column alone supplies no lifecycle or live proof authority.
            return 'deferred', 'done-awaits-bound-completion'
        if fields['column'] not in ('backlog', 'todo') or fields['assignee'] or fields['block_status'] not in ('', 'none') or fields['block_reason']:
            return 'deferred', 'existing-owner-or-hold-preserved'
        validate_admitted_body(fields['body'], self.entry)
        journal = self.directory / 'admission-intent.json'
        identity = {'version': 1, 'card': COUNT_CARD, 'config_sha256': value_sha(self.config), 'contract_sha256': self.contract}
        if journal.exists():
            retained = read_json(journal)
            require(version1(retained.get('version')) and all(retained.get(k) == v for k, v in identity.items()) and retained.get('witness') == item,
                    'admission-witness-drift-retained')
            require(not retained.get('write_intent'), 'admission-write-unknown-retained')
        else:
            retained = {**identity, 'witness': item, 'phase': 'surfaces'}
            atomic_json(journal, retained)
        self.effects.tracked_surfaces(self.entry)
        if set(fields['surfaces']) != set(self.entry['surfaces']):
            retained['write_intent'] = {'operation': 'surfaces', 'witness_sha256': item['snapshot_sha256']}; atomic_json(journal, retained)
            item = self.effects.guarded(item, 'surfaces')
            fields = validate_snapshot(item, COUNT_CARD)['fields']
            require(set(fields['surfaces']) == set(self.entry['surfaces']), 'surfaces-readback')
            del retained['write_intent']; retained.update(witness=item, phase='promote'); atomic_json(journal, retained)
        if fields['column'] == 'backlog':
            retained['write_intent'] = {'operation': 'promote', 'witness_sha256': item['snapshot_sha256']}; atomic_json(journal, retained)
            item = self.effects.guarded(item, 'promote')
            fields = validate_snapshot(item, COUNT_CARD)['fields']
            require(fields['column'] == 'todo' and fields['assignee'] == '', 'promotion-readback')
            del retained['write_intent']; retained.update(witness=item, phase='ready'); atomic_json(journal, retained)
        return 'reconciled', 'finite-card-ready'

    def once(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        receipt = self.effects.snapshot(); keys = queue_keys(receipt)
        with (self.directory / 'slot.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return self.effects.finish(receipt, classify(keys, '', 'deferred'), 'shared-slot-busy')
            return self.locked_once(receipt, keys)

    def locked_once(self, receipt, keys):
        reviewed = self.config.get('lifecycle_reviewed_keys')
        require(isinstance(reviewed, list) and 1 <= len(reviewed) <= 16 and len(reviewed) == len(set(reviewed)) and
                COUNT_PAPERCUT in reviewed and all(isinstance(k, str) and k.startswith('papercut-') and SLUG.fullmatch(k) for k in reviewed), 'reviewed-lifecycle-manifest')
        wanted = [key for key in reviewed if key in keys]
        buckets = classify(keys, '', 'deferred')
        def classify_key(key, bucket):
            for values in buckets.values():
                if key in values: values.remove(key)
            buckets[bucket].append(key)
        if not wanted: return self.effects.finish(receipt, buckets, 'finite-reviewed-claims-not-open')
        try:
            records = self.effects.records(reviewed)
            require(isinstance(records, list) and len(records) == len(reviewed) and [r.get('slug') for r in records] == reviewed and
                    all(isinstance(r.get('body'), str) and r.get('status') in ('open', 'partial', 'fixed', 'verified', 'duplicate', 'wontfix') and
                        isinstance(r.get('duplicate_of'), str) and isinstance(r.get('symptom_hash'), str) and r['symptom_hash'] for r in records), 'reviewed-lifecycle-batch-incomplete')
            card_keys = self.config['protected_card_keys']; card_items = self.effects.cards(card_keys)
            require(isinstance(card_items, list) and len(card_items) == len(card_keys) and
                    [item.get('slug') for item in card_items] == card_keys, 'finite-card-classification-incomplete')
            card_facts = {}
            for key, item in zip(card_keys, card_items):
                if item.get('missing') is True:
                    require(set(item) == {'slug', 'missing'}, 'finite-card-classification-missing-shape')
                    card_facts[key] = {'missing': True, 'admission': 'finite-candidate' if key == COUNT_CARD else 'deferred'}
                else:
                    fields = validate_snapshot(item, key)['fields']
                    card_facts[key] = {'column': fields['column'], 'owner': fields['assignee'],
                        'held': fields['block_status'] not in ('', 'none') or bool(fields['block_reason']),
                        'admission': 'finite-candidate' if key == COUNT_CARD else 'deferred'}
            claim_facts = {r['slug']: {'duplicate_of': r['duplicate_of'],
                'same_symptom_reviewed_keys': [other['slug'] for other in records if other['slug'] != r['slug'] and
                    other['symptom_hash'] == r['symptom_hash']]} for r in records}
            receipt['finite_review'] = {'scope': 'configured-reviewed-keys-only', 'reviewed_claims': claim_facts, 'finite_cards': card_facts}
        except (Refusal, OSError, ValueError, KeyError, TypeError) as error:
            for key in wanted: classify_key(key, 'failed')
            return self.effects.finish(receipt, buckets, str(error))
        progress_path = self.directory / 'lifecycle-progress.json'; config_sha = value_sha(self.config); cursor = 0
        if progress_path.exists():
            cursor = lifecycle_progress_cursor(read_bytes(progress_path), config_sha, len(reviewed))
        selected = next(reviewed[(cursor + i) % len(reviewed)] for i in range(len(reviewed)) if reviewed[(cursor + i) % len(reviewed)] in wanted)
        by_key = {r['slug']: r for r in records}
        for record in records:
            if record['slug'] in wanted and record['status'] not in ('open', 'partial'): classify_key(record['slug'], 'already_handled')
        closed_this_tick = False
        try:
            require_lifecycle_intent_clear(self.directory, config_sha, self.contract)
            if by_key[selected]['status'] == 'open' and not claim_facts[selected]['duplicate_of'] and not claim_facts[selected]['same_symptom_reviewed_keys']:
                lifecycle = self.effects.lifecycle(by_key[selected])
                require(isinstance(lifecycle, dict) and lifecycle.get('ok') is True and not lifecycle.get('errors') and
                        isinstance(lifecycle.get('fixed'), list) and len(lifecycle['fixed']) <= 1 and not lifecycle.get('terminal_closed'), 'lifecycle-unavailable')
                require(all(row.get('slug') == selected for row in lifecycle['fixed']), 'lifecycle-foreign-close')
                if lifecycle['fixed']:
                    closed_this_tick = True; classify_key(selected, 'already_handled')
            atomic_json(progress_path, {'version': 1, 'config_sha256': config_sha, 'cursor': (reviewed.index(selected) + 1) % len(reviewed)})
        except (Refusal, OSError, ValueError, KeyError, TypeError) as error:
            classify_key(selected, 'failed'); return self.effects.finish(receipt, buckets, str(error))
        # Lifecycle classification continues during a generation hold; Card creation
        # remains the sole reviewed finite exception and never follows a close failure.
        known = COUNT_PAPERCUT
        if closed_this_tick or known not in wanted or by_key[known]['status'] != 'open':
            return self.effects.finish(receipt, buckets, 'labeled-merged-repair-fixed')
        if claim_facts[known]['duplicate_of'] or claim_facts[known]['same_symptom_reviewed_keys']:
            return self.effects.finish(receipt, buckets, 'finite-reviewed-duplicate-preserved')
        try:
            if (self.directory / 'slot.json').exists():
                return self.effects.finish(receipt, buckets, 'controller-slot-retained')
            self.effects.bootstrap_ready()
            bucket, reason = self.admission(card_items[card_keys.index(COUNT_CARD)]); classify_key(known, bucket)
        except (Refusal, OSError, ValueError, KeyError, TypeError) as error:
            classify_key(known, 'failed'); reason = str(error)
        return self.effects.finish(receipt, buckets, reason)


class ReconcileRuntime:
    def __init__(self, root, config, directory, capture):
        self.root = Path(root); self.config = config; self.directory = Path(directory); self.capture = Path(capture)
        self.capture.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.brain = str(Path.home() / '.local/bin/brain')
        self.kanban = verify_fk(config['fkanban_authority'], require_claim_chain=True)

    def snapshot(self):
        path = self.capture / 'queue.json'
        json_call([str(self.root / 'bin/last-stack-papercut-queue'), 'snapshot', '--output', str(path), '--brain-bin', self.brain,
                   '--timeout', '60', '--json'], 90)
        return read_json(path)

    def records(self, keys):
        return brain_papercut_batch(self.config, self.brain, keys)

    def lifecycle(self, record):
        intent = self.directory / 'lifecycle-close-intent.json'
        contract_sha256 = validate_local(self.root)['contract_sha256']
        require_lifecycle_intent_clear(self.directory, value_sha(self.config), contract_sha256)
        atomic_json(intent, {'version': 1, 'status': 'pending', 'slug': record['slug'], 'record_sha256': value_sha(record),
                             'config_sha256': value_sha(self.config), 'contract_sha256': contract_sha256})
        path = self.capture / 'records.json'; atomic_json(path, [record])
        result = json_call([str(self.root / 'bin/last-stack-papercut-lifecycle-close'), '--records-json', str(path),
                           '--brain-bin', self.brain, '--budget-seconds', '120', '--require-labeled-repair', '--durable', '--json'], 150)
        atomic_json(self.capture / 'lifecycle.json', result)
        require(result.get('ok') is True and not result.get('errors'), 'lifecycle-close-receipt-unknown-retained')
        atomic_json(intent, {'version': 1, 'status': 'complete', 'slug': record['slug'], 'record_sha256': value_sha(record),
                             'config_sha256': value_sha(self.config), 'contract_sha256': contract_sha256, 'result_sha256': value_sha(result)})
        return result

    def bootstrap_ready(self):
        from factory_bootstrap import require_bootstraps_complete
        require_bootstraps_complete(self.root, self.directory, validate_local(self.root)['contract_sha256'], self.kanban)

    def card(self):
        return public_card_batch(self.kanban, [COUNT_CARD])['items'][0]

    def cards(self, keys):
        return public_card_batch(self.kanban, keys)['items']

    def tracked_surfaces(self, entry):
        gh = shutil.which('gh', path=str(Path.home() / '.local/bin') + ':' + __import__('os').environ.get('PATH', ''))
        require(gh is not None, 'github-cli-unavailable')
        branch = json_call([gh, 'api', 'repos/' + entry['repo'] + '/branches/' + entry['base']], 30)
        oid = branch.get('commit', {}).get('sha', '')
        require(re.fullmatch(r'[0-9a-f]{40}', oid), 'reviewed-base-oid-unavailable')
        def one(path):
            data = json_call([gh, 'api', 'repos/' + entry['repo'] + '/contents/' + path + '?ref=' + oid], 30)
            require(data.get('type') == 'file' and data.get('path') == path and re.fullmatch(r'[0-9a-f]{40}', data.get('sha', '')),
                    'reviewed-surface-not-tracked: ' + path)
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(one, entry['surfaces']))
        atomic_json(self.capture / 'tracked-surfaces.json', {'repo': entry['repo'], 'base': entry['base'], 'oid': oid, 'paths': entry['surfaces']})

    def file(self, brief):
        self.creation_ready()
        # The standard decision gate forwards the reviewed public atomic
        # create-only route. An ordinary add never supplies absence authority.
        argv = [str(self.root / 'bin/last-stack-kanban-file-pr'), COUNT_CARD, '--title', 'Count canonical active Loom executions once',
                '--repo', 'EdgeVector/loom', '--base', 'main', '--north-star', 'north-star-portable-routine-fleet',
                '--milestone', 'ms-factory-heal-via-state-machine', '--column', 'backlog', '--kind', 'pr', '--work-class', 'repair',
                '--difficulty', 'hard', '--priority', 'P1', '--tags', 'papercut,factory-repair',
                '--surfaces', ','.join(self.config['admitted'][0]['surfaces']), '--no-derive-surfaces', '--board-cli', str(self.kanban),
                '--create-only', '--json', '--factory-reviewed-decision']
        # The finite LastDB-only path must not inherit a retired backend from
        # the caller or a stale decision-check config.
        rc, out, err = bounded_call(argv, 120, env={**os.environ, 'BRAIN_BIN': self.brain}, stdin=brief)
        (self.capture / 'file.out').write_bytes(out); (self.capture / 'file.err').write_bytes(err)
        require(rc == 0, 'filing-attempt-unknown-retained')
        receipt = strict_json(out); validate_created_receipt(receipt, self.config)
        atomic_json(self.capture / 'filing-receipt.json', receipt)
        return receipt

    def creation_ready(self):
        return verify_creation_contract(self.root, self.config, self.kanban)

    def guarded(self, item, action):
        witness = validate_snapshot(item, COUNT_CARD); path = self.capture / ('witness-' + witness['sha256'] + '.json')
        path.write_bytes(witness['text'].encode())
        if action == 'surfaces':
            args = ['set', COUNT_CARD, '--surfaces', ','.join(self.config['admitted'][0]['surfaces'])]
        else:
            require(action == 'promote', 'unknown-admission-action')
            args = ['move', COUNT_CARD, 'todo', '--from', 'backlog']
        receipt = json_call([str(self.kanban), *args, '--guard-snapshot', str(path), '--snapshot-sha256', witness['sha256'],
                             '--expect-assignee', '', '--json'], 60)
        require(receipt.get('durability') == 'durable' and receipt.get('contract_sha256') == self.config['fkanban_authority']['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == witness['sha256'], 'admission-guarded-write-receipt')
        next_item = {'slug': COUNT_CARD, 'snapshot_json': receipt.get('next_snapshot_json'), 'snapshot_sha256': receipt.get('next_snapshot_sha256')}
        validate_snapshot(next_item, COUNT_CARD)
        require(self.card() == next_item, 'admission-canonical-readback')
        return next_item

    def finish(self, receipt, buckets, reason):
        atomic_json(self.capture / 'classification.json', {'version': 1, 'reason': reason, **buckets, 'finite_review': receipt.get('finite_review')})
        argv = [str(self.root / 'bin/last-stack-papercut-queue'), 'verify', '--snapshot', str(self.capture / 'queue.json'), '--json']
        for name, values in buckets.items():
            path = self.capture / (name + '.txt'); path.write_text(''.join(key + '\n' for key in values))
            argv.extend(['--' + name.replace('_', '-') + '-file', str(path)])
        rc, out, err = bounded_call(argv, 30)
        from factory_repair import strict_json
        verified = strict_json(out)
        require(verified.get('conserved') is True and verified.get('discovered') == receipt['discovered'], 'classification-proof-unavailable')
        atomic_json(self.capture / 'queue-proof.json', verified)
        return {'version': 1, 'result': 'error' if rc or buckets['failed'] else ('ok' if buckets['reconciled'] or buckets['already_handled'] else 'noop'),
                'reason': reason, 'capture': str(self.capture), 'classification': verified}
