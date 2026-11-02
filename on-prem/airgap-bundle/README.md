# Air-gap bundle (lab)

Move container images and Helm charts into a network with no internet, and prove nothing changed on the way. Four small bash scripts. This is a lab and reference implementation, not a production release process, and it has only been run on one laptop with a local `registry:2`.

```
connected side                          disconnected side
export.sh  ->  bundle/  ->  (media)  ->  verify.sh  ->  import.sh  ->  internal registry
 pull by digest   manifest.json            offline checks     refuses on any failure
 sign manifest    manifest.sig
```

## What it does

- `export.sh <images.txt> <charts-dir> <out-dir> <cosign.key>` pulls each image as an OCI layout, records the registry digest, copies packaged charts with their sha256, writes `manifest.json` and signs it with a cosign key (`sign-blob`).
- `verify.sh <bundle> <cosign.pub>` checks the signature, every chart hash, each image's index digest against the manifest, and that every blob file hashes to its own name.
- `import.sh <bundle> <cosign.pub> <host:port>` runs `verify.sh` first and pushes images with `crane push` only if it passes.
- `test.sh` runs the whole path against a throwaway `registry:2` and then tampers with the bundle four ways.

## What it does not do

- It signs the bundle manifest with a key you hold. It does not sign images inside the registry, does not use Sigstore keyless, and does not manage key storage or rotation.
- It does not push charts into the registry; it only verifies them and tells you the `helm push` command.
- I did not run verification with the network disabled. The scripts only use a local public key, but that is not the same as an observed offline run.
- No vulnerability scan, SBOM or admission policy. Pair it with whatever your site requires.

## Tools

`docker`, `crane`, `cosign` (v2), `helm`, `jq`, bash. If your package manager does not carry them:

```bash
go install github.com/google/go-containerregistry/cmd/crane@v0.20.2
CGO_ENABLED=0 go install github.com/sigstore/cosign/v2/cmd/cosign@v2.4.1
```

## Run the proof

```bash
cd on-prem/airgap-bundle
./test.sh
```

Real output from a run on my machine (Docker Desktop, cosign v2.4.1, crane v0.20.2; temp paths shortened):

```text
exported image alpine:3.20 sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
exported image busybox:1.36 sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
exported chart web-service-0.1.0.tgz sha256:f4b5c0a014043e217dad16aaebc20a3b1ab23d8d76587e6b27931d0fdcc651c6
signed manifest.json -> manifest.sig
ok   manifest signature
ok   images/alpine_3.20 (sha256:d9e853e8...)
ok   images/busybox_1.36 (sha256:73aaf090...)
ok   charts/web-service-0.1.0.tgz
verified 3 entries
PASS: clean bundle verifies
imported localhost:5001/library/alpine:3.20
imported localhost:5001/library/busybox:1.36
PASS: imported image digest matches manifest (sha256:d9e853e8...)
PASS: tampered layer blob refused: FAIL: images/busybox_1.36 blob 6c9ce08c... hashes to 25c8a276...
PASS: edited manifest digest refused: FAIL: manifest signature does not verify against $TMP/cosign.pub
PASS: modified chart archive refused: FAIL: charts/web-service-0.1.0.tgz sha256 is 2aa5b548..., manifest says f4b5c0a0...
PASS: wrong public key refused: FAIL: manifest signature does not verify against $TMP/other.pub
all 6 checks passed
```

The test generates its own throwaway keys with an empty password. Do not reuse that pattern for a real bundle.
