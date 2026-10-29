# Mocked plans never authenticate to AWS and never create a bucket.
mock_provider "aws" {}

variables {
  bucket_name = "blueprints-lifecycle-test"
  environment = "dev"
}

run "default_schedule" {
  command = plan
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "log-tiering"]) == 1
    error_message = "The default tiering rule must remain enabled."
  }
}

run "valid_custom_schedule" {
  command = plan
  variables {
    transition_to_ia_days      = 45
    transition_to_glacier_days = 75
    expiration_days            = 365
  }
}

run "ia_before_30_days" {
  command = plan
  variables { transition_to_ia_days = 29 }
  expect_failures = [var.transition_to_ia_days]
}

run "fractional_ia_days" {
  command = plan
  variables { transition_to_ia_days = 30.5 }
  expect_failures = [var.transition_to_ia_days]
}

run "glacier_before_ia" {
  command = plan
  variables { transition_to_glacier_days = 20 }
  expect_failures = [aws_s3_bucket_lifecycle_configuration.this]
}

run "glacier_same_day_as_ia" {
  command = plan
  variables { transition_to_glacier_days = 30 }
  expect_failures = [aws_s3_bucket_lifecycle_configuration.this]
}

run "glacier_before_minimum_ia_duration" {
  command = plan
  variables { transition_to_glacier_days = 59 }
  expect_failures = [aws_s3_bucket_lifecycle_configuration.this]
}

run "fractional_glacier_days" {
  command = plan
  variables { transition_to_glacier_days = 90.5 }
  expect_failures = [var.transition_to_glacier_days]
}

run "expiration_before_archive" {
  command = plan
  variables { expiration_days = 80 }
  expect_failures = [aws_s3_bucket_lifecycle_configuration.this]
}

run "expiration_same_day_as_archive" {
  command = plan
  variables { expiration_days = 90 }
  expect_failures = [aws_s3_bucket_lifecycle_configuration.this]
}

run "fractional_expiration_days" {
  command = plan
  variables { expiration_days = 365.5 }
  expect_failures = [var.expiration_days]
}

run "negative_expiration_days" {
  command = plan
  variables { expiration_days = -1 }
  expect_failures = [var.expiration_days]
}
