mock_provider "akamai" {}

variables {
  domain_name         = "shop.example.akadns.net"
  property_name       = "www"
  notification_emails = ["oncall@example.com"]
  sites = {
    dc-east = {
      nickname   = "dc-east"
      city       = "Ashburn"
      country    = "US"
      latitude   = 39.04
      longitude  = -77.49
      servers    = ["192.0.2.10"]
      precedence = 0
    }
    aws-west = {
      nickname   = "aws-west"
      city       = "Portland"
      country    = "US"
      latitude   = 45.52
      longitude  = -122.68
      servers    = ["198.51.100.20"]
      precedence = 1
    }
  }
}

run "failover_mode_answers_one_site_by_precedence" {
  command = plan

  assert {
    condition     = akamai_gtm_property.this.type == "failover" && akamai_gtm_property.this.handout_limit == 1
    error_message = "Failover mode must be a failover property that hands out one answer."
  }
}

run "weighted_mode_lets_a_site_drain_to_zero" {
  command = plan

  variables {
    mode = "weighted"
    sites = {
      dc-east = {
        nickname  = "dc-east"
        city      = "Ashburn"
        country   = "US"
        latitude  = 39.04
        longitude = -77.49
        servers   = ["192.0.2.10"]
        weight    = 0
      }
      aws-west = {
        nickname  = "aws-west"
        city      = "Portland"
        country   = "US"
        latitude  = 45.52
        longitude = -122.68
        servers   = ["198.51.100.20"]
        weight    = 100
      }
    }
  }

  assert {
    condition     = akamai_gtm_property.this.type == "weighted-round-robin" && akamai_gtm_property.this.handout_limit == 2
    error_message = "Weighted mode must be weighted-round-robin and hand out every live site."
  }
}

run "one_site_is_rejected" {
  command = plan

  variables {
    sites = {
      dc-east = {
        nickname  = "dc-east"
        city      = "Ashburn"
        country   = "US"
        latitude  = 39.04
        longitude = -77.49
        servers   = ["192.0.2.10"]
      }
    }
  }

  expect_failures = [var.sites]
}

run "timeout_longer_than_interval_is_rejected" {
  command = plan

  variables {
    health_check = {
      interval = 10
      timeout  = 20
    }
  }

  expect_failures = [var.health_check]
}

run "domain_must_end_in_akadns" {
  command = plan

  variables {
    domain_name = "shop.example.com"
  }

  expect_failures = [var.domain_name]
}
