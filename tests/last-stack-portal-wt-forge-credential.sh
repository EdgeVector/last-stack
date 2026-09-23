#!/usr/bin/env bash
# Plain `git fetch` in a forge mirror must not depend on the login keychain
# (papercut-forgejo-direct-fetch-prompts-for-username-20260923):
#   1. git-credential-last-stack-forge answers `get` for the forge host only.
#   2. last-stack-portal-wt registers it on a forge mirror, once, with an empty
#      reset entry first; a non-forge remote is left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/git-credential-last-stack-forge"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-forge-cred.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. helper protocol ---
out="$(printf 'protocol=http\nhost=localhost:3300\n\n' | FORGE_TOKEN=tok123 "$HELPER" get)"
[ "$out" = $'username=forge-token\npassword=tok123' ] || fail "forge host get: [$out]"
out="$(printf 'protocol=http\nhost=100.109.94.59:3300\n\n' | FORGE_TOKEN=tok123 "$HELPER" get)"
[[ "$out" == *"password=tok123"* ]] || fail "tailnet forge host get: [$out]"
out="$(printf 'protocol=https\nhost=github.com\n\n' | FORGE_TOKEN=tok123 "$HELPER" get)"
[ -z "$out" ] || fail "non-forge host must get nothing: [$out]"
out="$(printf 'protocol=http\nhost=localhost:3300\nusername=u\npassword=p\n\n' | FORGE_TOKEN=tok123 "$HELPER" store)"
[ -z "$out" ] || fail "store must be a no-op: [$out]"

# --- 2. portal registration (fetch is faked; no network) ---
mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = fetch ] && exit 1; done
exec /usr/bin/git "$@"
FAKE
chmod +x "$WORK/bin/git"

setup_portal() {  # name remote
  local name="$1" remote="$2" src="$WORK/$1-src"
  portal="$WORK/$name-portal"; cache="$WORK/$name-cache.git"
  mkdir -p "$src" "$portal/.portal"
  git -C "$src" init -q -b main
  git -C "$src" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m seed
  git clone -q --bare "$src" "$cache"
  printf '%s\n' "$name" >"$portal/.portal/slug"
  printf '%s\n' "$remote" >"$portal/.portal/remote"
  printf 'forgejo\n' >"$portal/.portal/venue"
  printf '%s\n' "$cache" >"$portal/.portal/cache"
}
run_wt() { GIT="$WORK/bin/git" WORKTREES_DIR="$WORK/wt" EDGEVECTOR_GIT_CACHE="$WORK" \
  bash "$BIN" --portal "$portal" fetch >/dev/null 2>&1 || true; }

setup_portal forge "http://localhost:3300/EdgeVector/forge.git"
run_wt; run_wt
got="$(git -C "$cache" config --local --get-all credential.http://localhost:3300.helper | tr '\n' '|')"
want='|!"$HOME/.last-stack/bin/git-credential-last-stack-forge"|'
[ "$got" = "$want" ] || fail "forge mirror helper list: [$got] want [$want]"

setup_portal plain "$WORK/plain-src"
run_wt
[ -z "$(git -C "$cache" config --local --get-regexp '^credential\.' || true)" ] \
  || fail "non-forge mirror got a credential helper"

echo "ok last-stack-portal-wt-forge-credential"
