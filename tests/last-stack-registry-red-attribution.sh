#!/usr/bin/env bash
# Fixture test for bin/last-stack-registry-red-attribution: turns a
# llms-txt-install-smoke proof's fails[] into a per-app verdict.
#
# Fault injection is the point: a RED proof shaped like the real 2026-09-28
# incident (one missing ~/Library/LaunchAgents dir broke install-apps for 6
# of 9 apps; brain, kanban, situations had zero fails of their own) must
# come back "these three passed", not "everything failed" and not "everything
# passed" — the old all-or-nothing gate blocked rows for ALL 9 apps that day,
# including the 3 that had nothing wrong.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-red-attribution"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/red-attribution-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

apps9="brain kanban situations routines dogfood-graph org lastsecrets search lastdb-browser"

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# --- GREEN passes straight through, no attribution needed -------------------
cat >"$WORK/green.json" <<'EOF'
{"verdict":"GREEN","sandbox":"/x","pass":40}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/green.json")"
[ "$out" = "verdict=GREEN" ] || fail "GREEN proof: got [$out]"

# --- the 2026-09-28 shape: install-apps failed for 6 named apps, 3 clean ---
cat >"$WORK/isolated.json" <<'EOF'
{"verdict":"RED","sandbox":"/x","fails":[
  "install-apps:routines:proved (wanted proved; lastdb=none)",
  "install-apps:org:proved",
  "install-apps:dogfood-graph:proved",
  "install-apps:lastsecrets:proved",
  "install-apps:search:proved",
  "install-apps:lastdb-browser:proved"
]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/isolated.json")"
[ "$(field "$out" verdict)" = RED ] || fail "isolated: verdict"
[ "$(field "$out" shared_fail)" = 0 ] || fail "isolated: shared_fail should be 0, got [$(field "$out" shared_fail)]"
passed="$(field "$out" passed_apps)"
for a in brain kanban situations; do
  case " $passed " in *" $a "*) ;; *) fail "isolated: $a should be in passed_apps=[$passed]" ;; esac
done
for a in routines org dogfood-graph lastsecrets search lastdb-browser; do
  case " $passed " in *" $a "*) fail "isolated: $a should NOT be in passed_apps=[$passed]" ;; esac
done

# --- cli: shape attributes the same way as install-apps: -------------------
cat >"$WORK/cli.json" <<'EOF'
{"verdict":"RED","fails":["cli:search not on PATH"]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/cli.json")"
[ "$(field "$out" shared_fail)" = 0 ] || fail "cli: shared_fail should be 0"
case " $(field "$out" passed_apps) " in *" search "*) fail "cli: search should not have passed" ;; esac
case " $(field "$out" failed_apps) " in *" search "*) ;; *) fail "cli: search should be in failed_apps" ;; esac

# --- <app>:<check> shape (brain:config, search:init, ...) ------------------
cat >"$WORK/appcheck.json" <<'EOF'
{"verdict":"RED","fails":["search:init timeout=30s"]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/appcheck.json")"
[ "$(field "$out" shared_fail)" = 0 ] || fail "appcheck: shared_fail should be 0"
case " $(field "$out" failed_apps) " in *" search "*) ;; *) fail "appcheck: search should be in failed_apps" ;; esac

# --- a shared/cross-cutting fail (the isolated node itself) is never safe --
for shape in \
  '{"verdict":"RED","fails":["daemon:socket never appeared"]}' \
  '{"verdict":"RED","fails":["prereq:bun missing"]}' \
  '{"verdict":"RED","fails":["brew-service:formula not installed"]}' \
  '{"verdict":"RED","fails":["resolver:unavailable no answer"]}' \
  '{"verdict":"RED","fails":["install-apps missing"]}' \
  '{"verdict":"RED","reason":"prereqs","sandbox":"/x"}'
do
  printf '%s' "$shape" >"$WORK/shared.json"
  out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/shared.json")"
  [ "$(field "$out" shared_fail)" = 1 ] || fail "shared shape got shared_fail=$(field "$out" shared_fail) for: $shape"
done

# --- a mix of one shared fail and one per-app fail is still shared ---------
cat >"$WORK/mixed.json" <<'EOF'
{"verdict":"RED","fails":["daemon:socket never appeared","install-apps:org:proved"]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/mixed.json")"
[ "$(field "$out" shared_fail)" = 1 ] || fail "mixed: one shared fail must still gate everything"

# --- every known app failing its own check leaves nothing to prove ---------
fails_json=""
for a in $apps9; do
  fails_json="${fails_json:+$fails_json,}\"install-apps:$a:proved\""
done
printf '{"verdict":"RED","fails":[%s]}' "$fails_json" >"$WORK/all9.json"
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/all9.json")"
[ "$(field "$out" shared_fail)" = 0 ] || fail "all9: shared_fail should be 0"
[ -z "$(field "$out" passed_apps)" ] || fail "all9: passed_apps should be empty, got [$(field "$out" passed_apps)]"

# --- the smoke also prints `install-apps exit=1` whenever any app fails -------
# last-stack-install-apps attempts every app and exits 1 only after naming each
# failed one, so the exit line next to named app lines is those apps' failure,
# not a shared one. Real shape, 2026-09-28 (one app failed at its source).
cat >"$WORK/exit-with-app.json" <<'EOF'
{"verdict":"RED","sandbox":"/x","fails":[
  "install-apps exit=1",
  "install-apps:situations:failed (wanted pinned; lastdb=/x; stage=source sha=38b0b7f6d689 source=lastdb:///situations)"
]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/exit-with-app.json")"
[ "$(field "$out" shared_fail)" = 0 ] || fail "exit+app: shared_fail should be 0, got [$out]"
[ "$(field "$out" failed_apps)" = situations ] || fail "exit+app: failed_apps [$(field "$out" failed_apps)]"
[ "$(field "$out" passed_apps)" = "brain kanban routines dogfood-graph org lastsecrets search lastdb-browser" ] \
  || fail "exit+app: passed_apps [$(field "$out" passed_apps)]"

# An exit with no named app line failed before or outside any one app: shared.
cat >"$WORK/exit-alone.json" <<'EOF'
{"verdict":"RED","sandbox":"/x","fails":["install-apps exit=127"]}
EOF
out="$(LAST_STACK_REGISTRY_KNOWN_APPS="$apps9" "$BIN" --proof "$WORK/exit-alone.json")"
[ "$(field "$out" shared_fail)" = 1 ] || fail "exit alone: shared_fail should be 1, got [$out]"

echo "OK: last-stack-registry-red-attribution"
