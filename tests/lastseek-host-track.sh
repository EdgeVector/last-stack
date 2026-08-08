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

registry="$ROOT/config/host-track/apps.json"
post_install="$ROOT/bin/last-stack-lastseek-host-track-post-install"

jq -e '
  .apps[] | select(.app == "lastseek")
  | .install_mode == "artifact"
    and .kind == "artifact cli"
    and .command == "lastseek"
    and .gate == "lastgit"
    and .gate_main == "lastdb:///lastseek#main"
    and .track_gate_main == true
    and .artifact_app == "lastseek"
    and .artifact_channel == "stable"
    and .artifact_root == "$HOME/.lastgit/artifacts"
    and .install_root == "$HOME/.host-track/apps/lastseek"
    and .post_install == "$HOME/.local/bin/last-stack-lastseek-host-track-post-install"
    and any(.links[]; .source == "dist/lastseek" and .target == "$HOME/.local/bin/lastseek")
' "$registry" >/dev/null || fail "lastseek registry entry does not match the artifact contract"

jq -e '
  .apps[] | select(.app == "last-stack")
  | any(.links[];
      .source == "bin/last-stack-lastseek-host-track-post-install"
      and .target == "$HOME/.local/bin/last-stack-lastseek-host-track-post-install")
' "$registry" >/dev/null || fail "last-stack artifact does not publish the stable post-install shim"

[ -x "$post_install" ] || fail "lastseek post-install verifier is not executable"

fake_bin="$tmp/fake-bin"
model_dir="$tmp/models/bge-small-en-v1.5"
network_marker="$tmp/network-called"
mkdir -p "$fake_bin" "$model_dir"
cat > "$fake_bin/curl" <<SH
#!/usr/bin/env bash
printf 'called\n' > "$network_marker"
exit 99
SH
chmod +x "$fake_bin/curl"

if LASTSEEK_MODEL_DIR="$model_dir" PATH="$fake_bin:/usr/bin:/bin" \
  "$post_install" >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  fail "missing model files passed post-install verification"
fi
[ ! -e "$network_marker" ] || fail "post-install verifier attempted a network download"
grep -Fq 'model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json' \
  "$tmp/missing.err" || fail "missing-file diagnostic did not name all five files"
grep -Fq 'base="https://huggingface.co/Xenova/bge-small-en-v1.5/resolve/main"' \
  "$tmp/missing.err" || fail "missing-file diagnostic omitted the README fetch source"
grep -Fq 'curl -L "$base/onnx/model.onnx" -o "$dir/model.onnx"' \
  "$tmp/missing.err" || fail "missing-file diagnostic omitted the README model fetch command"

required_files=(
  model.onnx
  tokenizer.json
  config.json
  special_tokens_map.json
  tokenizer_config.json
)
for file in "${required_files[@]}"; do
  printf 'fixture %s\n' "$file" > "$model_dir/$file"
done

LASTSEEK_MODEL_DIR="$model_dir" PATH="$fake_bin:/usr/bin:/bin" \
  "$post_install" >"$tmp/present.out"
grep -Fq 'verified five bge-small-en-v1.5 model files' "$tmp/present.out" \
  || fail "successful verification did not report the five-file contract"
[ ! -e "$network_marker" ] || fail "successful post-install verification used the network"

for file in "${required_files[@]}"; do
  mv "$model_dir/$file" "$model_dir/$file.hold"
  if LASTSEEK_MODEL_DIR="$model_dir" PATH="$fake_bin:/usr/bin:/bin" \
    "$post_install" >"$tmp/one-missing.out" 2>"$tmp/one-missing.err"; then
    fail "post-install verification passed with $file missing"
  fi
  grep -Fq "$file" "$tmp/one-missing.err" \
    || fail "missing-file diagnostic did not name $file"
  mv "$model_dir/$file.hold" "$model_dir/$file"
done

[ ! -e "$network_marker" ] || fail "negative verification cases used the network"

printf 'ok: lastseek artifact registry + model post-install verification\n'
