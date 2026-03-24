# Multi-Tenant Application Platform

A production-ready, cost-optimised multi-tenant application platform built on **AWS EKS**,
supporting 20+ engineering teams with a clear path to 50+. This repository contains:

| Folder | Contents |
|---|---|
| [`1_platform_design/`](1_platform_design/README.md) | Architecture diagram, multi-tenancy model, scalability plan, cost estimate, trade-offs |
| [`2_infrastructure/terraform/`](2_infrastructure/terraform/) | Terraform IaC — VPC, EKS, RDS, S3/ECR, platform services, per-tenant provisioning, Jenkins CI/CD, OTel observability |
| [`2_infrastructure/k8s/`](2_infrastructure/k8s/) | Standalone Kubernetes manifests (alternative to Terraform for K8s resources) |
| [`3_observability/`](3_observability/README.md) | OTel Collector config, monitoring strategy, SLIs/SLOs, New Relic dashboard queries |
| [`Jenkinsfile`](Jenkinsfile) | CI/CD pipeline: build → test → push images to ECR → deploy platform services |
| [`Jenkinsfile.tenant`](Jenkinsfile.tenant) | Tenant provisioning pipeline: accepts comma-separated tenant list, runs Terraform |

### Application Source Code (in `Tenant-Test/`)

The three FastAPI microservices live in the parent workspace under `Tenant-Test/`:
- `auth-service` — User registration, login, JWT issuance
- `gateway-service` — Request routing, JWT validation, tenant registry lookup (read-only)
- `time-service` — Per-tenant timezone management, deployed once per tenant namespace

---

## Prerequisites

| Tool | Minimum Version |
|---|---|
| Terraform | 1.5+ |
| AWS CLI | 2.x |
| kubectl | 1.29+ |
| Docker | 24+ |
| `psql` (postgresql-client) | 15+ (required on Terraform runner for DB init) |

AWS IAM permissions needed for the user/role running `terraform apply`:
`AmazonEKSFullAccess`, `AmazonRDSFullAccess`, `AmazonS3FullAccess`,
`AmazonEC2FullAccess`, `IAMFullAccess`, `AmazonECRFullAccess`, `SecretsManagerReadWrite`

---

## One-Time Setup

### 1. Create ACM Certificate

```bash
aws acm request-certificate \
    --domain-name "platform.example.com" \
    --subject-alternative-names "*.platform.example.com" \
    --validation-method DNS \
    --region eu-central-1
```

Complete DNS validation, then copy the certificate ARN.

### 2. Store Secrets in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
    --name "hrs/platform/jwt-secret" \
    --secret-string "$(openssl rand -base64 32)" \
    --region eu-central-1

aws secretsmanager create-secret \
    --name "hrs/platform/db-password" \
    --secret-string "YourStrongDBPassword!" \
    --region eu-central-1

aws secretsmanager create-secret \
    --name "hrs/platform/newrelic-license-key" \
    --secret-string "YOUR_NEW_RELIC_LICENSE_KEY" \
    --region eu-central-1
```

### 3. Configure Terraform Variables

```bash
cd 2_infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in db_password, jwt_secret, new_relic_license_key,
# acm_certificate_arn, and domain_name
```

---

## Deploy Infrastructure

> **Note:** The Kubernetes and Helm providers depend on the EKS cluster endpoint. Run in two steps:

### Step 1 — VPC + EKS

```bash
cd 2_infrastructure/terraform
terraform init
terraform apply -target=module.vpc -target=module.eks
```

Wait for the EKS cluster to be `ACTIVE` (~10 min).

### Step 2 — Full Stack

```bash
terraform apply \
    -var="new_relic_license_key=YOUR_KEY" \
    -var="db_password=YOUR_PASSWORD" \
    -var="jwt_secret=YOUR_JWT_SECRET" \
    -var="jenkins_admin_password=YOUR_JENKINS_PASSWORD" \
    -var="acm_certificate_arn=arn:aws:acm:..." \
    -var="domain_name=platform.example.com"
```

This provisions:
- RDS PostgreSQL (auth_db + registry_db created via psql local-exec)
- S3 artifact bucket + ECR repositories
- `platform` namespace with gateway and auth services, ESO, AWS LBC
- `observability` namespace with OTel Collector forwarding to New Relic
- `jenkins` namespace with Jenkins Helm release

### Update DNS

Point `api.platform.example.com` and `jenkins.platform.example.com` to the ALB DNS name:
```bash
kubectl get ingress -A
# Copy the ADDRESS field (ALB DNS name) and create CNAME records in Route 53
```

---

## Add Tenants

### Via Jenkins (recommended)

1. Open `https://jenkins.platform.example.com`
2. Trigger the **tenant-provision** pipeline
3. Set `TENANT_IDS = acme,beta,contoso` (comma-separated, provision many at once)
4. The pipeline: reads existing tenants → merges new ones → runs `terraform apply` →
   waits for rollouts → smoke tests each time-service

### Via CLI (manual)

```bash
cd 2_infrastructure/terraform

# Read current tenant list
CURRENT=$(terraform output -json tenant_ids)

# Append new tenants
terraform apply \
    -var='tenant_ids=["acme","beta","contoso"]' \
    -var-file=terraform.tfvars
```

Each tenant gets:
- Kubernetes namespace `tenant-{id}` with resource quotas
- Network policies: deny all, allow only from `platform` namespace
- RBAC ServiceAccount scoped to own namespace
- `time-service` deployment (1 replica, HPA 1–3)
- Dedicated PostgreSQL database `tenant_{id}` on shared RDS
- Registry row in `registry_db.tenant_registry` (read by gateway for routing)

---

## Request Flow

```
POST /auth/register  →  Gateway (platform)  →  Auth Service  →  RDS auth_db
POST /auth/login     →  Gateway (platform)  →  Auth Service  →  returns JWT
GET  /time/now       →  Gateway (platform)
                             → decode JWT → extract tenant_id
                             → SELECT namespace FROM tenant_registry
                             → proxy to http://time-service.tenant-{id}.svc.cluster.local:8080
```

---

## CI/CD Pipelines

| Pipeline | File | Trigger | Purpose |
|---|---|---|---|
| Platform Deploy | `Jenkinsfile` | Push to `main` | Build/push all 3 images → deploy platform services |
| Tenant Provision | `Jenkinsfile.tenant` | Manual (parameterised) | Provision new tenant namespaces via Terraform |

### Jenkins Credentials to Configure

| Credential ID | Type | Value |
|---|---|---|
| `aws-credentials` | Username+Password | AWS Access Key ID + Secret |
| `terraform-tfvars` | Secret file | Copy of `terraform.tfvars` |

---

## Design Decisions & Known Limitations

| Item | Note |
|---|---|
| **Auth-service database** | Code defaults to SQLite; overridden by `DATABASE_URL` env var pointing to RDS PostgreSQL. Code-level fix applied in `app/db/session.py`. |
| **Database migrations** | Using `Base.metadata.create_all()` (auto-create on startup). **Alembic migrations should be introduced before any schema changes in production** — skipped here due to time constraints. |
| **Terraform state** | Stored locally on Jenkins EBS PVC. For production: migrate to S3 backend with DynamoDB locking. |
| **Single NAT Gateway** | Cost trade-off (~$33/mo saving vs. 2 NAT Gateways). Add second NAT at 100+ tenants for HA. |
| **Single-AZ RDS** | Cost trade-off (~$15/mo saving). Mitigated by automated 7-day backups and point-in-time restore. Upgrade to Multi-AZ for production SLA requirements. |
| **Node isolation** | Tenants share EKS worker nodes. Namespace-level isolation via NetworkPolicy + RBAC is sufficient at this scale. Fargate profiles can be added per tenant at 50+ teams if stricter isolation is required. |

---

## Repository Structure

```
HRS-Assessment/
├── README.md                          ← This file
├── Jenkinsfile                         ← Platform deploy pipeline
├── Jenkinsfile.tenant                  ← Tenant provisioning pipeline
├── 1_platform_design/
│   └── README.md                      ← Architecture, scalability, cost estimate, trade-offs
├── 2_infrastructure/
│   ├── terraform/
│   │   ├── main.tf                    ← Module orchestration
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars.example
│   │   └── modules/
│   │       ├── vpc/                   ← VPC, subnets, NAT GW, security groups
│   │       ├── eks/                   ← EKS cluster, OIDC, node group, add-ons
│   │       ├── rds/                   ← RDS PostgreSQL 15 (db.t3.micro, single-AZ)
│   │       ├── s3/                    ← S3 artifact bucket, ECR repositories
│   │       ├── platform/              ← platform namespace, ESO, ALB controller, auth+gateway
│   │       ├── tenant/                ← per-tenant namespace, time-service, DB, registry row
│   │       ├── jenkins/               ← Jenkins Helm release, IRSA, RBAC
│   │       └── observability/         ← OTel Collector → New Relic
│   └── k8s/
│       ├── platform/                  ← Standalone K8s manifests for platform namespace
│       ├── tenant/                    ← Template manifests for tenant namespace (TENANT_ID placeholder)
│       └── observability/             ← OTel Collector K8s manifests
└── 3_observability/
    ├── otel-collector-config.yaml     ← OTLP receivers → New Relic OTLP exporter
    └── README.md                      ← Monitoring strategy, SLIs/SLOs, NRQL queries
```
