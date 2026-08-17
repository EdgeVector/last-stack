#!/usr/bin/env bash
# Drive the shipped last-stack-design-pack against fixture brain files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-design-pack"
chmod +x "$BIN"
python3 -m py_compile "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok_dir="$tmp/ok"
miss_dir="$tmp/miss"
mkdir -p "$ok_dir/get" "$miss_dir/get"

write_get() {
  local dir="$1" slug="$2" extra="${3:-}"
  cat >"$dir/get/${slug}.txt" <<EOF
[concept] ${slug}
title:      fixture ${slug}
linked_from: ${extra}
---
# ${slug}
fixture body
EOF
}

for slug in \
  concepts-lastdb-canonical-model \
  concepts-lastdb-agent-access-model \
  concepts-edgevector-agent-standing-rules \
  autonomy-contract-dev-no-gate \
  sop-feature-ship-loop \
  sop-north-star-terminal-verification
do
  extra=""
  if [ "$slug" = "concepts-lastdb-canonical-model" ]; then
    extra="design design-lastdb-cloud-sync-mutation-log-first (body)"
  fi
  write_get "$ok_dir" "$slug" "$extra"
  if [ "$slug" != "concepts-lastdb-canonical-model" ]; then
    write_get "$miss_dir" "$slug" ""
  fi
done
write_get "$ok_dir" "design-lastdb-cloud-sync-mutation-log-first" ""
printf '%s\n' \
  "1.  papercut-example-not-membership   Papercut    sample hit" \
  "2.  sop-feature-ship-loop             Sop         already required" \
  >"$ok_dir/search.txt"
printf '%s\n' "1.  papercut-example-not-membership   Papercut    sample hit" \
  >"$miss_dir/search.txt"
# Search candidate must be point-got, not trusted from the search page.
write_get "$ok_dir" "papercut-example-not-membership" ""
write_get "$miss_dir" "papercut-example-not-membership" ""

topic="LastDB access-pattern design for a new schema"

run_ok() {
  python3 "$BIN" --topic "$topic" --fixture-dir "$ok_dir" --json --out "$1.pack"
}

run_ok "$tmp/run1" >"$tmp/run1.json"
run_ok "$tmp/run2" >"$tmp/run2.json"
rc1=0
python3 "$BIN" --topic "$topic" --fixture-dir "$ok_dir" --json >/dev/null

python3 - "$tmp/run1.json" "$tmp/run2.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a["ok"] and b["ok"]
assert a["search_is_membership"] is False
for slug in (
    "concepts-lastdb-canonical-model",
    "concepts-lastdb-agent-access-model",
    "concepts-edgevector-agent-standing-rules",
    "autonomy-contract-dev-no-gate",
    "sop-feature-ship-loop",
    "sop-north-star-terminal-verification",
):
    assert slug in a["required_point_gets"], slug
    assert slug in a["required_got"], slug
    assert slug in a["point_gets"], slug
assert "papercut-example-not-membership" in a["search_candidates"]
assert "papercut-example-not-membership" in a["point_gets"]
# one-hop from canonical-model
assert "design-lastdb-cloud-sync-mutation-log-first" in a["point_gets"]
assert a["point_gets"] == b["point_gets"]
print("design-pack ok-fixture consistent")
PY

set +e
python3 "$BIN" --topic "$topic" --fixture-dir "$miss_dir" --json >"$tmp/miss.json"
miss_rc=$?
set -e
[ "$miss_rc" -ne 0 ] || { echo "expected non-zero when canonical-model missing"; exit 1; }
python3 - "$tmp/miss.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ok"] is False
assert p["lastdb_shaped"] is True
assert "concepts-lastdb-canonical-model" in p["missing_canonical"]
assert "concepts-lastdb-canonical-model" not in p["required_got"]
print("design-pack miss-canonical exits non-zero")
PY

echo "last-stack-design-pack tests ok"
