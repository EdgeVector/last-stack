#!/usr/bin/env bash
# A one-hour soak must delay an install, never prevent it. Mid-soak canary
# replacements on a fast-merging channel used to reset started_epoch forever;
# this bound activates the newest green canary after N abandons once
# min_checks is met, and carries soak credit across a forward channel tip.
# Card: host-track-soak-must-not-starve-a-fast-merging-app-20260906
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_SOAK_FILE_CARD=0
export HOST_TRACK_SOAK_STARVE_AFTER_ABANDONS=3
mkdir -p "$HOME" "$tmp/stamps" "$HOME/.local/bin"

install_root="$tmp/apps/demo"
artifact_root="$tmp/artifacts"
mkdir -p "$install_root/versions" "$artifact_root"

for d in digestaaaa digestbbbb digestcccc digestdddd; do
  mkdir -p "$install_root/versions/$d/bin"
  cat > "$install_root/versions/$d/bin/probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$install_root/versions/$d/bin/probe"
done

registry="$tmp/registry.json"
cat > "$registry" <<EOF
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_root": "$artifact_root",
    "safe_upgrade": { "soak_hours": 1, "min_checks": 3, "post_flip_ticks": 0 }
  },
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "install_mode": "artifact",
      "install_root": "$install_root",
      "artifact_root": "$artifact_root",
      "links": [{"source": "bin/probe", "target": "$HOME/.local/bin/demo"}],
      "notes": "soak starve-bound fixture",
      "safe_upgrade": {
        "probes": [
          {"argv": ["bin/probe"], "timeout_s": 10},
          {"argv": ["bin/probe"], "timeout_s": 10}
        ]
      }
    }
  ]
}
EOF
export HOST_TRACK_REGISTRY="$registry"

ht() { "$ROOT/bin/host-track" "$@"; }

# Load park_canary + helpers from host-track without running main.
{
  printf 'STAMP_DIR="%s"\n' "$HOST_TRACK_STAMP_DIR"
  cat <<'STUB'
atomic_symlink() {
  ln -sfn "$1" "$2"
}
die() { printf 'die: %s\n' "$*" >&2; exit 1; }
STUB
  # soak_stamp_path … park_canary (stops before soak_red_repo)
  awk '
    /^soak_stamp_path\(\)/ {keep=1}
    /^soak_red_repo\(\)/ {keep=0}
    keep {print}
  ' "$ROOT/bin/host-track"
} > "$tmp/park-lib.sh"

park() {
  local digest="$1" oid="$2"
  # shellcheck disable=SC1090
  bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    source "$1"
    park_canary "demo" "$2" "$3" 1 "$4"
  ' bash "$tmp/park-lib.sh" "$install_root" "$digest" "$oid"
}

stamp="$HOST_TRACK_STAMP_DIR/demo.soak.json"
ln -sfn versions/digestaaaa "$install_root/current"

# --- 1. Ordinary single-merge soak still waits the full window -------------
park digestbbbb oidbbbb00000000000000000000000000000001
[ -f "$stamp" ] || fail "park did not write soak stamp"
jq --argjson started "$(date +%s)" --argjson checks 5 \
  '.started_epoch=$started | .checks=$checks | .abandoned_consecutive=0' \
  "$stamp" > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
ln -sfn versions/digestbbbb "$install_root/canary"
out="$(ht soak-watch demo 2>&1)" || fail "ordinary tick should exit 0: $out"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "ordinary soak must still wait the window, got: $out"
printf '%s\n' "$out" | grep -q 'STARVE-BOUND' \
  && fail "ordinary soak must not starve-activate: $out"
[ "$(readlink "$install_root/current")" = "versions/digestaaaa" ] \
  || fail "ordinary soak must not flip current"

# --- 2. Three mid-soak replaces + min_checks → activate --------------------
rm -f "$stamp"
rm -f "$HOST_TRACK_STAMP_DIR/soak-history/"demo-*.soak.json 2>/dev/null || true
# Live current stays on digestaaaa; canaries advance b→c→d. Final canary is
# digestdddd (distinct from current) so soak-watch must flip, not no-op.
ln -sfn versions/digestaaaa "$install_root/current"
old_epoch=$(( $(date +%s) - 100 ))
park digestbbbb oidbbbb00000000000000000000000000000001
jq --argjson started "$old_epoch" --argjson checks 2 \
  '.started_epoch=$started | .checks=$checks' "$stamp" > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"

park digestcccc oidcccc00000000000000000000000000000002
[ "$(jq -r '.abandoned_consecutive' "$stamp")" = "1" ] \
  || fail "first replace should set abandoned=1, got $(cat "$stamp")"
[ "$(jq -r '.started_epoch' "$stamp")" = "$old_epoch" ] \
  || fail "FF replace must carry started_epoch"
[ "$(jq -r '.checks' "$stamp")" = "1" ] \
  || fail "FF replace must RESET checks — new bytes earn their own green probes"
[ "$(jq -r '.digest' "$stamp")" = "digestcccc" ] \
  || fail "stamp digest must advance to digestcccc"

park digestdddd oiddddd00000000000000000000000000000003
[ "$(jq -r '.abandoned_consecutive' "$stamp")" = "2" ] \
  || fail "second replace should set abandoned=2"

# Third replace: still digestdddd→ need a fourth digest. Re-use digestbbbb as
# the newest canary tip (content-addressed; ok for the fixture).
park digestbbbb oidbbbb00000000000000000000000000000005
[ "$(jq -r '.abandoned_consecutive' "$stamp")" = "3" ] \
  || fail "third replace should set abandoned=3, got $(cat "$stamp")"
[ "$(jq -r '.started_epoch' "$stamp")" = "$old_epoch" ] \
  || fail "third FF replace must still carry started_epoch"

ln -sfn versions/digestbbbb "$install_root/canary"
# checks reset to 1 on the replace, so the newest canary must still be probed
# green up to min_checks (3) before the bound may fire. Tick 1: checks 1->2.
out="$(ht soak-watch demo 2>&1)" || true
printf '%s\n' "$out" | grep -q 'STARVE-BOUND' \
  && fail "starve bound must not fire below min_checks on the new canary: $out"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "tick below min_checks should report pending, got: $out"
# Tick 2: checks 2->3 == min_checks, abandoned=3 >= N, window still unelapsed.
out="$(ht soak-watch demo 2>&1)" || true
printf '%s\n' "$out" | grep -q 'STARVE-BOUND' \
  || fail "expected STARVE-BOUND activation after 3 abandons, got: $out"
printf '%s\n' "$out" | grep -q 'activating' \
  || fail "starve-bound must attempt activation, got: $out"
# Full cutover needs a 64-hex digest + lastgit artifact resolve (same limit as
# host-track-soak-gate.sh section 2). The bound's contract here is the gate
# decision: STARVE-BOUND fires when abandoned>=N and checks>=min_checks while
# elapsed is still under the window.

# --- 3. Reverting the bound (N=0) keeps the ordinary wait ------------------
export HOST_TRACK_SOAK_STARVE_AFTER_ABANDONS=0
rm -f "$stamp"
rm -f "$HOST_TRACK_STAMP_DIR/soak-history/"demo-*.soak.json 2>/dev/null || true
ln -sfn versions/digestbbbb "$install_root/current"
park digestcccc oidcccc00000000000000000000000000000002
jq --argjson started "$old_epoch" --argjson checks 5 --argjson ab 9 \
  '.started_epoch=$started | .checks=$checks | .abandoned_consecutive=$ab' \
  "$stamp" > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
ln -sfn versions/digestcccc "$install_root/canary"
out="$(ht soak-watch demo 2>&1)" || fail "N=0 tick should exit 0: $out"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "N=0 must ignore abandoned count and wait, got: $out"
printf '%s\n' "$out" | grep -q 'STARVE-BOUND' \
  && fail "N=0 must not starve-activate: $out"
[ "$(readlink "$install_root/current")" = "versions/digestbbbb" ] \
  || fail "N=0 must not flip current"

# --- 3b. Carried credit is CLAMPED: new bytes never inherit a done window --
# Regression guard. An unclamped carry handed a canary parked one second ago a
# fully elapsed window, and soak-watch answered `soak GREEN after 3802s;
# activating` — the soak removed for exactly the fast-merging apps this bound
# exists for. The carry must leave at least HOST_TRACK_SOAK_CARRY_FLOOR_SECS.
export HOST_TRACK_SOAK_STARVE_AFTER_ABANDONS=3
export HOST_TRACK_SOAK_CARRY_FLOOR_SECS=600
rm -f "$stamp"
rm -f "$HOST_TRACK_STAMP_DIR/soak-history/"demo-*.soak.json 2>/dev/null || true
ln -sfn versions/digestaaaa "$install_root/current"
park digestbbbb oidbbbb00000000000000000000000000000001
# Canary B has soaked its whole window with plenty of green checks.
jq --argjson started "$(( $(date +%s) - 3800 ))" --argjson checks 12 \
  '.started_epoch=$started | .checks=$checks | .abandoned_consecutive=0' \
  "$stamp" > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
# A merge lands; brand-new bytes are parked over it.
#
# Assert against a reference taken BEFORE the clamp runs, not a `date` taken
# after it. park_canary computes `started = carry_now - carried` with
# `carried <= need - floor`, where `carry_now` is its OWN clock read, so
# `started_epoch >= park_at - 3000` holds however long park takes. Measuring
# `$(date +%s) - started_epoch` instead charged the clamp for every second that
# passed after it ran, and the check failed at 3001s on any run where park and
# the read landed in different seconds — which is what happened on a loaded
# Forge CI host on 2026-09-06T10:25Z.
park_at="$(date +%s)"
park digestcccc oidcccc00000000000000000000000000000002
carried_started="$(jq -r '.started_epoch' "$stamp")"
[ "$carried_started" -ge "$(( park_at - 3000 ))" ] \
  || fail "carry must cap the carried window at need-floor (3600-600=3000): started_epoch=$carried_started park_at=$park_at"
ln -sfn versions/digestcccc "$install_root/canary"
out="$(ht soak-watch demo 2>&1)" || fail "clamped tick should exit 0: $out"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "clamped carry must still wait out the floor, got: $out"
printf '%s\n' "$out" | grep -q 'activating' \
  && fail "a one-second-old canary must never activate on a carried window: $out"
[ "$(readlink "$install_root/current")" = "versions/digestaaaa" ] \
  || fail "clamped carry must not flip current"

# --- 4. status prints abandoned=N -----------------------------------------
# Stamp the count here rather than inheriting whatever the previous section
# left, so this assertion does not depend on section order.
jq '.abandoned_consecutive=9' "$stamp" > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
plain="$(ht status demo 2>/dev/null | tr '\t' '\n' | grep '^soak=' || true)"
printf '%s\n' "$plain" | grep -q 'abandoned=9' \
  || fail "status soak line must name abandoned count, got: $plain"

printf 'ok: host-track soak starve-bound (clamped carry, N=3 activate, N=0 wait, status)\n'
