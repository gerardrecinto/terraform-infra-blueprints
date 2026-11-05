terraform {
  required_version = ">= 1.5"

  required_providers {
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = ">= 1.80"
    }
  }
}
