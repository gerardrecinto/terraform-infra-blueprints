mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  cluster_name   = "gpu-east"
  prometheus_url = "http://prometheus.monitoring.svc:9090"
  kafka_brokers  = ["kafka-0.kafka:9092"]
  tenants = {
    acme-audit = { cpu_requests = "64", memory_limit = "512Gi", gpu_requests = 8, max_pods = 40, cost_center = "cc-100" }
    beta-tax   = { cpu_requests = "16", memory_limit = "128Gi", gpu_requests = 2, max_pods = 10 }
  }
}

run "each_tenant_gets_a_labelled_namespace_and_a_quota" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.tenant["acme-audit"].metadata[0].labels["tenant"] == "acme-audit" && kubernetes_namespace_v1.tenant["acme-audit"].metadata[0].labels["cost-center"] == "cc-100"
    error_message = "Tenant namespaces must carry the tenant and cost-center labels cost is attributed by."
  }

  assert {
    condition     = kubernetes_resource_quota_v1.tenant["beta-tax"].spec[0].hard["requests.nvidia.com/gpu"] == "2" && kubernetes_resource_quota_v1.tenant["beta-tax"].spec[0].hard["pods"] == "10"
    error_message = "The GPU and pod quota must match the tenant's inputs."
  }

  assert {
    condition     = kubernetes_namespace_v1.tenant["beta-tax"].metadata[0].labels["cost-center"] == "unassigned"
    error_message = "A tenant with no cost center must show as unassigned, not be dropped."
  }
}

run "every_pipeline_stamps_the_tenant_and_writes_to_kafka_through_a_queue" {
  command = plan

  assert {
    condition     = alltrue([for p in values(local.collector_config.service.pipelines) : contains(p.processors, "k8sattributes") && contains(p.processors, "resource") && contains(p.processors, "batch")])
    error_message = "Traces, metrics and logs must all be tenant-stamped and batched."
  }

  assert {
    condition     = alltrue([for e in values(local.collector_config.exporters) : e.sending_queue.enabled && e.retry_on_failure.enabled])
    error_message = "Every Kafka exporter needs a sending queue and retries."
  }

  assert {
    condition     = local.collector_config.exporters["kafka/traces"].traces.topic == "otlp_traces"
    error_message = "Topic names must follow the prefix."
  }
}

run "dcgm_is_scraped_only_when_enabled" {
  command = plan

  assert {
    condition     = length(helm_release.dcgm_exporter) == 1 && contains(local.collector_config.service.pipelines.metrics.receivers, "prometheus")
    error_message = "With DCGM on, the exporter is deployed and scraped."
  }
}

run "dcgm_off_removes_the_exporter_and_the_scrape" {
  command = plan

  variables {
    enable_dcgm_exporter = false
  }

  assert {
    condition     = length(helm_release.dcgm_exporter) == 0 && !contains(local.collector_config.service.pipelines.metrics.receivers, "prometheus")
    error_message = "With DCGM off, neither the exporter nor the scrape should exist."
  }
}

run "dropped_spans_come_from_the_variable" {
  command = plan

  variables {
    drop_span_names   = ["GET /ping"]
    drop_metric_names = ["noisy_total"]
  }

  assert {
    condition     = local.collector_config.processors["filter/drop"].traces.span == ["name == \"GET /ping\""] && local.collector_config.processors["filter/drop"].metrics.metric == ["name == \"noisy_total\""]
    error_message = "The filter processor must follow the drop lists."
  }
}

run "tenant_key_that_is_not_a_dns_label_is_rejected" {
  command = plan

  variables {
    tenants = {
      "Bad_Tenant" = { cpu_requests = "1", memory_limit = "1Gi", gpu_requests = 0, max_pods = 1 }
    }
  }

  expect_failures = [var.tenants]
}

run "negative_gpu_quota_is_rejected" {
  command = plan

  variables {
    tenants = {
      ok = { cpu_requests = "1", memory_limit = "1Gi", gpu_requests = -1, max_pods = 1 }
    }
  }

  expect_failures = [var.tenants]
}

run "no_kafka_brokers_is_rejected" {
  command = plan

  variables {
    kafka_brokers = []
  }

  expect_failures = [var.kafka_brokers]
}
