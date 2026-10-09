#!/usr/bin/env python3
"""Actual finite helper argv and public durable ack against private CLIs."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def check(value, message):
    if not value: raise AssertionError(message)

def fixture(mode):
    directory = Path(tempfile.mkdtemp(prefix='lifecycle-public-')); bindir = directory / 'bin'; bindir.mkdir()
    helper = bindir / 'last-stack-papercut-lifecycle-close'; shutil.copyfile(ROOT / 'bin/last-stack-papercut-lifecycle-close', helper)
    private = bindir / 'private-cli'
    private.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:];root=Path(os.environ['PRIVATE_LIFECYCLE_ROOT']);mode=os.environ['PRIVATE_LIFECYCLE_MODE']
with (root/'calls.jsonl').open('a') as stream: stream.write(json.dumps(args)+'\\n')
if args[:2]==['pr','view']:
    body='Papercut: papercut-fixture'
    if mode=='unlabeled':body='Context mentions papercut-fixture'
    if mode=='keep-open':body+='\\nKeep-open: papercut-fixture'
    print(json.dumps({'url':'https://github.com/EdgeVector/last-stack/pull/1','state':'MERGED','mergedAt':'2026-10-09T00:00:00Z','body':body}))
elif args[:2]==['papercut','close']:
    if '--durable' not in args:sys.exit('missing public durable request')
    print('papercut papercut-fixture: open → fixed durability='+('queued' if mode=='queued' else 'durable')+' revision=private-revision')
else:sys.exit('unexpected private command')
'''); private.chmod(0o755)
    ledger = bindir / 'last-stack-papercut-ledger-append'
    ledger.write_text('#!/usr/bin/env python3\nimport sys\nsys.stdin.read()\n'); ledger.chmod(0o755)
    records = directory / 'records.json'
    records.write_text(json.dumps([{'slug': 'papercut-fixture', 'status': 'open', '_typed': True,
        'body': 'Status: OPEN\nRepo: EdgeVector/last-stack\nPR: https://github.com/EdgeVector/last-stack/pull/1\n'}]))
    env = {**os.environ, 'PRIVATE_LIFECYCLE_ROOT': str(directory), 'PRIVATE_LIFECYCLE_MODE': mode}
    argv = [sys.executable, str(helper), '--records-json', str(records), '--brain-bin', str(private), '--gh-bin', str(private),
            '--budget-seconds', '5', '--require-labeled-repair', '--durable', '--json']
    result = subprocess.run(argv, capture_output=True, timeout=10, env=env)
    check(result.stdout, 'actual helper emitted no JSON: rc=' + str(result.returncode) + ' stderr=' + result.stderr.decode())
    reply = json.loads(result.stdout); calls = [json.loads(line) for line in (directory / 'calls.jsonl').read_text().splitlines()]
    return result, reply, calls

def positive():
    result, reply, calls = fixture('ok')
    check(result.returncode == 0 and len(reply['fixed']) == 1 and reply['fixed'][0]['durability'] == 'durable',
          'actual finite helper argv did not return a durable labeled close')
    check(sum(c[:2] == ['papercut', 'close'] for c in calls) == 1, 'finite helper did not use one exact public close')

def queued():
    result, reply, calls = fixture('queued')
    check(result.returncode != 0 and reply['errors'] and not reply['fixed'], 'queued ack became a durable lifecycle result')

def negative(mode):
    result, reply, calls = fixture(mode)
    check(not reply['fixed'] and not any(c[:2] == ['papercut', 'close'] for c in calls),
          mode + ' canonical direct PR authorized a lifecycle close')

CASES = {'positive': positive, 'queued': queued, 'unlabeled': lambda: negative('unlabeled'), 'keep-open': lambda: negative('keep-open')}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('case', nargs='?', choices=CASES); args = parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
