#!/usr/bin/env python3
from pathlib import Path
import sys

name=sys.argv[1]
path=Path('bin/host-track' if name=='exact-json-argv' else 'bin/last-stack-github-artifact-pull')
s=path.read_text()
def change(old,new,count=1):
    global s
    assert s.count(old)==count,(name,old,s.count(old),count)
    s=s.replace(old,new)

if name=='exact-json-argv':
    change('--oid "$expected_oid" --json)', '--oid "$expected_oid")')
elif name=='same-head-gates':
    change('if head == oid and not args.json:', 'if head == oid:')
elif name=='text-fast-current':
    change('if head == oid and not args.json:', 'if False:')
elif name=='text-signature-current':
    change('if not specs or channel_is_signed(root, args.app, args.channel, specs, args.codesign):', 'if True:')
elif name=='canonical-reuse':
    change('manifest = reuse_canonical_manifest(root, args.app, name, oid, plat, exp_files, bool(pre_sign), lg)', 'manifest = None')
elif name.startswith('identity-'):
    choices={
      'schema-type':('type(manifest.get("schema_version")) is not int','False'),
      'schema-version':('manifest["schema_version"] != 1','False'),
      'app':('manifest.get("app") != app','False'),
      'repo':('manifest.get("repo") != repo_name','False'),
      'source':('or manifest.get("source_oid") != oid\n','or False\n'),
      'platform':('manifest.get("platform") != plat','False')}
    change(*choices[name.removeprefix('identity-')])
elif name=='digest-format':
    change('''    if (not isinstance(digest, str) or len(digest) != 64
            or any(c not in "0123456789abcdef" for c in digest)):
''','    if False:\n')
elif name in ['tuple-path','tuple-sha','tuple-size','tuple-mode']:
    change('if canonical_file_tuples(manifest) != expected:', 'if False:')
elif name=='tuple-list':
    change('if not isinstance(files, list) or not files:', 'if False:')
elif name in ['tuple-item','tuple-fields']:
    change('if not isinstance(item, dict) or set(item) != {"path", "sha256", "size", "mode"}:','if False:')
elif name.startswith('tuple-type-'):
    change(*{
      'path':('not isinstance(path, str)', 'False'),
      'digest':('not isinstance(digest, str)\n                or len(digest)', 'False\n                or len(digest)'),
      'size':('type(size) is not int', 'False'),
      'mode':('type(mode) is not int', 'False')
    }[name.removeprefix('tuple-type-')])
elif name=='tuple-digest-format':
    change('any(c not in "0123456789abcdef" for c in digest)\n                or type(size)', 'False\n                or type(size)')
elif name=='tuple-size-range':change('size < 0','False')
elif name=='tuple-mode-range':change('not 0 <= mode <= 0o777','False')
elif name=='tuple-duplicate':change('if path in seen:', 'if False:')
elif name=='tuple-safe-path':change('        safe_rel(path)\n','')
elif name=='canonical-equality':change('if canonical != manifest:', 'if False:')
elif name=='canonical-verify-all-fences':
    change('    lastgit(lg, "verify", "--manifest", digest, "--root", root, "--json")\n','')
    change('        lastgit(lg, "verify", "--manifest", mdigest, "--root", root, "--json")\n','')
elif name=='canonical-json-duplicate':change('if key in result:', 'if False:')
elif name=='canonical-no-follow':change(' | os.O_NOFOLLOW','')
elif name=='canonical-nonblock':change(' | os.O_NONBLOCK','')
elif name=='canonical-regular':change('not stat.S_ISREG(info.st_mode)', 'False')
elif name=='canonical-byte-cap-all-fences':
    change('info.st_size > CANONICAL_MANIFEST_MAX_BYTES','False')
    change('fh.read(CANONICAL_MANIFEST_MAX_BYTES + 1)','fh.read()')
    change('len(data) > CANONICAL_MANIFEST_MAX_BYTES','False')
elif name=='canonical-read-byte-cap':change('len(data) > CANONICAL_MANIFEST_MAX_BYTES','False')
else:raise SystemExit('unknown probe: '+name)
path.write_text(s)
