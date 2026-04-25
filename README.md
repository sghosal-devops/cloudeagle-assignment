# CloudEagle — sync-service DevOps Assignment

This repository delivers the complete CI/CD pipeline design and GCP infrastructure proposal for the `sync-service` Spring Boot application.

## Repository Structure

```
.
├── part1-cicd/
│   ├── CICD-DESIGN.md        ← Full CI/CD design document
│   ├── Jenkinsfile           ← Production declarative pipeline (merge/deploy)
│   ├── Jenkinsfile.pr        ← Pull-request validation pipeline
│   └── scripts/
│       ├── deploy.sh         ← Environment-aware deployment (blue/green + rolling)
│       ├── rollback.sh       ← Automated & manual rollback
│       └── health-check.sh   ← Post-deployment health verification
└── part2-infrastructure/
    ├── INFRASTRUCTURE-DESIGN.md  ← Architecture decisions & rationale
    ├── architecture/
    │   └── diagram.md            ← Mermaid architecture diagrams
    └── terraform/                ← Infrastructure as Code (GCP / Terraform)
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── gke.tf
        ├── networking.tf
        ├── iam.tf
        └── monitoring.tf
```

## How to Read This

| Goal | Start here |
|---|---|
| Understand the CI/CD approach | [part1-cicd/CICD-DESIGN.md](part1-cicd/CICD-DESIGN.md) |
| See the Jenkins pipeline code | [part1-cicd/Jenkinsfile](part1-cicd/Jenkinsfile) |
| Understand the GCP infrastructure | [part2-infrastructure/INFRASTRUCTURE-DESIGN.md](part2-infrastructure/INFRASTRUCTURE-DESIGN.md) |
| View architecture diagrams | [part2-infrastructure/architecture/diagram.md](part2-infrastructure/architecture/diagram.md) |
| Provision infrastructure | [part2-infrastructure/terraform/](part2-infrastructure/terraform/) |

## Key Design Decisions

| Area | Decision | Rationale |
|---|---|---|
| Branching | GitFlow (`main`/`staging`/`develop`) | Clear env mapping, protected gates |
| Deployment (prod) | Blue/Green | Zero downtime, instant rollback |
| Deployment (non-prod) | Rolling update | Cost-effective, sufficient for dev/test |
| Compute | GKE Autopilot | Managed nodes, cost-per-pod, auto-scaling |
| Database | MongoDB Atlas on GCP | Fully managed, same-region, VPC peering |
| Secrets | Google Secret Manager + Workload Identity | No long-lived credentials in pods |
| Observability | Cloud Logging + Prometheus/Grafana | Native GCP + rich application metrics |
