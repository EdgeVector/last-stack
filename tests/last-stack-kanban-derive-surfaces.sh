#!/usr/bin/env bash
# Hermetic fixtures for last-stack-kanban-derive-surfaces and the filer's use
# of it. A card with no surfaces reserves its whole repo in claim-v2, so the
# filer derives surfaces from the repo paths the brief names.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-kanban-derive-surfaces"
filer="$ROOT/bin/last-stack-kanban-file-pr"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A bare mirror shaped like ~/.cache/edgevector-git/<name>.git with the
# origin/main ref the helper reads.
src="$tmp/src"
mkdir -p "$src/bin" "$src/tests" "$src/lib/deploy" "$src/skills/a/scripts"
for f in bin/last-stack-milestone-driver-gate bin/last-stack-milestone-driver-snapshot \
  bin/host-track tests/host-track.sh lib/deploy/step.sh \
  skills/a/scripts/recovery.sh README.md \
  bin/w-common-1 bin/w-common-2 bin/w-common-3 bin/w-common-4; do
  printf 'x\n' >"$src/$f"
done
git -C "$src" init -q -b main
git -C "$src" add -A
git -C "$src" -c user.email=t@t -c user.name=t commit -q -m init
mirrors="$tmp/mirrors"
mkdir -p "$mirrors"
git clone -q --bare "$src" "$mirrors/demo.git"
git -C "$mirrors/demo.git" update-ref refs/remotes/origin/main refs/heads/main
export LAST_STACK_GIT_MIRROR_ROOT="$mirrors"

derive() { printf '%s\n' "$1" | "$bin" --repo EdgeVector/demo; }

# Exact path, trailing punctuation and a line suffix.
[ "$(derive 'Edit `bin/host-track:120`.')" = "bin/host-track" ] || fail "exact path"
# A tracked directory named with a slash reserves that directory.
[ "$(derive 'Touch lib/deploy/ only.')" = "lib/deploy/**" ] || fail "directory"
# A file name with an extension resolves to its one tracked path.
[ "$(derive 'recovery.sh misreads GNU stat')" = "skills/a/scripts/recovery.sh" ] || fail "basename"
# A hyphenated command family resolves to its small file set.
got="$(derive 'Fix two milestone-driver gaps.')"
[ "$got" = "bin/last-stack-milestone-driver-gate,bin/last-stack-milestone-driver-snapshot" ] \
  || fail "subsystem name: $got"
# A name that hits too many files is not a surface.
[ -z "$(derive 'the w-common family')" ] || fail "broad name must not match"
# Plain words and brain slugs are not surfaces.
[ -z "$(derive 'Fix the reseal race. papercut-lastdb-reseal-race-20260923')" ] || fail "prose"
# DECISION-CHECK names brain records, never files.
[ -z "$(derive $'## GOAL\nx\n## DECISION-CHECK\nread: bin/host-track\n')" ] || fail "decision-check"
# URLs are ignored.
[ -z "$(derive 'see http://localhost:3300/EdgeVector/demo/src/branch/main/bin/host-track')" ] || fail "url"
# No mirror: empty answer, exit 0 (the card keeps the whole-repo reservation).
out="$(printf 'bin/host-track\n' | "$bin" --repo EdgeVector/absent)" || fail "missing mirror must exit 0"
[ -z "$out" ] || fail "missing mirror must be empty"
"$bin" --repo nope </dev/null >/dev/null 2>&1 && fail "bad --repo must fail"

# Filer wiring: a fake board records the add args.
mkdir -p "$tmp/bin" "$tmp/empty-fixture" "$tmp/admission/get"
cat >"$tmp/admission/get/preference-feature-delivery-portfolio-admission.txt" <<'TXT'
[preference] preference-feature-delivery-portfolio-admission
---
Policy-Version: 1
Primary: ns-a
Secondary: ns-b
Paused: all-other-feature-north-stars
TXT
cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = milestone ]; then
  printf '{"slug":"ms","state":"active","north_star":"ns-a"}\n'
  exit 0
fi
printf '%s\n' "$*" >>"$FAKE_ADD_LOG"
cat >/dev/null
SH
chmod +x "$tmp/bin/kanban"
export FAKE_ADD_LOG="$tmp/add.log"
body=$'Repo: EdgeVector/demo\n## GOAL\nFix bin/host-track.\n## END STATE\nIt works.\n'
file_card() {
  printf '%s' "$body" | "$filer" "$1" --board-cli "$tmp/bin/kanban" --title t --repo EdgeVector/demo \
    --north-star ns-a --milestone ms --skip-decision-check \
    --admission-fixture "$tmp/admission" "${@:2}" 2>"$tmp/filer.err" >/dev/null
}
: >"$FAKE_ADD_LOG"
file_card derived || fail "filer derived run"
grep -q -- '--surfaces bin/host-track' "$FAKE_ADD_LOG" || fail "filer must pass derived surfaces"
grep -q 'derived surfaces' "$tmp/filer.err" || fail "filer must say it derived surfaces"
: >"$FAKE_ADD_LOG"
file_card explicit --surfaces src/x.ts || fail "filer explicit run"
grep -q -- '--surfaces src/x.ts' "$FAKE_ADD_LOG" || fail "explicit surfaces win"
: >"$FAKE_ADD_LOG"
file_card optout --no-derive-surfaces || fail "filer opt-out run"
grep -q -- '--surfaces' "$FAKE_ADD_LOG" && fail "opt-out must not pass surfaces"
body=$'## GOAL\nFix the thing.\n## END STATE\nIt works.\n'
: >"$FAKE_ADD_LOG"
file_card nopaths || fail "filer no-path run"
grep -q -- '--surfaces' "$FAKE_ADD_LOG" && fail "no path, no surfaces"
grep -q 'reserves all of EdgeVector/demo' "$tmp/filer.err" || fail "filer must warn on whole-repo card"

printf 'PASS last-stack-kanban-derive-surfaces\n'
