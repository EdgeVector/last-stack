#!/usr/bin/env bash
# Fixture for the logical resident set terminal proof.
# Covers offline FAIL, offline PASS, the live refuse rules, and live verdict copy.
# Does not read or clone ~/.lastdb.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
RUN="$HERE/run.sh"
SLUG=north-star-lastdb-logical-resident-set
PIECE_SCRIPT="fold_db/scripts/logical-resident-set-copy-proof.sh"
PIECE_RANGE="fold_db/crates/core/src/resident/range.rs"
PIECE_SET="fold_db/crates/core/src/resident/logical_set.rs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lrs-proof-test.XXXXXX")"
CANON="$HOME/.last-stack/north-star-proofs/$SLUG.md"
CAP_RC=0
if [ -f "$CANON" ]; then
  CANON_BEFORE="$(cksum "$CANON")"
else
  CANON_BEFORE="absent"
fi

cleanup() {
  case "${WORK:-}" in
    ""|/|"$HOME"|/tmp|/private/tmp) return 0 ;;
  esac
  case "$WORK" in
    /tmp/*|/private/tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$WORK" ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

bash -n "$RUN"

git_commit() {
  git -C "$1" add -A
  git -C "$1" \
    -c user.email=fixture@example.com \
    -c user.name=fixture \
    -c commit.gpgsign=false \
    commit -q -m "$2"
}

init_repo() {
  local src="$1"
  rm -rf "$src"
  mkdir -p "$src"
  git init -q -b main "$src"
  printf 'fixture\n' >"$src/README"
}

publish() {
  local src="$1" gitdir="$2" origin_oid="$3" main_oid="$4"
  rm -rf "$gitdir"
  git clone -q --bare "$src" "$gitdir"
  git --git-dir="$gitdir" update-ref refs/heads/main "$main_oid"
  if [ -n "$origin_oid" ]; then
    git --git-dir="$gitdir" update-ref refs/remotes/origin/main "$origin_oid"
  else
    git --git-dir="$gitdir" update-ref -d refs/remotes/origin/main >/dev/null 2>&1 || true
  fi
}

write_fixture_script() {
  local dest="$1" log="$2"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$log"
verdict="\${LOGICAL_RESIDENT_SET_FIXTURE_VERDICT:-PASS}"
rc="\${LOGICAL_RESIDENT_SET_FIXTURE_RC:-0}"
home=""
report=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --home) home="\$2"; shift 2 ;;
    --report) report="\$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
if [ -f "\$(dirname "\$0")/../../Cargo.toml" ]; then
  printf 'cargo_root=yes\n' >>"$log"
else
  printf 'cargo_root=no\n' >>"$log"
fi
if [ -n "\$home" ]; then
  if [ -e "\$home/cloud_sync.json" ] || [ -e "\$home/cloud_sync.json.extra" ]; then
    printf 'cloud=present\n' >>"$log"
  else
    printf 'cloud=absent\n' >>"$log"
  fi
  if [ -d "\$home/data" ]; then
    printf 'data=dir\n' >>"$log"
  else
    printf 'data=missing\n' >>"$log"
  fi
fi
if [ -n "\$report" ]; then
  printf '%s\n' "\$verdict" >"\$report"
fi
printf '%s\n' "\$verdict"
exit "\$rc"
EOF
  chmod +x "$dest"
}

add_all_pieces() {
  local src="$1" script="$2"
  mkdir -p "$src/fold_db/scripts" "$src/fold_db/crates/core/src/resident"
  cp "$script" "$src/$PIECE_SCRIPT"
  chmod +x "$src/$PIECE_SCRIPT"
  printf '[workspace]\n' >"$src/Cargo.toml"
  printf 'range\n' >"$src/$PIECE_RANGE"
  printf 'set\n' >"$src/$PIECE_SET"
}

invoke() {
  local out="$1" err="$2"
  shift 2
  set +e
  env \
    -u LOGICAL_RESIDENT_SET_FOLD_REF \
    -u LOGICAL_RESIDENT_SET_FOLD_MIRROR \
    -u LOGICAL_RESIDENT_SET_COPY_HOME \
    -u LOGICAL_RESIDENT_SET_FIXTURE_VERDICT \
    -u LOGICAL_RESIDENT_SET_FIXTURE_RC \
    -u NORTH_STAR_PROOF_DIR \
    -u NORTH_STAR_PROOF_MODE \
    LASTDB_DEV_PRIMARY_HOME="$WORK/no-primary" \
    "$@" \
    bash "$RUN" >"$out" 2>"$err"
  CAP_RC=$?
  set -e
}

report_of() {
  printf '%s\n' "$1/$SLUG.md"
}

first_line() {
  sed -n '1p' "$1"
}

section_lines() {
  awk -v header="$2" '
    $0 == header { on=1; next }
    on && $0 == "" { exit }
    on { print }
  ' "$1"
}

assert_first() {
  local got
  got="$(first_line "$1")"
  [ "$got" = "$2" ] || fail "first line [$got] want [$2] in $1"
}

assert_has() {
  printf '%s\n' "$1" | /usr/bin/grep -F -x -q -- "$2" || fail "missing [$2]"
}

assert_lacks() {
  if printf '%s\n' "$1" | /usr/bin/grep -F -x -q -- "$2"; then
    fail "unexpected [$2]"
  fi
}

assert_rc() {
  [ "$CAP_RC" -eq "$1" ] || fail "exit $CAP_RC want $1"
}

# --- mirrors ---

SCRIPT="$WORK/copy-proof.sh"
LOG="$WORK/invoked"
write_fixture_script "$SCRIPT" "$LOG"

FULL_SRC="$WORK/src-full"
init_repo "$FULL_SRC"
git_commit "$FULL_SRC" empty
EMPTY_OID="$(git -C "$FULL_SRC" rev-parse HEAD)"
add_all_pieces "$FULL_SRC" "$SCRIPT"
git_commit "$FULL_SRC" pieces
FULL_OID="$(git -C "$FULL_SRC" rev-parse HEAD)"

# origin/main lacks the pieces. refs/heads/main holds them.
FAIL_MIRROR="$WORK/fail-origin.git"
publish "$FULL_SRC" "$FAIL_MIRROR" "$EMPTY_OID" "$FULL_OID"

# origin/main holds the pieces. refs/heads/main lacks them.
PASS_MIRROR="$WORK/pass-origin.git"
publish "$FULL_SRC" "$PASS_MIRROR" "$FULL_OID" "$EMPTY_OID"

# Only refs/heads/main exists. The fallback must see the pieces.
FALLBACK_MIRROR="$WORK/fallback.git"
publish "$FULL_SRC" "$FALLBACK_MIRROR" "" "$FULL_OID"

PARTIAL_SRC="$WORK/src-partial"
init_repo "$PARTIAL_SRC"
mkdir -p "$PARTIAL_SRC/fold_db/crates/core/src/resident"
printf 'set\n' >"$PARTIAL_SRC/$PIECE_SET"
git_commit "$PARTIAL_SRC" partial
PARTIAL_OID="$(git -C "$PARTIAL_SRC" rev-parse HEAD)"
PARTIAL_MIRROR="$WORK/partial.git"
publish "$PARTIAL_SRC" "$PARTIAL_MIRROR" "$PARTIAL_OID" "$PARTIAL_OID"

git init -q --bare "$WORK/empty.git"

# --- offline FAIL: mirror absent ---

PROOF="$WORK/proof-mirror-absent"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$WORK/no-such-mirror.git"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The Fold bare mirror is absent." "$REPORT" || fail "mirror sentence"
ABSENT="$(section_lines "$REPORT" "Absent pieces:")"
assert_has "$ABSENT" "- $PIECE_SCRIPT"
assert_has "$ABSENT" "- $PIECE_RANGE"
assert_has "$ABSENT" "- $PIECE_SET"
/usr/bin/grep -F -q "This run does not open a LastDB home." "$REPORT" || fail "home sentence"
/usr/bin/grep -F -x -q "PROOF_VERDICT=FAIL" "$WORK/out" || fail "verdict stdout"
/usr/bin/grep -F -x -q "PROOF_REPORT=$REPORT" "$WORK/out" || fail "report stdout"

# --- offline FAIL: ref absent ---

PROOF="$WORK/proof-ref-absent"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$WORK/empty.git"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "is absent from the bare mirror." "$REPORT" || fail "ref sentence"
ABSENT="$(section_lines "$REPORT" "Absent pieces:")"
assert_has "$ABSENT" "- $PIECE_SCRIPT"
assert_has "$ABSENT" "- $PIECE_RANGE"
assert_has "$ABSENT" "- $PIECE_SET"

# --- offline FAIL: origin/main lacks pieces that main has ---

PROOF="$WORK/proof-origin-lacks"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$FAIL_MIRROR"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "Resolved: origin/main" "$REPORT" || fail "fail mirror resolved main"
ABSENT="$(section_lines "$REPORT" "Absent pieces:")"
assert_has "$ABSENT" "- $PIECE_SCRIPT"
assert_has "$ABSENT" "- $PIECE_RANGE"
assert_has "$ABSENT" "- $PIECE_SET"
[ ! -e "$LOG" ] || fail "offline fail ran the copy proof"

# --- offline FAIL: name only the absent pieces ---

PROOF="$WORK/proof-partial"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PARTIAL_MIRROR"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
ABSENT="$(section_lines "$REPORT" "Absent pieces:")"
PRESENT="$(section_lines "$REPORT" "Present pieces:")"
assert_has "$ABSENT" "- $PIECE_SCRIPT"
assert_has "$ABSENT" "- $PIECE_RANGE"
assert_lacks "$ABSENT" "- $PIECE_SET"
assert_has "$PRESENT" "- $PIECE_SET"
assert_lacks "$PRESENT" "- $PIECE_SCRIPT"
assert_lacks "$PRESENT" "- $PIECE_RANGE"

# --- offline PASS: origin/main holds the pieces; main does not ---

PROOF="$WORK/proof-pass"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$HOME/.lastdb"
assert_rc 0
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" PASS-OFFLINE
case "$(first_line "$REPORT")" in
  PASS*) ;;
  *) fail "passing first line does not start with PASS" ;;
esac
/usr/bin/grep -F -q "Resolved: origin/main" "$REPORT" || fail "pass mirror did not read origin/main"
/usr/bin/grep -F -q "The bare mirror holds the three Fold pieces." "$REPORT" || fail "pass sentence"
/usr/bin/grep -F -q "This run does not open a LastDB home." "$REPORT" || fail "pass home sentence"
/usr/bin/grep -F -q "This run does not run the copy proof." "$REPORT" || fail "pass proof sentence"
ABSENT="$(section_lines "$REPORT" "Absent pieces:")"
PRESENT="$(section_lines "$REPORT" "Present pieces:")"
assert_has "$ABSENT" "- none"
assert_has "$PRESENT" "- $PIECE_SCRIPT"
assert_has "$PRESENT" "- $PIECE_RANGE"
assert_has "$PRESENT" "- $PIECE_SET"
/usr/bin/grep -F -x -q "PROOF_VERDICT=PASS-OFFLINE" "$WORK/out" || fail "pass verdict stdout"
/usr/bin/grep -F -x -q "PROOF_REPORT=$REPORT" "$WORK/out" || fail "pass report stdout"
[ ! -e "$LOG" ] || fail "offline pass ran the copy proof"

# --- offline PASS: refs/heads/main fallback when origin/main is absent ---

PROOF="$WORK/proof-fallback"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$FALLBACK_MIRROR"
assert_rc 0
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" PASS-OFFLINE
/usr/bin/grep -F -q "Resolved: refs/heads/main" "$REPORT" || fail "fallback ref"

# --- invalid mode ---

PROOF="$WORK/proof-mode"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=sideways \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The proof mode is invalid: sideways." "$REPORT" || fail "mode sentence"

# --- live refuse: primary, folddb symlink, and a symlink home ---

PROOF="$WORK/proof-refuse-primary"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$HOME/.lastdb"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The harness refuses a home under the primary LastDB path." "$REPORT" || fail "primary refuse"
[ ! -e "$LOG" ] || fail "primary refuse ran the copy proof"

PROOF="$WORK/proof-refuse-folddb"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$HOME/.folddb"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The harness refuses a home under the primary LastDB path." "$REPORT" || fail "folddb refuse"
[ ! -e "$LOG" ] || fail "folddb refuse ran the copy proof"

ln -s "$HOME/.lastdb" "$WORK/primary-link"
PROOF="$WORK/proof-refuse-link"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$WORK/primary-link"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The harness refuses a home under the primary LastDB path." "$REPORT" || fail "link refuse"
[ ! -e "$LOG" ] || fail "link refuse ran the copy proof"

mkdir -p "$WORK/safe-target"
ln -s "$WORK/safe-target" "$WORK/safe-link"
PROOF="$WORK/proof-refuse-symlink"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$WORK/safe-link"
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The harness refuses a symlink home." "$REPORT" || fail "symlink refuse"
[ ! -e "$LOG" ] || fail "symlink refuse ran the copy proof"

# --- live copies PASS and FAIL without a primary clone ---

COPY="$WORK/copy-home"
mkdir -p "$COPY"
PROOF="$WORK/proof-live-pass"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$COPY"
assert_rc 0
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" PASS
case "$(first_line "$REPORT")" in
  PASS*) ;;
  *) fail "live pass first line does not start with PASS" ;;
esac
/usr/bin/grep -F -q "Copy home: $COPY" "$REPORT" || fail "live copy home"
if /usr/bin/grep -F -q "Copy home: $HOME/.lastdb" "$REPORT"; then
  fail "live report names the primary home"
fi
if /usr/bin/grep -F -q "Copy home: $HOME/.folddb" "$REPORT"; then
  fail "live report names the folddb home"
fi
[ -f "$LOG" ] || fail "live pass did not run the copy proof"
/usr/bin/grep -F -q -- "--home $COPY" "$LOG" || fail "live pass home arg"
/usr/bin/grep -F -q -- "--report " "$LOG" || fail "live pass report arg"
# The copy proof runs cargo from its repo root; a lone extracted script
# has no Cargo.toml above it and can never pass on a real home.
/usr/bin/grep -F -q "cargo_root=yes" "$LOG" || fail "live pass ran the script outside a full Fold tree"
rm -f "$LOG"

PROOF="$WORK/proof-live-fail"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$COPY" \
  LOGICAL_RESIDENT_SET_FIXTURE_VERDICT=FAIL \
  LOGICAL_RESIDENT_SET_FIXTURE_RC=1
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The copy proof returned FAIL." "$REPORT" || fail "live fail sentence"
/usr/bin/grep -F -q "Child exit: 1" "$REPORT" || fail "live fail exit"
rm -f "$LOG"

PROOF="$WORK/proof-live-lie"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LOGICAL_RESIDENT_SET_COPY_HOME="$COPY" \
  LOGICAL_RESIDENT_SET_FIXTURE_VERDICT=PASS \
  LOGICAL_RESIDENT_SET_FIXTURE_RC=1
assert_rc 1
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" FAIL
/usr/bin/grep -F -q "The copy proof printed PASS and exited 1." "$REPORT" || fail "live lie sentence"
rm -f "$LOG"

# --- live CoW clone of a fake primary, never ~/.lastdb ---

FAKE="$WORK/fake-primary"
mkdir -p "$FAKE/data"
printf 'identity\n' >"$FAKE/identity.key"
printf 'secret\n' >"$FAKE/cloud_sync.json"
printf 'secret\n' >"$FAKE/cloud_sync.json.extra"
PROOF="$WORK/proof-live-cow"
invoke "$WORK/out" "$WORK/err" \
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$PROOF" \
  LOGICAL_RESIDENT_SET_FOLD_MIRROR="$PASS_MIRROR" \
  LASTDB_DEV_PRIMARY_HOME="$FAKE"
assert_rc 0
REPORT="$(report_of "$PROOF")"
assert_first "$REPORT" PASS
/usr/bin/grep -F -q "Copy home: " "$REPORT" || fail "cow report has no copy home"
if /usr/bin/grep -F -q "Copy home: $FAKE" "$REPORT"; then
  fail "cow target is the clone source"
fi
if /usr/bin/grep -F -q "Copy home: $HOME/.lastdb" "$REPORT"; then
  fail "cow target is the primary home"
fi
if /usr/bin/grep -F -q "Copy home: $HOME/.folddb" "$REPORT"; then
  fail "cow target is the folddb home"
fi
[ -f "$LOG" ] || fail "cow clone did not run the copy proof"
/usr/bin/grep -F -q "cloud=absent" "$LOG" || fail "cow clone kept cloud_sync"
/usr/bin/grep -F -q "data=dir" "$LOG" || fail "cow clone has no data dir"
if /usr/bin/grep -F -q -- "--home $FAKE" "$LOG"; then
  fail "copy proof received the clone source"
fi
if /usr/bin/grep -F -q -- "--home $HOME/.lastdb" "$LOG"; then
  fail "copy proof received the primary home"
fi

if [ -f "$CANON" ]; then
  CANON_AFTER="$(cksum "$CANON")"
else
  CANON_AFTER="absent"
fi
[ "$CANON_BEFORE" = "$CANON_AFTER" ] || fail "fixture changed the canonical report"

printf '%s\n' "PASS logical-resident-set offline fixture"
