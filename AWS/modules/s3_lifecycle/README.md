# S3 lifecycle deployment prerequisites

This module creates the source bucket, its lifecycle, default encryption, public-access block and optional replication configuration. Terraform validation and mocked plans are not a live replication test.

`replication_regions` does not create destination buckets. Before enabling it, provision `${bucket_name}-${region}` in each destination region, enable destination versioning, and review the destination bucket policy and replication-role permissions. The source bucket has versioning enabled. Cross-account replication also needs a separately reviewed trust and destination ownership policy.

SSE-KMS replication is not fully wired by this example: it does not configure the replication rule's encrypted-source selection, destination replica key, or source/destination KMS grants. Do not treat setting `kms_key_arn` plus `replication_regions` as a working KMS replication deployment. Multi-destination replication also needs service-valid rule priorities and destination configuration. Adapt and test that design before enabling replication; leaving `replication_regions = []` avoids suggesting a replication setup that has not been proven.

AWS prerequisites: [replication requirements](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-requirements.html), [replication of encrypted objects](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-config-for-kms-objects.html).
