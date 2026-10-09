#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import shlex
import subprocess

ap=argparse.ArgumentParser()
ap.add_argument('--output-dir',required=True,type=Path)
ap.add_argument('--patch',required=True,type=Path)
ap.add_argument('--name')
ap.add_argument('--start-at')
a=ap.parse_args()
cases=[
('exact-json-argv','test_public_hosttrack_passes_real_json_argv','actual public JSON argv produces exact receipt'),
('same-head-gates','test_same_head_failed_ci_has_zero_effects','same-head failed CI refuses'),
('text-fast-current','test_text_same_head_keeps_fast_no_zip_status','ordinary text same-head performs zero ZIP downloads'),
('text-signature-current','test_text_same_head_unsigned_repeats_sign_gates','unsigned ordinary text repeats signing gates'),
('canonical-reuse','test_distinct_clock_cross_channel_reuses_canonical','canonical build bytes remain immutable'),
('identity-schema-type','test_wrong_canonical_schema_type','wrong canonical schema_version has zero publication'),
('identity-schema-version','test_wrong_canonical_schema','wrong canonical schema_version has zero publication'),
('identity-app','test_wrong_canonical_app','wrong canonical app has zero publication'),
('identity-repo','test_wrong_canonical_repo','wrong canonical repo has zero publication'),
('identity-source','test_wrong_canonical_source','wrong canonical source_oid has zero publication'),
('identity-platform','test_wrong_canonical_platform','wrong canonical platform has zero publication'),
('digest-format','test_direct_canonical_digest_guard','canonical digest format refuses before a verified receipt'),
('tuple-path','test_wrong_canonical_path','wrong canonical tuple path has zero publication'),
('tuple-sha','test_wrong_canonical_sha','wrong canonical sha has zero publication'),
('tuple-size','test_wrong_canonical_size','wrong canonical tuple size has zero publication'),
('tuple-mode','test_wrong_canonical_mode','wrong canonical tuple mode has zero publication'),
('tuple-list','test_tuple_guard_list','tuple-list typed refusal'),
('tuple-item','test_tuple_guard_item','tuple-item typed refusal'),
('tuple-fields','test_tuple_guard_field_set','tuple-fields typed refusal'),
('tuple-type-path','test_tuple_guard_path_type','tuple-path-type typed refusal'),
('tuple-type-digest','test_tuple_guard_digest_type','tuple-digest-type typed refusal'),
('tuple-type-size','test_tuple_guard_size_type','tuple-size-type typed refusal'),
('tuple-type-mode','test_tuple_guard_mode_type','tuple-mode-type typed refusal'),
('tuple-digest-format','test_tuple_guard_digest_format','tuple-digest-format typed refusal'),
('tuple-size-range','test_tuple_guard_size_range','tuple-size-range typed refusal'),
('tuple-mode-range','test_tuple_guard_mode_range','tuple-mode-range typed refusal'),
('tuple-duplicate','test_tuple_guard_duplicate','tuple-duplicate typed refusal'),
('tuple-safe-path','test_tuple_guard_safe_path','tuple-safe-path typed refusal'),
('canonical-equality','test_canonical_build_manifest_disagree','canonical build disagreement has zero publication'),
('canonical-verify-all-fences','test_canonical_verify_failure_has_zero_effects','failed public canonical verify has zero publication'),
('canonical-json-duplicate','test_duplicate_canonical_json_key','duplicate canonical JSON key has zero publication'),
('canonical-no-follow','test_symlink_canonical_build','canonical symlink has zero publication'),
('canonical-nonblock','test_fifo_canonical_build_refuses_promptly','canonical FIFO refuses promptly without a writer'),
('canonical-regular','test_direct_nonregular_stat_guard','nonregular stat refuses before JSON acceptance'),
('canonical-byte-cap-all-fences','test_oversize_canonical_build','canonical byte cap has zero publication'),
('canonical-read-byte-cap','test_direct_read_byte_cap_guard','grown canonical file refuses at the read byte cap'),
]
if a.name and a.name not in {x[0] for x in cases}:raise SystemExit('unknown probe')
start=next(i for i,x in enumerate(cases) if x[0]==a.start_at) if a.start_at else 0
a.output_dir.mkdir(parents=True,exist_ok=True)
receipts=[]
for name,case,assertion in cases[start:]:
    if a.name and a.name!=name:continue
    target='bin/host-track' if name=='exact-json-argv' else 'bin/last-stack-github-artifact-pull'
    command=[str(Path.home()/'.local/bin/last-stack-mutation-probe'),'--name','artifact-reuse-'+name,
      '--target',target,'--patch',shlex.join(['python3',str(a.patch),name]),
      '--test',shlex.join(['env','PYTHONDONTWRITEBYTECODE=1','python3','tests/last-stack-github-artifact-pull.py','CanonicalReuseTests.'+case]),
      '--expect-red-on',assertion]
    r=subprocess.run(command,text=True,capture_output=True)
    out=a.output_dir/(name+'.out');out.write_text(r.stdout);out.with_suffix('.err').write_text(r.stderr)
    receipt={'name':name,'case':case,'target':target,'expected_assertion':assertion,'exit_code':r.returncode,'stdout':str(out),'stderr':str(out.with_suffix('.err'))}
    receipts.append(receipt);(a.output_dir/'receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
    print(json.dumps(receipt),flush=True)
    if r.returncode:raise SystemExit(r.returncode)
