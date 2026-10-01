#!/usr/bin/env bash
# bin/last-stack-registry-proof-plan: the cheap plan step of the scheduled
# registry-proof workflow. Fixture only: no network, no lastdb binary.
#   - the target build is the build of the newest `next` row, or the override
#   - a head that equals the pin `next` holds for the build is not moved
#   - an app with no row for the build is moved
#   - the fingerprint changes when any head changes
#   - bin/last-stack-canary-candidate-set --lastdb-build needs no lastdbd
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLAN="$ROOT/bin/last-stack-registry-proof-plan"
SET="$ROOT/bin/last-stack-canary-candidate-set"
work="$(mktemp -d "${TMPDIR:-/tmp}/proof-plan.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

B_OLD=0.23.3-2375-ga7bac36f1
B_NEW=0.23.3-2378-gbe41e547e
A1=1111111111111111111111111111111111111111
A2=2222222222222222222222222222222222222222
A3=3333333333333333333333333333333333333333

jq -n --arg o "$B_OLD" --arg n "$B_NEW" --arg a1 "$A1" --arg a2 "$A2" '{
  index_version: 1, channel: "next", apps: [
    {app_id: "alpha", source: "s", compat: [
      {sha: $a1, lastdb_version: $o, proved_at: "2026-09-28T00:00:00Z", proof_run: "p1", app_version: "1"},
      {sha: $a1, lastdb_version: $n, proved_at: "2026-09-29T00:00:00Z", proof_run: "p2", app_version: "1"}]},
    {app_id: "beta", source: "s", compat: [
      {sha: $a2, lastdb_version: $o, proved_at: "2026-09-28T00:00:00Z", proof_run: "p1", app_version: "1"}]}
  ]}' >"$work/next.json"

# 1. newest build is B_NEW (alpha's newest row), source next-newest
out="$("$PLAN" select-build --index "$work/next.json")"
[ "$(jq -r .build <<<"$out")" = "$B_NEW" ] || fail "newest build: $out"
[ "$(jq -r .source <<<"$out")" = next-newest ] || fail "source: $out"

# 2. override wins; a null target does not
echo '{"target": null}' >"$work/ov-null.json"
out="$("$PLAN" select-build --index "$work/next.json" --override "$work/ov-null.json")"
[ "$(jq -r .build <<<"$out")" = "$B_NEW" ] || fail "null override changed the build"
jq -n --arg b "$B_OLD" '{target: {build: $b, fold_oid: "a7bac36f1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$work/ov.json"
out="$("$PLAN" select-build --index "$work/next.json" --override "$work/ov.json")"
[ "$(jq -r .build <<<"$out")" = "$B_OLD" ] || fail "override build: $out"
[ "$(jq -r .source <<<"$out")" = override ] || fail "override source: $out"
[ "$(jq -r .fold_oid <<<"$out")" = a7bac36f1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] || fail "override oid: $out"
echo '{"target": {"build": "not-a-describe"}}' >"$work/ov-bad.json"
if "$PLAN" select-build --index "$work/next.json" --override "$work/ov-bad.json" 2>"$work/err"; then fail "a bad build must be refused"; fi
# an empty index and no override is an error, not a silent default
echo '{"apps": []}' >"$work/empty.json"
if "$PLAN" select-build --index "$work/empty.json" 2>"$work/err"; then fail "empty index must be refused"; fi

# 3. moved: heads from the real candidate-set tool, with --lastdb-build and no lastdbd.
#    A fake `gh` answers the github-ci head reads.
fake="$work/fake"; mkdir -p "$fake"
cat >"$fake/gh" <<GHEOF
#!/usr/bin/env bash
# gh api repos/EdgeVector/<repo>/commits?sha=main...      -> one head per repo
# gh api repos/EdgeVector/<repo>/commits/<sha>/check-runs -> a green ci-required
# gh api repos/.../actions/artifacts?name=ht-artifact-... -> one live artifact
path="\$2"
case "\$path" in
  repos/EdgeVector/alpha/commits\?*) echo '["$A1"]' ;;
  repos/EdgeVector/beta/commits\?*) echo '["$A3"]' ;;
  */check-runs*) echo '["success"]' ;;
  */actions/artifacts*) echo 1 ;;
  *) echo "fake gh: \$*" >&2; exit 1 ;;
esac
GHEOF
chmod +x "$fake/gh"
jq -n '{apps: {
  alpha: {github: "https://github.com/EdgeVector/alpha.git", public: "x", artifact_app: "alpha", install_name: "alpha"},
  beta:  {github: "https://github.com/EdgeVector/beta.git",  public: "x", artifact_app: "beta",  install_name: "beta"}}}' >"$work/apps.json"
LAST_STACK_GH_BIN="$fake/gh" "$SET" --lastdb-build "$B_NEW" --apps-config "$work/apps.json" \
  --source-venue github --sha-source github-ci --no-version-lookup --no-source-probe \
  --out "$work/heads.json" >/dev/null || fail "candidate set with --lastdb-build"
[ "$(jq -r .lastdb.build "$work/heads.json")" = "$B_NEW" ] || fail "heads build"
[ "$(jq -r .lastdb.bin "$work/heads.json")" = "" ] || fail "no lastdbd recorded"
[ "$(jq -r .apps.beta.sha "$work/heads.json")" = "$A3" ] || fail "beta head"

out="$("$PLAN" moved --index "$work/next.json" --build "$B_NEW" --heads "$work/heads.json")"
# alpha: head A1 equals the pin for B_NEW. beta: no row for B_NEW at all (its row is B_OLD): moved.
[ "$(jq -r '.moved | join(",")' <<<"$out")" = beta ] || fail "moved set: $out"
[ "$(jq -r .held.alpha <<<"$out")" = "$A1" ] || fail "held alpha"
[ "$(jq -r .held.beta <<<"$out")" = "" ] || fail "held beta"
fp1="$(jq -r .fingerprint <<<"$out")"

# 4. nothing moved: both heads equal their pins for the build
jq --arg a3 "$A3" --arg n "$B_NEW" '(.apps[] | select(.app_id == "beta") | .compat) += [{sha: $a3, lastdb_version: $n, proved_at: "2026-09-30T00:00:00Z", proof_run: "p3", app_version: "1"}]' \
  "$work/next.json" >"$work/next2.json"
out="$("$PLAN" moved --index "$work/next2.json" --build "$B_NEW" --heads "$work/heads.json")"
[ "$(jq -r '.moved | length' <<<"$out")" = 0 ] || fail "nothing should be moved: $out"

# 5. the pin is the NEWEST row for the build: an older row with the head's sha does not count
jq --arg a1 "$A1" --arg a3 "$A3" --arg n "$B_NEW" '(.apps[] | select(.app_id == "beta") | .compat) = [
  {sha: $a3, lastdb_version: $n, proved_at: "2026-09-29T00:00:00Z", proof_run: "p3", app_version: "1"},
  {sha: $a1, lastdb_version: $n, proved_at: "2026-09-30T00:00:00Z", proof_run: "p4", app_version: "1"}]' \
  "$work/next.json" >"$work/next3.json"
out="$("$PLAN" moved --index "$work/next3.json" --build "$B_NEW" --heads "$work/heads.json")"
[ "$(jq -r '.moved | join(",")' <<<"$out")" = beta ] || fail "newest row must decide: $out"

# 6. the fingerprint follows the heads; it does not follow the index
fpset="$("$PLAN" fingerprint --candidate-set "$work/heads.json" | jq -r .fingerprint)"
[ "$fpset" = "$fp1" ] || fail "fingerprint of the set and of the heads differ"
jq --arg x "$A2" '.apps.beta.sha = $x' "$work/heads.json" >"$work/heads2.json"
fp2="$("$PLAN" fingerprint --candidate-set "$work/heads2.json" | jq -r .fingerprint)"
[ "$fp1" != "$fp2" ] || fail "fingerprint must change when a head changes"

# 7. a heads file for another build is refused
if "$PLAN" moved --index "$work/next.json" --build "$B_OLD" --heads "$work/heads.json" 2>"$work/err"; then fail "build mismatch must be refused"; fi

# 8. candidate set: exactly one of --lastdbd and --lastdb-build
if "$SET" --apps-config "$work/apps.json" --out "$work/x.json" 2>"$work/err"; then fail "neither flag must be refused"; fi
grep -q 'exactly one of' "$work/err" || fail "reason: $(cat "$work/err")"

echo "ok last-stack-registry-proof-plan"
