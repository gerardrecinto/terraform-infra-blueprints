# AI observability and cost: the collection layer for model-serving clusters.
#
# What it sets up
#   - A namespace and ResourceQuota per tenant, labelled tenant=<key>. The quota bounds GPU, CPU,
#     memory and pod count. The label is what cost and telemetry are attributed by.
#   - OpenCost, reading usage from Prometheus or Mimir, for cost per tenant namespace.
#   - An OpenTelemetry Collector (contrib build) that receives OTLP, scrapes the DCGM exporter,
#     stamps tenant.id from the pod label, filters, batches and writes to Kafka through a queue.
#   - Optionally the NVIDIA DCGM exporter for GPU telemetry.
#
# Trade-offs
#   - Tenant identity comes from a pod label. It is cheap and works for every signal, but a
#     tenant that can edit its own pod labels can mislabel itself. Restrict the label with an
#     admission policy (Kyverno or ValidatingAdmissionPolicy) before relying on it for billing.
#   - Kafka between the collector and storage adds a component to run. It buys back-pressure
#     tolerance: a Loki or Mimir outage fills Kafka instead of dropping data. For a single small
#     cluster, exporting straight to the backends is simpler.
#   - ResourceQuota bounds what a tenant can request. It does not rate-limit inference requests;
#     request quotas belong in the gateway in front of the model servers.
#
# Not applied against a real cluster from this repo. Checked by terraform validate, plan tests with
# mocked providers, helm template, and the collector's own `validate` command.

locals {
  tenant_label = "tenant"

  collector_config = {
    receivers = merge(
      {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      },
      var.enable_dcgm_exporter ? {
        prometheus = {
          config = {
            scrape_configs = [{
              job_name        = "dcgm"
              scrape_interval = "15s"
              static_configs  = [{ targets = ["dcgm-exporter.${var.namespace}.svc:9400"] }]
            }]
          }
        }
      } : {}
    )

    processors = {
      memory_limiter = {
        check_interval         = "1s"
        limit_percentage       = 80
        spike_limit_percentage = 20
      }
      k8sattributes = {
        auth_type = "serviceAccount"
        extract = {
          metadata = ["k8s.namespace.name", "k8s.pod.name", "k8s.node.name"]
          labels = [{
            tag_name = "tenant.id"
            key      = local.tenant_label
            from     = "pod"
          }]
        }
        pod_association = [
          { sources = [{ from = "resource_attribute", name = "k8s.pod.ip" }] },
          { sources = [{ from = "connection" }] },
        ]
      }
      resource = {
        attributes = [
          { key = "k8s.cluster.name", value = var.cluster_name, action = "upsert" },
          # Signals from pods with no tenant label stay visible as "unattributed" instead of vanishing.
          { key = "tenant.id", value = "unattributed", action = "insert" },
        ]
      }
      "filter/drop" = {
        error_mode = "ignore"
        traces = {
          span = [for n in var.drop_span_names : "name == \"${n}\""]
        }
        metrics = {
          metric = [for n in var.drop_metric_names : "name == \"${n}\""]
        }
      }
      batch = {
        send_batch_size = 8192
        timeout         = "5s"
      }
    }

    exporters = {
      "kafka/traces"  = local.kafka_exporter["traces"]
      "kafka/metrics" = local.kafka_exporter["metrics"]
      "kafka/logs"    = local.kafka_exporter["logs"]
    }

    service = {
      pipelines = {
        traces = {
          receivers  = ["otlp"]
          processors = ["memory_limiter", "k8sattributes", "resource", "filter/drop", "batch"]
          exporters  = ["kafka/traces"]
        }
        metrics = {
          receivers  = var.enable_dcgm_exporter ? ["otlp", "prometheus"] : ["otlp"]
          processors = ["memory_limiter", "k8sattributes", "resource", "filter/drop", "batch"]
          exporters  = ["kafka/metrics"]
        }
        logs = {
          receivers  = ["otlp"]
          processors = ["memory_limiter", "k8sattributes", "resource", "batch"]
          exporters  = ["kafka/logs"]
        }
      }
    }
  }

  kafka_exporter = {
    for signal in ["traces", "metrics", "logs"] : signal => {
      brokers          = var.kafka_brokers
      protocol_version = "2.6.2"
      "${signal}" = {
        topic    = "${var.kafka_topic_prefix}_${signal}"
        encoding = "otlp_proto"
      }
      sending_queue = {
        enabled    = true
        queue_size = var.queue_size
      }
      retry_on_failure = {
        enabled          = true
        initial_interval = "5s"
        max_interval     = "30s"
        max_elapsed_time = "300s"
      }
    }
  }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_namespace_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name = each.key
    labels = {
      (local.tenant_label) = each.key
      "cost-center"        = each.value.cost_center
      "engagement-code"    = each.value.engagement_code
    }
  }
}

resource "kubernetes_resource_quota_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "tenant-bounds"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"            = each.value.cpu_requests
      "limits.memory"           = each.value.memory_limit
      "requests.nvidia.com/gpu" = tostring(each.value.gpu_requests)
      "pods"                    = tostring(each.value.max_pods)
    }
  }
}

resource "helm_release" "dcgm_exporter" {
  count = var.enable_dcgm_exporter ? 1 : 0

  name       = "dcgm-exporter"
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  version    = var.chart_versions.dcgm_exporter
}

resource "helm_release" "opentelemetry_collector" {
  name       = "otel-collector"
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.chart_versions.opentelemetry_collector

  values = [yamlencode({
    mode    = "deployment"
    image   = { repository = "otel/opentelemetry-collector-contrib" }
    command = { name = "otelcol-contrib" }
    # The k8sattributes processor reads pod metadata from the API server.
    clusterRole = {
      create = true
      rules = [{
        apiGroups = [""]
        resources = ["pods", "namespaces", "nodes"]
        verbs     = ["get", "watch", "list"]
      }]
    }
    config = local.collector_config
  })]
}

resource "helm_release" "opencost" {
  name       = "opencost"
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  repository = "https://opencost.github.io/opencost-helm-chart"
  chart      = "opencost"
  version    = var.chart_versions.opencost

  values = [yamlencode({
    opencost = {
      exporter = { defaultClusterId = var.cluster_name }
      prometheus = {
        internal = { enabled = false }
        external = { enabled = true, url = var.prometheus_url }
      }
    }
  })]
}
