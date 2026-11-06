# All company-specific values (account IDs, hostnames, ARNs, CIDRs, resource names)
# have been replaced with generic placeholders to preserve company CCI.
# IoT telemetry logging pipeline on Azure AKS
# Full stack: FluentBit -> Kafka (MSK equivalent via Event Hubs) -> Logstash -> OpenSearch -> Grafana
# Deployed via Terraform + Helm for ExampleCorp IoT telemetry platform

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "helm" {
  kubernetes {
    host                   = module.aks.host
    client_certificate     = base64decode(module.aks.client_certificate)
    cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
  }
}

provider "kubernetes" {
  host                   = module.aks.host
  client_certificate     = base64decode(module.aks.client_certificate)
  cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
}

locals {
  tags = {
    Environment = var.environment
    Project     = "iot-platform"
    Terraform   = "true"
  }
}

# Resource group
resource "azurerm_resource_group" "this" {
  name     = "${var.project_name}-${var.environment}-rg"
  location = var.location
  tags     = local.tags
}

# ACR
module "acr" {
  source = "../../modules/acr"

  registry_name       = "${var.project_name}${var.environment}acr"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  environment         = var.environment
  sku                 = "Standard"
  tags                = local.tags
}

# AKS cluster
module "aks" {
  source = "../../modules/aks"

  cluster_name        = "${var.project_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  environment         = var.environment
  kubernetes_version  = var.kubernetes_version
  system_node_count   = 2
  system_vm_size      = "Standard_D4s_v3"
  vnet_subnet_id      = azurerm_subnet.aks.id
  azure_ad_tenant_id  = var.azure_ad_tenant_id
  acr_id              = module.acr.registry_id

  node_pools = {
    logging = {
      vm_size    = "Standard_D8s_v3"
      min_count  = 2
      max_count  = 5
      node_count = 2
      labels     = { "workload" = "logging" }
      taints     = ["workload=logging:NoSchedule"]
    }
  }

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

# VNet for AKS
resource "azurerm_virtual_network" "this" {
  name                = "${var.project_name}-${var.environment}-vnet"
  address_space       = ["10.10.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.0.0/22"]
}

# Log Analytics workspace for Container Insights
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.project_name}-${var.environment}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Event Hubs (Kafka-compatible) -- receives logs from FluentBit
resource "azurerm_eventhub_namespace" "kafka" {
  name                = "${var.project_name}-${var.environment}-eh"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  capacity            = 2
  # Kafka protocol support is automatic on Standard/Premium/Dedicated tier
  # namespaces -- there's no kafka_enabled argument on this resource.

  tags = local.tags
}

resource "azurerm_eventhub" "logs" {
  name                = "app-logs"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  resource_group_name = azurerm_resource_group.this.name
  partition_count     = 4
  message_retention   = 3
}

resource "azurerm_eventhub_authorization_rule" "producer" {
  name                = "fluentbit-producer"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  eventhub_name       = azurerm_eventhub.logs.name
  resource_group_name = azurerm_resource_group.this.name
  listen              = false
  send                = true
  manage              = false
}

resource "azurerm_eventhub_authorization_rule" "consumer" {
  name                = "logstash-consumer"
  namespace_name      = azurerm_eventhub_namespace.kafka.name
  eventhub_name       = azurerm_eventhub.logs.name
  resource_group_name = azurerm_resource_group.this.name
  listen              = true
  send                = false
  manage              = false
}

# Namespace for the logging stack
resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Secret: Event Hubs connection strings for FluentBit and Logstash
resource "kubernetes_secret" "eventhub_creds" {
  metadata {
    name      = "eventhub-creds"
    namespace = kubernetes_namespace.logging.metadata[0].name
  }

  data = {
    producer_connection_string = azurerm_eventhub_authorization_rule.producer.primary_connection_string
    consumer_connection_string = azurerm_eventhub_authorization_rule.consumer.primary_connection_string
    bootstrap_servers          = "${azurerm_eventhub_namespace.kafka.name}.servicebus.windows.net:9093"
  }
}

# FluentBit -- deployed as DaemonSet, tails all pod logs and ships to Event Hubs (Kafka)
resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.46.7"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [yamlencode({
    daemonset = { enabled = true }

    tolerations = [{
      operator = "Exists"
    }]

    config = {
      inputs = <<-EOT
        [INPUT]
            Name              tail
            Path              /var/log/containers/*.log
            Parser            docker
            Tag               kube.*
            Refresh_Interval  5
            Mem_Buf_Limit     50MB
            Skip_Long_Lines   On
      EOT

      filters = <<-EOT
        [FILTER]
            Name                kubernetes
            Match               kube.*
            Kube_URL            https://kubernetes.default.svc:443
            Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
            Merge_Log           On
            Keep_Log            Off
            K8S-Logging.Parser  On
            K8S-Logging.Exclude On
      EOT

      outputs = <<-EOT
        [OUTPUT]
            Name        kafka
            Match       kube.*
            Brokers     $${KAFKA_BROKERS}
            Topics      app-logs
            rdkafka.security.protocol   SASL_SSL
            rdkafka.sasl.mechanism      PLAIN
            rdkafka.sasl.username       $$ConnectionString
            rdkafka.sasl.password       $${KAFKA_PRODUCER_PASSWORD}
            rdkafka.api.version.request true
      EOT
    }

    env = [
      {
        name = "KAFKA_BROKERS"
        valueFrom = {
          secretKeyRef = { name = "eventhub-creds", key = "bootstrap_servers" }
        }
      },
      {
        name = "KAFKA_PRODUCER_PASSWORD"
        valueFrom = {
          secretKeyRef = { name = "eventhub-creds", key = "producer_connection_string" }
        }
      }
    ]
  })]

  depends_on = [module.aks, kubernetes_secret.eventhub_creds]
}

# OpenSearch (self-hosted on AKS) -- receives processed logs from Logstash
resource "helm_release" "opensearch" {
  name       = "opensearch"
  repository = "https://opensearch-project.github.io/helm-charts"
  chart      = "opensearch"
  version    = "2.23.1"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [yamlencode({
    replicas           = 2
    minimumMasterNodes = 1

    resources = {
      requests = { cpu = "500m", memory = "2Gi" }
      limits   = { cpu = "2", memory = "4Gi" }
    }

    persistence = {
      enabled      = true
      size         = "50Gi"
      storageClass = "managed-premium"
    }

    tolerations  = [{ key = "workload", value = "logging", effect = "NoSchedule" }]
    nodeSelector = { "workload" = "logging" }

    config = {
      "opensearch.yml" = <<-EOT
        cluster.name: iot-platform-logs
        network.host: 0.0.0.0
        discovery.type: multi-node
        plugins.security.disabled: false
      EOT
    }
  })]

  depends_on = [module.aks]
}

# Logstash -- consumes from Event Hubs (Kafka) and indexes into OpenSearch
resource "helm_release" "logstash" {
  name       = "logstash"
  repository = "https://helm.elastic.co"
  chart      = "logstash"
  version    = "8.5.1"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [yamlencode({
    replicas = 2

    resources = {
      requests = { cpu = "500m", memory = "1Gi" }
      limits   = { cpu = "2", memory = "2Gi" }
    }

    tolerations  = [{ key = "workload", value = "logging", effect = "NoSchedule" }]
    nodeSelector = { "workload" = "logging" }

    logstashConfig = {
      "logstash.yml" = "http.host: 0.0.0.0\nxpack.monitoring.enabled: false\n"
    }

    logstashPipeline = {
      "main.conf" = <<-EOT
        input {
          kafka {
            bootstrap_servers => "$${KAFKA_BROKERS}"
            topics => ["app-logs"]
            consumer_threads => 4
            decorate_events => true
            security_protocol => "SASL_SSL"
            sasl_mechanism => "PLAIN"
            sasl_jaas_config => "org.apache.kafka.common.security.plain.PlainLoginModule required username='$$ConnectionString' password='$${KAFKA_CONSUMER_PASSWORD}';"
            codec => json
          }
        }

        filter {
          mutate {
            add_field => { "environment" => "${var.environment}" }
            add_field => { "project" => "iot-platform" }
          }
          if [kubernetes] {
            mutate {
              rename => { "[kubernetes][pod_name]" => "pod" }
              rename => { "[kubernetes][namespace_name]" => "namespace" }
              rename => { "[kubernetes][container_name]" => "container" }
            }
          }
          date {
            match => ["time", "ISO8601"]
            target => "@timestamp"
          }
        }

        output {
          opensearch {
            hosts => ["opensearch-cluster-master.logging.svc.cluster.local:9200"]
            index => "iot-platform-logs-%%{+YYYY.MM.dd}"
            user => "admin"
            password => "$${OPENSEARCH_PASSWORD}"
            ssl => false
          }
        }
      EOT
    }

    extraEnvs = [
      {
        name      = "KAFKA_BROKERS"
        valueFrom = { secretKeyRef = { name = "eventhub-creds", key = "bootstrap_servers" } }
      },
      {
        name      = "KAFKA_CONSUMER_PASSWORD"
        valueFrom = { secretKeyRef = { name = "eventhub-creds", key = "consumer_connection_string" } }
      }
    ]
  })]

  depends_on = [helm_release.opensearch, helm_release.fluentbit]
}

# Grafana -- dashboards over OpenSearch datasource
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "7.3.9"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [yamlencode({
    replicas = 1

    persistence = {
      enabled      = true
      size         = "10Gi"
      storageClass = "managed-premium"
    }

    datasources = {
      "datasources.yaml" = {
        apiVersion = 1
        datasources = [{
          name      = "OpenSearch"
          type      = "grafana-opensearch-datasource"
          url       = "http://opensearch-cluster-master.logging.svc.cluster.local:9200"
          access    = "proxy"
          isDefault = true
          jsonData = {
            version   = "2.x"
            timeField = "@timestamp"
          }
        }]
      }
    }

    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
      }
    }

    tolerations  = [{ key = "workload", value = "logging", effect = "NoSchedule" }]
    nodeSelector = { "workload" = "logging" }
  })]

  depends_on = [helm_release.opensearch]
}
