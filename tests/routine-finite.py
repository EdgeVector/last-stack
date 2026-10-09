#!/usr/bin/env python3
"""Private routine seeds, report receipts, deadlines, and report deferral."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]; sys.path.insert(0, str(ROOT / 'lib'))
import factory_repair as f

def check(value, message):
    if not value: raise AssertionError(message)

def seeder():
    root = Path(tempfile.mkdtemp(prefix='finite-seeder-')); registry = root / 'registry'; registry.mkdir()
    old = {}
    for i in range(13):
        path = registry / ('paused-' + str(i) + '.toml'); path.write_text('status = "paused"\n# exact retained ' + str(i) + '\n'); old[path] = path.read_bytes()
    command = [sys.executable, str(ROOT / 'bin/last-stack-factory-repair-routine'), '--registry-dir', str(registry)]
    environment = {**os.environ, 'HOME': str(root)}
    result = subprocess.run(command, env=environment, capture_output=True, timeout=5)
    check(result.returncode == 0, 'finite paused seeder failed')
    new = registry / 'last-stack-factory-repair.toml'; text = new.read_text()
    check('status = "paused"' in text and 'timeout_min = 20' in text and '# PAUSED-REASON:' in text and '# PAUSED-UNTIL:' in text,
          'new routine did not start paused and bounded')
    check(str(root / '.last-stack/routines/factory-repair.md') in text and str(root / '.last-stack/bin/last-stack-factory-repair-controller') in text,
          'finite routine did not use stable installed paths')
    generated = tomllib.loads(text)
    check(generated['difficulty'] == 'normal' and not any(key in generated for key in ('harness', 'model', 'pin')),
          'generated route mixes difficulty with an explicit harness')
    template = tomllib.loads((ROOT / 'config/routines-registry/last-stack-factory-repair.toml').read_text())
    check(template['difficulty'] == 'normal' and not any(key in template for key in ('harness', 'model', 'pin')),
          'template route mixes difficulty with an explicit harness')
    new.write_text('status = "paused"\nrrule = "owner schedule"\ntimeout_min = 33\n'); kept = new.read_bytes()
    again = subprocess.run(command, env=environment, capture_output=True, timeout=5)
    check(again.returncode == 0 and new.read_bytes() == kept and all(path.read_bytes() == data for path, data in old.items()),
          'install changed an existing pause or schedule')

def report(mode='ok'):
    root = Path(tempfile.mkdtemp(prefix='finite-report-')); calls = []; bodies = {}; routine = 'last-stack-factory-repair'
    result = {'version': 1, 'result': 'error' if mode == 'friction' else 'ok', 'phase': 'proof', 'reason': 'native-query-timeout' if mode == 'friction' else 'phase-complete'}
    def command(argv, seconds, *args, **kwargs):
        calls.append(argv)
        if argv[1] == 'put': bodies[argv[2]] = kwargs['stdin'].decode()
        if argv[1] == 'get': return 1, json.dumps({'error': 'No papercut: ' + argv[2]}).encode(), b''
        if argv[1] == 'latest': return 0, next(iter(bodies)).encode(), b''
        return (1 if mode == 'unknown' and argv[1] == 'put' else 0), b'receipt', b''
    def query(argv, *args, **kwargs):
        calls.append(argv)
        if argv[1] == 'search': return []
        return {'slug': argv[2], 'body': bodies[argv[2]]}
    with patch.object(Path, 'home', return_value=root), patch.object(f, 'bounded_call', side_effect=command), patch.object(f, 'json_call', side_effect=query):
        output = f.routine_report(ROOT, routine, result)
        if mode == 'unknown':
            count = len(calls); again = f.routine_report(ROOT, routine, result)
            check(len(calls) == count and again['reason'] == 'routine-closeout-unknown-retained', 'unknown report write was retried')
            try: f.require_report_ready(root / '.local/state/last-stack/factory-repair-slot', routine)
            except f.Refusal: pass
            else: raise AssertionError('unknown report allowed another factory effect')
        else:
            check(output['result'] == result['result'] and output.get('closeout_slug'), 'finite report did not retain a confirmed receipt')
            writes = [a for a in calls if a[1] in ('put', 'record', 'latest')]
            check([a[1] for a in writes] == ['put', 'record', 'latest'], 'report/index sequence did not precede the trailer')
            if mode == 'friction': check(any(a[1:3] == ['papercut', 'file'] for a in calls) and output['friction_slug'].startswith('papercut-factory-runtime-'), 'runtime friction did not use its distinct phase/error identity')

def quiet():
    with patch.object(f, 'bounded_call', side_effect=AssertionError('quiet completion made a command')):
        result = {'result': 'noop', 'phase': 'completed'}
        check(f.routine_report(ROOT, 'last-stack-factory-repair', result) == result, 'quiet complete receipt changed')

def load_entry(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / ('bin/' + name));
    from importlib.machinery import SourceFileLoader
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, str(ROOT / ('bin/' + name))))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

def deadline(name):
    module = load_entry(name); previous = f.DEADLINE; f.DEADLINE = None
    def stop(root):
        check(f.DEADLINE is not None, name + ' did not set a shared phase deadline before work')
        raise f.Refusal('private stop')
    argv = [name, '--state', '/tmp/private-proof.json', '--json'] if name.endswith('-proof') else [name, '--once', '--json']
    try:
        with patch.object(sys, 'argv', argv), patch.object(module, 'validate_local', side_effect=stop), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()): module.main()
    finally: f.DEADLINE = previous

CASES = {'seeder': seeder, 'report': report, 'unknown_report': lambda: report('unknown'), 'friction': lambda: report('friction'),
         'quiet': quiet, 'controller_deadline': lambda: deadline('last-stack-factory-repair-controller'),
         'proof_deadline': lambda: deadline('last-stack-factory-repair-proof')}
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('case', nargs='?', choices=CASES); args = p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
