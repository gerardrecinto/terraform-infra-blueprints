#!/usr/bin/env bash
# Builds a throwaway kind cluster, installs Istio with Helm, and proves three things:
#   1. before policy, a plaintext client outside the mesh can reach the server
#   2. with mTLS STRICT alone, the plaintext client is refused and both mesh clients still pass
#   3. adding an AuthorizationPolicy, only the allowed service account gets a 200 (the other gets 403)
# Needs docker, kind, kubectl and helm. Set KEEP=1 to leave the cluster up.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cluster="istio-lab"
istio_version="${ISTIO_VERSION:-1.30.7}"

cleanup() { [ "${KEEP:-0}" = "1" ] || kind delete cluster --name "$cluster" >/dev/null 2>&1 || true; }
trap cleanup EXIT

kind create cluster --name "$cluster" --config "$here/kind.yaml" --wait 120s
kubectl --context "kind-$cluster" version --short >/dev/null 2>&1 || true
k() { kubectl --context "kind-$cluster" "$@"; }

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null
k create namespace istio-system
helm --kube-context "kind-$cluster" install istio-base istio/base -n istio-system --version "$istio_version" --wait
helm --kube-context "kind-$cluster" install istiod istio/istiod -n istio-system --version "$istio_version" --wait --timeout 5m

k apply -f "$here/manifests.yaml"
k -n mesh rollout status deploy/server deploy/allowed-client deploy/other-client --timeout=240s
k -n plain rollout status deploy/plain-client --timeout=240s

code() { # namespace deployment
  k -n "$1" exec "deploy/$2" -c curl -- curl -s -o /dev/null -m 5 -w '%{http_code}' http://server.mesh.svc.cluster.local/ 2>/dev/null || true
}

echo "--- 1. baseline, no policy"
echo "plain-client -> server: $(code plain plain-client)"
echo "allowed-client -> server: $(code mesh allowed-client)"

k apply -f "$here/peer-auth-strict.yaml"
sleep 8
echo "--- 2. PeerAuthentication STRICT only"
strict_plain="$(code plain plain-client)"
strict_allowed="$(code mesh allowed-client)"
strict_other="$(code mesh other-client)"
echo "plain-client (no sidecar, plaintext) -> server: ${strict_plain:-000}"
echo "allowed-client (mesh) -> server: $strict_allowed"
echo "other-client (mesh) -> server: $strict_other"

k apply -f "$here/authz-one-client.yaml"
# policy reaches the sidecars asynchronously, so wait for three 403s in a row and show what was seen
seen=""; streak=0
for _ in $(seq 1 40); do
  c="$(code mesh other-client)"; seen="$seen $c"
  if [ "$c" = "403" ]; then streak=$((streak + 1)); else streak=0; fi
  [ "$streak" -ge 3 ] && break
  sleep 3
done
echo "other-client responses while the policy propagated:$seen"
echo "--- 3. plus AuthorizationPolicy for one service account"
allowed="$(code mesh allowed-client)"
other="$(code mesh other-client)"
echo "allowed-client (mesh, allowed principal) -> server: $allowed"
echo "other-client (mesh, other principal) -> server: $other"

case "${strict_plain:-000}" in 000) ;; *) echo "FAIL: STRICT should refuse the plaintext client, got $strict_plain"; exit 1 ;; esac
[ "$strict_allowed" = "200" ] && [ "$strict_other" = "200" ] || { echo "FAIL: both mesh clients should pass under STRICT alone"; exit 1; }
[ "$allowed" = "200" ] || { echo "FAIL: allowed client should get 200"; exit 1; }
[ "$other" = "403" ] || { echo "FAIL: other mesh client should get 403"; exit 1; }
echo "PASS: STRICT mTLS refuses plaintext, AuthorizationPolicy allows one principal only"
