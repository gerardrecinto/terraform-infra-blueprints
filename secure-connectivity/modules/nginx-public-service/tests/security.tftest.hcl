mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}" }
  }
}

variables {
  name               = "blueprints"
  vpc_id             = "vpc-0123456789abcdef0"
  public_subnet_ids  = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  private_subnet_ids = ["subnet-0123456789abcdef2", "subnet-0123456789abcdef3"]
}

run "malformed_headers_are_dropped" {
  command = plan
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "The public ALB must drop malformed HTTP headers."
  }
}

run "https_still_redirects_plain_http" {
  command = plan
  variables {
    certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/00000000-0000-0000-0000-000000000001"
  }
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields && one(aws_lb_listener.http.default_action).type == "redirect"
    error_message = "Header filtering must remain enabled with HTTP to HTTPS redirection."
  }
}
