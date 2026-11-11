variable "cluster_name" {
  description = "Cluster name stamped on every signal and used as the OpenCost cluster ID."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be a lowercase DNS label, 2 to 63 characters."
  }
}

variable "namespace" {
  description = "Namespace for the collector, OpenCost and the DCGM exporter."
  type        = string
  default     = "ai-observability"
}

variable "tenants" {
  description = "One entry per tenant. Each gets a namespace labelled tenant=<key> and a ResourceQuota, so GPU, CPU, memory and pod counts are bounded per tenant and OpenCost can attribute cost by that label."
  type = map(object({
    cpu_requests    = string
    memory_limit    = string
    gpu_requests    = number
    max_pods        = number
    cost_center     = optional(string, "unassigned")
    engagement_code = optional(string, "unassigned")
  }))

  validation {
    condition     = alltrue([for k in keys(var.tenants) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", k))])
    error_message = "Tenant keys become namespace names and label values, so each must be a lowercase DNS label."
  }

  validation {
    condition     = alltrue([for t in values(var.tenants) : t.gpu_requests >= 0 && t.max_pods >= 1])
    error_message = "gpu_requests must be 0 or more and max_pods must be at least 1."
  }
}

variable "prometheus_url" {
  description = "Prometheus or Mimir query URL that OpenCost reads usage from."
  type        = string

  validation {
    condition     = can(regex("^https?://", var.prometheus_url))
    error_message = "prometheus_url must start with http:// or https://."
  }
}

variable "kafka_brokers" {
  description = "Kafka bootstrap brokers the collector writes to. Kafka is the durable buffer between collection and storage, so a slow backend does not drop signals."
  type        = list(string)

  validation {
    condition     = length(var.kafka_brokers) > 0
    error_message = "Give at least one Kafka broker."
  }
}

variable "kafka_topic_prefix" {
  description = "Prefix for the per-signal topics: <prefix>_traces, <prefix>_metrics, <prefix>_logs."
  type        = string
  default     = "otlp"
}

variable "enable_dcgm_exporter" {
  description = "Deploy the NVIDIA DCGM exporter and scrape it for GPU utilisation, memory and power. Needs GPU nodes with the NVIDIA driver and device plugin."
  type        = bool
  default     = true
}

variable "drop_metric_names" {
  description = "Metric names the collector drops before export. Change this list to shed noisy series without redeploying the pipeline."
  type        = list(string)
  default     = []
}

variable "drop_span_names" {
  description = "Span names the collector drops before export, for example health checks."
  type        = list(string)
  default     = ["GET /healthz", "GET /readyz"]
}

variable "queue_size" {
  description = "Collector sending queue length in batches. When Kafka is slow, signals wait here before they are dropped."
  type        = number
  default     = 5000

  validation {
    condition     = var.queue_size >= 100
    error_message = "queue_size must be at least 100."
  }
}

variable "chart_versions" {
  description = "Helm chart versions. Pinned so a plan today matches a plan next month."
  type = object({
    opentelemetry_collector = string
    opencost                = string
    dcgm_exporter           = string
  })
  default = {
    opentelemetry_collector = "0.178.3"
    opencost                = "2.5.34"
    dcgm_exporter           = "4.9.0"
  }
}
