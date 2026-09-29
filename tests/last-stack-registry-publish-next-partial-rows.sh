#!/usr/bin/env bash
# Fixture test for bin/last-stack-registry-publish-next's per-app RED path:
# a RED proof whose fails[] all attribute to named apps writes rows only for
# the apps that had none, instead of the old all-or-nothing GREEN-only gate
# that zeroed out every app (2026-09-28: 6/9 apps genuinely broken zeroed out
# brain, kanban, situations too, which had passed every check of their own).
#
# Uses --dry-run (writes rows in a scratch clone of a local bare tap repo, no
# push, no PR) and a fake `lastdb` that does a real Ed25519-shaped sign/verify
# round trip is not required here -- last-stack-registry-index only checks
# the subprocess exit code -- so the fake just has to exit 0 and, for
# `verify`, agree the file it was asked to check exists. Nothing in this test
# touches the primary LastDB node, the real signing key, or the real forge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-publish-next"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-next-partial-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

apps9="brain kanban situations routines dogfood-graph org lastsecrets search lastdb-browser"

# --- a fake lastdb: exits 0 for the sign/verify shapes publish-next uses ---
cat >"$WORK/lastdb" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2 $3" = "app index sign" ] && [ "${4:-}" = "--help" ]; then
  echo "fake sign help"; exit 0
fi
if [ "$1 $2 $3" = "app index sign" ]; then
  shift 3
  index=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --index) index="$2"; shift 2 ;; *) shift ;; esac
  done
  printf 'fake-signature\n' >"$index.sig"
  exit 0
fi
if [ "$1 $2 $3" = "app index verify" ]; then
  echo '{"status":"ok"}'; exit 0
fi
echo "fake lastdb: unhandled args: $*" >&2
exit 1
FAKE
chmod +x "$WORK/lastdb"

# --- a signing key file; the fake lastdb never reads it, but publish-next
# checks it exists before doing anything else -----------------------------
echo "not-a-real-key" >"$WORK/signing.key"

# --- a bare tap repo with a real registry/next.json on main ----------------
mkdir -p "$WORK/tap-src/registry"
"$ROOT/bin/last-stack-registry-index" init --channel next --out "$WORK/tap-src/registry/next.json" >/dev/null
git init --quiet -b main "$WORK/tap-src"
git -C "$WORK/tap-src" add registry
git -C "$WORK/tap-src" -c user.name=t -c user.email=t@example.com commit --quiet -m seed
git clone --quiet --bare "$WORK/tap-src" "$WORK/tap.git"

# --- a fake Forge API: publish-next posts a PR then a best-effort merge.
# Real PR/merge calls never happen in this test -- the fake just has to hand
# back a PR number so the script's own success/failure path is exercised. ---
cat >"$WORK/forge-api" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do
  if [ "$a" = "--jq" ]; then
    echo 4242
    exit 0
  fi
done
echo '{}'
FAKE
chmod +x "$WORK/forge-api"

# --- a candidate set naming all 9 apps --------------------------------------
python3 - "$apps9" >"$WORK/candidate-set.json" <<'PY'
import json, sys
apps = sys.argv[1].split()
out = {
    "created_at": "2026-09-28T00:00:00Z",
    "lastdb": {"build": "0.23.3-2375-gtest", "api_version": 1},
    "apps": {
        a: {"sha": "0" * 40, "app_version": "1.0.0", "source": "http://forge.local/%s.git" % a, "description": a}
        for a in apps
    },
}
json.dump(out, sys.stdout)
PY

# This test covers the Forgejo PR path (status=pr). Pin that venue, and hand
# lastgit a fake that fails loudly: the LastGit default would otherwise reach
# the real node (tests/last-stack-registry-publish-next-venue.sh covers it).
cat >"$WORK/lastgit" <<'FAKE'
#!/usr/bin/env bash
echo "fake lastgit: this test must not reach LastGit: $*" >&2
exit 97
FAKE
chmod +x "$WORK/lastgit"

run_publish() {
  local proof="$1" run_id="$2" tap_dir="$3"
  shift 3
  LAST_STACK_REGISTRY_TAP_VENUE=forgejo \
  LASTGIT_BIN="$WORK/lastgit" \
  LAST_STACK_REGISTRY_TAP_URL="$WORK/tap.git" \
  LAST_STACK_REGISTRY_TAP_DIR="$tap_dir" \
  LASTDB_REGISTRY_SIGNING_KEY="$WORK/signing.key" \
  LASTDB_BIN="$WORK/lastdb" \
  FORGE_API_BIN="$WORK/forge-api" \
  FORGE_GIT_BIN="$WORK/no-such-forge-git" \
  LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" \
    "$BIN" --candidate-set "$WORK/candidate-set.json" --proof "$proof" \
      --lastdb-bin "$WORK/lastdb" --proof-run "$run_id" "$@"
}

# --- GREEN: unchanged behavior, all 9 rows ----------------------------------
cat >"$WORK/green.json" <<'EOF'
{"verdict":"GREEN","sandbox":"/x","pass":40,"lastdb_build":"0.23.3-2375-gtest","proved_at":"2026-09-28T00:00:00Z"}
EOF
out="$(run_publish "$WORK/green.json" run-green "$WORK/tap-work-green")"
echo "$out" | grep -q '^REGISTRY_NEXT status=pr build=0.23.3-2375-gtest apps=9 ' || fail "GREEN: expected apps=9, got: $out"
for a in $apps9; do
  jq -e --arg a "$a" '.apps[] | select(.app_id==$a)' "$WORK/tap-work-green/registry/next.json" >/dev/null ||
    fail "GREEN: $a is missing a row"
done

# --- RED, isolated to 6 apps: brain/kanban/situations still get rows -------
cat >"$WORK/isolated.json" <<'EOF'
{"verdict":"RED","sandbox":"/x","lastdb_build":"0.23.3-2375-gtest","fails":[
  "install-apps:routines:proved (wanted proved; lastdb=none)",
  "install-apps:org:proved",
  "install-apps:dogfood-graph:proved",
  "install-apps:lastsecrets:proved",
  "install-apps:search:proved",
  "install-apps:lastdb-browser:proved"
]}
EOF
out="$(run_publish "$WORK/isolated.json" run-partial "$WORK/tap-work-partial")"
echo "$out" | grep -q '^REGISTRY_NEXT status=pr build=0.23.3-2375-gtest apps=3 ' || fail "partial: expected apps=3, got: $out"
dir="$WORK/tap-work-partial"
for a in brain kanban situations; do
  jq -e --arg a "$a" '.apps[] | select(.app_id==$a)' "$dir/registry/next.json" >/dev/null ||
    fail "partial: $a is missing a row in the written index"
done
for a in routines org dogfood-graph lastsecrets search lastdb-browser; do
  jq -e --arg a "$a" '.apps[] | select(.app_id==$a)' "$dir/registry/next.json" >/dev/null &&
    fail "partial: $a should NOT have a row"
done
jq -e '.partial == true' "$dir/registry/proofs/run-partial.json" >/dev/null ||
  fail "partial: proof record does not say partial:true"
jq -e '.apps_proved == ["brain","kanban","situations"]' "$dir/registry/proofs/run-partial.json" >/dev/null ||
  fail "partial: proof record apps_proved is wrong: $(jq -c .apps_proved "$dir/registry/proofs/run-partial.json")"

# --- RED, shared fail: zero rows, non-zero exit, nothing pushed ------------
cat >"$WORK/shared.json" <<'EOF'
{"verdict":"RED","sandbox":"/x","lastdb_build":"0.23.3-2375-gtest","fails":["daemon:socket never appeared"]}
EOF
if run_publish "$WORK/shared.json" run-shared "$WORK/tap-work-shared" >"$WORK/shared.out" 2>"$WORK/shared.err"; then
  fail "shared-fail RED should have failed; wrote: $(cat "$WORK/shared.out")"
fi
grep -q "shared/cross-cutting" "$WORK/shared.err" || fail "shared-fail RED: wrong error: $(cat "$WORK/shared.err")"
tap_rows_after="$(git -C "$WORK/tap.git" log --all --oneline | grep -c 'proved by run-shared' || true)"
[ "$tap_rows_after" -eq 0 ] || fail "shared-fail RED: a branch for run-shared reached the tap repo"

# --- --strict-green forces the old behavior even on an isolated RED --------
if run_publish "$WORK/isolated.json" run-strict "$WORK/tap-work-strict" --strict-green \
    >"$WORK/strict.out" 2>"$WORK/strict.err"; then
  fail "--strict-green on a RED proof should have failed"
fi
grep -q "strict-green requires GREEN" "$WORK/strict.err" || fail "--strict-green: wrong error: $(cat "$WORK/strict.err")"

echo "OK: last-stack-registry-publish-next-partial-rows"
