# CloudEagle — sync-service DevOps Assignment

Spring Boot service (`sync-service`) — CI/CD design for GCP VM deployment (Part 1) and GCP infrastructure proposal for a startup-scale future state (Part 2).

---

## Repository Structure

```
.
├── part1-cicd/
│   ├── CICD-DESIGN.md          ← Full CI/CD design: branching, pipeline, secrets, rollback
│   ├── Dockerfile              ← Production image: eclipse-temurin:17-jre-alpine, non-root user
│   ├── Jenkinsfile             ← Declarative pipeline: build → test → Docker image → deploy → verify
│   ├── Jenkinsfile.pr          ← PR pipeline: build + test + local Docker scan (no push, no deploy)
│   └── scripts/
│       ├── deploy.sh           ← Blue/green (prod) + rolling (QA/staging) deploy via IAP SSH
│       ├── rollback.sh         ← Prod: LB backend flip in <5s. Non-prod: previous image re-run
│       └── health-check.sh     ← 7 per-VM checks: SSH, docker inspect, actuator, liveness, readiness, MongoDB
│
└── part2-infrastructure-cloud-run/
    ├── INFRASTRUCTURE-DESIGN.md    ← Cloud Run infrastructure proposal with full justification
    └── architecture/
        ├── diagram.md              ← Mermaid diagrams: architecture + CI/CD deployment flow
        └── sync-service-cloud-run-architecture.svg   ← Rendered architecture diagram
```

---

## Part 1 — CI/CD Pipeline (GCP Compute Engine VMs + Docker)

### Pipeline Overview

```
PR open / update  →  Jenkinsfile.pr
                      ├── Build (mvn package)
                      ├── Unit Tests + SonarQube + OWASP  (parallel)
                      ├── Quality Gate
                      ├── Docker Build  (local only — never pushed)
                      └── Trivy image scan  →  result posted as GitHub check status

Merge to develop  →  Jenkinsfile
Merge to staging  →  Jenkinsfile
Merge to main     →  Jenkinsfile
                      ├── Build → Unit Tests → SonarQube → OWASP  (parallel)
                      ├── Quality Gate (SonarQube blocks pipeline on failure)
                      ├── Docker Build  →  gcr.io/cloudeagle-prod/sync-service:<sha>
                      ├── Trivy image scan  (fail on unfixed HIGH/CRITICAL CVE)
                      ├── Push to GCR
                      ├── Deploy → QA         (develop branch only — rolling, IAP SSH)
                      ├── Integration Tests   (develop branch only)
                      ├── Deploy → Staging    (staging branch only — rolling, IAP SSH)
                      ├── Performance Tests   (staging branch only — Gatling)
                      ├── ── MANUAL APPROVAL ──  (main branch only — release-managers + change ticket)
                      ├── Deploy → Prod       (main branch only — blue/green, LB backend flip)
                      └── Health Checks  →  auto-rollback if any check fails
```

### Key Design Decisions — Part 1

| Area | Decision | Rationale |
|---|---|---|
| **Branching** | GitFlow: `main` / `staging` / `develop` | One branch per environment; protected merges prevent skipped gates |
| **Prod deployment** | Blue/Green (two MIGs + LB backend flip) | Zero downtime; rollback is a single `gcloud` command in <5 seconds |
| **Non-prod deployment** | Rolling update (VM-by-VM via IAP SSH) | No extra VMs needed; one VM offline at a time |
| **Image registry** | GCR (`gcr.io/cloudeagle-prod/sync-service`) | Authenticated via GCE metadata server — no credentials stored anywhere |
| **SSH access** | Cloud IAP tunnel + OS Login | No static SSH keys; ephemeral 10-minute certificates per session |
| **Secrets** | Google Secret Manager → tmpfs `/run/sync-service/secrets.env` | Secrets never touch disk; cleared on reboot |
| **CVE scanning** | Trivy image scan on every build | Blocks push on unfixed HIGH/CRITICAL; SARIF output to Jenkins |
| **Prod guard** | `input()` step — change ticket + 30-min timeout | Human in the loop; pipeline self-aborts if nobody approves |
| **Rollback** | LB backend swap (prod) / previous image tag (non-prod) | No JAR/artifact movement for prod rollback |

---

## Part 2 — Infrastructure Proposal (Cloud Run on GCP)

The assignment asks to propose a startup-appropriate infrastructure. Rather than defaulting to Kubernetes (which adds cluster, node, and operational overhead a startup may not need), the proposal is **Cloud Run** — serverless containers that scale to zero, require no node management, and connect privately to MongoDB Atlas.

### Key Design Decisions — Part 2

| Area | Decision | Rationale |
|---|---|---|
| **Compute** | Cloud Run | Scale to zero, pay-per-use, managed HTTPS, no cluster ops |
| **Database** | MongoDB Atlas M30 (prod) on GCP | Managed replica set, backups, Private Service Connect to VPC |
| **Networking** | VPC connector + Private Service Connect | Database traffic never leaves Google's network |
| **Ingress** | Cloud Run managed HTTPS + optional Cloud Armor | TLS handled by Google; WAF added when needed |
| **Secrets** | Secret Manager injected as env vars into Cloud Run | No key files; IAM-scoped per environment |
| **Deployment** | Revision-based canary: 0% → 10% → 50% → 100% | Same blue/green outcome without maintaining two VM groups |
| **CI/CD link** | Same Docker image from GCR/Artifact Registry, deployed via `gcloud run deploy` | Part 1 pipeline pushes the image; Part 2 deploys it |

The same Docker image built and scanned in Part 1 is deployed to Cloud Run — no rebuild needed. The deployment step changes from `deploy.sh` (VM SSH) to `gcloud run deploy` (serverless revision).

### Migration Path

Cloud Run is the right starting point. Migration to **GKE Autopilot** is warranted if the service gains always-on background workers, multiple services needing a service mesh, or Kubernetes-native policy requirements.

---

## How to Read This

| Question | Go to |
|---|---|
| How does the pipeline work end-to-end? | [part1-cicd/CICD-DESIGN.md](part1-cicd/CICD-DESIGN.md) |
| Show me the Jenkins pipeline code | [part1-cicd/Jenkinsfile](part1-cicd/Jenkinsfile) |
| Show me the Docker image spec | [part1-cicd/Dockerfile](part1-cicd/Dockerfile) |
| How does deployment / rollback work? | [part1-cicd/scripts/deploy.sh](part1-cicd/scripts/deploy.sh) · [part1-cicd/scripts/rollback.sh](part1-cicd/scripts/rollback.sh) |
| How are health checks done post-deploy? | [part1-cicd/scripts/health-check.sh](part1-cicd/scripts/health-check.sh) |
| What infrastructure is proposed? | [part2-infrastructure-cloud-run/INFRASTRUCTURE-DESIGN.md](part2-infrastructure-cloud-run/INFRASTRUCTURE-DESIGN.md) |
| Show me the architecture diagram | [part2-infrastructure-cloud-run/architecture/diagram.md](part2-infrastructure-cloud-run/architecture/diagram.md) |
