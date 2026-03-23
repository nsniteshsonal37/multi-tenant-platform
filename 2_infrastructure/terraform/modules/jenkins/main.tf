data "aws_caller_identity" "current" {}

locals {
  oidc_sub = replace(var.cluster_oidc_issuer, "https://", "")
}

# ── Namespace: jenkins ────────────────────────────────────────────────────────
resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# ── IRSA: Jenkins needs ECR push + EKS describe for kubectl ──────────────────
data "aws_iam_policy_document" "jenkins_assume" {
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
      values   = ["system:serviceaccount:jenkins:jenkins"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_policy" {
  # ECR: push images
  statement {
    effect  = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = ["*"]
  }
  # EKS: update kubeconfig
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.jenkins_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "jenkins-ecr-eks"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_policy.json
}

# ── ServiceAccount ────────────────────────────────────────────────────────────
resource "kubernetes_service_account" "jenkins" {
  metadata {
    name      = "jenkins"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.jenkins.arn
    }
  }
}

# ── ClusterRole: Jenkins needs to create namespaces + deploy to any namespace ─
resource "kubernetes_cluster_role" "jenkins" {
  metadata { name = "jenkins-provisioner" }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "serviceaccounts", "configmaps", "secrets", "services", "pods"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies", "ingresses"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["*"]
  }
  rule {
    api_groups = [""]
    resources  = ["resourcequotas"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "jenkins" {
  metadata { name = "jenkins-provisioner" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.jenkins.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.jenkins.metadata[0].name
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }
}

# ── Helm: Jenkins ─────────────────────────────────────────────────────────────
resource "helm_release" "jenkins" {
  name       = "jenkins"
  namespace  = kubernetes_namespace.jenkins.metadata[0].name
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  version    = "5.1.5"

  values = [yamlencode({
    controller = {
      serviceType   = "ClusterIP"
      adminPassword = var.jenkins_admin_password
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.jenkins.metadata[0].name
      }
      installPlugins = [
        "kubernetes:4253.v7700d91739e5",
        "workflow-aggregator:596.v8c21c963d92d",
        "git:5.2.1",
        "pipeline-stage-view:2.34",
        "aws-credentials:231.v08a_c4b_291571",
        "docker-workflow:572.v950f58993843",
        "pipeline-utility-steps:2.16.2",
      ]
      resources = {
        requests = { memory = "512Mi", cpu = "250m" }
        limits   = { memory = "1Gi",   cpu = "1" }
      }
    }
    persistence = {
      enabled      = true
      size         = "8Gi"
      storageClass = "gp2"
    }
    agent = {
      enabled   = true
      namespace = kubernetes_namespace.jenkins.metadata[0].name
    }
  })]
}

# ── Ingress: Jenkins via shared ALB ───────────────────────────────────────────
resource "kubernetes_ingress_v1" "jenkins" {
  metadata {
    name      = "jenkins"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/group.name"      = "hrs-platform"
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ "HTTPS" = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
    }
  }
  spec {
    rule {
      host = "jenkins.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "jenkins"
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
}
