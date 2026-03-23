data "aws_caller_identity" "current" {}

locals {
  oidc_sub = replace(var.cluster_oidc_issuer, "https://", "")
}

# ── Namespace: platform ───────────────────────────────────────────────────────
resource "kubernetes_namespace" "platform" {
  metadata {
    name = "platform"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# ── IAM Role for ExternalSecrets Operator (IRSA) ─────────────────────────────
data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_sub}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_sub}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

data "aws_iam_policy_document" "eso_policy" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:hrs/*"
    ]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "eso" {
  name   = "eso-secrets-manager"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_policy.json
}

# ── IAM Role for AWS Load Balancer Controller (IRSA) ─────────────────────────
data "aws_iam_policy_document" "lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_sub}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_sub}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
  tags               = var.tags
}

# Download the official AWS LBC IAM policy
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-lbc-policy"
  policy = data.http.lbc_iam_policy.response_body
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# ── Helm: ExternalSecrets Operator ───────────────────────────────────────────
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.16"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }
}

# ── Helm: AWS Load Balancer Controller ───────────────────────────────────────
resource "helm_release" "aws_lbc" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.7.1"

  set { name = "clusterName";                         value = var.cluster_name }
  set { name = "serviceAccount.create";               value = "true" }
  set { name = "serviceAccount.name";                 value = "aws-load-balancer-controller" }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lbc.arn
  }
}

# ── ClusterSecretStore → AWS Secrets Manager ─────────────────────────────────
resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "aws-secrets-manager" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.external_secrets]
}

# ── Platform Secrets (synced from AWS Secrets Manager) ───────────────────────
# Store these in Secrets Manager before running terraform apply:
#   hrs/platform/jwt-secret
#   hrs/platform/db-password
#   hrs/platform/newrelic-license-key
resource "kubernetes_manifest" "platform_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "platform-secrets"
      namespace = kubernetes_namespace.platform.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager"; kind = "ClusterSecretStore" }
      target = {
        name           = "platform-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "jwt-secret"
          remoteRef = { key = "hrs/platform/jwt-secret" }
        },
        {
          secretKey = "db-password"
          remoteRef = { key = "hrs/platform/db-password" }
        },
        {
          secretKey = "newrelic-license-key"
          remoteRef = { key = "hrs/platform/newrelic-license-key" }
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.cluster_secret_store]
}

# ── ConfigMap: auth-service ───────────────────────────────────────────────────
resource "kubernetes_config_map" "auth_service" {
  metadata {
    name      = "auth-service-config"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    SERVICE_NAME    = "auth-service"
    SERVICE_VERSION = "0.1.0"
    DATABASE_URL    = "postgresql+psycopg2://${var.db_username}@${var.rds_endpoint}/${var.auth_db_name}"
  }
}

# ── ConfigMap: gateway-service ────────────────────────────────────────────────
resource "kubernetes_config_map" "gateway_service" {
  metadata {
    name      = "gateway-service-config"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    SERVICE_NAME   = "gateway-service"
    REGISTRY_DB_URL = "postgresql+psycopg2://${var.db_username}@${var.rds_endpoint}/${var.registry_db_name}"
  }
}

# ── ServiceAccounts ───────────────────────────────────────────────────────────
resource "kubernetes_service_account" "auth_service" {
  metadata {
    name      = "auth-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
}

resource "kubernetes_service_account" "gateway_service" {
  metadata {
    name      = "gateway-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
}

# ── RBAC: allow gateway to read tenant registry only ─────────────────────────
resource "kubernetes_role" "gateway" {
  metadata {
    name      = "gateway-role"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "gateway" {
  metadata {
    name      = "gateway-rolebinding"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.gateway.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gateway_service.metadata[0].name
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
}

# ── Deployment: auth-service ──────────────────────────────────────────────────
resource "kubernetes_deployment" "auth_service" {
  metadata {
    name      = "auth-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "auth-service" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "auth-service" }
    }

    template {
      metadata {
        labels = { app = "auth-service" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.auth_service.metadata[0].name

        container {
          name  = "auth-service"
          image = "${var.ecr_registry}/${var.cluster_name}/auth-service:latest"
          image_pull_policy = "Always"

          port { container_port = 8080 }

          env_from {
            config_map_ref { name = kubernetes_config_map.auth_service.metadata[0].name }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.auth_service.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = "platform-secrets"
                key  = "jwt-secret"
              }
            }
          }

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "platform-secrets"
                key  = "db-password"
              }
            }
          }

          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.observability.svc.cluster.local:4317"
          }

          liveness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          readiness_probe {
            http_get { path = "/ready"; port = 8080 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "100m"; memory = "128Mi" }
            limits   = { cpu = "500m"; memory = "512Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "auth_service" {
  metadata {
    name      = "auth-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    selector = { app = "auth-service" }
    port {
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ── Deployment: gateway-service ───────────────────────────────────────────────
resource "kubernetes_deployment" "gateway_service" {
  metadata {
    name      = "gateway-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "gateway-service" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "gateway-service" }
    }

    template {
      metadata {
        labels = { app = "gateway-service" }
      }

      spec {
        service_account_name = kubernetes_service_account.gateway_service.metadata[0].name

        container {
          name  = "gateway-service"
          image = "${var.ecr_registry}/${var.cluster_name}/gateway-service:latest"
          image_pull_policy = "Always"

          port { container_port = 8080 }

          env_from {
            config_map_ref { name = kubernetes_config_map.gateway_service.metadata[0].name }
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref { name = "platform-secrets"; key = "jwt-secret" }
            }
          }

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref { name = "platform-secrets"; key = "db-password" }
            }
          }

          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.observability.svc.cluster.local:4317"
          }

          liveness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 10
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "100m"; memory = "128Mi" }
            limits   = { cpu = "500m"; memory = "512Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "gateway_service" {
  metadata {
    name      = "gateway-service"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    selector = { app = "gateway-service" }
    port {
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ── Ingress: shared ALB for platform ─────────────────────────────────────────
resource "kubernetes_ingress_v1" "platform" {
  metadata {
    name      = "platform-ingress"
    namespace = kubernetes_namespace.platform.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/group.name"               = "hrs-platform"
      "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ "HTTPS" = 443 }, { "HTTP" = 80 }])
      "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
      "alb.ingress.kubernetes.io/certificate-arn"          = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/health"
      "alb.ingress.kubernetes.io/security-groups"          = var.node_sg_id
    }
  }

  spec {
    rule {
      host = "api.${var.domain_name}"
      http {
        path {
          path      = "/auth"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.gateway_service.metadata[0].name
              port { number = 80 }
            }
          }
        }
        path {
          path      = "/time"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.gateway_service.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}

# ── HorizontalPodAutoscaler ───────────────────────────────────────────────────
resource "kubernetes_horizontal_pod_autoscaler_v2" "auth_service" {
  metadata {
    name      = "auth-service-hpa"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.auth_service.metadata[0].name
    }
    min_replicas = 2
    max_replicas = 5
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 60
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "gateway_service" {
  metadata {
    name      = "gateway-service-hpa"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.gateway_service.metadata[0].name
    }
    min_replicas = 2
    max_replicas = 5
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 60
        }
      }
    }
  }
}

# ── NetworkPolicy: platform namespace ────────────────────────────────────────
resource "kubernetes_network_policy" "platform_default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "platform_allow_alb" {
  metadata {
    name      = "allow-alb-ingress"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "gateway-service" } }
    ingress {
      ports { protocol = "TCP"; port = "8080" }
    }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "allow_gateway_to_auth" {
  metadata {
    name      = "allow-gateway-to-auth"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "auth-service" } }
    ingress {
      from {
        pod_selector { match_labels = { app = "gateway-service" } }
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "platform" } }
      }
      ports { protocol = "TCP"; port = "8080" }
    }
    policy_types = ["Ingress"]
  }
}
