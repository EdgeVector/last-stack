#!/usr/bin/env bash
# Regression: portal-pointed prove-fold style resolution never silent-skips
# and never returns the portal path itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/last-stack-portal-live-checkout"
PORTAL_WT="$ROOT/bin/last-stack-portal-wt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-live-checkout-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export WORKTREES_DIR="$WORK/worktrees"
export EDGEVECTOR_GIT_CACHE="$WORK/cache"
mkdir -p "$WORKTREES_DIR" "$EDGEVECTOR_GIT_CACHE"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- 1) Real git worktree passes through ---
real="$WORK/real-checkout"
git -C "$WORK" init -q -b main "$real"
printf 'live\n' >"$real/marker.txt"
git -C "$real" add marker.txt
git -C "$real" -c user.name=Test -c user.email=test@example.invalid commit -q -m seed

out="$("$HELPER" "$real")"
[ "$out" = "$(cd "$real" && pwd -P)" ] || fail "real worktree pass-through got: $out"

# --- 2) Portal → dedicated worktree (transparent start) ---
source_repo="$WORK/source-fold"
cache="$WORK/cache/fold.git"
portal="$WORK/edgevector/fold"

git -C "$WORK" init -q -b main "$source_repo"
printf 'from-cache\n' >"$source_repo/marker.txt"
# Shape that looks like fold product tree for prove-fold-ish checks
mkdir -p "$source_repo/fold_db/crates/core/src"
printf 'mod engine;\n' >"$source_repo/fold_db/crates/core/src/lib.rs"
git -C "$source_repo" add .
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid commit -q -m 'seed fold cache'
git clone -q --bare "$source_repo" "$cache"
# Ensure refs/heads/main exists for portal-wt fetch path
git -C "$cache" update-ref refs/heads/main HEAD 2>/dev/null || true

mkdir -p "$portal/.portal" "$portal/bin"
printf 'fold\n' >"$portal/.portal/slug"
printf 'lastgit\n' >"$portal/.portal/venue"
printf 'file://%s\n' "$cache" >"$portal/.portal/remote"
printf '%s\n' "$cache" >"$portal/.portal/cache"
# Minimal portal bin/wt wrapper → last-stack portal-wt
cat >"$portal/bin/wt" <<EOF
#!/usr/bin/env bash
exec bash "$PORTAL_WT" --portal "$portal" "\$@"
EOF
chmod +x "$portal/bin/wt"

# No .git on portal — prove the silent-skip class of bug would have fired
if [ -e "$portal/.git" ]; then
  fail "test portal unexpectedly has .git"
fi

resolved="$("$HELPER" --name prove-fold-fixture "$portal")"
[ -n "$resolved" ] || fail "empty resolve for portal"
[ "$resolved" != "$portal" ] || fail "resolver returned portal path itself"
[ -f "$resolved/marker.txt" ] || fail "resolved checkout missing marker: $resolved"
[ -d "$resolved/.git" ] || [ -f "$resolved/.git" ] || fail "resolved path not a git worktree: $resolved"
git -C "$resolved" rev-parse HEAD >/dev/null || fail "resolved path not rev-parseable"

# Second call reuses existing dedicated worktree (idempotent)
resolved2="$("$HELPER" --name prove-fold-fixture "$portal")"
[ "$resolved2" = "$resolved" ] || fail "second resolve diverged: $resolved2 vs $resolved"

# --- 3) Loud fail: incomplete portal (no remote) ---
bad="$WORK/edgevector/half-portal"
mkdir -p "$bad/.portal" "$bad/bin"
printf 'half\n' >"$bad/.portal/slug"
# missing remote + slug complete? has slug only — incomplete
set +e
err="$(
  "$HELPER" --name x "$bad" 2>&1
)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected non-zero for incomplete portal"
printf '%s\n' "$err" | grep -q 'portal, not a checkout' ||
  fail "expected 'portal, not a checkout' in stderr, got: $err"

# --- 4) Loud fail: missing path ---
set +e
err2="$(
  "$HELPER" "$WORK/does-not-exist" 2>&1
)"
rc2=$?
set -e
[ "$rc2" -ne 0 ] || fail "expected non-zero for missing path"
printf '%s\n' "$err2" | grep -q 'does not exist' ||
  fail "expected missing-path message, got: $err2"

# --- 5) Non-portal non-git directory ---
plain="$WORK/plain-dir"
mkdir -p "$plain"
set +e
err3="$(
  "$HELPER" "$plain" 2>&1
)"
rc3=$?
set -e
[ "$rc3" -ne 0 ] || fail "expected non-zero for plain dir"

echo "PASS last-stack-portal-live-checkout"
