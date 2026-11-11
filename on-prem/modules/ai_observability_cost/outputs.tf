output "tenant_namespaces" {
  description = "Namespace created for each tenant."
  value       = { for k, ns in kubernetes_namespace_v1.tenant : k => ns.metadata[0].name }
}

output "collector_otlp_endpoint" {
  description = "In-cluster OTLP gRPC endpoint for workloads to send traces, metrics and logs to."
  value       = "otel-collector-opentelemetry-collector.${var.namespace}.svc:4317"
}

output "kafka_topics" {
  description = "Topics the collector writes to."
  value       = [for s in ["traces", "metrics", "logs"] : "${var.kafka_topic_prefix}_${s}"]
}

output "collector_config_yaml" {
  description = "The rendered collector configuration, for review or for `otelcol-contrib validate`."
  value       = yamlencode(local.collector_config)
}
