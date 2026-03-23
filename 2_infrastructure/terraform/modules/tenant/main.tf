locals {
  ns = "tenant-${var.tenant_id}"
  # PostgreSQL database name (hyphens not valid in DB names)
  db_name = "tenant_${replace(var.tenant_id, "-", "_")}"
}

# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "tenant" {
  metadata {
    name = local.ns
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "hrs/tenant-id"                = var.tenant_id
    }
  }
}

# ── ResourceQuota (prevents noisy-neighbour resource exhaustion) ──────────────
resource "kubernetes_resource_quota" "tenant" {
  metadata {
    name      = "tenant-quota"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "2"
      "requests.memory" = "2Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "4Gi"
      pods              = "20"
    }
  }
}

# ── NetworkPolicy: default deny + allow only from platform ───────────────────
resource "kubernetes_network_policy" "deny_all" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    # Explicit egress to DNS and RDS
    egress {
      ports { protocol = "UDP"; port = "53" }
      ports { protocol = "TCP"; port = "53" }
    }
    egress {
      ports { protocol = "TCP"; port = "5432" }
    }
    egress {
      ports { protocol = "TCP"; port = "6379" }
    }
    # Allow OTLP to observability namespace
    egress {
      ports { protocol = "TCP"; port = "4317" }
      to {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "observability" } }
      }
    }
  }
}

resource "kubernetes_network_policy" "allow_from_platform" {
  metadata {
    name      = "allow-from-platform"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "time-service" } }
    ingress {
      from {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "platform" } }
      }
      ports { protocol = "TCP"; port = "8080" }
    }
    policy_types = ["Ingress"]
  }
}

# ── ServiceAccount + RBAC ─────────────────────────────────────────────────────
resource "kubernetes_service_account" "time_service" {
  metadata {
    name      = "time-service"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
}

resource "kubernetes_role" "time_service" {
  metadata {
    name      = "time-service-role"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "time_service" {
  metadata {
    name      = "time-service-rolebinding"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.time_service.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.time_service.metadata[0].name
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
}

# ── ConfigMap: time-service ───────────────────────────────────────────────────
resource "kubernetes_config_map" "time_service" {
  metadata {
    name      = "time-service-config"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  data = {
    TENANT_ID       = var.tenant_id
    SERVICE_NAME    = "time-service"
    POSTGRES_HOST   = var.rds_endpoint
    POSTGRES_PORT   = "5432"
    POSTGRES_USER   = var.db_master_username
    POSTGRES_DB     = local.db_name
    REDIS_HOST      = "redis.${local.ns}.svc.cluster.local"
    REDIS_PORT      = "6379"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.observability.svc.cluster.local:4317"
  }
}

# ── Secret: time-service DB password ─────────────────────────────────────────
# Uses kubernetes_secret here for simplicity; in production source from ESO.
resource "kubernetes_secret" "time_service_db" {
  metadata {
    name      = "time-service-secret"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  data = {
    POSTGRES_PASSWORD = var.db_master_password
    JWT_SECRET        = var.jwt_secret
  }
  type = "Opaque"
}

# ── Deployment: time-service ──────────────────────────────────────────────────
resource "kubernetes_deployment" "time_service" {
  metadata {
    name      = "time-service"
    namespace = kubernetes_namespace.tenant.metadata[0].name
    labels    = { app = "time-service"; "hrs/tenant-id" = var.tenant_id }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "time-service" }
    }

    template {
      metadata {
        labels = { app = "time-service"; "hrs/tenant-id" = var.tenant_id }
      }

      spec {
        service_account_name = kubernetes_service_account.time_service.metadata[0].name

        container {
          name  = "time-service"
          image = "${var.ecr_registry}/${var.cluster_name}/time-service:latest"
          image_pull_policy = "Always"

          port { container_port = 8080 }

          env_from {
            config_map_ref { name = kubernetes_config_map.time_service.metadata[0].name }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.time_service_db.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.time_service_db.metadata[0].name
                key  = "JWT_SECRET"
              }
            }
          }

          liveness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "50m";  memory = "64Mi" }
            limits   = { cpu = "250m"; memory = "256Mi" }
          }
        }
      }
    }
  }

  depends_on = [null_resource.create_tenant_db]
}

resource "kubernetes_service" "time_service" {
  metadata {
    name      = "time-service"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  spec {
    selector = { app = "time-service" }
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ── HPA: time-service ─────────────────────────────────────────────────────────
resource "kubernetes_horizontal_pod_autoscaler_v2" "time_service" {
  metadata {
    name      = "time-service-hpa"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.time_service.metadata[0].name
    }
    min_replicas = 1
    max_replicas = 3
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

# ── Create per-tenant PostgreSQL database ─────────────────────────────────────
# Runs from the Jenkins agent (inside the cluster) which has network access to RDS.
# Requires postgresql-client in the Jenkins agent image.
resource "null_resource" "create_tenant_db" {
  triggers = { tenant_id = var.tenant_id }

  provisioner "local-exec" {
    command = "psql -h ${var.rds_endpoint} -p 5432 -U ${var.db_master_username} -d postgres -c \"CREATE DATABASE ${local.db_name};\" 2>/dev/null || true"
    environment = {
      PGPASSWORD = var.db_master_password
    }
  }
}

# ── Register tenant in registry_db (write-once, read by gateway) ──────────────
resource "null_resource" "register_tenant" {
  triggers = { tenant_id = var.tenant_id }

  provisioner "local-exec" {
    command = <<-EOT
      psql \
        -h ${var.rds_endpoint} -p 5432 \
        -U ${var.db_master_username} -d ${var.registry_db_name} \
        -c "INSERT INTO tenant_registry (tenant_id, namespace, service_name, status) \
            VALUES ('${var.tenant_id}', '${local.ns}', 'time-service', 'active') \
            ON CONFLICT (tenant_id) DO NOTHING;"
    EOT
    environment = {
      PGPASSWORD = var.db_master_password
    }
  }

  depends_on = [kubernetes_deployment.time_service]
}
