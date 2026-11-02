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
  name            = "demo-api"
  environment     = "dev"
  vpc_id          = "vpc-0123456789abcdef0"
  subnet_ids      = ["subnet-aaaa1111", "subnet-bbbb2222"]
  container_image = "registry.example.internal/demo-api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

run "commercial_defaults" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-east-1" }
  }

  assert {
    condition     = output.execution_role_policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    error_message = "Commercial execution policy ARN is wrong."
  }
  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].rollback == true
    error_message = "Rollback on failed deployment must stay enabled."
  }
  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == false
    error_message = "Tasks must not get public IPs."
  }
}

run "govcloud_partition" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-us-gov", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-gov-west-1" }
  }

  assert {
    condition     = output.execution_role_policy_arn == "arn:aws-us-gov:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    error_message = "GovCloud execution policy ARN must use the aws-us-gov partition."
  }
}

run "invalid_cpu_memory_pair" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-east-1" }
  }

  variables {
    cpu    = 256
    memory = 8192
  }
  expect_failures = [aws_ecs_task_definition.this]
}

run "open_ingress_rejected" {
  command = plan
  variables {
    ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.ingress_cidrs]
}

run "single_subnet_rejected" {
  command = plan
  variables {
    subnet_ids = ["subnet-aaaa1111"]
  }
  expect_failures = [var.subnet_ids]
}

run "min_above_max_rejected" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = data.aws_region.current
    values = { name = "us-east-1" }
  }

  variables {
    min_capacity = 5
    max_capacity = 2
  }
  expect_failures = [aws_appautoscaling_target.this]
}
