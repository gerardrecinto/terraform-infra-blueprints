terraform {
  required_version = ">= 1.5"

  required_providers {
    akamai = {
      source  = "akamai/akamai"
      version = ">= 7.0"
    }
  }
}
