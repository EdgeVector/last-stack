#!/usr/bin/env bash
# Every hook file in last-stack/hooks/ must reach the host, and must be wired
# to an event once it is there.
#
# `install_claude_hooks` used to copy a HARDCODED LIST OF FOUR hook names, so a
# hook added to hooks/ installed nowhere: the installer ran, printed success,
# and skipped the file because it was not named in the list. The repo copy then
# read as managed while being decorative, and nothing compared it to the live
# one. Brain:
# papercut-setup-installs-a-hardcoded-list-of-four-hooks-so-a-hook-added-to-the-repo-installs-nowhere-20261004
#
# Case 1 is behavioural and covers the COPY: a hook this repo has never seen is
# dropped into a copy of the source tree, setup runs against a throwaway HOME,
# and the file must appear under ~/.claude/hooks. A literal-list loop fails it.
#
# Case 2 is structural and covers the REGISTRATION, which is still a literal
# enumeration on purpose — each hook needs its own event, matcher and notice
# text, so a glob cannot write it. Copying a hook without registering it is the
# same silent failure one layer down, so every hooks/*.sh must either be named
# in a registration call or be listed in hooks/UNREGISTERED with a reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------- case 1: copy
src="$tmp/src"
mkdir -p "$src"
# Copy the source tree without .git: setup resolves SOURCE_ROOT to its own
# directory when no artifact root is present, so the copy's hooks/ is the one
# it installs from.
(cd "$ROOT" && tar --exclude='./.git' -cf - .) | (cd "$src" && tar -xf -)
[ -f "$src/setup" ] || fail "tree copy did not carry setup"
[ -d "$src/hooks" ] || fail "tree copy did not carry hooks/"

probe="zz-install-probe-hook.sh"
cat > "$src/hooks/$probe" <<'PROBE'
#!/usr/bin/env bash
# Fixture only. Never registered, never shipped: this file exists inside a
# throwaway copy of the source tree so the installer has a hook it has never
# been told about by name.
exit 0
PROBE
chmod 755 "$src/hooks/$probe"

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"

"$src/setup" --host claude >"$tmp/setup.out" 2>"$tmp/setup.err" || {
  sed -n '1,40p' "$tmp/setup.err" >&2
  fail "setup --host claude exited non-zero against the copied tree"
}

for hook_src in "$src/hooks"/*.sh; do
  hook="$(basename "$hook_src")"
  [ -f "$HOME/.claude/hooks/$hook" ] || fail \
    "setup did not install hooks/$hook. install_claude_hooks must iterate \$HOOKS_SRC/*.sh, not a literal list of hook names."
done

# -------------------------------------------------------- case 2: registration
# Strip comments first: the rationale comment inside install_claude_hooks names
# a retired hook, and a guard that reads its own explanation is reading the
# wrong thing.
registrations="$tmp/setup.nocomments"
sed 's/[[:space:]]*#.*$//' "$ROOT/setup" > "$registrations"

unregistered_file="$ROOT/hooks/UNREGISTERED"

for hook_src in "$ROOT/hooks"/*.sh; do
  hook="$(basename "$hook_src")"
  if grep -Fq "\$hooks_dir/$hook" "$registrations"; then
    continue
  fi
  if [ -f "$unregistered_file" ] && grep -Fq "$hook" "$unregistered_file"; then
    continue
  fi
  fail "hooks/$hook is installed but never registered: no \$hooks_dir/$hook argument in a setup registration call, and no entry in hooks/UNREGISTERED. Register it on its real event, or list it in hooks/UNREGISTERED with the reason it ships unarmed."
done

echo "ok"
