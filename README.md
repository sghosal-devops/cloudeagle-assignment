# CloudEagle — sync-service DevOps Assignment

This repository delivers the complete CI/CD pipeline design and GCP infrastructure proposal for the `sync-service` Spring Boot application.

## Repository Structure

```
.
├── part1-cicd/
│   ├── CICD-DESIGN.md        ← Full CI/CD design document
│   ├── Jenkinsfile           ← Production declarative pipeline (merge/deploy)
│   ├── Jenkinsfile.pr        ← Pull-request validation pipeline
│   ├── Dockerfile            ← Docker image packaging for VM deployment
│   └── scripts/
│       ├── deploy.sh         ← Environment-aware deployment (blue/green + rolling)
│       ├── rollback.sh       ← Automated & manual rollback
│       └── health-check.sh   ← Post-deployment health verification
└── part2-infrastructure-cloud-run/
    ├── INFRASTRUCTURE-DESIGN.md  ← Cloud Run infrastructure proposal
    ├── architecture/
    │   ├── diagram.md            ← Mermaid architecture diagrams
    │   └── sync-service-cloud-run-architecture.svg
    │                               ← Rendered architecture diagram
```

## How to Read This

| Goal | Start here |
|---|---|
| Understand the CI/CD approach | [part1-cicd/CICD-DESIGN.md](part1-cicd/CICD-DESIGN.md) |
| See the Jenkins pipeline code | [part1-cicd/Jenkinsfile](part1-cicd/Jenkinsfile) |
| Understand the GCP infrastructure | [part2-infrastructure-cloud-run/INFRASTRUCTURE-DESIGN.md](part2-infrastructure-cloud-run/INFRASTRUCTURE-DESIGN.md) |
| View architecture diagrams | [part2-infrastructure-cloud-run/architecture/diagram.md](part2-infrastructure-cloud-run/architecture/diagram.md) |
| Open the rendered architecture diagram | [sync-service-cloud-run-architecture.svg](part2-infrastructure-cloud-run/architecture/sync-service-cloud-run-architecture.svg) |

## Key Design Decisions

| Area | Decision | Rationale |
|---|---|---|
| Branching | GitFlow (`main`/`staging`/`develop`) | Clear env mapping, protected gates |
| Deployment (prod) | Blue/Green | Zero downtime, instant rollback |
| Deployment (non-prod) | Rolling update | Cost-effective, sufficient for dev/test |
| Part 1 runtime | Docker on GCP Compute Engine VMs | Matches the given VM deployment constraint |
| Part 2 compute | Cloud Run | Best fit for startup cost constraints, autoscaling, and low ops overhead |
| Database | MongoDB Atlas on GCP | Fully managed, same-region, private connectivity |
| Networking | Cloud Run + VPC connector + Private Service Connect | Private MongoDB access with managed HTTPS ingress |
| Secrets | Google Secret Manager + least-privilege IAM | No long-lived service account keys |
| Observability | Cloud Logging + Cloud Monitoring + Error Reporting | Native GCP stack with low operational overhead |
