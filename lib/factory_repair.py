"""Finite factory authority, exact witnesses, and bounded public effects.

The controller owns one reviewed Card. A failed read never replaces a retained
witness, source contract, install request, or execution identity.
"""
from __future__ import annotations

import concurrent.futures
import fcntl
import hashlib
import http.client
import json
import os
import re
import signal
import socket
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

MAX_BYTES = 16 * 1024 * 1024
MAX_KEYS = 8192
SLUG = re.compile(r'[a-z0-9][a-z0-9_-]{0,255}\Z')
HEX = re.compile(r'[0-9a-f]{64}\Z')
OID = re.compile(r'[0-9a-f]{40}\Z')
EXEC_ID = re.compile(r'lx-[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\Z')
RFC3339 = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\Z')
REQUIRED_KEYS = {
    'factory-scoped-dispatch-20261008', 'factory-guarded-closeout-20261008',
    'factory-canonical-active-counts-20261008', 'factory-repair-controller-20261009',
}
COUNT_CARD = 'factory-canonical-active-counts-20261008'
COUNT_PAPERCUT = 'papercut-loom-active-summary-counts-terminal-duplicate-memberships-20261008'
AUTHORITY = 'decision-2026-10-08-factory-repair-slot-and-bounded-proof'
DECISION_POLICY_PATH = Path(__file__).resolve().parents[1] / 'config/factory-reviewed-decision.json'
DECISION_POLICY_SHA = 'a06114ee93dda0abe23bf1703938ee529db0a6d47623e2376df8bc415ecb0a94'
CREATE_POLICY_SHA = '34881ecda9239902a6bab8671e93da0627e3381c235f87d66739236dc7f1c6ae'
ARRAYS = ('tags', 'deps', 'surfaces')
SCALARS = ('slug', 'title', 'body', 'board', 'column', 'position', 'assignee',
           'created_at', 'created_by', 'updated_at', 'db', 'repo', 'base', 'kind',
           'block_status', 'block_reason', 'north_star', 'milestone', 'pr_url', 'branch')
ACTIVE = {'initializing', 'running', 'waiting'}
FEATURES = {'exact_card_selector': '--only-card', 'canonical_resume_fence': True,
            'immutable_execution_input': True, 'factory_proof_handoff': 'execution-receipt-no-card-write',
            'park_policy': 'defer-without-card-write',
            'definition_policy': 'compiled-reviewed-version-without-latest-fallback',
            'worktree_policy': 'portal-dev-original-factory-branch',
            'execution_view_json': 'show ID --json',
            'reviewed_named_decision_receipt': {'version': 1, 'file_flag': '--reviewed-decision-receipt',
                'sha_flag': '--reviewed-decision-sha256', 'input_field': 'factory_decision_receipt',
                'max_bytes': 65536, 'max_snapshot_bytes': 65536, 'sha_encoding': 'utf8-exact-bytes',
                'record_encoding': 'utf8-sorted-compact-json-no-newline',
                'native_route': 'owner-uid-mode0600-uds-hash-range-keys', 'no_card_write': True,
                'claim_authority': 'supplied-raw23-snapshot-sha-before-decision-read',
                'policy_file': 'release/factory-reviewed-decision.json'}}
RUNTIME_REQUIRED = {
    'lib/forge-token.sh',
    'lib/factory_repair.py', 'lib/factory_bootstrap.py', 'lib/closeout_evidence.py', 'lib/sanitize_structured_fields.py',
    'bin/host-track', 'bin/last-stack-factory-repair-contract', 'bin/last-stack-factory-repair-controller',
    'bin/last-stack-factory-repair-kanban-adapter', 'bin/last-stack-factory-repair-proof',
    'bin/last-stack-factory-repair-routine', 'bin/last-stack-factory-bootstrap-closeout', 'bin/last-stack-kanban-show-batch',
    'bin/last-stack-papercut-reconcile-finite', 'bin/last-stack-papercut-lifecycle-close',
    'bin/last-stack-card-closeout', 'bin/last-stack-board-closeout-sweep',
    'bin/last-stack-card-closeout-merge-probe', 'bin/last-stack-kanban-done-when-eval',
    'bin/last-stack-lastdb-retry', 'lib/lastdb-retry-schedule.sh',
    'bin/last-stack-legacy-residue-probe', 'bin/last-stack-shell-prelude',
    'bin/last-stack-worktree-reclaim', 'bin/last-stack-brain-append-heartbeat',
    'bin/last-stack-github-artifact-pull', 'bin/last-stack-papercut-queue',
    'bin/last-stack-kanban-file-pr', 'bin/last-stack-kanban-decision-check',
    'bin/last-stack-closeout-index', 'lib/factory_reconcile.py', 'lib/host-track-install-lock.sh',
    'config/factory-canonical-active-counts.md', 'config/factory-reviewed-decision.json', 'config/factory-create-only-contract.json', 'config/factory-bootstrap-closeout.json', 'routines/factory-repair.md',
    'routines/papercut-reconciler.md', 'config/routines-registry/last-stack-factory-repair.toml',
}
DEADLINE = None


class Refusal(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def version1(value):
    return type(value) is int and value == 1


def kickoff_key(key, card):
    return isinstance(key, str) and re.fullmatch(r'card-' + re.escape(card) + r'-[0-9]{8}T[0-9]{6}Z', key) is not None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate-json-field')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def set_deadline(seconds=1050):
    global DEADLINE
    DEADLINE = time.monotonic() + seconds


def value_sha(value):
    return sha(encoded(value))


def compact_sha(value):
    return sha(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())


def regular_file(path, cap):
    fd = os.open(Path(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and 0 <= info.st_size <= cap, 'bounded-regular-file: ' + str(path))
        return os.fdopen(fd, 'rb')
    except BaseException:
        os.close(fd); raise


def read_bytes(path, cap=MAX_BYTES):
    with regular_file(path, cap) as stream:
        data = stream.read(cap + 1)
    require(len(data) <= cap, 'file-byte-limit: ' + str(path))
    require(DEADLINE is None or time.monotonic() < DEADLINE, 'phase-deadline')
    return data


def read_json(path):
    try:
        return strict_json(read_bytes(path))
    except (OSError, ValueError) as error:
        raise Refusal('invalid-json-file: ' + str(path)) from error


def file_sha(path):
    cap = 256 * 1024 * 1024; digest = hashlib.sha256(); total = 0
    with regular_file(path, cap) as stream:
        while block := stream.read(1024 * 1024):
            total += len(block); require(total <= cap, 'runtime-file-byte-limit')
            require(DEADLINE is None or time.monotonic() < DEADLINE, 'phase-deadline')
            digest.update(block)
    return digest.hexdigest()


def relative_file(root, relative):
    require(isinstance(relative, str) and 0 < len(relative) <= 512, 'invalid-relative-path')
    rel = Path(relative)
    require(not rel.is_absolute() and '..' not in rel.parts and '.' not in rel.parts, 'escaping-relative-path')
    path = root / rel
    require(path.resolve().is_relative_to(root.resolve()), 'escaping-file-symlink')
    return path


def validate_manifest(config):
    require(isinstance(config, dict) and version1(config.get('version')), 'manifest-version')
    keys = config.get('protected_card_keys')
    require(isinstance(keys, list) and 1 <= len(keys) <= 16 and all(isinstance(k, str) and SLUG.fullmatch(k) for k in keys), 'protected-keys-shape')
    require(len(keys) == len(set(keys)) and REQUIRED_KEYS.issubset(keys), 'protected-keys-incomplete')
    admitted = config.get('admitted')
    require(isinstance(admitted, list) and len(admitted) <= 1, 'finite-admission-shape')
    for entry in admitted:
        require(isinstance(entry, dict) and entry.get('card') == COUNT_CARD and entry.get('papercut') == COUNT_PAPERCUT,
                'unknown-finite-admission')
        require(entry.get('repo') == 'EdgeVector/loom' and entry.get('base') == 'main', 'admission-repo-base')
        require(entry.get('proof_action') == 'canonical-active-counts-v1', 'unknown-proof-action')
        require(HEX.fullmatch(entry.get('brief_sha256', '')), 'reviewed-brief-sha')
        require(set(entry.get('surfaces', [])) == {'src/runner.rs', 'src/storage.rs', 'release/factory-dispatch-contract.json'}, 'admission-surfaces')
    return config


def validate_admitted_body(body, entry):
    require(isinstance(body, str), 'reviewed-brief-body')
    raw = read_bytes(DECISION_POLICY_PATH, 65536); require(sha(raw) == DECISION_POLICY_SHA, 'reviewed-decision-policy-drift')
    policy = strict_json(raw); decision = policy['decision']
    require(version1(policy.get('version')) and policy.get('card') == entry['card'] == COUNT_CARD and policy.get('repo') == entry['repo'] and
            policy.get('base') == entry['base'] and policy.get('authority_slug') == AUTHORITY and policy.get('brief_sha256') == entry['brief_sha256'] and
            sha(decision['body'].encode()) == policy['decision_body_sha256'] and compact_sha(decision) == policy['decision_record_sha256'], 'reviewed-decision-policy-identity')
    require(body.count('\n## DECISION-CHECK\n') == 1 and body.count('## DECISION-CHECK') == 1, 'reviewed-decision-stamp-count')
    prefix, stamp = body.split('\n## DECISION-CHECK\n'); lines = stamp.splitlines()
    require(len(lines) == 5 and re.fullmatch(r'date: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', lines[0]) and
            lines[1:] == ['verdict: honor', 'slugs: ' + decision['slug'], 'store: brain', 'read: brain get ' + decision['slug']], 'reviewed-decision-clearance')
    require(sha(prefix.encode()) == entry['brief_sha256'], 'reviewed-brief-drift')
    receipt = {'version': 1, 'card': policy['card'], 'repo': policy['repo'], 'base': policy['base'], 'authority_slug': AUTHORITY,
        'brief_sha256': policy['brief_sha256'], 'card_body_sha256': sha(body.encode()),
        'decision_stamp': {'verdict': 'honor', 'store': 'brain', 'slugs': [decision['slug']]},
        'reads': [{'type': 'decision', 'schema_hash': policy['schema_hash'], **decision,
                   'body_sha256': policy['decision_body_sha256'], 'record_sha256': policy['decision_record_sha256'], 'constraints': policy['constraints']}]}
    receipt['receipt_sha256'] = compact_sha(receipt)
    return receipt


def validate_local(root):
    root = Path(root).resolve()
    path = root / 'config/factory-repair-contract.json'
    raw = read_bytes(path); contract = strict_json(raw)
    require(version1(contract.get('version')), 'runtime-contract-version')
    require(contract.get('manifest_path') == 'config/factory-repair-slot.json', 'manifest-path')
    config_path = relative_file(root, contract['manifest_path'])
    require(file_sha(config_path) == contract.get('manifest_sha256'), 'manifest-digest-mismatch')
    config = validate_manifest(read_json(config_path))
    files = contract.get('runtime_files')
    require(isinstance(files, list) and 1 <= len(files) <= 512, 'runtime-file-list')
    seen = set()
    for entry in files:
        require(isinstance(entry, dict) and isinstance(entry.get('sha256'), str) and HEX.fullmatch(entry['sha256']), 'runtime-file-entry')
        relative = entry.get('path')
        require(relative != 'config/factory-repair-contract.json' and relative not in seen, 'runtime-file-duplicate-or-self')
        seen.add(relative)
        require(file_sha(relative_file(root, relative)) == entry['sha256'], 'runtime-file-mismatch: ' + relative)
    require(RUNTIME_REQUIRED.issubset(seen), 'runtime-dependencies-incomplete')
    present = set()
    with os.scandir(root / 'bin') as entries:
        for index, entry in enumerate(entries):
            require(index < 512, 'runtime-bin-count-limit')
            require(entry.is_file(), 'runtime-bin-entry-shape')
            present.add('bin/' + entry.name)
    require(present == {rel for rel in seen if rel.startswith('bin/') and len(Path(rel).parts) == 2}, 'runtime-unbound-bin-file')
    return {'version': 1, 'result': 'ok', 'contract_sha256': sha(raw),
            'manifest_sha256': contract['manifest_sha256'], 'protected_card_keys': config['protected_card_keys']}


def validate_snapshot(item, slug):
    require(isinstance(item, dict) and item.get('slug') == slug and item.get('missing') is not True, 'snapshot-key')
    text = item.get('snapshot_json'); expected = item.get('snapshot_sha256')
    require(isinstance(text, str) and text.endswith('\n') and len(text.encode()) <= 1024 * 1024, 'snapshot-bytes')
    require(isinstance(expected, str) and HEX.fullmatch(expected) and sha(text.encode()) == expected, 'snapshot-byte-sha')
    value = strict_json(text)
    require(set(value) == {'version', 'schema_hash', 'fields'} and version1(value['version']) and
            isinstance(value['schema_hash'], str) and HEX.fullmatch(value['schema_hash']), 'snapshot-shape')
    fields = value['fields']
    require(isinstance(fields, dict) and set(fields) == set(SCALARS + ARRAYS), 'raw23-field-set')
    require(all(isinstance(fields[key], str) for key in SCALARS), 'raw23-scalar-type')
    require(all(isinstance(fields[key], list) and all(isinstance(v, str) for v in fields[key]) for key in ARRAYS), 'raw23-array-type')
    require(fields['slug'] == slug, 'raw23-canonical-key')
    return {'slug': slug, 'fields': fields, 'text': text, 'sha256': expected, 'schema_hash': value['schema_hash']}


def synthetic_claim_reason(owner):
    return 'claim recovery pending for worker "' + owner + '": do not work this card until the claim completes'


def validate_claim_stage_one(previous_item, item, owner):
    slug = previous_item['slug']; previous = validate_snapshot(previous_item, slug)['fields']; fields = validate_snapshot(item, slug)['fields']
    reason = synthetic_claim_reason(owner)
    require(previous['column'] == 'todo' and previous['assignee'] == '' and previous['block_status'] in ('', 'none') and previous['block_reason'] == '' or
            previous['column'] == 'doing' and previous['assignee'] == owner and previous['block_status'] == 'needs_human' and previous['block_reason'] == reason,
            'claim-stage-one-original-state')
    expected_tags = [v for v in previous['tags'] if not v.startswith(('done_at:', 'first_doing_at:'))]
    first = next((v[len('first_doing_at:'):] for v in previous['tags'] if v.startswith('first_doing_at:')), '')
    expected_tags.append('first_doing_at:' + (first or fields['updated_at']))
    require(fields['column'] == 'doing' and fields['assignee'] == owner and fields['block_status'] == 'needs_human' and fields['block_reason'] == reason and
            re.fullmatch(r'[0-9]{1,20}', fields['position']) and fields['tags'] == expected_tags and
            re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z', fields['updated_at']) and
            all(fields[k] == previous[k] for k in previous if k not in ('assignee', 'column', 'position', 'tags', 'block_status', 'block_reason', 'updated_at')),
            'claim-stage-one-field-drift')
    return fields


def validate_card_batch(reply, keys):
    require(isinstance(reply, dict) and version1(reply.get('version')) and isinstance(reply.get('schema_hash'), str) and HEX.fullmatch(reply['schema_hash']), 'card-batch-shape')
    items = reply.get('items')
    require(isinstance(items, list) and len(items) == len(keys), 'card-batch-incomplete')
    for key, item in zip(keys, items):
        require(isinstance(item, dict) and item.get('slug') == key, 'card-batch-order-or-key')
        if item.get('missing') is True:
            require(set(item) == {'slug', 'missing'}, 'missing-item-shape')
        else:
            snapshot = validate_snapshot(item, key)
            require(snapshot['schema_hash'] == reply['schema_hash'], 'card-batch-schema-drift')
    return items


def bounded_call(argv, timeout=30, env=None, cap=MAX_BYTES, stdin=None):
    """Bound bytes, wall time and the generated client's process group."""
    require(0 < timeout <= 900, 'invalid-call-deadline')
    if DEADLINE is not None:
        timeout = min(timeout, DEADLINE - time.monotonic())
        require(timeout > 0, 'phase-deadline')
    require(stdin is None or isinstance(stdin, bytes) and len(stdin) <= 1024 * 1024, 'command-stdin-limit')
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err, tempfile.TemporaryFile() as inp:
        if stdin is not None:
            inp.write(stdin); inp.seek(0)
        proc = subprocess.Popen(argv, stdout=out, stderr=err, stdin=inp if stdin is not None else subprocess.DEVNULL,
                                env=env, start_new_session=True, close_fds=True)
        end = time.monotonic() + timeout
        try:
            while proc.poll() is None:
                if time.monotonic() >= end or os.fstat(out.fileno()).st_size > cap or os.fstat(err.fileno()).st_size > cap:
                    raise Refusal('bounded-command-timeout-or-bytes')
                time.sleep(0.02)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=2)
        out.seek(0); err.seek(0)
        stdout = out.read(cap + 1); stderr = err.read(cap + 1)
        require(len(stdout) <= cap and len(stderr) <= cap, 'command-byte-limit')
        return proc.returncode, stdout, stderr


def json_call(argv, timeout=30, env=None, cap=MAX_BYTES):
    rc, out, err = bounded_call(argv, timeout, env, cap)
    require(rc == 0, 'public-command-refused: ' + Path(argv[0]).name)
    try:
        return strict_json(out)
    except ValueError as error:
        raise Refusal('public-command-malformed-json') from error


def public_card_batch(binary, keys, chunk=256):
    require(0 < chunk <= 256 and len(keys) <= MAX_KEYS and len(keys) == len(set(keys)), 'card-key-limit-or-duplicates')
    require(all(isinstance(k, str) and SLUG.fullmatch(k) for k in keys), 'invalid-card-key')
    parts = [keys[i:i + chunk] for i in range(0, len(keys), chunk)]
    def fetch(part):
        with tempfile.TemporaryDirectory(prefix='last-stack-card-keys-') as name:
            path = Path(name) / 'keys.json'; path.write_bytes(encoded(part))
            reply = json_call([str(binary), 'guarded-snapshot', '--slugs-file', str(path), '--json'], 30, cap=8 * 1024 * 1024)
            return reply['schema_hash'], validate_card_batch(reply, part)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        replies = list(pool.map(fetch, parts))
    schemas = {reply[0] for reply in replies}
    require(len(schemas) <= 1, 'card-batch-schema-change')
    return {'version': 1, 'schema_hash': next(iter(schemas), ''),
            'items': [item for _, items in replies for item in items]}


def atomic_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encoded(value)); stream.flush(); os.fsync(stream.fileno())
    os.replace(name, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def artifact_root(authority):
    path = Path(authority['root']).expanduser().resolve()
    require(path.is_dir() and path.name == authority['manifest_sha256'], 'artifact-root-identity')
    return path


def verify_artifact(authority, current=False):
    root = artifact_root(authority)
    manifest_path = Path(authority['manifest_path']).expanduser()
    require(file_sha(manifest_path) == authority['manifest_file_sha256'], 'official-manifest-bytes-changed')
    manifest = read_json(manifest_path)
    require(manifest.get('manifest_digest') == authority['manifest_sha256'] and manifest.get('source_oid') == authority['source_oid'] and
            manifest.get('app') == authority['app'], 'official-artifact-identity')
    files = manifest.get('files')
    require(isinstance(files, list) and 1 <= len(files) <= 1024, 'official-artifact-files')
    seen = set()
    for item in files:
        rel = item.get('path'); require(rel not in seen, 'official-artifact-duplicate-file'); seen.add(rel)
        file = relative_file(root, rel)
        require(file.is_file() and file.stat().st_size == item.get('size') and file_sha(file) == item.get('sha256'), 'official-artifact-file-mismatch: ' + str(rel))
    if current:
        require(Path(authority['current']).expanduser().resolve() == root, 'installed-current-drift')
    return root


def verify_fk(authority, current=True):
    root = verify_artifact(authority, current)
    receipt = read_json(root / 'dist/guarded-contract.json')
    require(receipt.get('source_commit') == authority['source_oid'] and receipt.get('contract_sha256') == authority['contract_sha256'], 'fkanban-contract-identity')
    require(receipt.get('cli_sha256') == file_sha(root / 'dist/kanban') and receipt.get('mcp_sha256') == file_sha(root / 'dist/kanban-mcp'), 'fkanban-build-receipt')
    contract = receipt.get('contract', {})
    require(version1(contract.get('version')) and contract.get('snapshot_batch_shape') == 'ordered-items-with-explicit-missing' and
            contract.get('max_snapshot_keys') == 256 and contract.get('durability') == 'durable' and
            set(contract.get('card_fields', [])) == set(SCALARS + ARRAYS), 'fkanban-contract-capabilities')
    return root / 'dist/kanban'


def verify_loom(authority, current=True):
    root = verify_artifact(authority, current)
    path = root / 'release/factory-dispatch-contract.json'; contract = read_json(path)
    require(file_sha(path) == authority['contract_sha256'] and contract.get('features') == FEATURES and contract.get('definition_version') == '5' and
            isinstance(contract.get('cli_source_sha256'), str) and HEX.fullmatch(contract['cli_source_sha256']) and
            contract.get('files', {}).get('release/factory-reviewed-decision.json') == DECISION_POLICY_SHA, 'loom-contract-identity')
    for rel, expected in contract.get('files', {}).items():
        require(file_sha(relative_file(root, rel)) == expected, 'loom-contract-file: ' + rel)
    build = read_json(root / 'release/factory-dispatch-build.json')
    require(build.get('contract_sha256') == authority['contract_sha256'] and build.get('runner_sha256') == file_sha(root / 'dist/loom'), 'loom-runner-binding')
    return root

def verify_creation_contract(root, config, binary):
    authority = config.get('creation_authority', {})
    require(authority.get('configured') is True, 'public-create-only-capability-unavailable')
    policy_path = Path(root) / 'config/factory-create-only-contract.json'
    require(file_sha(policy_path) == CREATE_POLICY_SHA, 'creation-policy-bytes')
    policy = read_json(policy_path)
    require(authority.get('contract_sha256') == policy.get('contract_sha256') and
            authority.get('card_guarded_contract_sha256') == config['fkanban_authority']['contract_sha256'], 'creation-config-contract-binding')
    current = json_call([str(binary), 'create-only-contract', '--json'], 30, cap=65536)
    require(isinstance(current, dict) and version1(current.get('version')) and current == policy and
            all(type(current.get(key)) is int for key in ('max_board_destinations', 'max_batch_operations', 'retries')) and
            current.get('force') is False and current.get('existing_board_required') is True and current.get('exact_card_schema_fields') is True,
            'creation-public-contract-binding')
    return authority

def validate_created_receipt(receipt, config):
    authority = config['creation_authority']
    require(isinstance(receipt, dict) and receipt.get('slug') == COUNT_CARD and receipt.get('action') == 'created' and
            receipt.get('board') == 'default' and receipt.get('column') == 'backlog' and receipt.get('durability') == 'durable' and
            receipt.get('contract_sha256') == authority['contract_sha256'] and
            receipt.get('card_guarded_contract_sha256') == config['fkanban_authority']['contract_sha256'] == authority['card_guarded_contract_sha256'] and
            receipt.get('absence_guard') == 'all23-absent' and receipt.get('membership_cleanup') == 'deferred', 'create-only-durable-receipt')
    item = {'slug': COUNT_CARD, 'snapshot_json': receipt.get('next_snapshot_json'), 'snapshot_sha256': receipt.get('next_snapshot_sha256')}
    fields = validate_snapshot(item, COUNT_CARD)['fields']
    require(fields['board'] == 'default' and fields['column'] == 'backlog' and fields['assignee'] == '' and
            fields['block_status'] in ('', 'none') and fields['block_reason'] == '' and fields['pr_url'] == '' and fields['branch'] == '', 'created-card-state')
    return item


def validate_execution(view, state):
    require(isinstance(view, dict) and view.get('id') == state['execution_id'] and view.get('idempotency_key') == state['key'], 'execution-identity')
    require(view.get('definition_name') == 'land-card' and view.get('definition_version') == '0000000005' and
            view.get('original_input') == state['original_input'], 'execution-original-input')
    original = state['original_input']; context = view.get('context')
    require(isinstance(context, dict) and original.get('factory_repair') is True, 'immutable-factory-mode')
    for key in ('factory_repair', 'factory_card', 'card', 'claim_worker', 'repo', 'base', 'factory_decision_receipt'):
        require(key in original and context.get(key) == original[key], 'execution-context-drift: ' + key)
    require(original['factory_decision_receipt'] == state['intent']['factory_decision_receipt'], 'execution-reviewed-decision-receipt')
    require(original['card'] == original['factory_card'] == state['card'] and original['claim_worker'] == state['owner'] and
            original['repo'] == state['repo'] and original['base'] == state['base'], 'execution-scope')
    require(view.get('corrected_reads', 0) == 0, 'canonical-read-below-accepted-ledger')
    return view


def accepted_handoff(view, state):
    validate_execution(view, state)
    require(view.get('status') == 'succeeded' and view.get('state') == 'DONE', 'execution-not-completed')
    nodes = [n for n in view.get('nodes', []) if n.get('node_id') == 'CLOSE_CARD']
    require(nodes, 'accepted-close-attempt-absent')
    latest = max(nodes, key=lambda n: n.get('attempt', -1))
    require(latest.get('status') == 'succeeded' and latest.get('pending_effect') is None, 'close-attempt-not-accepted')
    result = latest.get('result')
    require(isinstance(result, dict) and result.get('column') == 'factory-proof-handoff', 'close-handoff-result')
    handoff = result.get('handoff')
    require(isinstance(handoff, dict) and version1(handoff.get('contract')) and handoff.get('status') == 'awaiting-factory-proof' and
            handoff.get('no_card_write') is True and handoff.get('card_column') == 'doing', 'close-handoff-shape')
    for source, target in (('card', 'card'), ('owner', 'claim_worker'), ('repo', 'repo'), ('execution_id', 'execution_id'), ('key', 'idempotency_key')):
        require(handoff.get(target) == state[source], 'close-handoff-identity: ' + target)
    require(re.fullmatch(r'https://github.com/EdgeVector/loom/pull/[1-9][0-9]*', handoff.get('pr_url', '')), 'close-handoff-pr')
    return handoff


def compare_count(status, rows):
    require(isinstance(status, dict) and isinstance(status.get('executions'), list), 'status-result-shape')
    executions = status['executions']; keys = [r.get('id') for r in executions]
    require(len(keys) == len(set(keys)) and len(keys) <= MAX_KEYS, 'duplicate-active-execution')
    require(all(r.get('status') in ACTIVE for r in executions), 'terminal-or-parked-counted-active')
    canonical = {r.get('id'): r for r in rows}
    require(len(canonical) == len(rows) and set(keys).issubset(canonical), 'canonical-count-key-error')
    expected = [r for r in rows if r.get('status') in ACTIVE]
    require(set(keys) == {r['id'] for r in expected}, 'active-canonical-membership-mismatch')
    for row in executions:
        actual = canonical[row['id']]
        require(all(row.get(k) == actual.get(k) for k in ('status', 'state', 'updated_at', 'definition_name')), 'status-canonical-value-mismatch')
    by_status = {}; by_definition = {}
    for row in expected:
        by_status[row['status']] = by_status.get(row['status'], 0) + 1
        name = row['definition_name']; by_definition[name] = by_definition.get(name, 0) + 1
    require(type(status.get('total')) is int and status['total'] == len(expected) and status.get('by_status') == by_status and
            status.get('by_definition') == by_definition and all(type(value) is int for values in (status['by_status'], status['by_definition'])
            for value in values.values()), 'active-summary-count-mismatch')
    return {'total': len(expected), 'by_status': by_status, 'by_definition': by_definition,
            'candidate_source_limit': 'active IDs absent from all three named active status hashes are outside this read'}


class OwnerHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=20); self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); self.sock.settimeout(self.timeout); self.sock.connect(self.path)


def owner_query_page(socket_path, schema, filter_value, fields, limit, offset=0):
    path = Path(socket_path).expanduser()
    info = path.stat()
    require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600, 'owner-socket-identity')
    require(HEX.fullmatch(schema) and 0 < limit <= 1000, 'native-query-bounds')
    connection = OwnerHTTP(str(path))
    remaining = 20 if DEADLINE is None else min(20, DEADLINE - time.monotonic())
    require(remaining > 0, 'phase-deadline')
    connection.timeout = remaining
    connection.connect()
    # HTTPConnection can detach connection.sock when a response closes the
    # connection. Retain the actual wire through the bounded response drain.
    wire = connection.sock
    def expire():
        try:
            wire.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    timer = threading.Timer(remaining, expire); timer.daemon = True; timer.start()
    response = None
    try:
        body = encoded({'schema_name': schema, 'filter': filter_value, 'fields': fields, 'limit': limit, 'offset': offset})
        connection.request('POST', '/api/query', body, {'Content-Type': 'application/json', 'X-LastDB-Client': 'last-stack-factory-proof'})
        response = connection.getresponse(); data = response.read(8 * 1024 * 1024 + 1)
        if DEADLINE is not None: require(time.monotonic() < DEADLINE, 'phase-deadline')
        require(response.status == 200 and len(data) <= 8 * 1024 * 1024, 'native-query-response')
        value = strict_json(data)
    finally:
        timer.cancel()
        if response is not None: response.close()
        connection.close(); wire.close()
    require(isinstance(value, dict) and value.get('ok') is True and isinstance(value.get('has_more'), bool) and isinstance(value.get('results'), list), 'native-query-incomplete')
    validate_native_metadata(value, 'native-query')
    require(value.get('next_cursor') is None, 'native-query-unexpected-cursor')
    require('returned_count' not in value or type(value['returned_count']) is int and value['returned_count'] == len(value['results']), 'native-query-returned-count')
    require(value.get('total_count') is None or type(value['total_count']) is int and value['total_count'] == len(value['results']), 'native-query-total-count')
    return value


def validate_native_metadata(value, scope, row=False):
    require(not value.get('error') and not value.get('errors'), scope + '-item-error')
    for key, count in value.items():
        if key == 'truncated':
            require(type(count) is bool and count is False, scope + '-truncated')
        elif re.search(r'skip|dangling|missing_atom|unresolved|failed|tombstoned', key, re.I):
            if row and key in ('skipped', 'dangling', 'missing_atom', 'unresolved', 'failed', 'tombstoned'):
                require(type(count) is bool and count is False, scope + '-record-flag: ' + key)
            else:
                require(type(count) is int and count == 0, scope + '-incomplete-counter: ' + key)


def require_lifecycle_intent_clear(directory, config_sha256, contract_sha256):
    path = Path(directory) / 'lifecycle-close-intent.json'
    if path.exists():
        intent = read_json(path)
        require(version1(intent.get('version')) and intent.get('config_sha256') == config_sha256 and
                intent.get('contract_sha256') == contract_sha256 and intent.get('status') == 'complete' and
                isinstance(intent.get('result_sha256'), str) and HEX.fullmatch(intent['result_sha256']),
                'lifecycle-close-unknown-retained')


def owner_query(socket_path, schema, filter_value, fields, limit):
    value = owner_query_page(socket_path, schema, filter_value, fields, limit)
    require(value['has_more'] is False, 'native-keyed-query-truncated')
    return value['results']


def native_execution_rows(reply, keys):
    require(isinstance(reply, list) and len(reply) == len(keys), 'native-canonical-missing')
    wanted = set(keys); seen = set(); records = []
    for row in reply:
        require(isinstance(row, dict) and isinstance(row.get('key'), dict) and isinstance(row.get('fields'), dict), 'native-row-shape')
        validate_native_metadata(row, 'native-row', row=True)
        key = row['key']; fields = row['fields']; ident = key.get('hash')
        require(ident in wanted and ident not in seen and 'range' in key and key['range'] is None, 'native-row-foreign-duplicate-or-range')
        seen.add(ident)
        require(fields.get('id') == ident and all(isinstance(fields.get(k), str) and fields[k] for k in
                ('id', 'status', 'state', 'updated_at', 'definition_name')), 'native-canonical-field-shape')
        require(fields['status'] in ACTIVE | {'parked', 'succeeded', 'failed', 'cancelled'}, 'native-canonical-status')
        records.append(fields)
    require(seen == wanted, 'native-canonical-unresolved')
    return records


def status_membership_id(row, status_name):
    require(isinstance(row, dict) and isinstance(row.get('key'), dict) and
            row['key'].get('hash') == status_name and isinstance(row.get('fields'), dict),
            'native-membership-row-shape-or-hash')
    validate_native_metadata(row, 'native-membership', row=True)
    fields = row['fields']; ident = fields.get('id'); definition = fields.get('definition_name')
    sort = fields.get('by_status_sort')
    require(isinstance(ident, str) and EXEC_ID.fullmatch(ident), 'native-membership-id')
    require(isinstance(definition, str) and definition and isinstance(sort, str) and
            row['key'].get('range') == sort, 'native-membership-key')
    # Loom encodes created_at only in this range, not as a status-schema field.
    parts = sort.rsplit('#', 2)
    require(len(parts) == 3 and parts[0] == definition and parts[2] == ident,
            'native-membership-composite-key')
    created = parts[1]
    require(RFC3339.fullmatch(created), 'native-membership-created-at-format')
    try:
        datetime.fromisoformat(created.replace('Z', '+00:00'))
    except ValueError as error:
        raise Refusal('native-membership-created-at-value') from error
    return ident


def active_candidate_keys(config):
    hashes = read_json(Path(config['schema_map']).expanduser())
    require(hashes.get('LoomExecution') == config['loom_schemas']['LoomExecution'] and
            hashes.get('LoomExecutionByStatus') == config['loom_schemas']['LoomExecutionByStatus'], 'loom-schema-map-drift')
    def one(status_name):
        out = []; offset = 0
        for page in range(16):
            reply = owner_query_page(config['owner_socket'], hashes['LoomExecutionByStatus'], {'HashKey': status_name}, ['id', 'definition_name', 'by_status_sort'], 1000, offset)
            rows = reply['results']
            require(len(rows) <= 1000 and (rows or not reply['has_more']), 'native-membership-page')
            for row in rows:
                out.append(status_membership_id(row, status_name))
            if not reply['has_more']:
                return out
            offset += len(rows)
        raise Refusal('native-membership-page-limit')
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        result = list(pool.map(one, sorted(ACTIVE)))
    keys = sorted(set(k for part in result for k in part))
    require(len(keys) <= MAX_KEYS, 'native-candidate-key-limit')
    return keys


def canonical_execution_batch(config, keys):
    require(len(keys) <= MAX_KEYS and len(keys) == len(set(keys)), 'native-execution-key-limit')
    fields = ['id', 'definition_name', 'status', 'state', 'updated_at']
    def one(part):
        rows = owner_query(config['owner_socket'], config['loom_schemas']['LoomExecution'],
                           {'HashRangeKeys': [[k, ''] for k in part]}, fields, len(part))
        return native_execution_rows(rows, part)
    parts = [keys[i:i + 512] for i in range(0, len(keys), 512)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(one, parts))
    return [row for part in rows for row in part]


class Controller:
    """One durable phase per wake; error leaves the retained phase and slot."""
    def __init__(self, config, state_dir, effects, contract_sha256):
        self.config = validate_manifest(config); self.directory = Path(state_dir)
        self.effects = effects; self.contract_sha256 = contract_sha256
        require(config.get('authority_slug') == AUTHORITY and len(config['admitted']) == 1, 'finite-authority')
        self.entry = config['admitted'][0]; self.config_sha256 = value_sha(config)

    def ensure_card(self, state, done=False, retained=False):
        require(not retained or done and state['phase'] == 'completed', 'retained-reader-terminal-only')
        current = self.effects.completed_card() if retained and hasattr(self.effects, 'completed_card') else self.effects.card()
        snapshot = validate_snapshot(current, state['card'])
        require(current['snapshot_sha256'] == state['witness']['snapshot_sha256'], 'retained-witness-changed')
        fields = snapshot['fields']
        require(fields['repo'] == state['repo'] and fields['base'] == state['base'] and
                set(fields['surfaces']) == set(self.entry['surfaces']), 'canonical-card-scope')
        if state['phase'] == 'claim-recovery-pending':
            require(fields['column'] == 'doing' and fields['assignee'] == state['owner'] and state.get('accepted_held'), 'accepted-held-canonical-owner')
            validate_claim_stage_one(state['original_witness'], current, state['owner'])
            return fields
        require(fields['block_status'] in ('', 'none') and fields['block_reason'] == '', 'canonical-human-hold')
        if done:
            require(fields['column'] == 'done' and fields['assignee'] == state['owner'], 'final-canonical-done')
        elif state['phase'] == 'reserved' or (state['phase'] == 'dispatch-pending' and not state.get('claim_receipt')):
            require(fields['column'] == 'todo' and fields['assignee'] == '', 'exact-card-not-ready')
        else:
            require(fields['column'] == 'doing' and fields['assignee'] == state['owner'], 'canonical-original-owner')
        return fields

    def save(self, state):
        atomic_json(self.directory / 'slot.json', state)

    def validate_state(self, state):
        require(version1(state.get('version')) and state.get('config_sha256') == self.config_sha256 and
                state.get('contract_sha256') == self.contract_sha256, 'slot-config-contract-drift')
        require(state.get('card') == self.entry['card'] and state.get('owner') == 'loom:factory-repair-slot' and
                state.get('repo') == self.entry['repo'] and state.get('base') == self.entry['base'], 'slot-identity')
        require(state.get('dispatch_authority') == self.config['dispatch_authority'] and
                state.get('fkanban_authority') == self.config['fkanban_authority'], 'slot-retained-authority')
        require(value_sha(state.get('intent')) == state.get('intent_sha256'), 'slot-intent-digest')
        require(validate_snapshot(state['original_witness'], state['card'])['sha256'] == state['intent']['witness_sha256'], 'slot-original-witness')
        decision = validate_admitted_body(validate_snapshot(state['original_witness'], state['card'])['fields']['body'], self.entry)
        require(state['intent'].get('factory_decision_receipt') == decision and
                strict_json(state['intent']['decision_receipt_json']) == decision and
                sha(state['intent']['decision_receipt_json'].encode()) == state['intent']['decision_receipt_sha256'], 'slot-retained-decision-receipt')
        require(all(state['intent'].get(k) == state[k] for k in ('card', 'owner', 'repo', 'base', 'config_sha256', 'contract_sha256')),
                'slot-intent-scope')

    def accept_write(self, state, receipt):
        require(isinstance(receipt, dict) and receipt.get('durability') == 'durable' and
                receipt.get('contract_sha256') == self.config['fkanban_authority']['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'guarded-write-not-durable')
        next_item = {'slug': state['card'], 'snapshot_json': receipt.get('next_snapshot_json'),
                     'snapshot_sha256': receipt.get('next_snapshot_sha256')}
        validate_snapshot(next_item, state['card'])
        state['witness'] = next_item
        state.setdefault('write_receipts', []).append(receipt)

    def validate_proof(self, state):
        proof = state.get('proof', {})
        require(version1(proof.get('version')) and proof.get('result') == 'positive' and proof.get('signal'), 'positive-proof-required')
        require(proof.get('signal') == value_sha({k: v for k, v in proof.items() if k != 'signal'}), 'proof-signal-digest')
        require(proof.get('intent_sha256') == state['intent_sha256'] and proof.get('card') == state['card'] and
                proof.get('execution_id') == state['execution_id'] and proof.get('action_attempt') == state['proof_attempt'] and
                proof.get('candidate_sha256') == value_sha(state['candidate']) and
                all(proof.get('candidate_' + k) == state['candidate'][k] for k in ('source_oid', 'contract_sha256', 'manifest_sha256')), 'proof-attempt-identity')

    def validate_install(self, state, receipt):
        self.validate_candidate(state)
        candidate = state['candidate']; requested = receipt.get('requested', {})
        require(version1(receipt.get('version')) and requested == {'app': 'loom', 'channel': 'candidate',
                'source_oid': candidate['source_oid'], 'manifest_sha256': candidate['manifest_sha256']}, 'install-request-drift')
        official = receipt.get('official', {})
        expected_official = {
            'repo': state['repo'], 'channel': 'candidate', 'platform': candidate['official']['platform'],
            'source_oid': candidate['source_oid'], 'tree_oid': candidate['tree_oid'],
            'manifest_sha256': candidate['manifest_sha256'], 'run_id': candidate['official']['run_id'],
            'artifact_id': candidate['official']['artifact_id']}
        require(isinstance(official, dict) and official == expected_official and
            all(type(official.get(k)) is int and official[k] > 0 for k in ('run_id', 'artifact_id')), 'install-official-drift')
        soak = receipt.get('soak', {})
        require(isinstance(soak, dict) and type(soak.get('required')) is bool, 'install-soak-shape')
        if receipt.get('result') == 'pending':
            require(receipt.get('exact_match') is False and receipt.get('installed') is None and
                    soak == {'required': True, 'status': 'pending'}, 'install-pending-shape')
            return False
        require(receipt.get('result') == 'installed' and receipt.get('exact_match') is True, 'exact-install-not-complete')
        require(soak.get('status') == 'complete', 'install-soak-not-complete')
        installed = receipt.get('installed', {})
        expected_files = [{k: row[k] for k in ('path', 'sha256')} for row in strict_json(candidate['manifest_json'])['files']]
        require(isinstance(installed, dict) and installed.get('source_oid') == candidate['source_oid'] and
                installed.get('tree_oid') == candidate['tree_oid'] and installed.get('manifest_sha256') == candidate['manifest_sha256'] and
                installed.get('resolved_root') == str(Path(candidate['authority']['root']).expanduser()) and
                installed.get('files') == expected_files, 'installed-source-tree-files-drift')
        return True

    def validate_candidate(self, state):
        candidate = state['candidate']
        require(candidate.get('intent_sha256') == state['intent_sha256'] and
                candidate.get('dispatch_authority_sha256') == value_sha(state['dispatch_authority']) and
                candidate.get('completed_execution_sha256') == state['completed_execution_sha256'] and
                candidate.get('pr_url') == state['handoff']['pr_url'], 'candidate-dispatch-chain')
        require(OID.fullmatch(candidate.get('source_oid', '')) and OID.fullmatch(candidate.get('tree_oid', '')) and
                HEX.fullmatch(candidate.get('manifest_sha256', '')) and HEX.fullmatch(candidate.get('contract_sha256', '')), 'candidate-exact-identity')
        pr = candidate.get('merge_receipt', {})
        require(isinstance(pr, dict) and pr.get('url') == state['handoff']['pr_url'] and pr.get('state') == 'MERGED' and
                isinstance(pr.get('mergedAt'), str) and pr['mergedAt'] and pr.get('baseRefName') == state['base'] and
                pr.get('headRefName') == 'factory/' + state['execution_id'] + '#IMPLEMENT' and
                pr.get('mergeCommit', {}).get('oid') == candidate['source_oid'], 'candidate-merged-pr-binding')
        require(isinstance(pr.get('body'), str) and re.search(r'(?m)^Papercut:[ \t]*' + re.escape(COUNT_PAPERCUT) + r'[ \t]*$', pr['body']) and
                re.search(r'(?m)^Keep-open:[ \t]*papercut-loom-execution-status-backlog-sweep-pending-20260928[ \t]*$', pr['body']), 'candidate-labeled-claims')
        official = candidate.get('official', {})
        require(isinstance(official, dict) and official.get('status') in ('promoted', 'verified') and
                official.get('oid') == candidate['source_oid'] and official.get('tree_oid') == candidate['tree_oid'] and
                official.get('manifest_digest') == candidate['manifest_sha256'] and official.get('channel') == 'candidate' and
                isinstance(official.get('platform'), str) and re.fullmatch(r'[a-z0-9_-]{1,64}', official['platform']) and
                all(type(official.get(k)) is int and official[k] > 0 for k in ('run_id', 'artifact_id')), 'candidate-official-publish-binding')
        raw = candidate.get('source_contract_json'); baseline_raw = candidate.get('baseline_contract_json'); manifest_raw = candidate.get('manifest_json')
        require(all(isinstance(text, str) and len(text.encode()) <= MAX_BYTES for text in (raw, baseline_raw, manifest_raw)) and
                sha(raw.encode()) == candidate['contract_sha256'] and
                sha(baseline_raw.encode()) == state['dispatch_authority']['contract_sha256'], 'candidate-retained-contract-bytes')
        reviewed = strict_json(raw); baseline = strict_json(baseline_raw); manifest = strict_json(manifest_raw)
        require(isinstance(reviewed, dict) and isinstance(baseline, dict) and version1(reviewed.get('contract')) and
                HEX.fullmatch(reviewed.get('runner_source_sha256', '')) and
                reviewed['runner_source_sha256'] != baseline.get('runner_source_sha256') and
                reviewed == {**baseline, 'runner_source_sha256': reviewed['runner_source_sha256']}, 'candidate-retained-dispatch-contract')
        require(isinstance(manifest, dict) and manifest.get('source_oid') == candidate['source_oid'] and
                manifest.get('app') == 'loom' and manifest.get('manifest_digest') == candidate['manifest_sha256'], 'candidate-manifest-source-binding')
        files = manifest.get('files'); require(isinstance(files, list) and 1 <= len(files) <= 1024, 'candidate-manifest-files')
        indexed = {}
        for row in files:
            require(isinstance(row, dict) and isinstance(row.get('path'), str) and row['path'] not in indexed and
                    not Path(row['path']).is_absolute() and '..' not in Path(row['path']).parts and
                    isinstance(row.get('sha256'), str) and HEX.fullmatch(row['sha256']) and
                    type(row.get('size')) is int and row['size'] >= 0, 'candidate-manifest-file-shape')
            indexed[row['path']] = row
        require(indexed.get('release/factory-dispatch-contract.json', {}).get('sha256') == candidate['contract_sha256'] and
                all(indexed.get(rel, {}).get('sha256') == expected for rel, expected in reviewed['files'].items()), 'candidate-manifest-contract-files')
        expected_authority = {'app': 'loom', 'source_oid': candidate['source_oid'], 'manifest_sha256': candidate['manifest_sha256'],
            'manifest_file_sha256': sha(manifest_raw.encode()), 'contract_sha256': candidate['contract_sha256'],
            'root': str(Path.home() / '.host-track/apps/loom/versions' / candidate['manifest_sha256']),
            'current': str(Path.home() / '.host-track/apps/loom/current'),
            'manifest_path': str(Path.home() / '.lastgit/artifacts/manifests' / (candidate['manifest_sha256'] + '.json'))}
        require(candidate.get('authority') == expected_authority, 'candidate-authority-path-binding')

    def completion(self, state):
        result = {k: state[k] for k in ('intent_sha256', 'config_sha256', 'contract_sha256', 'card', 'owner', 'execution_id', 'key', 'proof_attempt')}
        result.update(candidate_sha256=value_sha(state['candidate']), proof_sha256=value_sha(state['proof']),
                      install_sha256=value_sha(state['install']), close_sha256=value_sha(state['close_receipt']),
                      final_snapshot_sha256=state['witness']['snapshot_sha256'],
                      original_input_sha256=value_sha(state['original_input']),
                      handoff_sha256=value_sha(state['handoff']), completed_execution_sha256=state['completed_execution_sha256'])
        return result

    def once(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'slot.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {'version': 1, 'result': 'noop', 'reason': 'shared-slot-busy'}
            path = self.directory / 'slot.json'
            if not path.exists():
                require_lifecycle_intent_clear(self.directory, self.config_sha256, self.contract_sha256)
                self.effects.check_authority()
                self.effects.bootstrap_ready()
                witness = self.effects.card(); value = validate_snapshot(witness, self.entry['card'])['fields']
                require(value['column'] == 'todo' and value['assignee'] == '' and value['block_status'] in ('', 'none') and
                        value['block_reason'] == '' and value['repo'] == self.entry['repo'] and value['base'] == self.entry['base'] and
                        set(value['surfaces']) == set(self.entry['surfaces']), 'finite-card-not-ready')
                decision = validate_admitted_body(value['body'], self.entry); decision_json = encoded(decision).decode()
                intent = {'card': self.entry['card'], 'owner': 'loom:factory-repair-slot', 'repo': self.entry['repo'],
                          'base': self.entry['base'], 'config_sha256': self.config_sha256,
                          'contract_sha256': self.contract_sha256, 'witness_sha256': witness['snapshot_sha256'],
                          'attempt': uuid.uuid4().hex, 'factory_decision_receipt': decision,
                          'decision_receipt_json': decision_json, 'decision_receipt_sha256': sha(decision_json.encode())}
                state = {'version': 1, 'phase': 'reserved', **{k: intent[k] for k in ('card', 'owner', 'repo', 'base', 'config_sha256', 'contract_sha256')},
                         'intent': intent, 'intent_sha256': value_sha(intent), 'witness': witness, 'original_witness': witness,
                         'dispatch_authority': self.config['dispatch_authority'], 'fkanban_authority': self.config['fkanban_authority']}
                self.save(state)
                return {'version': 1, 'result': 'ok', 'phase': 'reserved', 'card': state['card']}
            state = read_json(path); self.validate_state(state)
            phase = state['phase']
            if phase == 'completed':
                self.validate_proof(state)
                require(self.validate_install(state, state['install']), 'completion-install-pending')
                require(state.get('close_receipt', {}).get('durability') == 'durable' and
                        state.get('final_snapshot_sha256') == state['witness']['snapshot_sha256'] and
                        state.get('completion') == self.completion(state) and
                        state.get('completion_sha256') == value_sha(state['completion']), 'completion-receipt-invalid')
                self.ensure_card(state, done=True, retained=True)
                return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': state['card']}
            require_lifecycle_intent_clear(self.directory, self.config_sha256, self.contract_sha256)
            self.effects.check_authority(state)
            if phase == 'dispatch-pending' and hasattr(self.effects, 'recover_dispatch'):
                recovered = self.effects.recover_dispatch(state)
                if recovered:
                    state.update(recovered); self.save(state); phase = state['phase']
            self.ensure_card(state, done=phase == 'done-readback')
            if phase == 'reserved':
                # Persist attempted dispatch before the first public claim. Unknown
                # effect recovery reads this attempt; it never creates a new intent.
                state['phase'] = 'dispatch-pending'; self.save(state)
                update = self.effects.dispatch(state)
                state.update(update); self.save(state)
                if state.get('execution_id'):
                    validate_execution(self.effects.execution(state), state)
                    state['phase'] = 'execution'; self.save(state)
            elif phase == 'dispatch-pending':
                state.update(self.effects.dispatch(state))
                self.save(state)
                if state.get('execution_id'):
                    validate_execution(self.effects.execution(state), state)
                    state['phase'] = 'execution'; self.save(state)
            elif phase == 'claim-recovery-pending':
                state.update(self.effects.resume_claim(state)); state['phase'] = 'dispatch-pending'; self.save(state)
            elif phase == 'execution':
                view = self.effects.execution(state); validate_execution(view, state)
                if view.get('status') != 'succeeded':
                    return {'version': 1, 'result': 'noop', 'phase': phase, 'reason': 'execution-retained', 'card': state['card']}
                state['handoff'] = accepted_handoff(view, state)
                state['completed_execution_sha256'] = value_sha(view)
                state['phase'] = 'candidate'; self.save(state)
            elif phase == 'candidate':
                state['candidate'] = self.effects.candidate(state)
                self.validate_candidate(state)
                state['phase'] = 'install'; self.save(state)
            elif phase == 'install':
                receipt = self.effects.install(state)
                if not self.validate_install(state, receipt):
                    return {'version': 1, 'result': 'noop', 'phase': phase, 'reason': 'official-soak-pending', 'card': state['card']}
                state['install'] = receipt; state['proof_attempt'] = uuid.uuid4().hex
                state['phase'] = 'proof'; self.save(state)
            elif phase == 'proof':
                state['proof'] = self.effects.prove(state); self.validate_proof(state)
                state['phase'] = 'proof-mark'; self.save(state)
            elif phase == 'proof-mark':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                self.accept_write(state, self.effects.write(state, 'proof-mark'))
                state['phase'] = 'pr-metadata'; self.save(state)
            elif phase == 'pr-metadata':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                fields = self.ensure_card(state)
                evidence = self.effects.parse(fields, state['handoff']['pr_url'])
                require(evidence.get('verdict') == 'positive' and evidence.get('signal') and not evidence.get('reopened_same_signal'), 'latest-positive-evidence-required')
                require(not evidence.get('done_when'), 'card-prose-done-when-deferred')
                state['accepted_evidence'] = evidence
                self.accept_write(state, self.effects.write(state, 'pr-metadata'))
                state['phase'] = 'close'; self.save(state)
            elif phase == 'close':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                fields = self.ensure_card(state)
                evidence = self.effects.parse(fields, state['handoff']['pr_url'])
                require(evidence.get('verdict') == 'positive' and evidence.get('signal') == state['accepted_evidence']['signal'] and
                        not evidence.get('done_when') and not evidence.get('reopened_same_signal'), 'close-latest-evidence-drift')
                receipt = self.effects.write(state, 'close'); self.accept_write(state, receipt)
                state['close_receipt'] = receipt; state['phase'] = 'done-readback'; self.save(state)
            elif phase == 'done-readback':
                self.ensure_card(state, done=True)
                state['completion'] = self.completion(state)
                state['completion_sha256'] = value_sha(state['completion']); state['final_snapshot_sha256'] = state['witness']['snapshot_sha256']
                state['phase'] = 'completed'; self.save(state)
            else:
                raise Refusal('unknown-retained-phase')
            return {'version': 1, 'result': 'ok', 'phase': state['phase'], 'card': state['card']}


class Runtime:
    def __init__(self, root, config, directory):
        self.root = Path(root); self.config = config; self.directory = Path(directory)
        self.fk = config['fkanban_authority']; self.baseline = config['dispatch_authority']

    def check_authority(self, state=None):
        self.kanban = verify_fk(self.fk)
        if state is None or state['phase'] in ('reserved', 'dispatch-pending', 'claim-recovery-pending', 'execution', 'candidate', 'install'):
            self.loom = verify_loom(self.baseline, current=state is None or state['phase'] in ('reserved', 'dispatch-pending', 'claim-recovery-pending', 'execution', 'candidate'))
        else:
            self.loom = verify_loom(state['candidate']['authority'])

    def card(self):
        return self.read_card(current=True)

    def completed_card(self):
        return self.read_card(current=False)

    def read_card(self, current):
        self.kanban = verify_fk(self.fk, current=current)
        item = public_card_batch(self.kanban, [COUNT_CARD])['items'][0]
        require(item.get('missing') is not True, 'finite-card-missing')
        return item

    def bootstrap_ready(self):
        from factory_bootstrap import require_bootstraps_complete
        local = validate_local(self.root)
        require_bootstraps_complete(self.root, self.directory, local['contract_sha256'], self.kanban)

    def dispatch(self, state):
        logs = self.directory / 'kickoff'; logs.mkdir(exist_ok=True, mode=0o700)
        intent = {**state, 'receipt_path': str(self.directory / ('claim-' + state['intent']['attempt'] + '.json'))}
        atomic_json(self.directory / 'dispatch-intent.json', intent)
        current = logs / 'factory-repair-slot.current'
        if not current.exists():
            require(not Path(intent['receipt_path']).exists(), 'claim-without-observed-execution-retained')
            call_path = self.directory / ('dispatch-call-' + state['intent']['attempt'] + '.json')
            require(not call_path.exists(), 'dispatch-call-unknown-retained')
            env = dict(os.environ)
            for key in tuple(env):
                if key.startswith('LOOM_') or key == 'KANBAN_BIN':
                    del env[key]
            env.update(LOOM_BIN=str(self.loom / 'dist/loom'), LOOM_SCRIPTS=str(self.loom / 'scripts'), LOOM_DEFS=str(self.loom / 'definitions'),
                       KANBAN_BIN=str(self.root / 'bin/last-stack-factory-repair-kanban-adapter'),
                       LOOM_KICKOFF_LOG_ROOT=str(logs), LOOM_KICKOFF_WORKER='factory-repair-slot',
                       LAST_STACK_FACTORY_INTENT=str(self.directory / 'dispatch-intent.json'))
            decision_path = self.directory / ('reviewed-decision-' + state['intent']['decision_receipt_sha256'] + '.json')
            if not decision_path.exists(): decision_path.write_bytes(state['intent']['decision_receipt_json'].encode())
            require(file_sha(decision_path) == state['intent']['decision_receipt_sha256'], 'dispatch-decision-file-drift')
            atomic_json(call_path, {'version': 1, 'intent_sha256': state['intent_sha256'], 'card': state['card'],
                'decision_receipt_sha256': state['intent']['decision_receipt_sha256'], 'status': 'attempted'})
            rc, out, err = bounded_call([str(self.loom / 'scripts/loom-land-card-kickoff.sh'), '--only-card', state['card'],
                '--reviewed-decision-receipt', str(decision_path), '--reviewed-decision-sha256', state['intent']['decision_receipt_sha256']], 180, env)
            (self.directory / 'kickoff.out').write_bytes(out); (self.directory / 'kickoff.err').write_bytes(err)
            require(rc == 0 and current.exists(), 'exact-kickoff-no-observed-execution')
        parts = read_bytes(current, 1024 * 1024).decode().strip().split(' ', 3)
        require(len(parts) == 4 and parts[1] == state['card'] and kickoff_key(parts[0], state['card']), 'kickoff-current-identity')
        key, _, pid, raw_input = parts
        require(pid.isdigit(), 'kickoff-current-pid')
        log = logs / (key + '.log')
        lines = read_bytes(log, 8 * 1024 * 1024).decode().splitlines() if log.exists() else []
        ids = [line for line in lines if EXEC_ID.fullmatch(line)]
        require(len(set(ids)) <= 1, 'kickoff-execution-ambiguous')
        receipt = read_json(intent['receipt_path'])
        allowed_guards = {state['intent']['witness_sha256'], state.get('accepted_held', {}).get('snapshot_sha256')}
        require(receipt.get('result') == 'claimed' and receipt.get('durability') == 'durable' and
                receipt.get('contract_sha256') == self.fk['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') in allowed_guards, 'claim-durable-receipt')
        witness = {'slug': state['card'], 'snapshot_json': receipt['next_snapshot_json'], 'snapshot_sha256': receipt['next_snapshot_sha256']}
        validate_snapshot(witness, state['card'])
        return {'execution_id': ids[-1] if ids else '', 'key': key, 'original_input': strict_json(raw_input), 'witness': witness, 'claim_receipt': receipt}

    def recover_dispatch(self, state):
        path = self.directory / ('claim-' + state['intent']['attempt'] + '.json')
        if not path.exists():
            return None
        receipt = read_json(path)
        if receipt.get('result') == 'claimed':
            require(receipt.get('durability') == 'durable' and receipt.get('contract_sha256') == self.fk['contract_sha256'] and
                    receipt.get('guard_snapshot_sha256') in (state['intent']['witness_sha256'], state.get('accepted_held', {}).get('snapshot_sha256')), 'recovered-claim-authority')
            witness = {'slug': state['card'], 'snapshot_json': receipt.get('next_snapshot_json'), 'snapshot_sha256': receipt.get('next_snapshot_sha256')}
            validate_snapshot(witness, state['card'])
            return {'witness': witness, 'claim_receipt': receipt}
        require(receipt.get('code') == 'claim_recovery_pending', 'unknown-claim-recovery-receipt')
        accepted = receipt.get('accepted_held', {})
        require(version1(accepted.get('version')) and accepted.get('stage') == 'accepted-held' and accepted.get('durability') == 'durable' and
                accepted.get('contract_sha256') == self.fk['contract_sha256'] and
                accepted.get('guard_snapshot_sha256') == state['intent']['witness_sha256'], 'accepted-held-recovery-authority')
        witness = {'slug': state['card'], 'snapshot_json': accepted.get('snapshot_json'), 'snapshot_sha256': accepted.get('snapshot_sha256')}
        validate_claim_stage_one(state['original_witness'], witness, state['owner'])
        return {'witness': witness, 'accepted_held': accepted, 'phase': 'claim-recovery-pending'}

    def resume_claim(self, state):
        # This only clears the exact accepted synthetic stage through public FK.
        # It never drives or invents a missing execution/current identity.
        intent = {**state, 'receipt_path': str(self.directory / ('claim-' + state['intent']['attempt'] + '.json'))}
        path = self.directory / 'dispatch-intent.json'; atomic_json(path, intent)
        env = dict(os.environ); env['LAST_STACK_FACTORY_INTENT'] = str(path)
        receipt = json_call([str(self.root / 'bin/last-stack-factory-repair-kanban-adapter'), 'pickup', 'claim-v2',
                             '--only-card', state['card'], '--worker', state['owner'], '--json'], 90, env)
        require(receipt.get('result') == 'claimed' and receipt.get('durability') == 'durable' and
                receipt.get('contract_sha256') == self.fk['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'accepted-held-clear-not-durable')
        witness = {'slug': state['card'], 'snapshot_json': receipt['next_snapshot_json'], 'snapshot_sha256': receipt['next_snapshot_sha256']}
        validate_snapshot(witness, state['card'])
        return {'witness': witness, 'claim_receipt': receipt}

    def execution(self, state):
        return json_call([str(self.loom / 'dist/loom'), 'show', state['execution_id'], '--json'], 30)

    def candidate(self, state):
        gh = shutil.which('gh', path=str(Path.home() / '.local/bin') + os.pathsep + os.environ.get('PATH', ''))
        require(gh is not None, 'installed-github-cli-unavailable')
        pr = json_call([gh, 'pr', 'view', state['handoff']['pr_url'], '-R', state['repo'], '--json',
                        'state,mergedAt,mergeCommit,baseRefName,headRefName,body,url'], 30)
        require(pr.get('url') == state['handoff']['pr_url'] and pr.get('state') == 'MERGED' and pr.get('mergedAt') and pr.get('baseRefName') == state['base'] and
                pr.get('headRefName') == 'factory/' + state['execution_id'] + '#IMPLEMENT', 'merged-pr-execution-binding')
        oid = pr.get('mergeCommit', {}).get('oid', '')
        require(OID.fullmatch(oid), 'merged-source-oid')
        require(re.search(r'(?m)^Papercut:\s*' + re.escape(COUNT_PAPERCUT) + r'\s*$', pr.get('body', '')) and
                re.search(r'(?m)^Keep-open:\s*papercut-loom-execution-status-backlog-sweep-pending-20260928\s*$', pr.get('body', '')), 'merged-pr-labeled-claim')
        content = json_call([gh, 'api', 'repos/' + state['repo'] + '/contents/release/factory-dispatch-contract.json?ref=' + oid], 30)
        import base64
        raw = base64.b64decode(content.get('content', ''), validate=False); reviewed = strict_json(raw)
        baseline = read_json(self.loom / 'release/factory-dispatch-contract.json')
        require(reviewed.get('features') == FEATURES and reviewed.get('definition_version') == '5' and
                reviewed.get('files') == baseline['files'] and reviewed.get('supervisor_source_sha256') == baseline['supervisor_source_sha256'] and
                reviewed.get('budget_recovery_source_sha256') == baseline['budget_recovery_source_sha256'], 'candidate-retained-dispatch-authority')
        require(reviewed.get('runner_source_sha256') != baseline['runner_source_sha256'], 'candidate-count-runner-unchanged')
        pull = json_call([str(self.root / 'bin/last-stack-github-artifact-pull'), '--app', 'loom', '--repo', state['repo'],
                          '--branch', state['base'], '--oid', oid, '--channel', 'candidate', '--json'], 180)
        require(pull.get('status') in ('promoted', 'verified') and pull.get('oid') == oid and
                OID.fullmatch(pull.get('tree_oid', '')) and type(pull.get('artifact_id')) is int and pull['artifact_id'] > 0 and type(pull.get('run_id')) is int and pull['run_id'] > 0, 'candidate-official-publish-receipt')
        digest = pull.get('manifest_digest', ''); require(HEX.fullmatch(digest), 'candidate-manifest-digest')
        manifest_path = Path.home() / '.lastgit/artifacts/manifests' / (digest + '.json'); manifest = read_json(manifest_path)
        require(manifest.get('source_oid') == oid and manifest.get('manifest_digest') == digest and manifest.get('app') == 'loom', 'candidate-manifest-source')
        indexed = {item['path']: item for item in manifest['files']}
        require(indexed.get('release/factory-dispatch-contract.json', {}).get('sha256') == sha(raw), 'candidate-source-contract-not-in-artifact')
        for rel, expected in reviewed['files'].items():
            require(indexed.get(rel, {}).get('sha256') == expected, 'candidate-official-source-file: ' + rel)
        authority = {'app': 'loom', 'source_oid': oid, 'manifest_sha256': digest, 'manifest_file_sha256': file_sha(manifest_path),
                     'manifest_path': str(manifest_path), 'contract_sha256': sha(raw),
                     'root': str(Path.home() / '.host-track/apps/loom/versions' / digest),
                     'current': str(Path.home() / '.host-track/apps/loom/current')}
        return {'source_oid': oid, 'tree_oid': pull['tree_oid'], 'manifest_sha256': digest, 'contract_sha256': sha(raw),
                'manifest_json': read_bytes(manifest_path).decode(), 'source_contract_json': raw.decode(),
                'baseline_contract_json': read_bytes(self.loom / 'release/factory-dispatch-contract.json').decode(), 'merge_receipt': pr,
                'official': pull, 'authority': authority, 'dispatch_authority_sha256': value_sha(state['dispatch_authority']),
                'completed_execution_sha256': state['completed_execution_sha256'], 'intent_sha256': state['intent_sha256'], 'pr_url': state['handoff']['pr_url']}

    def install(self, state):
        candidate = state['candidate']
        rc, out, err = bounded_call([str(self.root / 'bin/host-track'), 'install', '--channel', 'candidate',
                                    '--expected-oid', candidate['source_oid'], '--expected-manifest', candidate['manifest_sha256'], '--json', 'loom'], 900)
        require(rc in (0, 75), 'official-exact-install-refused')
        receipt = strict_json(out)
        require((rc == 75) == (receipt.get('result') == 'pending'), 'installer-exit-receipt-mismatch')
        return receipt

    def prove(self, state):
        path = self.directory / ('proof-input-' + state['proof_attempt'] + '.json'); atomic_json(path, state)
        return json_call([str(self.root / 'bin/last-stack-factory-repair-proof'), '--state', str(path), '--json'], 180)

    def write(self, state, operation):
        witness = validate_snapshot(state['witness'], state['card'])
        path = self.directory / ('witness-' + witness['sha256'] + '.json')
        if not path.exists():
            path.write_text(witness['text'], encoding='utf-8')
        require(file_sha(path) == witness['sha256'], 'retained-witness-file')
        if operation == 'proof-mark':
            args = ['mark', state['card'], 'PROOF: END STATE met PASS factory-action=' + state['proof_attempt'] + ' signal=' + state['proof']['signal']]
        elif operation == 'pr-metadata':
            args = ['set', state['card'], '--pr-url', state['handoff']['pr_url'], '--branch', 'factory/' + state['execution_id'] + '#IMPLEMENT']
        elif operation == 'close':
            args = ['move', state['card'], 'done', '--from', 'doing']
        else:
            raise Refusal('unknown-guarded-operation')
        return json_call([str(self.kanban), *args, '--guard-snapshot', str(path), '--snapshot-sha256', witness['sha256'],
                          '--expect-assignee', state['owner'], '--json'], 60)

    def parse(self, card, pr):
        from closeout_evidence import parse_card_evidence
        return parse_card_evidence(card, pr)


def require_report_ready(directory, routine):
    path = Path(directory) / ('routine-closeout-' + routine + '.json')
    if path.exists():
        value = read_json(path)
        require(version1(value.get('version')) and value.get('status') == 'complete', 'routine-closeout-unknown-retained')


def routine_heartbeat(root, routine, result):
    outcome = 'ok' if result['result'] == 'ok' else ('noop' if result['result'] == 'noop' else 'error')
    detail = re.sub(r'[^a-zA-Z0-9_.-]', '-', str(result.get('phase', result.get('reason', 'retained'))))[:160]
    rc, out, err = bounded_call([str(Path(root) / 'bin/last-stack-brain-append-heartbeat'), '--automation', routine,
                               '--line', 'outcome=' + outcome + ' detail=' + detail], 10)
    require(rc == 0, 'routine-heartbeat-unavailable')


def routine_report(root, routine, result):
    """Report before the trailer. Unknown write receipts retain the report intent."""
    if result.get('result') == 'noop' and result.get('phase') == 'completed':
        return result
    import datetime as dt
    root = Path(root); directory = Path.home() / '.local/state/last-stack/factory-repair-slot'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / ('routine-closeout-' + routine + '.json')
    try:
        require_report_ready(directory, routine)
    except Refusal:
        return {**result, 'result': 'error', 'reason': 'routine-closeout-unknown-retained'}
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S')
    slug = 'closeout-' + stamp + '-' + routine
    phase = re.sub(r'[^a-z0-9-]', '-', str(result.get('phase', 'unavailable')).lower())[:48]
    reason = str(result.get('reason', 'none'))
    friction = result.get('result') == 'error' and any(token in reason for token in
        ('timeout', 'public-command-', 'native-query-', 'malformed-json', 'unavailable', 'filing-attempt-unknown'))
    paper = 'papercut-factory-runtime-' + routine + '-' + phase + '-' + re.sub(r'[^a-z0-9-]', '-', reason.split(':', 1)[0].lower())[:64]
    brain = str(Path.home() / '.local/bin/brain')
    body = ('---\ntype: reference\nslug: ' + slug + '\ntitle: ' + routine + ' finite repair report\n---\n'
            'The routine result is ' + result['result'] + '. The slot keeps its retained authority and witness.\n'
            'Result metadata:\n\n```json\n' + json.dumps(result, sort_keys=True) + '\n```\n\n'
            'Friction: ' + (paper if friction else 'none; this pass adds no distinct tool failure claim') + '.\n').encode()
    atomic_json(path, {'version': 1, 'status': 'pending', 'slug': slug, 'report_sha256': sha(body), 'result_sha256': value_sha(result)})
    try:
        jobs = [(lambda: bounded_call([brain, 'put', slug, '--type', 'reference'], 30, stdin=body))]
        if friction:
            hits = json_call([brain, 'search', paper, '--type', 'papercut', '--limit', '5', '--json'], 30)
            require(isinstance(hits, list), 'runtime-friction-search-unavailable')
            exact = [hit for hit in hits if isinstance(hit, dict) and hit.get('slug') == paper]
            # Search is a sample. The known slug receives an exact existence read.
            rc, raw, err = bounded_call([brain, 'get', paper, '--type', 'papercut', '--json'], 30)
            remedy = strict_json(raw)
            absent = rc != 0 and isinstance(remedy, dict) and remedy.get('error') == 'No papercut: ' + paper
            require(rc == 0 or absent, 'runtime-friction-remedy-unavailable')
            evidence = 'Phase: ' + phase + '\nError: ' + reason + '\nRoutine: ' + routine + '\nThe slot stays occupied. No read failure proves absence.\n'
            if not absent:
                require(remedy.get('slug') == paper and remedy.get('status') == 'open', 'runtime-friction-remedy-requires-review')
                jobs.append(lambda: bounded_call([brain, 'append', paper, '--type', 'papercut'], 30, stdin=evidence.encode()))
            else:
                jobs.append(lambda: bounded_call([brain, 'papercut', 'file', paper, '--component', 'factory-repair',
                    '--severity', 'p1', '--title', 'Finite factory runtime cannot confirm ' + phase,
                    '--symptom', reason[:240], '--body', evidence], 30))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            receipts = list(pool.map(lambda job: job(), jobs))
        require(all(rc == 0 for rc, out, err in receipts), 'routine-brain-write-receipt-unknown')
        record = json_call([brain, 'get', slug, '--type', 'reference', '--json'], 30)
        require(record.get('slug') == slug and isinstance(record.get('body'), str) and
                json.dumps(result, sort_keys=True) in record['body'], 'routine-report-readback-unavailable')
        rc, out, err = bounded_call([str(root / 'bin/last-stack-closeout-index'), 'record', routine, slug], 30)
        require(rc == 0, 'routine-closeout-index-unknown')
        rc, out, err = bounded_call([str(root / 'bin/last-stack-closeout-index'), 'latest', routine], 30)
        require(rc == 0 and out.decode().strip() == slug, 'routine-closeout-index-readback-unavailable')
        atomic_json(path, {'version': 1, 'status': 'complete', 'slug': slug, 'report_sha256': sha(body), 'result_sha256': value_sha(result)})
        return {**result, 'closeout_slug': slug, 'friction_slug': paper if friction else None}
    except (Refusal, OSError, ValueError, KeyError, TypeError):
        return {**result, 'result': 'error', 'reason': 'routine-closeout-unknown-retained', 'closeout_slug': slug}
