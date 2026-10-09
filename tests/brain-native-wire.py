#!/usr/bin/env python3
"""Authenticated public Brain raw CLI boundary with a private native reply."""
import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]; sys.path.insert(0, str(ROOT / 'lib'))
import factory_repair as f
from factory_reconcile import brain_papercut_batch, PAPERCUT_FIELDS

def check(value, message):
    if not value: raise AssertionError(message)

def fixture(mode, check_success=True):
    directory = Path(tempfile.mkdtemp(prefix='brain-native-wire-')); binary = directory / 'brain'; capture = directory / 'request.json'
    binary.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['PRIVATE_BRAIN_ROOT']);mode=os.environ['PRIVATE_BRAIN_MODE']
if sys.argv[1:]!=['raw','POST','/api/query','-']:sys.exit('unexpected public Brain argv')
query=json.load(sys.stdin);(root/'request.json').write_text(json.dumps(query))
rows=[]
for key,range_value in query['filter']['HashRangeKeys']:
    fields={name:[] if name=='tags' else '' for name in query['fields']};fields.update(slug=key,status='open',body='reviewed claim')
    rows.append({'key':{'hash':key,'range':None},'fields':fields})
reply={'ok':True,'has_more':False,'next_cursor':None,'results':rows,'returned_count':len(rows),'total_count':None,
       'tombstoned_rows':0,'unresolved_rows':0,'conflict_flags':'unknown'}
if mode=='missing':rows.pop();reply['returned_count']=len(rows)
if mode=='foreign':rows[0]['key']['hash']='papercut-foreign'
if mode=='duplicate':rows[-1]=rows[0]
if mode=='field':rows[0]['fields'].pop('title')
if mode=='unresolved':reply['unresolved_rows']=1
if mode=='failed':reply['failed_rows']=1
if mode=='tombstoned':reply['tombstoned_rows']=1
if mode=='truncated':reply['truncated']=True
if mode=='bool-counter':reply['unresolved_rows']=False
if mode=='cursor':reply['next_cursor']='later'
if mode=='row-error':rows[0]['error']='failure'
if mode=='row-tombstoned':rows[0]['tombstoned']=True
print(json.dumps(reply))
'''); binary.chmod(0o755)
    config = {'brain_papercut_schema_hash': 'a' * 64}; keys = ['papercut-first', 'papercut-second']
    with patch.dict(os.environ, {'PRIVATE_BRAIN_ROOT': str(directory), 'PRIVATE_BRAIN_MODE': mode}):
        rows = brain_papercut_batch(config, str(binary), keys)
    request = json.loads(capture.read_text())
    check(request == {'schema_name': 'a' * 64, 'filter': {'HashRangeKeys': [[key, ''] for key in keys]},
            'fields': list(PAPERCUT_FIELDS), 'offset': 0, 'limit': 2}, 'native Brain batch wire differs')
    if check_success: check([row['slug'] for row in rows] == keys, 'native Brain batch lost requested order')

# Explicit response guards and the requested-key dictionary projection both
# refuse incomplete membership. Their combined probe removes only those two
# protections; success-only order assertions do not mask the negative property.
def negative(mode):
    try: fixture(mode, check_success=False)
    except (f.Refusal, OSError, ValueError): return
    raise AssertionError(mode + ' Brain native reply admitted lifecycle truth')

CASES = {'positive': lambda: fixture('ok')}
for mode in ('missing', 'foreign', 'duplicate', 'field', 'unresolved', 'failed', 'tombstoned', 'truncated', 'bool-counter', 'cursor', 'row-error', 'row-tombstoned'):
    CASES[mode] = lambda mode=mode: negative(mode)
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('case', nargs='?', choices=CASES); args = parser.parse_args()
    for name in ([args.case] if args.case else CASES):
        try: CASES[name]()
        except Exception as error: print('FAIL: ' + name + ': ' + str(error), file=sys.stderr); sys.exit(1)
        print('PASS: ' + name)
