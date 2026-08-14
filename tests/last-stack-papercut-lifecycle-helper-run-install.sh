#!/usr/bin/env bash
# Compound proof: papercut lifecycle closer is published on the scheduled RUN
# PATH via host-track last-stack artifact links, and resolves without a source
# checkout on PATH.
#
# Failure invariant (from card COMPOUND PREVENTION):
#   scheduled reconciler prompt → RUN helper lookup → lifecycle close must
#   execute the intended bounded closer (or produce a structured diagnostic)
#   without silently skipping cleanup as lifecycle_helper_missing.
#
# Red-before / green-after:
#   - red: simulated product install omits the host-track PATH link →
#     command -v fails under a routinesd-style PATH
#   - green: registry publishes the link and install applies it →
#     command -v resolves and --limit 1 --json returns a bounded structure
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
registry="$ROOT/config/host-track/apps.json"
helper_src="$ROOT/bin/last-stack-papercut-lifecycle-close"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$registry" ] || fail "missing host-track registry: $registry"
[ -x "$helper_src" ] || fail "lifecycle helper not executable: $helper_src"

# Product install contract: last-stack artifact must PATH-link the closer.
jq -e '
  .apps[]
  | select(.app == "last-stack")
  | any(.links[];
      .source == "bin/last-stack-papercut-lifecycle-close"
      and .target == "$HOME/.local/bin/last-stack-papercut-lifecycle-close")
' "$registry" >/dev/null \
  || fail "last-stack host-track apps.json does not publish last-stack-papercut-lifecycle-close to ~/.local/bin"

# --- Simulate an artifact install tree + host-track link application ---------
install_root="$tmp/artifacts"
local_bin="$tmp/home/.local/bin"
mkdir -p "$install_root/current/bin" "$local_bin"
cp "$helper_src" "$install_root/current/bin/last-stack-papercut-lifecycle-close"
chmod +x "$install_root/current/bin/last-stack-papercut-lifecycle-close"

# Minimal fake brain so --limit 1 does not need a live node.
cat >"$tmp/fake-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  search\ *|--type\ reference*|get\ *|append\ *)
    # Empty search / no-op appends are enough for a bounded dry-run close pass.
    if [[ "$*" == search* ]]; then
      printf '[]\n'
    else
      exit 0
    fi
    ;;
  *)
    printf '[]\n'
    ;;
esac
SH
chmod +x "$tmp/fake-brain"

# Scheduled-style PATH: ~/.local/bin first, no source checkout, no ~/.last-stack/bin.
clean_path() {
  PATH="$local_bin:/usr/bin:/bin" command -v last-stack-papercut-lifecycle-close >/dev/null 2>&1
}

# --- Red-before: install without the PATH link ------------------------------
if clean_path; then
  fail "red-before expected missing helper on clean PATH before link application"
fi
missing_out="$(
  PATH="$local_bin:/usr/bin:/bin" bash -c '
    lifecycle_helper=last-stack-papercut-lifecycle-close
    if command -v "$lifecycle_helper" >/dev/null 2>&1; then
      echo unexpected
    else
      echo "lifecycle_helper_missing helper=$lifecycle_helper"
    fi
  '
)"
[ "$missing_out" = 'lifecycle_helper_missing helper=last-stack-papercut-lifecycle-close' ] \
  || fail "red-before did not emit lifecycle_helper_missing (got: $missing_out)"

# --- Green-after: apply the registry link the way host-track does ------------
ln -sfn "$install_root/current/bin/last-stack-papercut-lifecycle-close" \
  "$local_bin/last-stack-papercut-lifecycle-close"

clean_path || fail "green-after: command -v last-stack-papercut-lifecycle-close failed on clean scheduled PATH"

resolved="$(PATH="$local_bin:/usr/bin:/bin" command -v last-stack-papercut-lifecycle-close)"
[ -n "$resolved" ] || fail "green-after: empty resolve path"
[ -x "$resolved" ] || fail "green-after: resolved path not executable: $resolved"

# Bounded structured smoke (reconciler uses --limit 200; keep this smoke cheap).
smoke_json="$(
  PATH="$local_bin:/usr/bin:/bin" \
    last-stack-papercut-lifecycle-close \
      --limit 1 \
      --json \
      --brain-bin "$tmp/fake-brain" \
      --dry-run 2>"$tmp/smoke.err" || true
)"
# Accept either a successful JSON object or a dry-run shaped result; require
# parseable JSON with an ok/checked/scanned/fixed field so silent skip is not
# "success".
if ! printf '%s\n' "$smoke_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  # Some helper versions print non-JSON on empty inventory; still require the
  # binary exited 0 when invoked by path (retry without capturing stderr noise).
  if ! PATH="$local_bin:/usr/bin:/bin" \
      last-stack-papercut-lifecycle-close --limit 1 --json --brain-bin "$tmp/fake-brain" --dry-run \
      >"$tmp/smoke.out" 2>"$tmp/smoke.err2"; then
    cat "$tmp/smoke.err" "$tmp/smoke.err2" "$tmp/smoke.out" >&2 || true
    fail "green-after: last-stack-papercut-lifecycle-close --limit 1 --json failed"
  fi
  smoke_json="$(cat "$tmp/smoke.out")"
fi

printf '%s\n' "$smoke_json" | jq -e '
  type == "object"
  and (
    (.ok == true)
    or (.checked != null)
    or (.scanned != null)
    or (.fixed != null)
    or (.errors != null)
  )
' >/dev/null \
  || fail "green-after: smoke JSON lacked bounded lifecycle fields: $smoke_json"

printf 'ok last-stack-papercut-lifecycle-helper-run-install\n'
