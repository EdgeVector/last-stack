#!/usr/bin/env python3
"""Exact GitHub lifecycle claims; no public network or Brain mutations."""
import argparse
import importlib.machinery
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[1]
loader=importlib.machinery.SourceFileLoader('lifecycle_fixture',str(ROOT/'bin/last-stack-papercut-lifecycle-close'))
spec=importlib.util.spec_from_loader(loader.name,loader); m=importlib.util.module_from_spec(spec);sys.modules[loader.name]=m;loader.exec_module(m)

def check(value,message):
    if not value:raise AssertionError(message)

def run(search_body='Papercut: papercut-fixture', current_body=None, state='MERGED', record_body='', search_error=False):
    args=SimpleNamespace(forge_search=True,gh_bin='private-gh',forge_api_bin='private-forge',ignore_keep_open=False,dry_run=False,json_out=True)
    record={'slug':'papercut-fixture','status':'open','body':'Status: OPEN\nRepo: EdgeVector/last-stack\n'+record_body,'_typed':True}
    calls=[]; closes=[]
    def remote(argv,timeout=60):
        calls.append(argv)
        check(argv[0]=='private-gh','retired Forgejo route used for GitHub repo')
        if argv[1:3]==['search','prs']:
            check('--merged' in argv and argv[-1]=='number,repository,url,body','public GitHub search contract changed')
            if search_error:raise RuntimeError('private transport unavailable')
            return [{'number':1,'repository':{'nameWithOwner':'EdgeVector/last-stack'},'url':'https://github.com/EdgeVector/last-stack/pull/1','body':search_body}]
        return {'state':state,'mergedAt':'2026-10-09T00:00:00Z' if state=='MERGED' else None,
                'body':search_body if current_body is None else current_body,'url':'https://github.com/EdgeVector/last-stack/pull/1'}
    m.run_json=remote;m.load_records=lambda _: [record];m.close_record=lambda *a,**kw:closes.append(a[1]['slug']);m.DEADLINE=m.Deadline(30)
    result=m.close_review_records(args,'2026-10-09T00:00:00Z')
    return result,calls,closes

def merged():
    result,calls,closes=run();check(closes==['papercut-fixture'] and len(result['fixed'])==1,'exact merged GitHub repair did not close')

def prose():
    result,calls,closes=run('Context discusses papercut-fixture');check(not closes,'prose mention closed a record')

def prefix():
    result,calls,closes=run('Papercut: papercut-fixture_more');check(not closes,'longer slug prefix closed a record')

def unmerged():
    result,calls,closes=run(state='CLOSED');check(not closes,'closed unmerged repair closed an ordinary defect')

def record_hold():
    result,calls,closes=run(record_body='Keep-open: the titled claim still fails\n');check(not calls and not closes,'record Keep-open ran a venue read or close')

def pr_hold():
    result,calls,closes=run('Papercut: papercut-fixture\nKeep-open: papercut-fixture');check(not closes and len(calls)==1,'PR Keep-open closed its record')

def pr_other_hold():
    result,calls,closes=run('Papercut: papercut-fixture\nKeep-open: papercut-other');check(closes==['papercut-fixture'],'unrelated PR Keep-open hid the repair')

def canonical_withdrawn():
    result,calls,closes=run(current_body='Papercut: papercut-fixture\nKeep-open: papercut-fixture');check(not closes,'stale search body overruled canonical Keep-open')

def unavailable():
    result,calls,closes=run(search_error=True);check(result['errors'] and not closes,'unavailable search became no-review-ref absence')

def repair_verb():
    result,calls,closes=run('Fixes: papercut-fixture');check(closes==['papercut-fixture'],'exact repair verb was not accepted')

def record_patterns():
    for text in ('This record stays OPEN.\n','The record stays open because the structural remedy did not ship.\n'):
        result,calls,closes=run(record_body=text);check(not calls and not closes,'record retention phrase did not preserve its open claim')

CASES={name:globals()[name] for name in ('merged','prose','prefix','unmerged','record_hold','pr_hold','pr_other_hold','canonical_withdrawn','unavailable','repair_verb','record_patterns')}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('case',nargs='?',choices=CASES);args=p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try:CASES[name]()
        except Exception as error:print('FAIL: '+name+': '+str(error),file=sys.stderr);sys.exit(1)
        print('PASS: '+name)
