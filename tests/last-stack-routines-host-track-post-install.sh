#!/usr/bin/env bash
# Routines host-track post-install reloads the daemon after current flips.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
hook="$ROOT/bin/last-stack-routines-host-track-post-install"
apps="$ROOT/config/host-track/apps.json"

bash -n "$hook"
chmod +x "$hook"

command -v jq >/dev/null 2>&1 || {
  echo "jq required" >&2
  exit 1
}

jq -e '
  .apps[]
  | select(.app == "routines")
  | .post_install == "$HOME/.local/bin/last-stack-routines-host-track-post-install"
    and .safe_upgrade.post_install_phase == "after-cutover"
' "$apps" >/dev/null \
  || {
    echo "FAIL: routines app must run after-cutover install-daemon hook" >&2
    exit 1
  }

jq -e '
  .apps[]
  | select(.app == "last-stack")
  | .links
  | map(.source)
  | index("bin/last-stack-routines-host-track-post-install")
' "$apps" >/dev/null \
  || {
    echo "FAIL: last-stack must PATH-link last-stack-routines-host-track-post-install" >&2
    exit 1
  }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/dist"
mkdir -p "$stub"
cat >"$stub/routines" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "install-daemon" ]; then
  echo "install-daemon ok"
  exit 0
fi
echo "unexpected $*" >&2
exit 2
EOF
chmod +x "$stub/routines"

out="$(HOST_TRACK_VERSION_DIR="$tmp" "$hook")"
printf '%s\n' "$out" | grep -q 'install-daemon ok' \
  || {
    echo "FAIL: expected install-daemon ok: $out" >&2
    exit 1
  }

cat >"$stub/routines" <<'EOF'
#!/usr/bin/env bash
echo "Operation not permitted" >&2
exit 1
EOF
chmod +x "$stub/routines"
set +e
perm_out="$(HOST_TRACK_VERSION_DIR="$tmp" "$hook" 2>&1)"
perm_rc=$?
set -e
[ "$perm_rc" -eq 0 ] || {
  echo "FAIL: EPERM must not fail the artifact cutover: $perm_out" >&2
  exit 1
}
printf '%s\n' "$perm_out" | grep -qi 'WARN' \
  || {
    echo "FAIL: expected permission WARN: $perm_out" >&2
    exit 1
  }

echo "ok last-stack-routines-host-track-post-install"
