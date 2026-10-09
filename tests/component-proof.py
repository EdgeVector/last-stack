#!/usr/bin/env python3
"""Exact external component proof bytes and complete positive-field checks."""
import argparse
import copy
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]; sys.path.insert(0, str(ROOT / 'lib'))
import factory_repair as f
import factory_bootstrap as b

def check(value, message):
    if not value: raise AssertionError(message)

def fixture(change=None, pin=True):
    directory = Path(tempfile.mkdtemp(prefix='component-proof-')); binary = directory / 'kanban'; binary.write_text('compiled fixture')
    artifact = {'version': 1, 'source_commit': '1' * 40, 'contract_sha256': '2' * 64, 'cli_sha256': f.file_sha(binary), 'mcp_sha256': '3' * 64}
    f.atomic_json(directory / 'guarded-contract.json', artifact)
    producer = directory / 'producer.ts'; producer.write_text('reviewed fixture producer\n')
    value = {'version': 1, 'result': 'passed', 'source_unchanged': True, 'program_sha256': f.file_sha(producer),
        'artifact': artifact, 'build': '0.23.3-2588-g24334db75',
        'cases': [{'name': 'case-' + str(i), 'passed': True} for i in range(40)] + [{'name': 'observation-' + str(i)} for i in range(29)],
        'restart': {'passed': True, 'cards': 39, 'destinations': 17, 'absent_destinations': 25},
        'stop_checks': [{'pid': 1, 'signal': 'SIGKILL', 'argv_verified': True}, {'pid': 2, 'signal': 'SIGTERM', 'argv_verified': True}]}
    path = directory / 'evidence.json'; f.atomic_json(path, value); original_sha = f.file_sha(path)
    if change: change(value)
    f.atomic_json(path, value)
    entry = {'artifact_authority': {}, 'proof': {'kind': 'fkanban-installed-public-v1', 'path': str(path),
        'sha256': f.file_sha(path) if pin else original_sha, 'producer_path': str(producer), 'producer_sha256': f.file_sha(producer),
        'build': '0.23.3-2588-g24334db75', 'checks': 40, 'observations': 29,
        'restart': {'passed': True, 'cards': 39, 'destinations': 17, 'absent_destinations': 25}}}
    return entry, binary, producer

def run(change=None, pin=True):
    entry, binary, producer = fixture(change, pin)
    with patch.object(b, 'verify_fk', return_value=binary): b.verify_component(entry)

def negative(change, message, pin=True):
    try: run(change, pin)
    except (f.Refusal, OSError): return
    raise AssertionError(message)

def producer_drift():
    entry, binary, producer = fixture(); producer.write_text('changed producer\n')
    try:
        with patch.object(b, 'verify_fk', return_value=binary): b.verify_component(entry)
    except f.Refusal: return
    raise AssertionError('changed external producer accepted')

def file_child(field, kind):
    entry, binary, producer = fixture(); target = Path(entry['proof'][field]); replacement = target.with_name(target.name + '.unsafe')
    if kind == 'fifo': os.mkfifo(replacement)
    else: replacement.symlink_to(target)
    entry['proof'][field] = str(replacement); calls = []
    with patch.object(b, 'verify_fk', side_effect=lambda _: calls.append('artifact') or binary):
        try: b.verify_component(entry)
        except (f.Refusal, OSError):
            check(calls == [], 'unsafe external file reached artifact or Card effects')
            print('REFUSED: unsafe external ' + field); return
    raise AssertionError('unsafe external ' + field + ' admitted')

def unsafe_file(field, kind):
    try:
        result = subprocess.run([sys.executable, str(Path(__file__)), '--file-child', field, kind], capture_output=True, timeout=2)
    except subprocess.TimeoutExpired as error:
        raise AssertionError('external ' + field + ' FIFO blocks before file admission') from error
    check(result.returncode == 0 and ('REFUSED: unsafe external ' + field) in result.stdout.decode(),
          'external ' + field + ' unsafe file reached component admission: ' + result.stderr.decode())

def loom_component(change=None):
    directory = Path(tempfile.mkdtemp(prefix='loom-component-proof-')); (directory / 'dist').mkdir()
    runner = directory / 'dist/loom'; runner.write_bytes(b'private reviewed runner')
    producer = directory / 'producer.py'; producer.write_bytes(b'private reviewed component producer')
    authority = {'source_oid': '1' * 40, 'manifest_sha256': '2' * 64, 'contract_sha256': '3' * 64}
    cases = [{'name': 'exact-reviewed-native-batch', 'result': 'positive'},
             {'name': 'absent-receipt', 'result': 'refused'}]
    value = {'version': 1, 'kind': 'loom-reviewed-decision-component-v1', 'result': 'positive', **authority,
        'definition_version': 5, 'runner_sha256': f.file_sha(runner), 'producer_sha256': f.file_sha(producer),
        'source_unchanged': True, 'primary_effects': False, 'compiled_contract_verified': True, 'cases': copy.deepcopy(cases)}
    if change: change(value)
    path = directory / 'evidence.json'; f.atomic_json(path, value)
    entry = {'artifact_authority': authority, 'proof': {'kind': 'loom-reviewed-decision-component-v1',
        'path': str(path), 'sha256': f.file_sha(path), 'producer_path': str(producer),
        'producer_sha256': f.file_sha(producer), 'required_cases': cases}}
    with patch.object(b, 'verify_loom', return_value=directory):
        if not change: b.verify_component(entry); return
        try: b.verify_component(entry)
        except f.Refusal: return
    raise AssertionError('candidate, changed, or incomplete Loom component receipt admitted bootstrap')

CASES = {'positive': run, 'receipt_bytes': lambda: negative(lambda v: v.update(result='wrong'), 'changed external receipt bytes accepted', False),
    'producer_bytes': producer_drift, 'source_changed': lambda: negative(lambda v: v.update(source_unchanged=False), 'changed source component proof accepted'),
    'artifact': lambda: negative(lambda v: v['artifact'].update(source_commit='9' * 40), 'foreign installed artifact component accepted'),
    'version': lambda: negative(lambda v: v.update(version=True), 'boolean component proof version accepted'),
    'failed_case': lambda: negative(lambda v: v['cases'][0].update(passed=False), 'failed component guard counted positive'),
    'missing_case': lambda: negative(lambda v: v['cases'].pop(), 'incomplete component proof accepted'),
    'restart': lambda: negative(lambda v: v['restart'].update(passed=False), 'failed component restart accepted'),
    'stop_identity': lambda: negative(lambda v: v['stop_checks'][0].update(argv_verified=False), 'unverified synthetic stop accepted')}
for field in ('path', 'producer_path'):
    for kind in ('fifo', 'symlink'):
        CASES[field + '_' + kind] = lambda field=field, kind=kind: unsafe_file(field, kind)
CASES['loom-positive'] = loom_component
CASES['loom-candidate-kind'] = lambda: loom_component(lambda v: v.update(kind='loom-reviewed-decision-candidate-v1'))
CASES['loom-version-type'] = lambda: loom_component(lambda v: v.update(definition_version='5'))
CASES['loom-primary-effects'] = lambda: loom_component(lambda v: v.update(primary_effects=True))
CASES['loom-source'] = lambda: loom_component(lambda v: v.update(source_oid='9' * 40))
CASES['loom-incomplete-cases'] = lambda: loom_component(lambda v: v['cases'].pop())
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=(*CASES, 'fifo', 'symlink')); p.add_argument('--file-child', choices=('path', 'producer_path')); args = p.parse_args()
    if args.file_child:
        file_child(args.file_child, args.case); sys.exit(0)
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
