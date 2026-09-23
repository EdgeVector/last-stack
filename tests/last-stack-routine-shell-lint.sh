#!/usr/bin/env bash
# Fixture test for bin/last-stack-routine-shell-lint, the Claude hook that
# wraps it, and the Codex routine zsh->bash entry snippet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LINT="$ROOT/bin/last-stack-routine-shell-lint"
HOOK="$ROOT/hooks/routine-shell-lint.sh"
SNIPPET="$ROOT/lib/routine-shell/codex-routine-bash.zsh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/shell-lint-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail=0
expect() {
  # expect <want-rc> <shell> <label> ; command text on stdin
  local want="$1" shell="$2" label="$3" got
  set +e
  "$LINT" --shell "$shell" --quiet
  got=$?
  set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL [$label] shell=$shell want rc=$want got rc=$got" >&2
    fail=1
  fi
}

# --- spin-wait ---------------------------------------------------------------
expect 2 bash spin-basic <<'EOF'
while ! grep -q done f; do read -t 20 < /dev/zero; done
EOF
expect 2 bash spin-flags <<'EOF'
timeout 590 bash -c 'while true; do read -r -t 5 x </dev/zero 2>/dev/null; done'
EOF
expect 0 bash sleep-ok <<'EOF'
while ! grep -q done f; do sleep 30; done
EOF
expect 0 bash read-stdin-ok <<'EOF'
while IFS= read -r slug; do echo "$slug"; done < slugs.txt
EOF
expect 0 bash dd-dev-zero-ok <<'EOF'
dd if=/dev/zero of=blob bs=1k count=1
EOF

# --- heredoc-backticks -------------------------------------------------------
expect 2 bash heredoc-unquoted-backticks <<'OUTER'
cat > "$f" <<EOF
Closed `papercut-x` after the fix.
EOF
brain append x --type papercut < "$f"
OUTER
expect 0 bash heredoc-quoted-backticks <<'OUTER'
cat > "$f" <<'EOF'
Closed `papercut-x` after the fix. Also read -t 20 < /dev/zero is data here.
EOF
brain append x --type papercut < "$f"
OUTER
expect 0 bash heredoc-dquoted-backticks <<'OUTER'
cat > "$f" <<"EOF"
Closed `papercut-x`.
EOF
OUTER
expect 0 bash heredoc-unquoted-vars-ok <<'OUTER'
cat > "$f" <<EOF
run=$ROUTINES_RUN_DIR slug=$slug
EOF
OUTER
expect 2 bash heredoc-dash-tabs <<'OUTER'
cat <<-EOF
	see `x`
	EOF
OUTER
expect 0 bash herestring-ok <<'OUTER'
jq -r '.slug' <<< "$json"
OUTER
expect 2 bash second-heredoc-on-line <<'OUTER'
paste - - <<'A' 3<<B
`fine`
A
`bad`
B
OUTER
expect 0 bash after-heredoc-command-checked-clean <<'OUTER'
cat <<'EOF'
`x`
EOF
echo ok
OUTER
expect 2 bash after-heredoc-command-checked-bad <<'OUTER'
cat <<'EOF'
text
EOF
while true; do read -t 3 < /dev/zero; done
OUTER

expect 2 bash dquote-body-backticks <<'OUTER'
brain papercut close x --status verified --evidence "ran `kanban ping` ok"
OUTER
expect 0 bash dquote-body-file-ok <<'OUTER'
brain papercut close x --status verified --evidence "$(cat "$f")"
OUTER
expect 0 bash squote-body-backticks-ok <<'OUTER'
brain papercut close x --status verified --evidence 'ran `kanban ping` ok'
OUTER

# --- jq rules ----------------------------------------------------------------
expect 2 bash jq-match-optional-field <<'EOF'
jq -r '.body | match("DONE-WHEN:.*")?.string' card.json
EOF
expect 2 bash jq-capture-optional-field <<'EOF'
jq -r '.body // "" | capture("(?m)^DONE-WHEN:[[:space:]]*(?<p>.*)$")?.p // empty' c.json
EOF
expect 2 bash jq-paren-optional <<'EOF'
jq '(.a)?.b' x.json
EOF
expect 0 bash jq-field-optional-ok <<'EOF'
jq -r '.cards[]?.slug, .a?.b' x.json
EOF
expect 0 bash jq-try-ok <<'EOF'
jq -r 'try (.body | match("DONE-WHEN:.*").string) catch ""' card.json
EOF
expect 2 bash jq-escaped-quote <<'EOF'
jq -r '.[] | "\(.slug) \(.status) \(.severity // \"\")"' sit.json
EOF
expect 0 bash jq-interpolation-ok <<'EOF'
jq -r '.[] | "\(.slug) \(.status) \(.severity)"' sit.json
EOF
expect 0 bash jq-tsv-ok <<'EOF'
jq -r '.[] | [.slug, .status, (.severity // "-")] | @tsv' sit.json
EOF

# --- awk / sed ---------------------------------------------------------------
expect 2 bash awk-match-array <<'EOF'
awk 'match($0,/^DONE-WHEN:[[:space:]]*(.*)$/,m){print m[1]; exit}' body.md
EOF
expect 0 bash awk-match-two-args-ok <<'EOF'
awk 'match($0,/DONE-WHEN:/){print substr($0, RSTART)}' body.md
EOF
expect 2 bash sed-inplace-bare <<'EOF'
sed -i 's/^ tags:/tags:/' body.md
EOF
expect 2 bash sed-inplace-unquoted <<'EOF'
sed -i s/a/b/ body.md
EOF
expect 0 bash sed-inplace-empty-ext-ok <<'EOF'
sed -i '' 's/a/b/' body.md
EOF
expect 0 bash sed-inplace-bak-ok <<'EOF'
sed -i.bak 's/a/b/' body.md
EOF
expect 0 bash sed-n-ok <<'EOF'
sed -n 's/^DONE-WHEN:[[:space:]]*//p' body.md
EOF

expect 2 bash date-nanos <<'EOF'
start_ms=$(date +%s%3N); kanban ping; end_ms=$(date +%s%3N)
EOF
expect 0 bash gdate-nanos-ok <<'EOF'
start_ms=$(gdate +%s%3N)
EOF
expect 0 bash date-iso-ok <<'EOF'
date -u +%Y-%m-%dT%H:%M:%SZ
EOF

# --- zsh-only rules ----------------------------------------------------------
expect 2 zsh zsh-status-assign <<'EOF'
for pr in 1 2; do status=$(curl -s x); echo "$status"; done
EOF
expect 2 zsh zsh-status-read <<'EOF'
while IFS=$'\t' read -r slug status title; do echo "$slug"; done < rows.tsv
EOF
expect 0 bash bash-status-ok <<'EOF'
status=$(curl -s x); echo "$status"
EOF
expect 0 zsh zsh-status-word-ok <<'EOF'
routines status --json > s.json; jq -r '.status' s.json; git status --short
EOF
expect 2 zsh zsh-status-after-do <<'EOF'
for pr in 1 2; do status=$(curl -s x); done
EOF
expect 2 zsh zsh-status-line-start <<'EOF'
status="$(git rev-parse HEAD)"
EOF
expect 0 zsh zsh-status-in-grep-alternation-ok <<'EOF'
brain get x --type papercut | grep -n -i 'duplicate of\|status=\|done' | head
EOF
expect 0 zsh zsh-status-in-dquoted-arg-ok <<'EOF'
brain papercut close x --status verified --evidence "outcome.txt says status=ok"
EOF
expect 0 zsh zsh-status-key-in-url-ok <<'EOF'
last-stack-forge-api 'repos/o/r/pulls?status=open&limit=5' --jq '.[] | .number'
EOF
expect 2 zsh zsh-mapfile <<'EOF'
mapfile -t slugs < slugs.txt
EOF
expect 0 bash bash-mapfile-ok <<'EOF'
mapfile -t slugs < slugs.txt
EOF

# --- escape hatch and usage --------------------------------------------------
expect 0 bash escape-hatch <<'EOF'
sed -i 's/a/b/' f   # shell-lint-ok: GNU sed on the PC
EOF
if "$LINT" --shell fish </dev/null 2>/dev/null; then
  echo "FAIL [bad-shell] want usage error" >&2; fail=1
fi
msg="$(printf '%s\n' "jq '(.a)?.b' x" | "$LINT" 2>&1 || true)"
case "$msg" in
  *"rule=jq-optional-call"*"Do NOT file a papercut"*) ;;
  *) echo "FAIL [message] rejection text lacks rule id or no-refile line: $msg" >&2; fail=1 ;;
esac

# --- Claude hook -------------------------------------------------------------
hook_json() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' \
    | LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "$HOOK"
}
out="$(hook_json 'while true; do read -t 5 < /dev/zero; done')"
if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo "FAIL [hook-deny] got: $out" >&2; fail=1
fi
out="$(hook_json 'status=$(git rev-parse HEAD)')"
if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("zsh-status")' >/dev/null; then
  echo "FAIL [hook-zsh-mode] got: $out" >&2; fail=1
fi
out="$(hook_json 'echo ok')"
if [ -n "$out" ]; then
  echo "FAIL [hook-allow] want no output, got: $out" >&2; fail=1
fi
out="$(printf 'not json' | LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "$HOOK")"
if [ -n "$out" ]; then
  echo "FAIL [hook-fail-open] want no output on bad input, got: $out" >&2; fail=1
fi
out="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}}' \
  | LAST_STACK_ROUTINE_SHELL_LINT="$tmp/missing" "$HOOK")"
if [ -n "$out" ]; then
  echo "FAIL [hook-missing-lint] want fail-open, got: $out" >&2; fail=1
fi

# --- Codex routine entry snippet (zsh -c -> bash, via ~/.zshenv) -------------
if command -v zsh >/dev/null 2>&1; then
  zdot="$tmp/zdot"
  mkdir -p "$zdot"
  printf '. %q\n' "$SNIPPET" > "$zdot/.zshenv"
  run_z() {
    # run_z <env...> -- <command>
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" ZDOTDIR="$zdot" \
      LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "${envs[@]}" /bin/zsh -c "$1"
  }
  routine_env=(DRIVEN_BY=routine CODEX_THREAD_ID=test-thread)

  got="$(run_z "${routine_env[@]}" -- 'echo "${BASH_VERSION:+bash}${ZSH_VERSION:+zsh}"')"
  [ "$got" = bash ] || { echo "FAIL [snippet-bash] want bash, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" -- 'status=7; echo "s=$status"')"
  [ "$got" = "s=7" ] || { echo "FAIL [snippet-status] want s=7, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" -- 'spec="fold 2147"; set -- $spec; echo "$1|$2"')"
  [ "$got" = "fold|2147" ] || { echo "FAIL [snippet-wordsplit] got '$got'" >&2; fail=1; }

  set +e
  run_z "${routine_env[@]}" -- 'exit 5' ; rc=$?
  set -e
  [ "$rc" = 5 ] || { echo "FAIL [snippet-exit-code] want 5, got $rc" >&2; fail=1; }

  set +e
  err="$(run_z "${routine_env[@]}" -- 'while true; do read -t 1 < /dev/zero; done' 2>&1)"; rc=$?
  set -e
  [ "$rc" = 2 ] || { echo "FAIL [snippet-lint-reject] want 2, got $rc: $err" >&2; fail=1; }

  got="$(run_z -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-not-routine] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z DRIVEN_BY=routine -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-not-codex] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" LAST_STACK_ROUTINE_SHELL=zsh -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-opt-out] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" CLAUDECODE=1 -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-claude] want zsh, got '$got'" >&2; fail=1; }

  # Codex wrapper form: outer zsh execs an inner zsh -c; the inner one
  # (which reads .zshenv again) is the one that becomes bash.
  got="$(run_z "${routine_env[@]}" -- "exec '/bin/zsh' -c 'status=4; echo \"w=\$status \${BASH_VERSION:+bash}\"'")"
  [ "$got" = "w=4 bash" ] || { echo "FAIL [snippet-codex-wrapper] got '$got'" >&2; fail=1; }
  set +e
  run_z "${routine_env[@]}" -- "exec '/bin/zsh' -c 'cat <<'\"'\"'EOF'\"'\"'
sed -i 's/a/b/' f is only text here
EOF'" >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" = 0 ] || { echo "FAIL [snippet-wrapper-heredoc-data] want 0, got $rc" >&2; fail=1; }

  # A zsh script file has no -c string and stays zsh.
  printf 'echo "${ZSH_VERSION:+zsh}"\n' > "$tmp/script.zsh"
  got="$(env -i HOME="$HOME" PATH=/usr/bin:/bin ZDOTDIR="$zdot" "${routine_env[@]}" /bin/zsh "$tmp/script.zsh")"
  [ "$got" = zsh ] || { echo "FAIL [snippet-script] want zsh, got '$got'" >&2; fail=1; }
fi

# --- setup: managed ~/.zshenv block is idempotent and last ------------------
(
  set -e
  eval "$(sed -n '/^strip_managed_md_block()/,/^}/p' "$ROOT/setup")"
  eval "$(sed -n "/^RSZ_START=/p;/^RSZ_END=/p" "$ROOT/setup")"
  eval "$(sed -n '/^install_routine_shell_zshenv()/,/^}/p' "$ROOT/setup")"
  SOURCE_ROOT="$ROOT"
  ZDOTDIR="$tmp/setup-z"
  mkdir -p "$ZDOTDIR"
  printf 'export PATH="/x/bin:$PATH"\n' > "$ZDOTDIR/.zshenv"
  install_routine_shell_zshenv >/dev/null
  printf 'export LATER=1\n' >> "$ZDOTDIR/.zshenv"
  install_routine_shell_zshenv >/dev/null
  [ "$(grep -c 'codex-routine-bash.zsh' "$ZDOTDIR/.zshenv")" = 1 ]
  [ "$(tail -n 1 "$ZDOTDIR/.zshenv")" = "$RSZ_END" ]
  grep -q '^export PATH="/x/bin:$PATH"$' "$ZDOTDIR/.zshenv"
  grep -q '^export LATER=1$' "$ZDOTDIR/.zshenv"
) || { echo "FAIL [setup-zshenv] block not idempotent or not last" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ok last-stack-routine-shell-lint"
