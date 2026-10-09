#!/usr/bin/env python3
"""One exact defect per named HostTrack guard probe. Mutates only bin/host-track."""
from pathlib import Path
import sys

p = Path("bin/host-track")
s = p.read_text()
name = sys.argv[1]

def change(old, new, count=1):
    global s
    assert s.count(old) == count, (name, old, s.count(old), count)
    s = s.replace(old, new)

if name == "oid-shape": change('[[ "$expected_oid" =~ ^[0-9a-f]{40}$ ]]', 'true')
elif name in ["manifest-shape", "pair-required"]:
    change('[[ "$expected_manifest" =~ ^[0-9a-f]{64}$ ]]', 'true')
    if name == "manifest-shape":
        # The existing internal validator protects the same SHA shape.
        change('if [ -n "$expected_digest" ] && [[ ! "$expected_digest" =~ ^[0-9a-f]{64}$ ]]; then', 'if false; then')
elif name == "channel-all-fences": change('case "$channel" in candidate|canary|stable) ;; *) die "invalid artifact channel: $channel" ;; esac', ':', 3)
elif name == "one-app": change('[ -z "$app" ] || die "install accepts one app"', ':')
elif name == "unknown-flag": change('--*) die "unknown install flag: $1" ;;', '--*) shift ;;')
elif name == "activate-override": change('[ "${HOST_TRACK_ACTIVATE:-0}" != 1 ] && ', '')
elif name == "probe-override": change(' && [ "${HOST_TRACK_PROBE_SKIP:-0}" != 1 ]', '')
elif name == "strict-pull-held": change('3) EXACT_INSTALL_CODE=pull_held; return 75 ;;', '3) EXACT_INSTALL_CODE=pull_held; return 0 ;;')
elif name == "strict-pull-failed": change('*) EXACT_INSTALL_CODE=pull_failed; return 1 ;;', '*) EXACT_INSTALL_CODE=pull_failed; return 0 ;;')
elif name == "strict-pull-tool": change('if [ -n "$expected_oid" ]; then EXACT_INSTALL_CODE=pull_tool_missing; return 1; fi', ':')
elif name == "provenance-status": change('.status == "promoted"', 'true')
elif name == "provenance-source": change('.oid == $oid', 'true')
elif name == "provenance-manifest": change('.oid == $oid and .manifest_digest == $digest\n', '.oid == $oid and true\n')
elif name == "provenance-channel": change('.channel == $channel', 'true')
elif name == "provenance-tree": change('(.tree_oid | type == "string" and test("^[0-9a-f]{40}$"))', 'true')
elif name == "provenance-platform": change('(.platform | type == "string" and length > 0)', 'true')
elif name == "provenance-run": change('(.run_id | type == "number" and . > 0 and floor == .)', 'true')
elif name == "provenance-artifact": change('(.artifact_id | type == "number" and . > 0 and floor == .)', 'true')
elif name == "provenance-one-object": change('length == 1 and (.[0] |', 'length > 0 and (.[-1] |')
elif name == "raw-source": change('if [ "$source" != "$EXACT_INSTALL_OID" ]; then', 'if false; then')
elif name == "raw-manifest-all-fences":
    change('if [ "$digest" != "$EXACT_INSTALL_MANIFEST" ]; then', 'if false; then')
    change('if [ -n "$expected_digest" ] && [ "$digest" != "$expected_digest" ]; then', 'if false; then')
    change('if [ "$latest_digest" != "$expected_digest" ]; then', 'if false; then')
elif name in ["fresh-source-all-fences", "fresh-manifest-all-fences"]:
    old='''  if [ -n "$expected_oid" ]; then
    latest_manifest="$(artifact_desired_manifest "$app" "$json" "$artifact_app" "$channel" "$artifact_root" || true)"
    if ! exact_install_manifest_matches "$latest_manifest"; then'''
    change(old, old.replace('if [ -n "$expected_oid" ]; then', 'if false; then', 1))
    change('if [ -n "$expected_oid" ] && ! exact_install_manifest_matches "$latest_manifest"; then', 'if false; then')
    if name == "fresh-manifest-all-fences": change('if [ "$latest_digest" != "$expected_digest" ]; then', 'if false; then')
elif name == "soak-request-retained": change('+ (if $exact_request == null then {} else {exact_request:$exact_request,exact_official:$exact_official} end)', '')
elif name == "soak-app": change('type == "object" and .app == $app and .manifest_sha256 == $digest', 'type == "object" and .manifest_sha256 == $digest')
elif name == "soak-manifest-all-fences":
    change('type == "object" and .app == $app and .manifest_sha256 == $digest', 'type == "object" and .app == $app')
    change(' and .exact_official.manifest_sha256 == $request.manifest_sha256', '')
elif name == "soak-source-all-fences":
    change('''      || [ "$(jq -r '.source_oid // empty' "$(soak_stamp_path "$app")")" != "$(printf '%s' "$exact_request" | jq -r '.source_oid')" ] \\
''', '')
    change('.exact_official.source_oid == $request.source_oid and ', '')
elif name == "soak-channel": change(' and .exact_official.channel == $request.channel', '')
elif name == "no-successor": change('''    if [ -n "$exact_oid" ]; then
      printf 'host-track: %s exact soak activation refused; retaining request and current\\n' "$app" >&2
      return 75
    fi
''', '')
elif name == "json-parent-only": change('  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0\n', '')
elif name == "json-dependency-stream": change('if [ "$EXACT_INSTALL_JSON" = 1 ]; then ensure_requires_installed "$app" >&2; else ensure_requires_installed "$app"; fi', 'ensure_requires_installed "$app"')
elif name == "installed-stamp":
    old='''    if [ "$(readlink "$install_root/current" 2>/dev/null || true)" != "versions/$expected_digest" ] \\
      || ! jq -e --arg oid "$expected_oid" --arg digest "$expected_digest" --arg tree "$(printf '%s' "$EXACT_INSTALL_OFFICIAL" | jq -r '.tree_oid')" \\
        '.source_oid == $oid and .manifest_digest == $digest and .tree_oid == $tree' "$stamp_path" >/dev/null \\
      || ! verify_active_artifact "$app" "$json"; then
      EXACT_INSTALL_CODE=installed_verification_failed
      finish_artifact_install_lock "$reuse_install_lock"
      return 1
    fi
'''
    change(old, '')
elif name == "registry-availability": change('''    if ! command -v lastdb >/dev/null 2>&1 || ! lastdb app resolve --help >/dev/null 2>&1; then''', '    if false; then')
elif name == "match-only-installed": change('if [ "$result" = installed ] && [ "$EXACT_INSTALL_INSTALLED" != null ]; then match=true; fi', 'match=true')
elif name == "json-one-result": change('[ "$EXACT_INSTALL_JSON" = 1 ] && [ "$EXACT_INSTALL_EMITTED" = 0 ] || return 0', '[ "$EXACT_INSTALL_JSON" = 1 ] || return 0')
elif name in ["stamp-app-bound-final", "stamp-app-bound-soak"]:
    change(' || { [ -n "$app" ] && [ "$EXACT_INSTALL_APP" != "$app" ]; }', '')
elif name == "retained-app-bound":
    change('if .exact_request.app == $app then .exact_request else null end', '.exact_request // null')
elif name == "retained-matching-app":
    change('if .exact_request.app == $app then .exact_request else null end', 'null')
else: raise SystemExit("unknown probe: " + name)
p.write_text(s)
