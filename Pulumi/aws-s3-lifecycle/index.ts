// Pulumi (TypeScript) port of ../../AWS/modules/s3_lifecycle. Same bucket,
// same lifecycle rules, same encryption and public-access posture as the
// Terraform module, written as a real ComponentResource instead of a
// module block, so the two can be compared side by side rather than taken
// on faith. As with the Terraform module: published as supporting
// evidence for skills, no company names, account IDs, or production
// metrics are claimed here.

import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

export interface S3LifecycleArgs {
    bucketName: string;
    environment: "dev" | "staging" | "prod";
    logPrefix?: string;
    transitionToIaDays?: number;
    transitionToGlacierDays?: number;
    expirationDays?: number;
    kmsKeyArn?: pulumi.Input<string>;
    enforceEncryptionPolicy?: boolean;
    replicationRegions?: string[];
    tags?: Record<string, string>;
}

export class S3Lifecycle extends pulumi.ComponentResource {
    public readonly bucketId: pulumi.Output<string>;
    public readonly bucketArn: pulumi.Output<string>;
    public readonly bucketDomainName: pulumi.Output<string>;

    constructor(name: string, args: S3LifecycleArgs, opts?: pulumi.ComponentResourceOptions) {
        super("blueprints:aws:S3Lifecycle", name, {}, opts);

        if (!["dev", "staging", "prod"].includes(args.environment)) {
            throw new Error("environment must be one of: dev, staging, prod");
        }

        const transitionToIaDays = args.transitionToIaDays ?? 30;
        const transitionToGlacierDays = args.transitionToGlacierDays ?? 90;
        const expirationDays = args.expirationDays ?? 0;
        const enforceEncryptionPolicy = args.enforceEncryptionPolicy ?? true;
        const replicationRegions = args.replicationRegions ?? [];

        const bucket = new aws.s3.BucketV2(name, {
            bucket: args.bucketName,
            tags: {
                ...args.tags,
                Environment: args.environment,
                Pulumi: "true",
            },
        }, { parent: this });

        new aws.s3.BucketVersioningV2(`${name}-versioning`, {
            bucket: bucket.id,
            versioningConfiguration: { status: "Enabled" },
        }, { parent: this });

        new aws.s3.BucketServerSideEncryptionConfigurationV2(`${name}-sse`, {
            bucket: bucket.id,
            rules: [{
                applyServerSideEncryptionByDefault: {
                    sseAlgorithm: args.kmsKeyArn ? "aws:kms" : "AES256",
                    kmsMasterKeyId: args.kmsKeyArn,
                },
                bucketKeyEnabled: args.kmsKeyArn !== undefined,
            }],
        }, { parent: this });

        // Same two-rule shape as the Terraform module: tiering on the
        // log prefix (IA at transitionToIaDays, Deep Archive at
        // transitionToGlacierDays -- saves roughly 45% and 95% vs
        // Standard respectively, same as the Terraform module's comment),
        // plus a second rule expiring old noncurrent versions to keep
        // versioning storage cost from growing unbounded.
        new aws.s3.BucketLifecycleConfigurationV2(`${name}-lifecycle`, {
            bucket: bucket.id,
            rules: [
                {
                    id: "log-tiering",
                    status: "Enabled",
                    filter: { prefix: args.logPrefix ?? "" },
                    transitions: [
                        { days: transitionToIaDays, storageClass: "STANDARD_IA" },
                        { days: transitionToGlacierDays, storageClass: "DEEP_ARCHIVE" },
                    ],
                    expiration: expirationDays > 0 ? { days: expirationDays } : undefined,
                    abortIncompleteMultipartUpload: { daysAfterInitiation: 7 },
                },
                {
                    id: "expire-noncurrent",
                    status: "Enabled",
                    filter: {},
                    noncurrentVersionExpiration: { noncurrentDays: 30 },
                },
            ],
        }, { parent: this });

        new aws.s3.BucketPublicAccessBlock(`${name}-public-access-block`, {
            bucket: bucket.id,
            blockPublicAcls: true,
            blockPublicPolicy: true,
            ignorePublicAcls: true,
            restrictPublicBuckets: true,
        }, { parent: this });

        if (enforceEncryptionPolicy) {
            new aws.s3.BucketPolicy(`${name}-policy`, {
                bucket: bucket.id,
                policy: pulumi.all([bucket.arn, args.kmsKeyArn]).apply(([arn, kmsKeyArn]) =>
                    JSON.stringify({
                        Version: "2012-10-17",
                        Statement: [
                            {
                                Sid: "DenyNonHTTPS",
                                Effect: "Deny",
                                Principal: "*",
                                Action: "s3:*",
                                Resource: [arn, `${arn}/*`],
                                Condition: { Bool: { "aws:SecureTransport": "false" } },
                            },
                            {
                                Sid: "DenyNonKMSEncryption",
                                Effect: kmsKeyArn ? "Deny" : "Allow",
                                Principal: "*",
                                Action: "s3:PutObject",
                                Resource: `${arn}/*`,
                                Condition: kmsKeyArn
                                    ? { StringNotEquals: { "s3:x-amz-server-side-encryption-aws-kms-key-id": kmsKeyArn } }
                                    : {},
                            },
                        ],
                    }),
                ),
            }, { parent: this });
        }

        if (replicationRegions.length > 0) {
            const replicationRole = new aws.iam.Role(`${name}-replication-role`, {
                name: `${args.bucketName}-replication`,
                assumeRolePolicy: JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [{
                        Effect: "Allow",
                        Principal: { Service: "s3.amazonaws.com" },
                        Action: "sts:AssumeRole",
                    }],
                }),
            }, { parent: this });

            new aws.iam.RolePolicy(`${name}-replication-policy`, {
                role: replicationRole.id,
                policy: bucket.arn.apply(arn => JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [
                        { Effect: "Allow", Action: ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource: arn },
                        { Effect: "Allow", Action: ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"], Resource: `${arn}/*` },
                        { Effect: "Allow", Action: ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"], Resource: replicationRegions.map(r => `arn:aws:s3:::${args.bucketName}-${r}/*`) },
                    ],
                })),
            }, { parent: this });

            new aws.s3.BucketReplicationConfig(`${name}-replication`, {
                bucket: bucket.id,
                role: replicationRole.arn,
                rules: replicationRegions.map(region => ({
                    id: `replicate-to-${region}`,
                    status: "Enabled",
                    filter: {},
                    destination: {
                        bucket: `arn:aws:s3:::${args.bucketName}-${region}`,
                        storageClass: "STANDARD_IA",
                    },
                    deleteMarkerReplication: { status: "Enabled" },
                })),
            }, { parent: this, dependsOn: [bucket] });
        }

        this.bucketId = bucket.id;
        this.bucketArn = bucket.arn;
        this.bucketDomainName = bucket.bucketDomainName;

        this.registerOutputs({
            bucketId: this.bucketId,
            bucketArn: this.bucketArn,
            bucketDomainName: this.bucketDomainName,
        });
    }
}
