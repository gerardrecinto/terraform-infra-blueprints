#!/usr/bin/env bash
# Build a signed bundle on the connected side.
# Usage: export.sh <images.txt> <charts-dir> <out-dir> <cosign-private-key>
#   images.txt  one image reference per line (blank lines and # comments ignored)
#   charts-dir  directory of packaged charts (*.tgz); may be empty
# The private key password comes from COSIGN_PASSWORD.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
need crane; need cosign; need jq

[ $# -eq 4 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
images_file="$1"; charts_dir="$2"; out="$3"; key="$4"

rm -rf "$out"
mkdir -p "$out/images" "$out/charts"

entries="[]"
while IFS= read -r ref; do
  ref="${ref%%#*}"; ref="$(echo "$ref" | xargs)"
  [ -n "$ref" ] || continue
  name="$(safe_name "$ref")"
  digest="$(crane digest "$ref")"
  crane pull --format oci "$ref" "$out/images/$name" 2>/dev/null
  # The OCI layout's index must point at the digest the registry reported.
  layout_digest="$(jq -r '.manifests[0].digest' "$out/images/$name/index.json")"
  [ "$layout_digest" = "$digest" ] || fail "$ref: registry digest $digest but layout has $layout_digest"
  entries="$(echo "$entries" | jq --arg ref "$ref" --arg name "$name" --arg digest "$digest" \
    '. + [{kind:"image", ref:$ref, path:("images/"+$name), digest:$digest}]')"
  echo "exported image $ref $digest"
done < "$images_file"

shopt -s nullglob
for chart in "$charts_dir"/*.tgz; do
  base="$(basename "$chart")"
  cp "$chart" "$out/charts/$base"
  sum="$(sha256_file "$out/charts/$base")"
  entries="$(echo "$entries" | jq --arg path "charts/$base" --arg sha "$sum" \
    '. + [{kind:"chart", path:$path, sha256:$sha}]')"
  echo "exported chart $base sha256:$sum"
done

echo "$entries" | jq '{version:1, created: (now|todate), entries: .}' > "$out/manifest.json"
cp "${key%.key}.pub" "$out/cosign.pub" 2>/dev/null || true
cosign sign-blob --yes --key "$key" --output-signature "$out/manifest.sig" "$out/manifest.json" >/dev/null 2>&1
echo "signed manifest.json -> manifest.sig"
echo "bundle ready: $out"
