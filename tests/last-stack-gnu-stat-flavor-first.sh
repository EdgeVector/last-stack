#!/usr/bin/env bash
# GNU stat treats `-f` as "filesystem status": it exits 0 and prints text, so a
# `stat -f ... || stat -c ...` chain never reaches the GNU branch on Linux.
# papercut-last-stack-pc-ci-linux-portability-20260923. This test runs the
# affected scripts with a stat shim that behaves like GNU stat and asserts a
# sane result, then lints for the unguarded chain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gnu-stat-flavor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/shim"
real_stat="$(command -v stat)"
cat >"$WORK/shim/stat" <<SHIM
#!/usr/bin/env bash
# GNU-flavored stat: --version works, -c reads the format, -f prints
# filesystem text with exit 0 (the false success).
case "\${1:-}" in
  --version) echo "stat (GNU coreutils) 9.4"; exit 0 ;;
  -f) printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "\${*: -1}"; exit 0 ;;
  -c) fmt="\$2"; shift 2
      case "\$fmt" in
        %Y) if $real_stat --version >/dev/null 2>&1; then exec $real_stat -c %Y "\$@"; else exec $real_stat -f %m "\$@"; fi ;;
        *) echo 0 ;;
      esac ;;
  *) exec $real_stat "\$@" ;;
esac
SHIM
chmod +x "$WORK/shim/stat"

# 1. ship-preflight: a fresh heartbeat log must not read as stale or crash.
hb="$WORK/heartbeats.log"; : >"$hb"
out="$(PATH="$WORK/shim:$PATH" LAST_STACK_HEARTBEATS_PATH="$hb" \
  "$ROOT/bin/last-stack-ship-preflight" 2>&1 || true)"
if ! printf '%s\n' "$out" | grep -qE '^ +OK +heartbeats'; then
  printf '%s\n' "$out" >&2; fail "ship-preflight did not report a fresh heartbeat under GNU stat"
fi
if printf '%s\n' "$out" | grep -qi 'syntax error\|arithmetic'; then
  printf '%s\n' "$out" >&2; fail "ship-preflight hit an arithmetic error under GNU stat"
fi

# 2. safe-activate-cli: best_restorable_previous must pick a version dir.
inst="$WORK/install"; v1="1111111111111111111111111111111111111111"; v2="2222222222222222222222222222222222222222"
mkdir -p "$inst/versions/$v1" "$inst/versions/$v2"
ln -s "versions/$v2" "$inst/current"
got="$(PATH="$WORK/shim:$PATH" bash -c '
  set -euo pipefail
  src="$1"; root="$2"
  fn="$(sed -n "/^is_restorable_local_safe_target()/,/^}/p;/^best_restorable_previous()/,/^}/p" "$src")"
  eval "$fn"
  best_restorable_previous "$root" "versions/'"$v2"'"
' _ "$ROOT/bin/last-stack-safe-activate-cli" "$inst" 2>&1 || true)"
[ "$got" = "versions/$v1" ] || fail "safe-activate-cli picked '$got' under GNU stat"

# 3. Lint: no first-choice `stat -f` chained to a `stat -c` fallback.
if grep -rnE 'stat -f [^|]*\|\| *stat -c' "$ROOT/bin" "$ROOT/lib" "$ROOT/skills" 2>/dev/null \
    | grep -v 'last-stack-gnu-stat-flavor-first'; then
  fail "unguarded stat -f || stat -c chain remains"
fi
echo PASS
