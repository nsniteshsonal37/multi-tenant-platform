resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

resource "kubernetes_config_map" "otel_collector" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }

  data = {
    "otel-collector-config.yaml" = yamlencode({
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
      processors = {
        batch = {
          timeout         = "5s"
          send_batch_size = 1000
        }
        "resource/add_cluster" = {
          attributes = [
            { key = "service.cluster"; value = "hrs-platform"; action = "insert" },
            { key = "deployment.environment"; value = var.environment; action = "insert" }
          ]
        }
      }
      exporters = {
        "otlp/newrelic" = {
          endpoint = "https://otlp.eu01.nr-data.net:4317"
          headers  = { "api-key" = "$${NEW_RELIC_LICENSE_KEY}" }
          compression = "gzip"
        }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["resource/add_cluster", "batch"]
            exporters  = ["otlp/newrelic"]
          }
          metrics = {
            receivers  = ["otlp"]
            processors = ["resource/add_cluster", "batch"]
            exporters  = ["otlp/newrelic"]
          }
          logs = {
            receivers  = ["otlp"]
            processors = ["resource/add_cluster", "batch"]
            exporters  = ["otlp/newrelic"]
          }
        }
      }
    })
  }
}

resource "kubernetes_deployment" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels    = { app = "otel-collector" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "otel-collector" }
    }

    template {
      metadata {
        labels = { app = "otel-collector" }
      }

      spec {
        container {
          name  = "otel-collector"
          image = "otel/opentelemetry-collector-contrib:0.96.0"

          args = ["--config=/conf/otel-collector-config.yaml"]

          port { container_port = 4317 }
          port { container_port = 4318 }

          env {
            name  = "NEW_RELIC_LICENSE_KEY"
            value = var.new_relic_license_key
          }

          env {
            name  = "ENVIRONMENT"
            value = var.environment
          }

          volume_mount {
            name       = "config"
            mount_path = "/conf"
          }

          resources {
            requests = { cpu = "100m"; memory = "128Mi" }
            limits   = { cpu = "500m"; memory = "512Mi" }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.otel_collector.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }
  spec {
    selector = { app = "otel-collector" }
    port {
      name        = "grpc"
      port        = 4317
      target_port = 4317
    }
    port {
      name        = "http"
      port        = 4318
      target_port = 4318
    }
    type = "ClusterIP"
  }
}
