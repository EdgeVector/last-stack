#!/usr/bin/env python3
"""Native owner-query protocol against a private Unix socket only."""
import argparse
import http.server
import json
import os
import socketserver
import sys
import tempfile
import threading
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'lib'))
import factory_repair as f

class Server(socketserver.ThreadingMixIn,socketserver.UnixStreamServer):
    daemon_threads=True

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.calls.append((self.path,request))
        flt=request['filter'];mode=self.server.mode
        if 'HashKey' in flt:
            status=flt['HashKey'];ident='lx-20261008T191927.569-'+status+'-1'
            sort='land-card#2026-10-08T19:19:27.569Z#'+ident
            key={'hash':'wrong' if mode=='wrong-hash' else status,'range':'foreign' if mode=='wrong-range' else sort}
            rows=[{'key':key,'fields':{'id':ident,'definition_name':'land-card','by_status_sort':sort}}]
            if mode=='empty-page':rows=[]
        else:
            keys=[key for key,range_value in flt['HashRangeKeys']]
            rows=[{'key':{'hash':key,'range':None},'fields':{'id':key,'definition_name':'land-card','status':'running','state':'IMPLEMENT','updated_at':'r1'}} for key in keys]
            if mode=='missing':rows=rows[:-1]
            if mode=='duplicate':rows[-1]=rows[0]
        reply={'ok':True,'has_more':mode in ('truncated','empty-page'),'results':rows,'next_cursor':'foreign' if mode=='cursor' else None,
               'unresolved_rows':1 if mode=='unresolved' else (False if mode=='bool-counter' else 0),
               'returned_count':len(rows),'total_count':None,'tombstoned_rows':0}
        if mode in ('failed-rows', 'tombstoned-rows'): reply[mode.replace('-', '_')] = 1
        if mode == 'truncated-flag': reply['truncated'] = True
        if mode in ('row-error', 'row-unresolved', 'row-tombstoned'):
            rows[0][mode[4:]] = 'failure' if mode == 'row-error' else True
        if mode=='slow':time.sleep(.15)
        data=json.dumps(reply).encode()
        try:
            self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers()
        except (BrokenPipeError,ConnectionResetError): return
        if mode=='trickle':
            try:
                for index in range(0,len(data),16):
                    self.wfile.write(data[index:index+16]);self.wfile.flush();time.sleep(.02)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass

def fixture(mode,action):
    directory=Path(tempfile.mkdtemp(prefix='factory-native-wire-'));path=directory/'private.sock'
    server=Server(str(path),Handler);server.calls=[];server.mode=mode;path.chmod(0o600)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    config={'owner_socket':str(path),'schema_map':str(directory/'hashes.json'),
            'loom_schemas':{'LoomExecution':'a'*64,'LoomExecutionByStatus':'b'*64}}
    f.atomic_json(directory/'hashes.json',config['loom_schemas'])
    try:return action(config,server)
    finally:server.shutdown();server.server_close();thread.join(2)

def check(value,message):
    if not value:raise AssertionError(message)

def refused(call,message):
    try:call()
    except (f.Refusal,OSError,ValueError):return
    raise AssertionError(message)

def wire():
    def action(config,server):
        rows=f.canonical_execution_batch(config,['lx-a','lx-b'])
        check([row['id'] for row in rows]==['lx-a','lx-b'],'native collected-ID read lost a requested key')
        check(len(server.calls)==1,'native canonical read used one call per ID')
        route,body=server.calls[0]
        check(route=='/api/query' and body['schema_name']=='a'*64 and body['filter']=={'HashRangeKeys':[['lx-a',''],['lx-b','']]},'native exact query wire changed')
    fixture('ok',action)

def mixed_hashes():
    def action(config,server):
        keys=f.active_candidate_keys(config)
        check(len(keys)==3 and len(server.calls)==3 and {body['filter']['HashKey'] for route,body in server.calls}==f.ACTIVE,'supported active-hash reads lost a hash')
        check(all(route=='/api/query' and body['fields']==['id','definition_name','by_status_sort'] for route,body in server.calls),'native status wire lost the supported fields')
    fixture('ok',action)

def negative(mode,membership=False):
    fixture(mode,lambda config,server:refused(lambda:f.active_candidate_keys(config) if membership else f.canonical_execution_batch(config,['lx-a','lx-b']),mode+' native response inferred absence or success'))

def deadline():
    previous=f.DEADLINE;f.set_deadline(.03);start=time.monotonic()
    try:fixture('slow',lambda config,server:refused(lambda:f.canonical_execution_batch(config,['lx-a']),'shared owner-query deadline did not refuse'))
    finally:f.DEADLINE=previous
    check(time.monotonic()-start<2,'shared owner query ran beyond its bounded fixture deadline')

def trickle():
    def action(config,server):
        previous=f.DEADLINE;f.set_deadline(.06);start=time.monotonic()
        try:
            refused(lambda:f.canonical_execution_batch(config,['lx-a']),'continuous native body escaped the total deadline')
            check(time.monotonic()-start<.25,'detached native wire escaped the total deadline')
        finally:f.DEADLINE=previous
    fixture('trickle',action)

CASES={'wire':wire,'mixed_hashes':mixed_hashes,'deadline':deadline,'trickle':trickle}
for mode in ('missing','duplicate','unresolved','bool-counter','truncated', 'failed-rows', 'tombstoned-rows', 'truncated-flag', 'row-error', 'row-unresolved', 'row-tombstoned'):
    CASES[mode]=lambda mode=mode:negative(mode)
CASES['wrong-hash']=lambda:negative('wrong-hash',True)
CASES['wrong-range']=lambda:negative('wrong-range',True)
CASES['cursor']=lambda:negative('cursor',True)
CASES['empty-page']=lambda:negative('empty-page',True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('case',nargs='?',choices=CASES);args=p.parse_args()
    for name in ([args.case] if args.case else CASES):
        try:CASES[name]()
        except Exception as error:print('FAIL: '+name+': '+str(error),file=sys.stderr);sys.exit(1)
        print('PASS: '+name)
