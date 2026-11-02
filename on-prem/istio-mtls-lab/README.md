# Istio mTLS lab (kind)

A throwaway kind cluster with Istio installed from the official Helm charts. It checks two things with real requests instead of reading YAML:

1. With `PeerAuthentication` set to STRICT, a client outside the mesh (no sidecar, plaintext) is refused.
2. With an `AuthorizationPolicy`, only one service account can call the server; another mesh client gets 403.

Lab only. One node, no ingress gateway, no multi-cluster, no production hardening, Istio 1.30.7 from `istio-release.storage.googleapis.com/charts`.

## Run it

Needs docker, kind, kubectl and helm. It takes about a minute once images are cached.

```bash
cd on-prem/istio-mtls-lab
./run.sh            # creates cluster istio-lab, runs the checks, deletes the cluster
KEEP=1 ./run.sh     # leave the cluster up to poke at it
```

## Files

- `kind.yaml` single-node cluster.
- `manifests.yaml` namespaces `mesh` (sidecar injection on) and `plain` (off), an unprivileged nginx server on 8080, two curl clients in `mesh` with different service accounts, one curl client in `plain`. Pods run non-root with a read-only root filesystem, dropped capabilities, a RuntimeDefault seccomp profile and resource limits. A Trivy config scan reports no HIGH or CRITICAL findings; it still flags the Docker Hub images as an untrusted registry (medium).
- `peer-auth-strict.yaml` mTLS STRICT for the `mesh` namespace.
- `authz-one-client.yaml` ALLOW only `cluster.local/ns/mesh/sa/allowed-client` on the server.

## Real output

```text
--- 1. baseline, no policy
plain-client -> server: 200
allowed-client -> server: 200
--- 2. PeerAuthentication STRICT only
plain-client (no sidecar, plaintext) -> server: 000
allowed-client (mesh) -> server: 200
other-client (mesh) -> server: 200
--- 3. plus AuthorizationPolicy for one service account
other-client responses while the policy propagated: 200 403 403 200 403 403 403
allowed-client (mesh, allowed principal) -> server: 200
other-client (mesh, other principal) -> server: 403
PASS: STRICT mTLS refuses plaintext, AuthorizationPolicy allows one principal only
```

`000` means curl got no HTTP response because the connection was reset, which is what STRICT does to a plaintext client.

## A thing I hit

My first version waited for one 403 and then checked again. It failed in about 3 of 10 runs. While the policy reaches the sidecars the responses flap, as the "responses while the policy propagated" line shows (403, then 200, then 403 again). The script now waits for three 403s in a row before it asserts, and it passed 6 runs in a row after that change. If you test policy changes in a pipeline, do the same.

## Not covered

No traffic management, no ingress gateway, no ambient mode, no certificate authority integration, and nothing measured about performance.
