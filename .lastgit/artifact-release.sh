#!/usr/bin/env bash
# Publish and promote the Last Stack Host Track payload after a merge to main.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

if [ "${LASTGIT_CI_CONTEXT:-}" != "artifact-release" ]; then
  echo "artifact-release.sh must run as the artifact-release LastGit context" >&2
  exit 2
fi
if [ "${LASTGIT_CI_REPO:-}" != "last-stack" ]; then
  echo "artifact-release.sh must run for the last-stack LastGit repo" >&2
  exit 2
fi

oid="${LASTGIT_CI_OID:-}"
if [[ ! "$oid" =~ ^[0-9a-f]{40}$ ]]; then
  echo "artifact-release.sh requires LASTGIT_CI_OID" >&2
  exit 2
fi
head_oid="$(git rev-parse HEAD)"
if [ "$head_oid" != "$oid" ]; then
  echo "artifact-release.sh checkout does not match LASTGIT_CI_OID" >&2
  exit 2
fi

lastgit_bin="${LASTGIT_BIN:-}"
if [ -z "$lastgit_bin" ]; then
  lastgit_bin="$(command -v lastgit || true)"
fi
[ -x "$lastgit_bin" ] || {
  echo "artifact-release.sh cannot find an executable lastgit" >&2
  exit 2
}

config="$ROOT/.lastgit/artifacts.json"
app="$(jq -r '.artifacts[] | select(.app == "last-stack" and .context == "artifact-release") | .app' "$config")"
paths="$(jq -r '.artifacts[] | select(.app == "last-stack" and .context == "artifact-release") | .paths | join(",")' "$config")"
[ "$app" = "last-stack" ] && [ -n "$paths" ] || {
  echo "artifact-release.sh has no last-stack artifact-release configuration" >&2
  exit 2
}

# Last Stack needs no compile step. Validate the runtime tree before publish.
for required in VERSION setup bin config docs harness hooks instructions lib routines skills templates launchd; do
  [ -e "$ROOT/$required" ] || {
    echo "artifact-release.sh payload is missing $required" >&2
    exit 1
  }
done
[ -x "$ROOT/setup" ] && [ -x "$ROOT/bin/host-track" ] || {
  echo "artifact-release.sh payload has no executable setup or host-track" >&2
  exit 1
}

publish_json="$(
  "$lastgit_bin" artifact publish \
    --app "$app" \
    --repo last-stack \
    --oid "$oid" \
    --input "$ROOT" \
    --paths "$paths" \
    --json
)"
digest="$(printf '%s\n' "$publish_json" | jq -r '.manifest_digest // empty')"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
  echo "artifact-release.sh publish returned no manifest digest" >&2
  exit 1
}
printf 'published %s manifest=%s oid=%s\n' "$app" "$digest" "$oid"

# The required gate can finish after this fast package job. Wait for its row.
max_attempts="${LAST_STACK_ARTIFACT_RELEASE_MAX_ATTEMPTS:-330}"
retry_seconds="${LAST_STACK_ARTIFACT_RELEASE_RETRY_SECONDS:-10}"
case "$max_attempts:$retry_seconds" in
  *[!0-9:]*|:*|*:) echo "artifact release retry settings must be whole numbers" >&2; exit 2 ;;
esac
[ "$max_attempts" -gt 0 ] || {
  echo "artifact release max attempts must be positive" >&2
  exit 2
}

promoted=0
for ((attempt=1; attempt<=max_attempts; attempt++)); do
  if "$lastgit_bin" artifact promote \
      --app "$app" \
      --channel stable \
      --manifest "$digest" \
      --repo last-stack \
      --oid "$oid" \
      --gate lastgit \
      --context ci-required; then
    promoted=1
    break
  fi
  printf 'promote attempt %s/%s did not pass ci-required; retry follows\n' \
    "$attempt" "$max_attempts" >&2
  [ "$attempt" -eq "$max_attempts" ] || [ "$retry_seconds" -eq 0 ] || sleep "$retry_seconds"
done
[ "$promoted" -eq 1 ] || {
  echo "artifact-release.sh could not promote stable" >&2
  exit 1
}

echo "last-stack artifact release PASSED"
