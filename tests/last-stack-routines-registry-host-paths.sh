#!/usr/bin/env bash
# Registry writers must never bake REPLACE or sandbox paths into the host
# routines registry (and must rewrite ROUTINES_HOME when HOME is ephemeral).
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-registry-host-paths.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- 1) Default dry-run under real HOME: never emit REPLACE ---
for bin in \
  last-stack-feature-prove-routine \
  last-stack-why-stopped-routine \
  last-stack-whats-wrong-routine \
  last-stack-lastdb-ops-offenders-routine \
  last-stack-kanban-validate-routine \
  last-stack-fleet-performance-routine
do
  out="$("$ROOT/bin/$bin" --dry-run 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -q 'REPLACE' && fail "$bin dry-run still contains REPLACE"
  printf '%s\n' "$out" | grep -qE 'cwd = ".+code/edgevector"' \
    || fail "$bin dry-run missing host-style cwd"
done

# Pickup workers: dry-run with explicit temp bootstrap/prompt
prompt="$tmp/kanban-pickup.md"
bootstrap="$tmp/prompts/bootstrap.md"
printf '%s\n' '---' 'name: kanban-pickup' '---' >"$prompt"
out="$(
  "$ROOT/bin/last-stack-kanban-pickup-workers" \
    --workers 3 \
    --registry-dir "$tmp/dry-registry" \
    --prompt-path "$prompt" \
    --bootstrap-path "$bootstrap" \
    --dry-run
)"
printf '%s\n' "$out" | grep -q 'REPLACE' && fail "pickup-workers dry-run still contains REPLACE"
printf '%s\n' "$out" | grep -qE 'cwd = ".+code/edgevector"' \
  || fail "pickup-workers dry-run missing host-style cwd"

# --- 2) Explicit registry under tmp: write succeeds, no REPLACE ---
"$ROOT/bin/last-stack-feature-prove-routine" \
  --registry-dir "$tmp/registry" \
  --prompt-path "$ROOT/routines/feature-prove.md" >/dev/null
entry="$tmp/registry/last-stack-feature-prove.toml"
test -f "$entry" || fail "feature-prove did not write entry"
grep -q 'REPLACE' "$entry" && fail "feature-prove wrote REPLACE into tmp registry"
grep -qE '^cwd = "' "$entry" || fail "feature-prove missing cwd"

# --- 3) Ephemeral HOME + inherited host ROUTINES_HOME must not touch host ---
# Simulate the llms-txt-install-smoke pollution class.
host_reg_probe="$tmp/fake-host-routines"
mkdir -p "$host_reg_probe/registry"
sandbox_home="$tmp/llms-txt-install-smoke.fake/home"
mkdir -p "$sandbox_home/.last-stack/routines" "$sandbox_home/code/edgevector"
# Minimal prompt so the writer can resolve paths under sandbox ROOT clone layout.
printf '%s\n' '# why-stopped fixture' >"$sandbox_home/.last-stack/routines/why-stopped.md"
printf '%s\n' '# feature-prove fixture' >"$sandbox_home/.last-stack/routines/feature-prove.md"

# Copy the generators + env helper into the fake sandbox last-stack tree so ROOT
# resolves under the ephemeral HOME.
mkdir -p "$sandbox_home/.last-stack/bin"
cp "$ROOT/bin/last-stack-routines-registry-env" \
  "$ROOT/bin/last-stack-feature-prove-routine" \
  "$ROOT/bin/last-stack-why-stopped-routine" \
  "$sandbox_home/.last-stack/bin/"
chmod +x "$sandbox_home/.last-stack/bin/"*

# Marker so we can detect host pollution.
printf '%s\n' 'marker = "host-pre"' >"$host_reg_probe/registry/last-stack-feature-prove.toml"
printf '%s\n' 'marker = "host-pre"' >"$host_reg_probe/registry/last-stack-why-stopped.toml"

(
  export HOME="$sandbox_home"
  export ROUTINES_HOME="$host_reg_probe" # deliberate host-like absolute inherit
  "$sandbox_home/.last-stack/bin/last-stack-feature-prove-routine"
  "$sandbox_home/.last-stack/bin/last-stack-why-stopped-routine"
)

# Host probe must remain untouched (generators forced ROUTINES_HOME under HOME).
grep -q 'marker = "host-pre"' "$host_reg_probe/registry/last-stack-feature-prove.toml" \
  || fail "feature-prove overwrote inherited host ROUTINES_HOME"
grep -q 'marker = "host-pre"' "$host_reg_probe/registry/last-stack-why-stopped.toml" \
  || fail "why-stopped overwrote inherited host ROUTINES_HOME"

# Sandbox registry under HOME/.routines should have been used instead.
test -f "$sandbox_home/.routines/registry/last-stack-feature-prove.toml" \
  || fail "feature-prove did not write sandbox registry"
test -f "$sandbox_home/.routines/registry/last-stack-why-stopped.toml" \
  || fail "why-stopped did not write sandbox registry"
grep -q 'REPLACE' "$sandbox_home/.routines/registry/"*.toml \
  && fail "sandbox registry still contains REPLACE"
grep -qE 'llms-txt-install-smoke' "$sandbox_home/.routines/registry/"*.toml \
  || fail "sandbox registry should reference sandbox paths for prompts under ephemeral HOME"

# --- 4) Direct host-registry write with sandbox prompt path must refuse ---
# Use real login home probe only if we can write a disposable dir under a
# temporary name that is NOT the live registry. Simulate by pointing
# REG_LOGIN_HOME via a unit-test of assert via the writer with --registry-dir
# equal to a path that looks like login/.routines/registry — the assert uses
# login home from dscl, so only the real host path is guarded.
login_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
login_home="${login_home:-$HOME}"
if [ -d "$login_home/.routines/registry" ]; then
  # Attempt a write that would poison host with /tmp prompt — must exit nonzero
  # and leave no new sandbox path in any last-stack-feature-prove.toml body
  # we can check via dry path: call assert indirectly.
  set +e
  HOME="$login_home" \
    "$ROOT/bin/last-stack-feature-prove-routine" \
    --registry-dir "$login_home/.routines/registry" \
    --prompt-path "/tmp/llms-txt-install-smoke.XXXX/home/.last-stack/routines/feature-prove.md" \
    >/dev/null 2>"$tmp/refuse.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected refuse of host write with sandbox prompt_path (rc=0)"
  grep -qi 'refusing\|not readable\|ephemeral' "$tmp/refuse.err" \
    || fail "refuse path did not explain itself: $(cat "$tmp/refuse.err")"
fi


# --- a versioned artifact dir must never become REG_STABLE_ROOT ---
# host-track runs <version>/setup with LAST_STACK_ROOT pointing at the version
# being installed, so trusting it pinned prompt_path into an artifacts/versions/
# tree on EVERY refresh. Those dirs are GC'd, and a pinned prompt stops tracking
# merged prompt changes — silently, because the file still exists for a while.
# Resolve through /var -> /private/var so comparisons match what pwd -P returns.
ver_home="$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)"
mkdir -p "$ver_home/.last-stack/routines"
mkdir -p "$ver_home/.local/state/last-stack/artifacts/versions/deadbeef/routines"
printf '# compat\n' >"$ver_home/.last-stack/routines/feature-prove.md"
printf '# versioned\n' >"$ver_home/.local/state/last-stack/artifacts/versions/deadbeef/routines/feature-prove.md"

resolved="$(
  HOME="$ver_home" \
  LAST_STACK_ROOT="$ver_home/.local/state/last-stack/artifacts/versions/deadbeef" \
  bash -c '
    . "'"$ROOT"'/bin/last-stack-routines-registry-env"
    last_stack_registry_paths_init
    last_stack_registry_prompt_path feature-prove.md /fallback.md
  '
)"
case "$resolved" in
  */artifacts/versions/*) fail "prompt_path pinned into a GC-able version dir: $resolved" ;;
esac
[ "$resolved" = "$ver_home/.last-stack/routines/feature-prove.md" ] \
  || fail "expected compat root, got $resolved"

# A non-versioned LAST_STACK_ROOT is still honoured.
mkdir -p "$ver_home/custom-root/routines"
printf '# custom\n' >"$ver_home/custom-root/routines/feature-prove.md"
resolved="$(
  HOME="$ver_home" LAST_STACK_ROOT="$ver_home/custom-root" \
  bash -c '
    . "'"$ROOT"'/bin/last-stack-routines-registry-env"
    last_stack_registry_paths_init
    last_stack_registry_prompt_path feature-prove.md /fallback.md
  '
)"
[ "$resolved" = "$ver_home/custom-root/routines/feature-prove.md" ] \
  || fail "non-versioned LAST_STACK_ROOT should win, got $resolved"
rm -rf "$ver_home"


# --- the versioned FALLBACK must be normalized too (mid-install race) ---
# Callers pass "$ROOT/routines/<name>" as the fallback and $ROOT is the version
# dir for a binary running out of the artifact. When the compat path is briefly
# unreadable during an install, the readable-check fails and the writer used to
# emit the versioned fallback — which is why the pin came back on every refresh
# even after REG_STABLE_ROOT was guarded.
race_home="$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)"
mkdir -p "$race_home/.local/state/last-stack/artifacts/versions/cafe01/routines"
printf '# versioned\n' >"$race_home/.local/state/last-stack/artifacts/versions/cafe01/routines/feature-prove.md"
# NOTE: no $race_home/.last-stack/routines/feature-prove.md — the compat path is
# deliberately absent, simulating the swap window.
resolved="$(
  HOME="$race_home" \
  bash -c '
    . "'"$ROOT"'/bin/last-stack-routines-registry-env"
    last_stack_registry_paths_init
    last_stack_registry_prompt_path feature-prove.md \
      "'"$race_home"'/.local/state/last-stack/artifacts/versions/cafe01/routines/feature-prove.md"
  '
)"
case "$resolved" in
  */artifacts/versions/*) fail "versioned fallback leaked into prompt_path: $resolved" ;;
esac
[ "$resolved" = "$race_home/.last-stack/routines/feature-prove.md" ] \
  || fail "expected compat path even when unreadable, got $resolved"
rm -rf "$race_home"

echo "ok"
