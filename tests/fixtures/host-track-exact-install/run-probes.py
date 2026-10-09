#!/usr/bin/env python3
"""Run exact assertion-filtered probes with the installed restore helper."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

ap=argparse.ArgumentParser()
ap.add_argument("--output-dir",required=True,type=Path)
ap.add_argument("--patch",required=True,type=Path)
ap.add_argument("--name")
ap.add_argument("--start-at")
args=ap.parse_args()
args.output_dir.mkdir(parents=True,exist_ok=True)
cases=[
("oid-shape","parser-hash","no effect before parser refusal"),
("manifest-shape","parser-manifest","no effect before parser refusal"),
("pair-required","parser-pair","no effect before parser refusal"),
("channel-all-fences","parser-channel","no effect before parser refusal"),
("one-app","parser-multi","no effect before parser refusal"),
("unknown-flag","parser-unknown","no effect before parser refusal"),
("activate-override","parser-activate","no effect before parser refusal"),
("probe-override","parser-probe","no effect before parser refusal"),
("strict-pull-held","pull-held","strict pull no old-channel fallback"),
("strict-pull-failed","pull-failed","strict pull no old-channel fallback"),
("strict-pull-tool","pull-tool-missing","strict pull no old-channel fallback"),
("provenance-status","provenance-status","strict pull no old-channel fallback"),
("provenance-source","pull-source-mismatch","strict pull no old-channel fallback"),
("provenance-manifest","pull-manifest-mismatch","strict pull no old-channel fallback"),
("provenance-channel","provenance-channel","strict pull no old-channel fallback"),
("provenance-tree","bad-provenance","strict pull no old-channel fallback"),
("provenance-platform","provenance-platform","strict pull no old-channel fallback"),
("provenance-run","provenance-run_id","strict pull no old-channel fallback"),
("provenance-artifact","provenance-artifact_id","strict pull no old-channel fallback"),
("provenance-one-object","provenance-multiple","strict pull no old-channel fallback"),
("raw-source","source-mismatch","no target activation"),
("raw-manifest-all-fences","manifest-mismatch","no install stamp publication"),
("fresh-source-all-fences","source-drift","no target activation"),
("fresh-manifest-all-fences","manifest-drift","no install stamp publication"),
("soak-request-retained","soak-success","soak retains exact request"),
("soak-app","soak-request-app","soak changed request no pull"),
("soak-manifest-all-fences","soak-request-manifest","soak changed request no pull"),
("soak-source-all-fences","soak-request-drift","soak changed request no pull"),
("soak-channel","soak-request-channel","soak changed request no pull"),
("no-successor","soak-channel-drift","soak drift no successor pull"),
("json-parent-only","stage-failed","one JSON receipt"),
("json-dependency-stream","dependency-positive","one JSON receipt"),
("installed-stamp","stamp-uncertain","uncertain stamp no success receipt"),
("registry-availability","registry-unavailable","registry unavailable no fallback"),
("match-only-installed","pull-held","no false installed receipt"),
("json-one-result","main-error","one JSON receipt"),
("stamp-app-bound-final","cross-app-soak-complete","ordinary app has no foreign exact authority"),
("stamp-app-bound-soak","cross-app-soak-pending","ordinary app has no foreign exact authority"),
("retained-app-bound","foreign-existing-soak","foreign existing exact authority not retained"),
("retained-matching-app","matching-existing-soak","matching existing exact authority retained"),
]
if args.name and args.name not in {x[0] for x in cases}: raise SystemExit("unknown probe")
if args.start_at and args.start_at not in {x[0] for x in cases}: raise SystemExit("unknown start probe")
start_index = next((i for i, c in enumerate(cases) if c[0] == args.start_at), 0)
receipts=[]
for name,case,assertion in cases[start_index:]:
    if args.name and args.name!=name: continue
    command=[str(Path.home()/".local/bin/last-stack-mutation-probe"),"--name","host-track-exact-"+name,
             "--target","bin/host-track","--patch",shlex.join(["python3",str(args.patch),name]),
             "--test",shlex.join(["python3","tests/host-track-exact-install.py",case]),
             "--expect-red-on","FAIL: "+case+": .*"+assertion]
    result=subprocess.run(command,text=True,capture_output=True)
    path=args.output_dir/(name+".out")
    path.write_text(result.stdout)
    path.with_suffix(".err").write_text(result.stderr)
    receipt={"name":name,"case":case,"expected_assertion":assertion,"exit_code":result.returncode,"stdout":str(path),"stderr":str(path.with_suffix('.err'))}
    receipts.append(receipt)
    (args.output_dir/"receipts.json").write_text(json.dumps(receipts,indent=2)+"\n")
    print(json.dumps(receipt),flush=True)
    if result.returncode: raise SystemExit(result.returncode)
