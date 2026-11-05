mock_provider "dynatrace" {}

variables {
  service_name = "checkout-api"
}

run "defaults_build_a_999_slo_with_burn_rate" {
  command = plan

  assert {
    condition     = dynatrace_slo_v2.availability.target_success == 99.9 && dynatrace_slo_v2.availability.evaluation_window == "-7d"
    error_message = "Default SLO must be 99.9 over 7 days."
  }

  assert {
    condition     = dynatrace_slo_v2.availability.filter == "type(\"SERVICE\"),entityName.equals(\"checkout-api\")"
    error_message = "SLO must select the named service."
  }
}

run "availability_problems_page_immediately" {
  command = plan

  assert {
    condition     = length([for r in dynatrace_alerting.oncall.rules[0].rule : r if r.severity_level == "AVAILABILITY" && r.delay_in_minutes == 0]) == 1
    error_message = "Availability problems must page with no delay."
  }
}

run "quote_in_service_name_is_rejected" {
  command = plan

  variables {
    service_name = "bad\"name"
  }

  expect_failures = [var.service_name]
}

run "target_of_100_is_rejected" {
  command = plan

  variables {
    availability_target = 100
  }

  expect_failures = [var.availability_target]
}
