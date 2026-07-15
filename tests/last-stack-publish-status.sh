#!/usr/bin/env bash
# Offline regression for last-stack-publish-status field collection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Fake install tree with VERSION + git + stub helpers.
install="$tmp/install"
mkdir -p "$install/bin"
printf '9.9.9\n' >"$install/VERSION"
git -C "$install" init --quiet
git -C "$install" config user.email test@example.com
git -C "$install" config user.name Test
git -C "$install" add VERSION
git -C "$install" commit --quiet -m initial
head_short="$(git -C "$install" rev-parse --short=12 HEAD)"

cat >"$install/bin/last-stack-self-upgrade" <<'EOF'
#!/usr/bin/env bash
echo "LAST_STACK_SELF_UPGRADE reason=publish-status result=up-to-date local_head=deadbeefcafe remote_head=deadbeefcafe version=9.9.9"
exit 0
EOF
chmod +x "$install/bin/last-stack-self-upgrade"

cat >"$install/bin/last-stack-verify-skill-links" <<'EOF'
#!/usr/bin/env bash
echo "last-stack-verify-skill-links: 12 skill link(s) OK"
exit 0
EOF
chmod +x "$install/bin/last-stack-verify-skill-links"

# Source helpers without running main (do not export — CLI invocations below
# must execute normally).
LAST_STACK_PUBLISH_STATUS_LIB_ONLY=1
# shellcheck source=../bin/last-stack-publish-status
. "$ROOT/bin/last-stack-publish-status"
unset LAST_STACK_PUBLISH_STATUS_LIB_ONLY

fields="$(last_stack_build_health_fields "$install" "2026-07-15T12:00:00Z")"

python3 - "$fields" "$head_short" <<'PY'
import json, sys
fields = json.loads(sys.argv[1])
head_short = sys.argv[2]
assert fields["slug"] == "health-latest", fields
assert fields["captured_at"] == "2026-07-15T12:00:00Z", fields
assert fields["version"] == "9.9.9", fields
assert fields["install_head_short"] == head_short, fields
assert fields["self_upgrade_result"] == "up-to-date", fields
assert "result=up-to-date" in fields["self_upgrade_line"], fields
assert fields["skill_link_status"] == "ok", fields
assert fields["skill_link_checked"] == "12", fields
assert fields["schema_version"] == "1", fields
# privacy: no secret-looking blobs
blob = json.dumps(fields)
assert "API_KEY" not in blob
assert "password" not in blob.lower()
print("ok: health fields")
PY

# Drift path
cat >"$install/bin/last-stack-verify-skill-links" <<'EOF'
#!/usr/bin/env bash
echo "last-stack-verify-skill-links: 2 skill link(s) drifted; run repair" >&2
exit 2
EOF
chmod +x "$install/bin/last-stack-verify-skill-links"
fields="$(last_stack_build_health_fields "$install" "2026-07-15T12:00:00Z")"
python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["skill_link_status"]=="drift", f' "$fields"
echo "ok: drift status"

# Dry-run CLI path (no LastDB required)
out="$("$ROOT/bin/last-stack-publish-status" --dry-run --install-root "$install")"
case "$out" in
  *"result=dry-run"*version=9.9.9*upgrade=up-to-date*skill=drift*) ;;
  *)
    printf 'unexpected dry-run output:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
echo "ok: dry-run CLI"

# JSON dry-run includes delivery_stage plan
json_out="$("$ROOT/bin/last-stack-publish-status" --dry-run --json --install-root "$install")"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["dry_run"] is True
assert d["fields"]["version"]=="9.9.9"
assert d["delivery_stage"]["legs"][0]["hash_keys"]==["health-latest"]
print("ok: dry-run json")
' <<<"$json_out"

# deliver-status dry-run with dummy recipient keys
deliver_out="$("$ROOT/bin/last-stack-deliver-status" --dry-run --json \
  --install-root "$install" \
  --recipient-pubkey dGVzdA== \
  --messaging-public-key dGVzdA== \
  --messaging-pseudonym 00000000-0000-0000-0000-000000000001)"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["dry_run"] is True
assert d["delivery_request"]["mode"]=="snapshot"
assert d["delivery_request"]["legs"][0]["hash_keys"]==["health-latest"]
assert d["staged"] is None
print("ok: deliver dry-run json")
' <<<"$deliver_out"

echo "PASS last-stack-publish-status"
