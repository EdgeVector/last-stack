#!/usr/bin/env bash
# Smoke fixtures for last-stack-unattached-outcome-heal (no live board writes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-unattached-outcome-heal"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || chmod +x "$bin"
"$bin" --help >/dev/null || fail "--help"

# Fake board CLI: pickup status returns one unattached card; show/milestone list
# provide attach target; add records argv.
export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin${PATH:+:$PATH}"
mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home"
: >"$tmp/add.log"

cat >"$tmp/bin/fkanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "$cmd" in
  pickup)
    # pickup status --json
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-needs-ms","category":"unattached-outcome","column":"todo","repo":"EdgeVector/last-stack"}]}
JSON
    ;;
  show)
    cat <<'JSON'
{"slug":"card-needs-ms","north_star":"","milestone":"","repo":"EdgeVector/last-stack","surfaces":[],"body":"Surfaces: bin/**,config/**\n\n## GOAL\nx\n\n## END STATE\ny\n"}
JSON
    ;;
  milestone)
    cat <<'JSON'
[{"slug":"ms-host-track-ops-hygiene-wave2","state":"active","north_star":"north-star-host-track"}]
JSON
    ;;
  add)
    printf '%s\n' "$*" >>"${HOME}/../add.log"
    exit 0
    ;;
  *)
    echo "unexpected fkanban $cmd $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/fkanban"
# add.log path relative to HOME parent used above — fix to absolute
cat >"$tmp/bin/fkanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "\$cmd" in
  pickup)
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-needs-ms","category":"unattached-outcome","column":"todo","repo":"EdgeVector/last-stack"}]}
JSON
    ;;
  show)
    cat <<'JSON'
{"slug":"card-needs-ms","north_star":"","milestone":"","repo":"EdgeVector/last-stack","surfaces":[],"body":"Surfaces: bin/**,config/**\n\n## GOAL\nx\n\n## END STATE\ny\n"}
JSON
    ;;
  milestone)
    cat <<'JSON'
[{"slug":"ms-host-track-ops-hygiene-wave2","state":"active","north_star":"north-star-host-track"}]
JSON
    ;;
  add)
    printf '%s\n' "\$*" >>"$tmp/add.log"
    exit 0
    ;;
  *)
    echo "unexpected fkanban \$cmd \$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/fkanban"

# jq required
command -v jq >/dev/null || fail "jq required"

out="$("$bin" --json 2>/dev/null)" || fail "heal exit non-zero: $out"
echo "$out" | jq -e '.ok == true and .attached >= 1' >/dev/null \
  || fail "expected attached>=1: $out"
grep -q 'card-needs-ms --milestone ms-host-track-ops-hygiene-wave2' "$tmp/add.log" \
  || fail "add log missing milestone attach: $(cat "$tmp/add.log")"
# surfaces backfill from body
grep -q 'card-needs-ms --surfaces' "$tmp/add.log" \
  || fail "add log missing surfaces: $(cat "$tmp/add.log")"

dry="$("$bin" --dry-run --json 2>/dev/null)" || fail "dry-run failed"
echo "$dry" | jq -e '.dry_run == 1' >/dev/null \
  || fail "dry_run flag: $dry"

echo "ok last-stack-unattached-outcome-heal"
