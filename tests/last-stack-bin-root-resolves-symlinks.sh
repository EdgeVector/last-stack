#!/usr/bin/env bash
# Every bin/ script that derives its install root from its own path must
# resolve symlinks first. host-track links helpers into ~/.local/bin as
# symlinks, so `dirname "$0"`/.. there is ~/.local, not the artifact tree:
# last-stack-canary-loom sourced ~/.local/lib/canary-loom/loom-run-deadline.sh
# and exited 1 before any work (papercut-last-stack-canary-artifact-missing-lib-20260922).
# 59 scripts carried the same line. Use:
#   ROOT="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")")/.." && pwd -P)"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

bad="$(grep -nE 'dirname (-- )?"\$(0|\{BASH_SOURCE\[0\]\})"\)/\.\.' bin/* 2>/dev/null || true)"
if [ -n "$bad" ]; then
  echo "FAIL: bin/ scripts derive ROOT from an unresolved \$0 (breaks behind a ~/.local/bin symlink):" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi

# Behavior: a symlinked copy of a resolving script must find its own tree.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bin-root-resolve.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tree/bin" "$tmp/tree/lib" "$tmp/links"
printf 'probe-lib-ok\n' >"$tmp/tree/lib/marker"
cat >"$tmp/tree/bin/probe" <<'PROBE'
#!/usr/bin/env bash
ROOT="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")")/.." && pwd -P)"
cat "$ROOT/lib/marker"
PROBE
chmod +x "$tmp/tree/bin/probe"
ln -s "$tmp/tree/bin/probe" "$tmp/links/probe"
out="$("$tmp/links/probe")"
[ "$out" = "probe-lib-ok" ] || { echo "FAIL: the resolving idiom did not find lib/ through a symlink (got: $out)" >&2; exit 1; }
echo "ok last-stack-bin-root-resolves-symlinks"
