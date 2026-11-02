# Credential-free: the provider is mocked and the partition is overridden per run.
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}

variables {
  bucket_name = "blueprints-artifact-test"
  environment = "dev"
}

run "commercial_partition" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-east-1" }
  }

  assert {
    condition     = output.bucket_arn == "arn:aws:s3:::blueprints-artifact-test"
    error_message = "Commercial bucket ARN must use the aws partition."
  }
  assert {
    condition     = output.s3_endpoint_host == "s3.us-east-1.amazonaws.com"
    error_message = "Commercial S3 endpoint host is wrong."
  }
}

run "govcloud_partition" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws-us-gov"
      dns_suffix = "amazonaws.com"
    }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-gov-west-1" }
  }

  assert {
    condition     = output.bucket_arn == "arn:aws-us-gov:s3:::blueprints-artifact-test"
    error_message = "GovCloud bucket ARN must use the aws-us-gov partition."
  }
  assert {
    condition     = output.partition == "aws-us-gov"
    error_message = "Partition output must report aws-us-gov."
  }
}

run "govcloud_fips_endpoint" {
  command = plan

  variables {
    use_fips_endpoints = true
  }
  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws-us-gov"
      dns_suffix = "amazonaws.com"
    }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-gov-east-1" }
  }

  assert {
    condition     = output.s3_endpoint_host == "s3-fips.us-gov-east-1.amazonaws.com"
    error_message = "FIPS endpoint host must include -fips."
  }
}

run "kms_key_from_other_partition_is_rejected_when_malformed" {
  command = plan
  variables {
    kms_key_arn = "not-an-arn"
  }
  expect_failures = [var.kms_key_arn]
}

run "bad_bucket_name" {
  command = plan
  variables {
    bucket_name = "Bad_Name"
  }
  expect_failures = [var.bucket_name]
}
