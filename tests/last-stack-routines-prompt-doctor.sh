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
# --- normalize-findings heals the twin-copy too ---
# Identical content means linking loses nothing, and twin-copy is the state
# EVERY prompt starts in the moment it first gains a tracked product twin
# (local copy already there, product file newly installed). Healing only
# twin-divergent left those red until someone hand-linked them.
"$DOC" --normalize-findings
if ! "$DOC" --quiet; then
  echo "fail: expected green after normalize-findings healed twin-copy" >&2
  "$DOC" >&2 || true
  exit 1
fi
if [ ! -L "$localp/copy.md" ]; then
  echo "fail: normalize-findings did not symlink twin-copy local -> product" >&2
  ls -la "$localp/copy.md" >&2
  exit 1
fi
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

# --- green: freshness bootstrap is the intended design, not drift ---
# routinesd dispatches a small local prompt whose body loads the product prompt
# through last-stack-routine-read. It is SUPPOSED to differ from
# routines/<name>.md. Flagging it red is what kept this doctor advisory: a gate
# that fires on a correct install cannot be enforced.
printf 'name: boot\nFULL PRODUCT BODY\nmany lines\n' >"$product/boot.md"
printf 'name: boot\nRead it with "$last_stack/bin/last-stack-routine-read" boot\n' >"$localp/boot.md"
cat >"$reg/boot.toml" <<EOF
id = "boot"
prompt_path = "$localp/boot.md"
EOF
if ! "$DOC" --quiet; then
  echo "fail: freshness bootstrap must not be reported as drift" >&2
  "$DOC" >&2 || true
  exit 1
fi
# ...and it must not be silently rewritten into a symlink either.
"$DOC" --normalize-findings --quiet || true
if [ -L "$localp/boot.md" ]; then
  echo "fail: normalize must not clobber a freshness bootstrap" >&2
  exit 1
fi
rm -f "$reg/boot.toml" "$localp/boot.md" "$product/boot.md"

# --- --normalize-findings heals exactly what scanned red ---
# Registered routine resolving a drifted full copy: heal it.
printf 'name: reg\nNEW PRODUCT BODY\n' >"$product/reg-drift.md"
printf 'name: reg\nSTALE LOCAL FULL COPY\n' >"$localp/reg-drift.md"
cat >"$reg/reg-drift.toml" <<EOF
id = "reg-drift"
prompt_path = "$localp/reg-drift.md"
EOF
# An unregistered local-only prompt is legitimate and must survive untouched.
printf 'name: localonly\nHAND WRITTEN LOCAL ONLY\n' >"$localp/local-only.md"

set +e
"$DOC" --quiet
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "fail: expected red before normalize-findings" >&2; exit 1; }

"$DOC" --normalize-findings --quiet
if ! "$DOC" --quiet; then
  echo "fail: expected green after --normalize-findings" >&2
  "$DOC" >&2 || true
  exit 1
fi
[ -L "$localp/reg-drift.md" ] || {
  echo "fail: registered drift was not relinked to product" >&2
  exit 1
}
ls "$localp"/reg-drift.md.bak-divergent-* >/dev/null 2>&1 || {
  echo "fail: drifted copy must be backed up, not destroyed" >&2
  exit 1
}
if [ -L "$localp/local-only.md" ] || ls "$localp"/local-only.md.bak-* >/dev/null 2>&1; then
  echo "fail: --normalize-findings touched an unregistered local-only prompt" >&2
  exit 1
fi
rm -f "$reg/reg-drift.toml" "$localp"/reg-drift.md* "$product/reg-drift.md" "$localp/local-only.md"

# --- normalize refuses to create a GC-eligible versions symlink ---
# host-track runs <version>/setup with LAST_STACK_ROOT set to the version being
# installed. If normalize trusted that, it would trade a drifted copy for a
# dangling one the next GC.
vtmp="$tmp/vpin"
vproduct="$vtmp/artifacts/versions/deadbeef0123/routines"
vlocal="$vtmp/rh/prompts"
vreg="$vtmp/rh/registry"
mkdir -p "$vproduct" "$vlocal" "$vreg"
printf 'name: v\nPRODUCT\n' >"$vproduct/v.md"
printf 'name: v\nSTALE LOCAL\n' >"$vlocal/v.md"
cat >"$vreg/v.toml" <<EOF
id = "v"
prompt_path = "$vlocal/v.md"
EOF
set +e
vout="$(LAST_STACK_ROOT="$vtmp/artifacts/versions/deadbeef0123" \
  LAST_STACK_ROUTINES_DIR="$vproduct" \
  ROUTINES_PROMPTS_DIR="$vlocal" \
  ROUTINES_REGISTRY_DIR="$vreg" \
  "$DOC" --normalize-findings 2>&1)"
vrc=$?
set -e
[ "$vrc" -ne 0 ] || { echo "fail: version-pin normalize must fail closed" >&2; exit 1; }
printf '%s\n' "$vout" | grep -q 'kind=normalize-refused' || {
  echo "fail: missing normalize-refused finding" >&2
  printf '%s\n' "$vout" >&2
  exit 1
}
if [ -L "$vlocal/v.md" ]; then
  echo "fail: normalize created a symlink into a GC-eligible versions tree" >&2
  exit 1
fi

# --- enforcement contract: something must actually RUN the doctor ---
# The doctor shipped, was PATH-shimmed, and was never invoked; red stayed
# advisory for weeks. Keep a caller wired.
heal="$ROOT/bin/last-stack-class-a-heal"
[ -f "$heal" ] || { echo "fail: missing $heal" >&2; exit 1; }
grep -Fq -- '--normalize-findings' "$heal" || {
  echo "fail: class-a-heal must run the prompt doctor heal, not only PATH-shim it" >&2
  exit 1
}
grep -Fq 'ensure_single_live_prompt_root' "$heal" || {
  echo "fail: class-a-heal lost the single-live-prompt-root enforcement step" >&2
  exit 1
}

# --- product root reached through a SYMLINK (the shipping layout) ---
# In artifact install mode ~/.last-stack/routines is a symlink into
# artifacts/current/routines. `find <symlink> -maxdepth 1` without -L yields
# the symlink itself and zero *.md, so every twin scan compared against an
# empty set and the doctor reported green no matter how badly prompts drifted.
# This case fails against that bug and passes with `find -L`.
sym_real="$tmp/sym-product-real/routines"
sym_local="$tmp/sym-home/prompts"
sym_reg="$tmp/sym-home/registry"
mkdir -p "$sym_real" "$sym_local" "$sym_reg"
ln -s "$sym_real" "$tmp/sym-routines-link"

printf 'name: drifted\nPRODUCT\n' >"$sym_real/drifted.md"
printf 'name: drifted\nLOCAL_STALE\n' >"$sym_local/drifted.md"

set +e
out="$(LAST_STACK_ROUTINES_DIR="$tmp/sym-routines-link" \
       ROUTINES_PROMPTS_DIR="$sym_local" \
       ROUTINES_REGISTRY_DIR="$sym_reg" \
       "$DOC" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "fail: doctor blind through a symlinked product root (needs find -L)" >&2
  echo "$out" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'kind=twin-divergent' || {
  echo "fail: expected twin-divergent through a symlinked product root" >&2
  echo "$out" >&2
  exit 1
}

echo "ok last-stack-routines-prompt-doctor"
