# OpsGrid — Live DevOps Operations Dashboard

> A production-grade DevOps monitoring dashboard showcasing real-world AWS + Kubernetes + CI/CD infrastructure patterns.

🔴 **[Live Demo →](https://yourorg.github.io/opsgrid)**

---

## 🧱 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions                           │
│   checkout → sonarqube → docker build → trivy → ECR → EKS      │
└────────────────────────┬────────────────────────────────────────┘
                         │
          ┌──────────────▼──────────────┐
          │         Jenkins CI          │
          │  build → test → deploy      │
          └──────────────┬──────────────┘
                         │
     ┌───────────────────▼───────────────────┐
     │         AWS EKS (ap-south-1)          │
     │   ┌──────────┐   ┌──────────────┐     │
     │   │ api-gw   │   │ payment-svc  │     │
     │   │ auth-svc │   │ order-svc    │     │
     │   │ notif-sv │   │ image-svc    │     │
     │   └──────────┘   └──────────────┘     │
     │          Kubernetes 1.29              │
     └───────────────────────────────────────┘
                         │
     ┌───────────────────▼───────────────────┐
     │      Terraform-managed AWS infra       │
     │  VPC · RDS · ElastiCache · ALB · ECR  │
     └───────────────────────────────────────┘
```

## 🛠 Tech Stack

| Layer | Tool |
|---|---|
| **Container Orchestration** | Kubernetes 1.29 on AWS EKS |
| **Infrastructure as Code** | Terraform 1.7 (84 resources) |
| **CI — Source Control** | GitHub Actions (multi-stage workflows) |
| **CI — Internal** | Jenkins (Declarative Pipelines) |
| **Code Quality** | SonarQube (coverage, bugs, smells) |
| **Container Security** | Trivy (CVE scanning, image hardening) |
| **DAST** | OWASP ZAP (active web scan) |
| **Dependency Audit** | OWASP Dependency-Check |
| **Container Registry** | AWS ECR (12 private repos) |
| **Database** | AWS RDS PostgreSQL (db.r6g.large) |
| **Cache** | AWS ElastiCache Redis |
| **Load Balancer** | AWS ALB (internet-facing) |
| **Monitoring** | Prometheus + CloudWatch |
| **Alerting** | AlertManager + CloudWatch Alarms |

## 📁 Repository Structure

```
opsgrid/
├── .github/
│   └── workflows/
│       ├── build-deploy.yml        # Main CI/CD pipeline
│       ├── nightly-scan.yml        # Scheduled security scans
│       └── release-staging.yml     # Staging release workflow
├── terraform/
│   ├── modules/
│   │   ├── eks/                    # EKS cluster module
│   │   ├── vpc/                    # VPC + subnets
│   │   ├── rds/                    # RDS postgres
│   │   └── security/               # IAM, SGs
│   ├── environments/
│   │   ├── prod/
│   │   ├── staging/
│   │   └── dev/
│   └── backend.tf                  # S3 state backend
├── k8s/
│   ├── namespaces/
│   ├── deployments/
│   ├── services/
│   ├── ingress/
│   └── hpa/                        # HorizontalPodAutoscaler
├── jenkins/
│   └── Jenkinsfile
├── sonar-project.properties
├── trivy.yaml
├── index.html                      # ← This dashboard
└── README.md
```

## 🔐 Security Pipeline

Every push triggers this security gate sequence:

```
[SonarQube]           → code quality + vulnerability scan
      ↓ PASS
[Trivy]               → Docker image CVE scan
      ↓ PASS (no CRITICAL)
[OWASP Dep-Check]     → dependency vulnerability audit
      ↓ PASS
[OWASP ZAP]           → dynamic application security testing
      ↓ PASS
[Deploy to EKS]       → rolling update with health checks
```

If any gate fails, the pipeline stops and notifies via Slack + email.

## 🚀 GitHub Actions Workflow (Simplified)

```yaml
name: Build & Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: SonarQube Scan
        uses: sonarqube/sonarqube-scan-action@v2

      - name: Build Docker Image
        run: docker build -t $ECR_REGISTRY/$SERVICE:$SHA .

      - name: Trivy Scan
        uses: aquasecurity/trivy-action@master
        with:
          exit-code: '1'
          severity: CRITICAL

      - name: Push to ECR
        run: docker push $ECR_REGISTRY/$SERVICE:$SHA

      - name: Deploy to EKS
        run: kubectl set image deployment/$SERVICE $SERVICE=$ECR_REGISTRY/$SERVICE:$SHA
```

## 📊 Infrastructure Costs

| Resource | Monthly |
|---|---|
| EKS cluster | $146.00 |
| EC2 nodes (6×) | $388.40 |
| RDS PostgreSQL | $192.50 |
| ElastiCache | $68.30 |
| ALB + data transfer | $42.10 |
| **Total** | **$837.30** |

---

## 🧑‍💻 Author

**Your Name**  
AWS DevOps Engineer  
[LinkedIn](https://linkedin.com/in/yourprofile) · [GitHub](https://github.com/yourorg)
