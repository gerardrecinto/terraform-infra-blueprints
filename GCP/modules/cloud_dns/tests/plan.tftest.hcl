mock_provider "google" {}

variables {
  project_id       = "example-dns-lab"
  zone_name        = "internal-example"
  dns_name         = "internal.example.com."
  private_networks = ["https://www.googleapis.com/compute/v1/projects/example-dns-lab/global/networks/main"]
  records = {
    api = { name = "api", type = "A", rrdatas = ["10.0.0.10"] }
  }
}

run "private_zone_has_networks_and_no_dnssec" {
  command = plan

  assert {
    condition     = google_dns_managed_zone.this.visibility == "private" && length(google_dns_managed_zone.this.private_visibility_config) == 1
    error_message = "A private zone must carry its network list."
  }

  assert {
    condition     = length(google_dns_managed_zone.this.dnssec_config) == 0
    error_message = "A private zone must not request DNSSEC."
  }
}

run "record_name_is_joined_to_the_zone" {
  command = plan

  assert {
    condition     = google_dns_record_set.this["api"].name == "api.internal.example.com."
    error_message = "A relative record name must be joined to dns_name."
  }
}

run "public_zone_turns_dnssec_on" {
  command = plan

  variables {
    visibility       = "public"
    private_networks = []
  }

  assert {
    condition     = google_dns_managed_zone.this.dnssec_config[0].state == "on"
    error_message = "A public zone signs with DNSSEC by default."
  }
}

run "private_zone_without_network_is_rejected" {
  command = plan

  variables {
    private_networks = []
  }

  expect_failures = [var.private_networks]
}

run "apex_cname_is_rejected" {
  command = plan

  variables {
    records = {
      bad = { name = "@", type = "CNAME", rrdatas = ["other.example.com."] }
    }
  }

  expect_failures = [var.records]
}
