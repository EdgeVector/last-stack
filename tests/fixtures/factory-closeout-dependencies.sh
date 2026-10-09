#!/usr/bin/env bash
# Private consumer fixtures supply their external contract and batch response.
fixture_closeout_dependencies() {
  local stack="$1" board="$2"
  export BOARD_CLOSEOUT_FIXTURE_BOARD="$board"
  cat > "$stack/bin/last-stack-factory-repair-contract" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"version":1,"result":"ok","contract_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","protected_card_keys":["factory-scoped-dispatch-20261008","factory-guarded-closeout-20261008","factory-canonical-active-counts-20261008","factory-repair-controller-20261009"]}'
SH
  cat > "$stack/bin/last-stack-kanban-show-batch" <<'SH'
#!/usr/bin/env bash
exec "$BOARD_CLOSEOUT_FIXTURE_BOARD" list --column doing --json
SH
  chmod +x "$stack/bin/last-stack-factory-repair-contract" "$stack/bin/last-stack-kanban-show-batch"
}

# Keep the old consumer-only setup above for its existing three callers.
# These fixtures exercise the real public raw23 reader, never a list fallback.
fixture_closeout_native_dependencies() {
  local stack="$1" board="${2:-}"
  fixture_closeout_dependencies "$stack" "$board"
  mkdir -p "$stack/lib"
  cp "$ROOT/bin/last-stack-kanban-show-batch" "$stack/bin/last-stack-kanban-show-batch"
  cp "$ROOT/lib/factory_repair.py" "$stack/lib/factory_repair.py"
  export FACTORY_CLOSEOUT_FIXTURE_NATIVE="$stack/bin/fixture-guarded-snapshot"
  cat > "$FACTORY_CLOSEOUT_FIXTURE_NATIVE" <<'PY'
#!/usr/bin/env python3
import argparse,hashlib,json,os,subprocess,sys
from pathlib import Path
SCALARS = ('slug','title','body','board','column','position','assignee','created_at','created_by','updated_at','db','repo','base','kind','block_status','block_reason','north_star','milestone','pr_url','branch')
ARRAYS = ('tags','deps','surfaces')
SCHEMA = 'a'*64
args=sys.argv[1:]
if '--prepare' in args:
    parser=argparse.ArgumentParser()
    parser.add_argument('--prepare',type=Path,required=True)
    parser.add_argument('--column',action='append',default=[])
    parser.add_argument('--missing',action='append',default=[])
    a=parser.parse_args(args)
    result=subprocess.run([str(a.prepare),'list','--column','doing','--json','--all'],capture_output=True,text=True,check=True)
    rows=json.loads(result.stdout)
    if isinstance(rows,dict): rows=rows['cards']
    Path(str(a.prepare)+'.preview-all.json').write_text(json.dumps(rows))
    overrides=dict(v.split('=',1) for v in a.column)
    records={}
    for row in rows:
        fields={k:'' for k in SCALARS}
        fields.update(board='default',base='main',kind='pr',block_status='none')
        fields.update({k:[] for k in ARRAYS})
        fields.update({k:row[k] for k in SCALARS+ARRAYS if k in row})
        if fields['slug'] in overrides: fields['column']=overrides[fields['slug']]
        assert set(fields)==set(SCALARS+ARRAYS)
        assert all(isinstance(fields[k],str) for k in SCALARS)
        assert all(isinstance(fields[k],list) and all(isinstance(v,str) for v in fields[k]) for k in ARRAYS)
        records[fields['slug']]=fields
    Path(str(a.prepare)+'.cards.json').write_text(json.dumps({'records':records,'missing':a.missing}))
    sys.exit(0)
if '--preview' in args:
    parser=argparse.ArgumentParser()
    parser.add_argument('--preview',type=Path,required=True)
    parser.add_argument('--keys',required=True)
    a=parser.parse_args(args)
    rows=json.loads(Path(str(a.preview)+'.preview-all.json').read_text())
    keys=a.keys.split(',')
    assert len(keys)==len(set(keys)) and set(keys).issubset({r['slug'] for r in rows})
    Path(str(a.preview)+'.preview.json').write_text(json.dumps([r for r in rows if r['slug'] in keys]))
    sys.exit(0)
assert '--cards-file' in args and '--slugs-file' in args and 'guarded-snapshot' in args
file=Path(args[args.index('--cards-file')+1])
keys=json.loads(Path(args[args.index('--slugs-file')+1]).read_text())
assert isinstance(keys,list) and len(keys)==len(set(keys)) and all(isinstance(k,str) for k in keys)
stored=json.loads(file.read_text())
if os.environ.get('BOARD_CALLS'):
    with open(os.environ['BOARD_CALLS'],'a') as log:
        public=args[args.index('guarded-snapshot'):]
        log.write(' '.join(public)+'\n')
items=[]
for key in keys:
    if key in stored['missing'] or key not in stored['records']:
        items.append({'slug':key,'missing':True})
    else:
        text=json.dumps({'version':1,'schema_hash':SCHEMA,'fields':stored['records'][key]},sort_keys=True,separators=(',',':'))+'\n'
        items.append({'slug':key,'snapshot_json':text,'snapshot_sha256':hashlib.sha256(text.encode()).hexdigest()})
print(json.dumps({'version':1,'schema_hash':SCHEMA,'items':items}))
PY
  chmod +x "$stack/bin/last-stack-kanban-show-batch" "$FACTORY_CLOSEOUT_FIXTURE_NATIVE"
}

fixture_closeout_prepare_native_cards() {
  local board="$1"
  shift
  "$FACTORY_CLOSEOUT_FIXTURE_NATIVE" --prepare "$board" "$@"
}

fixture_closeout_select_native_preview() {
  "$FACTORY_CLOSEOUT_FIXTURE_NATIVE" --preview "$1" --keys "$2"
}
