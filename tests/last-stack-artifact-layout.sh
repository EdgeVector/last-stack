#!/usr/bin/env bash
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
compat="$HOME/.last-stack"
install_root="$compat/.artifacts"
version="$install_root/versions/manifest-one"
backup_root="$tmp/backups"
mkdir -p "$compat/.git" "$compat/launchd" "$version"
printf 'keep-git\n' > "$compat/.git/marker"
printf 'keep-launchd\n' > "$compat/launchd/marker"

managed=(VERSION setup bin config docs harness hooks instructions lib routines skills templates)
for rel in "${managed[@]}"; do
  case "$rel" in
    VERSION)
      printf 'old\n' > "$compat/$rel"
      printf 'new\n' > "$version/$rel"
      ;;
    setup)
      printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\n" "$LAST_STACK_ROOT" > "$HOME/setup-ran"\n' > "$compat/$rel"
      cp "$compat/$rel" "$version/$rel"
      chmod +x "$compat/$rel" "$version/$rel"
      ;;
    *)
      mkdir -p "$compat/$rel" "$version/$rel"
      printf 'old-%s\n' "$rel" > "$compat/$rel/marker"
      printf 'new-%s\n' "$rel" > "$version/$rel/marker"
      ;;
  esac
done
ln -s "versions/manifest-one" "$install_root/current"

dry="$tmp/dry-run.txt"
LAST_STACK_LAYOUT_BACKUP_ROOT="$backup_root" "$ROOT/bin/last-stack-activate-artifact-layout" --dry-run > "$dry"
grep -q 'WOULD_LINK' "$dry" || fail "dry run did not report planned links"
[ ! -L "$compat/bin" ] || fail "dry run changed compatibility paths"

result="$(LAST_STACK_LAYOUT_BACKUP_ROOT="$backup_root" "$ROOT/bin/last-stack-activate-artifact-layout")"
printf '%s\n' "$result" | grep -q 'result=activated' || fail "activation did not report success"
for rel in "${managed[@]}"; do
  [ -L "$compat/$rel" ] || fail "$rel is not an artifact compatibility link"
  [ "$(readlink "$compat/$rel")" = "$install_root/current/$rel" ] || fail "$rel points at the wrong artifact path"
done
[ "$(cat "$compat/bin/marker")" = new-bin ] || fail "compatibility path did not expose artifact content"
[ "$(cat "$HOME/setup-ran")" = "$install_root/current" ] || fail "setup did not run from the artifact root"
[ "$(cat "$compat/.git/marker")" = keep-git ] || fail ".git state was changed"
[ "$(cat "$compat/launchd/marker")" = keep-launchd ] || fail "launchd state was changed"
backup="$(printf '%s\n' "$result" | sed -n 's/.* backup=\([^ ]*\).*/\1/p')"
[ "$(cat "$backup/bin/marker")" = old-bin ] || fail "old code was not preserved in the recovery tree"

second="$(LAST_STACK_LAYOUT_BACKUP_ROOT="$backup_root" "$ROOT/bin/last-stack-activate-artifact-layout")"
printf '%s\n' "$second" | grep -q 'moved=0' || fail "repeat activation was not idempotent"

printf 'ok: Last Stack artifact compatibility layout\n'
