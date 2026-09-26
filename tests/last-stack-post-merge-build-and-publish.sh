#!/usr/bin/env bash
# A LastGit-native repo has no Forgejo `publish` job: nothing else runs
# .lastgit/ci.sh and calls `lastgit artifact publish` after a merge. This
# fixture proves the worker builds and publishes the artifact itself from a
# real checkout when no manifest already exists for the merge oid, then
# promotes and refreshes host-track from what it just built (era-3:
# north-star-lastgit-era-3-primary-migration).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-build-publish-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

REAL_GIT="$(command -v git)"
WORKER="$ROOT/bin/last-stack-post-merge-safe-upgrade"

remote="$tmp/search.git"
seed="$tmp/seed"
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/artifacts" "$tmp/log"

git init -q --bare "$remote"
git init -q "$seed"
git -C "$seed" checkout -q -b main
git -C "$seed" config user.name fixture
git -C "$seed" config user.email fixture@example.invalid
mkdir -p "$seed/.lastgit"

cat >"$seed/.lastgit/ci.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p dist
git rev-parse HEAD >dist/app
SH
chmod +x "$seed/.lastgit/ci.sh"

cat >"$seed/.lastgit/artifacts.json" <<'JSON'
{"artifacts": [{"app": "search", "paths": ["dist/app"], "context": "ci-required"}]}
JSON

git -C "$seed" add -A
git -C "$seed" commit -qm initial
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q origin main
oid="$(git -C "$seed" rev-parse HEAD)"

# Real git, with the one addition of understanding lastdb:/// as this bare
# remote — everything else (checkout, rev-parse, ...) passes straight through.
cat >"$tmp/bin/git" <<SH
#!/usr/bin/env bash
set -euo pipefail
REAL_GIT="$REAL_GIT"
if [ "\${1:-}" = clone ]; then
  args=()
  for a in "\$@"; do
    case "\$a" in
      lastdb:///*) args+=("$remote") ;;
      *) args+=("\$a") ;;
    esac
  done
  exec "\$REAL_GIT" "\${args[@]}"
fi
exec "\$REAL_GIT" "\$@"
SH
chmod +x "$tmp/bin/git"

cat >"$tmp/bin/lastgit" <<SH
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}:\${2:-}" in
  cr:list)
    printf '[]\n'
    exit 0
    ;;
  cr:view)
    [ "\$3" = search ] && [ "\$4" = cr-search ] || { echo "unexpected cr view: \$*" >&2; exit 2; }
    cat <<JSON
{"cr_id":"cr-search","repo":"search","state":"merged","base_ref":"refs/heads/main","head_oid":"$oid","merge_oid":"$oid"}
JSON
    exit 0
    ;;
  artifact:publish)
    shift 2
    app="" repo="" oid_arg="" input="" paths=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --app) app="\$2"; shift 2 ;;
        --repo) repo="\$2"; shift 2 ;;
        --oid) oid_arg="\$2"; shift 2 ;;
        --input) input="\$2"; shift 2 ;;
        --paths) paths="\$2"; shift 2 ;;
        --json) shift ;;
        *) shift ;;
      esac
    done
    [ "\$app" = search ] && [ "\$repo" = search ] && [ "\$oid_arg" = "$oid" ] || {
      echo "unexpected publish args: app=\$app repo=\$repo oid=\$oid_arg" >&2; exit 2
    }
    built="\$(cat "\$input/dist/app" 2>/dev/null || true)"
    [ "\$built" = "$oid" ] || { echo "ci.sh did not run before publish (dist/app=\$built)" >&2; exit 2; }
    printf 'publish app=%s repo=%s oid=%s paths=%s\n' "\$app" "\$repo" "\$oid_arg" "\$paths" >>"$tmp/log/calls.log"
    printf '{"manifest_digest":"deadbeef00000000000000000000000000000000000000000000000000000000"}\n'
    exit 0
    ;;
  artifact:promote)
    shift 2
    manifest="" app="" repo="" oid_arg=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --app) app="\$2"; shift 2 ;;
        --manifest) manifest="\$2"; shift 2 ;;
        --repo) repo="\$2"; shift 2 ;;
        --oid) oid_arg="\$2"; shift 2 ;;
        --json) shift ;;
        *) shift ;;
      esac
    done
    [ "\$manifest" = deadbeef00000000000000000000000000000000000000000000000000000000 ] \
      || { echo "promote did not receive the digest published above: \$manifest" >&2; exit 2; }
    printf 'promote app=%s repo=%s oid=%s manifest=%s\n' "\$app" "\$repo" "\$oid_arg" "\$manifest" >>"$tmp/log/calls.log"
    printf '{}\n'
    exit 0
    ;;
esac
echo "unexpected lastgit args: \$*" >&2
exit 2
SH
chmod +x "$tmp/bin/lastgit"

cat >"$tmp/bin/host-track" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = refresh ]; then
  printf 'refresh %s\n' "\$2" >>"$tmp/log/calls.log"
  exit 0
fi
exit 2
SH
chmod +x "$tmp/bin/host-track"

# Cold-seed the open-CR snapshot with the CR already open, then merge it —
# mirrors the main test's departure pattern.
printf 'search:cr-search\n' >"$tmp/state/fleet.open"

PATH="$tmp/bin:$PATH" \
  LASTGIT_ARTIFACT_ROOT="$tmp/artifacts" \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge.log" \
  LAST_STACK_POST_MERGE_CONVERGE=0 \
  "$WORKER" --once --all "$tmp/state" >/dev/null

grep -q "no published search manifest for repo=search oid=$oid; building from source" \
  "$tmp/post-merge.log" || fail "worker did not recognize the missing manifest and try to build"
grep -q "publish app=search repo=search oid=$oid paths=dist/app" "$tmp/log/calls.log" \
  || fail "worker did not publish the artifact it built from source"
grep -q "promote app=search repo=search oid=$oid manifest=deadbeef" "$tmp/log/calls.log" \
  || fail "worker did not promote the manifest it just published"
grep -qx "refresh search" "$tmp/log/calls.log" \
  || fail "worker did not refresh host-track after promoting"
grep -qx 'cr-search' "$tmp/state/search.handled" \
  || fail "search CR was not marked handled after the build+publish+promote path"

printf 'ok: post-merge worker builds and publishes a missing artifact from source\n'
