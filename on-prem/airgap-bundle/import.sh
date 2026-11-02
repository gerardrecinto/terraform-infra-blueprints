#!/usr/bin/env bash
# Import a verified bundle into an internal registry.
# Usage: import.sh <bundle-dir> <cosign-public-key> <registry-host:port>
# Refuses to import anything unless verify.sh passes first.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
need crane; need jq

[ $# -eq 3 ] || { sed -n '2,5p' "$0" >&2; exit 2; }
bundle="$1"; pub="$2"; registry="$3"

"$here/verify.sh" "$bundle" "$pub" || fail "bundle did not verify, nothing imported"

while IFS= read -r entry; do
  kind="$(echo "$entry" | jq -r .kind)"
  if [ "$kind" = "image" ]; then
    ref="$(echo "$entry" | jq -r .ref)"
    path="$(echo "$entry" | jq -r .path)"
    repo_tag="$(repo_and_tag "$ref")"
    crane push --insecure "$bundle/$path" "$registry/$repo_tag" >/dev/null 2>&1 || fail "push of $repo_tag to $registry failed"
    echo "imported $registry/$repo_tag"
  fi
done < <(jq -c '.entries[]' "$bundle/manifest.json")
echo "charts stay in $bundle/charts; push them with: helm push <chart>.tgz oci://$registry/charts"
