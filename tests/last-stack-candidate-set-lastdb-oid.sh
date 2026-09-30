#!/usr/bin/env bash
# The candidate set records the real source oid of the lastdb build, for a
# released tarball (manifest source_git_oid) and for a built binary (--lastdb-oid),
# and refuses an oid that the build string does not name. Fixture only, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-candidate-set"
work="$(mktemp -d "${TMPDIR:-/tmp}/candidate-set-oid.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$work/home"
mkdir -p "$HOME" "$work/rel" "$work/built"

src="$work/src"
git init --quiet -b main "$src"
printf '{"name":"x","version":"1.0.0"}\n' >"$src/package.json"
git -C "$src" add package.json
git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet -m v1
git clone --quiet --bare "$src" "$work/app.git"
jq -n --arg w "$work" '{apps: {a: {github: ($w + "/app.git"), public: "https://github.com/EdgeVector/a.git",
  artifact_app: null, install_name: "a"}}}' >"$work/apps.json"

OID=be41e547e901f835fff7ad09bcc3a8f4df8265e0
BUILD=0.23.3-2378-gbe41e547e
for d in rel built; do
  printf '#!/bin/sh\necho "lastdbd %s"\n' "$BUILD" >"$work/$d/lastdbd"
  chmod +x "$work/$d/lastdbd"
done

run_set() {
  local out="$1" bin="$2"
  shift 2
  PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" "$BIN" --lastdbd "$bin" --apps-config "$work/apps.json" \
    --artifact-root "$work/artifacts" --cache-root "$work/cache" --no-version-lookup \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

# 1. release: oid from a manifest that sits outside the bin dir
jq -n --arg o "$OID" '{source_git_oid: $o}' >"$work/dl-manifest.json"
run_set "$work/rel.json" "$work/rel/lastdbd" --lastdb-manifest "$work/dl-manifest.json" || { cat "$work/rel.json.stderr" >&2; fail "release run"; }
[ "$(jq -r .lastdb.oid "$work/rel.json")" = "$OID" ] || fail "release oid not recorded"
[ "$(jq -r .lastdb.oid_source "$work/rel.json")" = manifest ] || fail "release oid_source"

# 2. built binary: oid from the flag
run_set "$work/built.json" "$work/built/lastdbd" --lastdb-oid "$OID" || { cat "$work/built.json.stderr" >&2; fail "built run"; }
[ "$(jq -r .lastdb.oid "$work/built.json")" = "$OID" ] || fail "built oid not recorded"
[ "$(jq -r .lastdb.oid_source "$work/built.json")" = flag ] || fail "built oid_source"
[ "$(jq -r .lastdb.build "$work/built.json")" = "$BUILD" ] || fail "build not recorded"

# 3. an oid the build does not name is refused
if run_set "$work/bad.json" "$work/built/lastdbd" --lastdb-oid 1111111111111111111111111111111111111111; then
  fail "a mismatched oid must be refused"
fi
grep -q 'does not match build' "$work/bad.json.stderr" || fail "no mismatch reason: $(cat "$work/bad.json.stderr")"
if run_set "$work/short.json" "$work/built/lastdbd" --lastdb-oid be41e547e; then
  fail "a short oid must be refused"
fi

# 4. no oid source: empty oid, not an error (unchanged default)
run_set "$work/none.json" "$work/built/lastdbd" || fail "no-oid run"
[ "$(jq -r .lastdb.oid "$work/none.json")" = "" ] || fail "oid must be empty with no source"

# 5. the smoke verdict JSON carries lastdb_build and lastdb_oid on RED and GREEN
RUN="$ROOT/skills/llms-txt-install-smoke/run.sh"
n="$(grep -c '"lastdb_build":"%s","lastdb_oid":"%s"' "$RUN")"
[ "$n" -eq 2 ] || fail "run.sh must emit lastdb_build and lastdb_oid on both verdicts (found $n)"

echo "ok last-stack-candidate-set-lastdb-oid"
