# aws-s3-lifecycle (Pulumi)

Same module as `../../AWS/modules/s3_lifecycle`, rewritten in Pulumi
(TypeScript) instead of Terraform HCL. Same bucket, same two lifecycle
rules (log tiering to Standard-IA then Glacier Deep Archive, noncurrent
version expiration), same public-access block, same HTTPS/KMS-enforcing
bucket policy, same optional cross-region replication.

This exists to close a specific gap: Terraform is the tool actually run
in production, this module is the "I understand Pulumi's model, not
just Terraform's" proof, done as real working code instead of a
comparison table.

## What's actually different from the Terraform version, and why

- **State**: Terraform state for this module is wherever the calling
  workflow configures its backend (S3 + DynamoDB lock, typically).
  Pulumi's default here is Pulumi Cloud, per-stack, with secrets
  encrypted by a stack-specific key automatically, no separate backend
  config to write.
- **Structure**: the Terraform module is a flat set of `resource` blocks
  wired together by implicit references. The Pulumi version is a
  `ComponentResource` (`S3Lifecycle`), so the whole thing composes as one
  typed unit another Pulumi program can import and instantiate, closer to
  a real class than a set of resources that happen to share a file.
- **Validation**: Terraform's `variable` blocks get `validation {}`
  blocks per input. Pulumi validates in the constructor body with plain
  TypeScript, same guarantee (bad input fails before any API call), just
  expressed as real code instead of a DSL block.

## Usage

```bash
npm install
pulumi stack init dev
pulumi up
```

```typescript
import { S3Lifecycle } from "./index";

new S3Lifecycle("app-logs", {
    bucketName: "my-app-logs-bucket",
    environment: "prod",
    logPrefix: "app-logs/",
    kmsKeyArn: myKmsKey.arn,
    replicationRegions: ["us-west-2"],
});
```

As with the rest of this repo: personal portfolio code, no company
names, account IDs, or production metrics are claimed here.
