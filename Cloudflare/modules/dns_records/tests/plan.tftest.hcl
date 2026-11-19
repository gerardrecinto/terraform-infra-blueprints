mock_provider "cloudflare" {}

variables {
  zone_id = "0123456789abcdef0123456789abcdef"
  records = {
    www = { name = "www.example.com", type = "A", content = "192.0.2.10" }
  }
}

run "record_keeps_its_values" {
  command = plan

  assert {
    condition     = cloudflare_dns_record.this["www"].content == "192.0.2.10" && cloudflare_dns_record.this["www"].ttl == 300
    error_message = "A record keeps its content and the default ttl."
  }
}

run "proxied_record_needs_automatic_ttl" {
  command = plan

  variables {
    records = {
      www = { name = "www.example.com", type = "A", content = "192.0.2.10", proxied = true }
    }
  }

  expect_failures = [var.records]
}

run "proxied_record_with_automatic_ttl_passes" {
  command = plan

  variables {
    records = {
      www = { name = "www.example.com", type = "A", content = "192.0.2.10", proxied = true, ttl = 1 }
    }
  }

  assert {
    condition     = cloudflare_dns_record.this["www"].proxied == true
    error_message = "A proxied record with ttl 1 must plan."
  }
}

run "txt_cannot_be_proxied" {
  command = plan

  variables {
    records = {
      spf = { name = "example.com", type = "TXT", content = "v=spf1 -all", proxied = true, ttl = 1 }
    }
  }

  expect_failures = [var.records]
}

run "bad_zone_id_is_rejected" {
  command = plan

  variables {
    zone_id = "not-a-zone"
  }

  expect_failures = [var.zone_id]
}
