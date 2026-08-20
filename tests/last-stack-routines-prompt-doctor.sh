#!/usr/bin/env bash
# Hermetic probe for last-stack-routines-prompt-doctor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

DOC="$ROOT/bin/last-stack-routines-prompt-doctor"
[ -x "$DOC" ] || chmod +x "$DOC"

product="$tmp/product/routines"
localp="$tmp/routines-home/prompts"
reg="$tmp/routines-home/registry"
mkdir -p "$product" "$localp" "$reg"

export LAST_STACK_ROOT="$tmp/product"
export ROUTINES_HOME="$tmp/routines-home"
export LAST_STACK_ROUTINES_DIR="$product"
export ROUTINES_PROMPTS_DIR="$localp"
export ROUTINES_REGISTRY_DIR="$reg"

# --- green: product only ---
printf 'name: only-product\n' >"$product/only-product.md"
if ! "$DOC" --quiet; then
  echo "fail: expected green with product-only file" >&2
  exit 1
fi

# --- green: local symlink to product (pipeline-health policy) ---
printf 'name: linked\nbody v1\n' >"$product/linked.md"
ln -s "$product/linked.md" "$localp/linked.md"
if ! "$DOC" --quiet; then
  echo "fail: expected green when local is symlink to product" >&2
  exit 1
fi

# --- red: divergent twin ---
printf 'name: twin\nPRODUCT\n' >"$product/twin.md"
printf 'name: twin\nLOCAL_STALE\n' >"$localp/twin.md"
set +e
out="$("$DOC" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "fail: expected red on divergent twin" >&2
  echo "$out" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'kind=twin-divergent' || {
  echo "fail: missing twin-divergent finding" >&2
  echo "$out" >&2
  exit 1
}

# --- normalize heals the twin ---
"$DOC" --normalize --basename twin.md
if ! "$DOC" --quiet; then
  echo "fail: expected green after normalize symlink" >&2
  "$DOC" >&2 || true
  exit 1
fi
# local must be symlink to product
if [ ! -L "$localp/twin.md" ]; then
  echo "fail: normalize did not create symlink" >&2
  ls -la "$localp/twin.md" >&2
  exit 1
fi
# drifted copy backed up
if ! ls "$localp"/twin.md.bak-divergent-* >/dev/null 2>&1; then
  echo "fail: expected backup of drifted local twin" >&2
  ls -la "$localp" >&2
  exit 1
fi

# Product seed for the capstone canary must load the last-stack prompt, not a
# drifted ~/.routines/prompts twin (prompt-doctor registry-divergent-local).
seed="$ROOT/config/routines-registry/coderings-capstone-exerciser.toml"
[ -f "$seed" ] || { echo "fail: missing $seed" >&2; exit 1; }
grep -q 'prompt_path = "/Users/REPLACE/.last-stack/routines/coderings-capstone-exerciser.md"' "$seed" \
  || { echo "fail: capstone seed prompt_path must be last-stack product file" >&2; exit 1; }
grep -q '\.routines/prompts/coderings-capstone-exerciser' "$seed" \
  && { echo "fail: capstone seed still points at drifted local prompt twin" >&2; exit 1; }

# --- red: same-content twin-copy (latent drift) ---
printf 'name: copy\nSAME\n' >"$product/copy.md"
printf 'name: copy\nSAME\n' >"$localp/copy.md"
set +e
out="$("$DOC" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "fail: expected red on twin-copy same-content different-inode" >&2
  echo "$out" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'kind=twin-copy' || {
  echo "fail: missing twin-copy finding" >&2
  echo "$out" >&2
  exit 1
}
rm -f "$localp/copy.md"

# --- red: version-dir pin in registry ---
cat >"$reg/pinned.toml" <<EOF
id = "pinned"
prompt_path = "$HOME/.local/state/last-stack/artifacts/versions/deadbeef0123/routines/kanban-pickup.md"
EOF
# touch a dummy so path shape is the finding (existence not required for pin)
set +e
out="$("$DOC" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "fail: expected red on version-pin" >&2
  echo "$out" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'kind=version-pin' || {
  echo "fail: missing version-pin finding" >&2
  echo "$out" >&2
  exit 1
}
rm -f "$reg/pinned.toml"

# --- json mode ---
printf 'name: j\n' >"$product/j-only.md"
json_out="$("$DOC" --json)"
if command -v jq >/dev/null 2>&1; then
  status_j="$(printf '%s\n' "$json_out" | jq -r '.status')"
  [ "$status_j" = "green" ] || {
    echo "fail: json green expected got=$status_j" >&2
    echo "$json_out" >&2
    exit 1
  }
else
  printf '%s\n' "$json_out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"green"' || {
    echo "fail: json green expected" >&2
    echo "$json_out" >&2
    exit 1
  }
fi

# --- default normalize set only touches listed basenames when present ---
printf 'name: canary\nP\n' >"$product/lastdb-canary-dogfood.md"
printf 'name: canary\nL\n' >"$localp/lastdb-canary-dogfood.md"
"$DOC" --normalize --dry-run --basename lastdb-canary-dogfood.md >/dev/null
"$DOC" --normalize --basename lastdb-canary-dogfood.md
if [ ! -L "$localp/lastdb-canary-dogfood.md" ]; then
  echo "fail: canary normalize" >&2
  exit 1
fi

echo "ok last-stack-routines-prompt-doctor"
