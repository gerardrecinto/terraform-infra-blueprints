#!/usr/bin/env bash
# End-to-end proof, run on a connected machine with docker, crane, cosign, helm and jq.
# Exports a bundle, verifies it, imports it into a local registry:2, then tampers with
# the bundle four ways and checks that verify and import both refuse each time.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
need docker; need crane; need cosign; need helm; need jq

work="$(mktemp -d)"
port="${REGISTRY_PORT:-5001}"
cname="airgap-test-registry"
cleanup() { docker rm -f "$cname" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

passed=0
check() { echo "PASS: $1"; passed=$((passed + 1)); }

# 1. keys and inputs
( cd "$work" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 )
mkdir -p "$work/other"
( cd "$work/other" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1 )
cp "$work/other/cosign.pub" "$work/other.pub"
printf 'alpine:3.20\nbusybox:1.36\n' > "$work/images.txt"
mkdir -p "$work/charts"
helm package "$here/../../helm/charts/web-service" -d "$work/charts" >/dev/null

# 2. export and verify
export COSIGN_PASSWORD=""
"$here/export.sh" "$work/images.txt" "$work/charts" "$work/bundle" "$work/cosign.key"
"$here/verify.sh" "$work/bundle" "$work/cosign.pub"
check "clean bundle verifies"

# 3. import into a local registry and compare digests
docker rm -f "$cname" >/dev/null 2>&1 || true
docker run -d --name "$cname" -p "$port:5000" registry:2 >/dev/null
for _ in $(seq 1 30); do curl -fs "http://localhost:$port/v2/" >/dev/null 2>&1 && break; sleep 1; done
"$here/import.sh" "$work/bundle" "$work/cosign.pub" "localhost:$port"
want="$(jq -r '.entries[] | select(.ref=="alpine:3.20") | .digest' "$work/bundle/manifest.json")"
got="$(crane digest --insecure "localhost:$port/library/alpine:3.20")"
[ "$want" = "$got" ] || fail "imported alpine digest $got differs from manifest $want"
check "imported image digest matches manifest ($got)"

# 4. tamper cases, each on a fresh copy
expect_refusal() {
  local label="$1" dir="$2" pub="${3:-$work/cosign.pub}"
  if "$here/verify.sh" "$dir" "$pub" >"$work/out.txt" 2>&1; then
    cat "$work/out.txt"; fail "$label: verify accepted a tampered bundle"
  fi
  if "$here/import.sh" "$dir" "$pub" "localhost:$port" >/dev/null 2>&1; then
    fail "$label: import accepted a tampered bundle"
  fi
  check "$label refused: $(tail -1 "$work/out.txt")"
}

# a) flip bytes in a layer blob
cp -R "$work/bundle" "$work/t1"
blob="$(find "$work/t1/images" -path '*/blobs/sha256/*' -type f -size +10k | head -1)"
printf 'X' | dd of="$blob" bs=1 seek=100 conv=notrunc 2>/dev/null
expect_refusal "tampered layer blob" "$work/t1"

# b) rewrite an image digest in the manifest (signature must break)
cp -R "$work/bundle" "$work/t2"
jq '(.entries[] | select(.kind=="image") | .digest) |= sub("^sha256:."; "sha256:0")' "$work/t2/manifest.json" > "$work/m.json" && mv "$work/m.json" "$work/t2/manifest.json"
expect_refusal "edited manifest digest" "$work/t2"

# c) tamper with the packaged chart
cp -R "$work/bundle" "$work/t3"
printf 'extra' >> "$(find "$work/t3/charts" -name '*.tgz' | head -1)"
expect_refusal "modified chart archive" "$work/t3"

# d) verify against the wrong key
expect_refusal "wrong public key" "$work/bundle" "$work/other.pub"

echo "all $passed checks passed"
