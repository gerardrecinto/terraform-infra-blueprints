#!/usr/bin/env bash
# Verify a bundle on the disconnected side. No network needed.
# Usage: verify.sh <bundle-dir> <cosign-public-key>
# Checks, in order: manifest signature, every chart sha256, every image layout
# (index digest matches the manifest, every blob file hashes to its own name).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
need cosign; need jq

[ $# -eq 2 ] || { sed -n '2,6p' "$0" >&2; exit 2; }
bundle="$1"; pub="$2"

[ -f "$bundle/manifest.json" ] || fail "manifest.json missing"
[ -f "$bundle/manifest.sig" ] || fail "manifest.sig missing"

cosign verify-blob --key "$pub" --signature "$bundle/manifest.sig" "$bundle/manifest.json" >/dev/null 2>&1 \
  || fail "manifest signature does not verify against $pub"
echo "ok   manifest signature"

count=0
while IFS= read -r entry; do
  kind="$(echo "$entry" | jq -r .kind)"
  path="$(echo "$entry" | jq -r .path)"
  case "$kind" in
    chart)
      want="$(echo "$entry" | jq -r .sha256)"
      [ -f "$bundle/$path" ] || fail "$path is missing"
      got="$(sha256_file "$bundle/$path")"
      [ "$got" = "$want" ] || fail "$path sha256 is $got, manifest says $want"
      echo "ok   $path"
      ;;
    image)
      want="$(echo "$entry" | jq -r .digest)"
      dir="$bundle/$path"
      [ -f "$dir/index.json" ] || fail "$path/index.json is missing"
      got="$(jq -r '.manifests[0].digest' "$dir/index.json")"
      [ "$got" = "$want" ] || fail "$path index digest is $got, manifest says $want"
      for blob in "$dir"/blobs/sha256/*; do
        name="$(basename "$blob")"
        sum="$(sha256_file "$blob")"
        [ "$sum" = "$name" ] || fail "$path blob $name hashes to $sum"
      done
      [ -f "$dir/blobs/sha256/${want#sha256:}" ] || fail "$path is missing its manifest blob"
      echo "ok   $path ($want)"
      ;;
    *) fail "unknown entry kind: $kind" ;;
  esac
  count=$((count + 1))
done < <(jq -c '.entries[]' "$bundle/manifest.json")

[ "$count" -gt 0 ] || fail "manifest has no entries"
echo "verified $count entries"
