# CI/CD Design — sync-service

## 1. Overview & Goals

The CI/CD pipeline for `sync-service` must satisfy five requirements:

1. **Safety** — No accidental production deployments; every prod release requires an explicit human approval and a change-management ticket.
2. **Speed** — Developers get test feedback in < 10 minutes; a standard QA deployment completes in < 15 minutes.
3. **Reliability** — Automated rollback triggers within 60 seconds of a failed health check.
4. **Traceability** — Every deployed artifact is traceable to a commit, a build number, an approver, and a change ticket.
5. **Security** — Secrets are never stored in source code, config files on disk, or Jenkins console output.

---

## 2. Branching Strategy

### Branch Model (GitFlow-based)

```
main          ← Production. Protected. Merge via PR from `staging` only.
 └── staging  ← Staging environment. Protected. Merge via PR from `develop` only.
      └── develop   ← QA environment. Default integration branch.
           ├── feature/<ticket>-<description>   ← Feature work. PR → develop.
           ├── bugfix/<ticket>-<description>     ← Bug fixes.   PR → develop.
           └── hotfix/<ticket>-<description>     ← Critical prod fixes. PR → main AND develop.
```

### Branch-to-Environment Mapping

| Branch | Environment | Deployment trigger |
|---|---|---|
| `feature/*`, `bugfix/*` | — (no deployment) | PR open: build + test + scan |
| `develop` | QA | Merge: full pipeline → auto-deploy to QA VMs |
| `staging` | Staging | Merge: full pipeline → auto-deploy to staging VMs |
| `main` | Production | Merge: full pipeline → **manual approval gate** → blue/green deploy to prod VMs |
| `hotfix/*` | QA → Staging → Production (fast-track) | PR → emergency fast-track flow |

### Branch Protection Rules

**`main`**
- Require 2 approving reviews (at least 1 from `release-managers` group)
- Dismiss stale reviews on new commits
- Require all status checks to pass: `build`, `unit-tests`, `sonarqube`, `trivy-scan`
- Require branches to be up to date before merging
- No direct pushes (including admins)
- Restrict merge to `release-managers` group

**`staging`**
- Require 1 approving review
- Require status checks: `build`, `unit-tests`, `sonarqube`
- No direct pushes

**`develop`**
- Require status checks: `build`, `unit-tests`
- Allow squash merges; delete branch after merge

### Preventing Accidental Production Deployments

Five independent guards prevent accidental prod deployments:

1. **Branch protection**: Only PRs from `staging` can merge to `main`; requires 2 reviewers.
2. **Pipeline environment detection**: The `Jenkinsfile` only executes the prod deploy stage when `BRANCH_NAME == 'main'`. Feature branches and `develop` cannot reach the prod stage.
3. **Manual approval gate** (`input` step): A human from `release-managers` must explicitly confirm in Jenkins, supply a change-ticket number, and check a confirmation checkbox. The pipeline aborts if the ticket field is empty or confirmation is unchecked.
4. **Timeout**: The approval gate has a 30-minute timeout. If nobody approves, the pipeline aborts — preventing a forgotten build from deploying hours later.
5. **Audit log**: The approver identity, change ticket, commit SHA, image tag, and blue/green slot state are recorded in Jenkins logs and persisted to GCS (`active-slot.json` for production rollback metadata).

---

## 3. Jenkins Pipeline Design

### Pipeline Types

| Pipeline file | Triggered by | Purpose |
|---|---|---|
| `Jenkinsfile` | Merge to `develop`, `staging`, `main` | Full build + test + Docker image + deploy to VMs |
| `Jenkinsfile.pr` | PR open / update | Build + test + quality scan + local Docker image scan (no push, no deploy) |

### Full Pipeline Stages

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  STAGE               │  DESCRIPTION                         │  BRANCHES      │
├──────────────────────┼──────────────────────────────────────┼────────────────┤
│ 1. Initialise        │ Metadata, resolve env, Slack notify  │ ✓ all          │
│ 2. Build             │ mvn clean package -DskipTests        │ ✓ all          │
│ 3. Unit Tests   ┐    │ mvn test + JaCoCo coverage           │ ✓ all          │
│ 4. Sonar        ├ ⟺  │ SonarQube static analysis            │ ✓ all          │
│ 5. OWASP Dep    ┘    │ Dependency vulnerability check       │ ✓ all          │
│ 6. Quality Gate      │ SonarQube gate (blocks on fail)      │ ✓ all          │
│ 7. Docker Build      │ docker build → gcr.io image:sha      │ ✓ all          │
│ 8. Security Scan     │ Trivy CVE scan on Docker image       │ ✓ all          │
│ 9. Push to GCR       │ docker push gcr.io/…/sync-service    │ ✓ all          │
│10. Deploy → QA       │ IAP SSH: docker pull + docker run    │ develop only   │
│11. Integration Tests │ mvn verify -Pintegration-tests       │ develop only   │
│12. Deploy → Staging  │ IAP SSH: docker pull + docker run    │ staging only   │
│13. Perf Tests        │ Gatling load test                    │ staging only   │
│14. Prod Approval     │ input() — human gate + change ticket │ main only      │
│15. Deploy → Prod     │ Blue/Green: idle MIG → LB flip       │ main only      │
│16. Health Checks     │ SSH: docker inspect + actuator probes│ deploy stages  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Parallelism

Stages 3–5 (Unit Tests, SonarQube, OWASP) run **in parallel** to reduce pipeline time.

### PR Pipeline Stages

```
Checkout → Build → [Unit Tests ⟺ SonarQube ⟺ OWASP] → Quality Gate → Docker Build (local) → Trivy Image Scan
```

The Docker image is built locally on the Jenkins agent, scanned by Trivy, then discarded — never pushed to GCR. Results posted as GitHub check statuses.

### What Happens on PR vs Merge?

**On PR open/update (`Jenkinsfile.pr`)**
- Full build and test suite runs
- SonarQube posts inline annotations to the PR
- Docker image is built locally on the agent (tagged `pr-<number>-<sha>`)
- Trivy scans the Docker image for OS package and dependency CVEs — fails on unfixed HIGH/CRITICAL
- OWASP dependency report uploaded as Jenkins artifact
- The local Docker image is removed after the scan (`docker rmi`) — never pushed to GCR, no VM touched
- All results become required GitHub check statuses

**On merge to `develop`**
- Full pipeline including Docker Build → Trivy scan → Push to GCR
- Automatic rolling deploy to QA VMs: each VM pulls the new image from GCR via IAP SSH, stops the old container, starts the new one
- Integration tests run against QA environment
- Slack notification with deployment summary

**On merge to `staging`**
- Full pipeline including Docker Build → Trivy scan → Push to GCR
- Automatic rolling deploy to staging VMs
- Gatling performance tests
- Slack notification

**On merge to `main`**
- Full pipeline including Docker Build → Trivy scan → Push to GCR
- **30-minute manual approval gate** — requires `release-managers` group member + change ticket
- Blue/green deploy: new image deployed to idle MIG, health-checked, then LB flipped
- Automated health checks (SSH: docker inspect + actuator probes)
- Auto-rollback (LB backend switch) if health checks fail
- Rollback/audit metadata written to GCS; Slack/Jenkins retain the approval and deployment trail
- Slack notification to `#deployments` and `#prod-releases`

---

## 4. Configuration Management

### Principle

Source code is environment-agnostic. Configuration is environment-specific and lives outside the Docker image.

### Approach: Spring Boot Profiles + Docker `--env-file` + volume-mounted config

**Configuration layers** passed into the container at startup (highest priority first):

```
1. /run/sync-service/secrets.env   ← secrets from Secret Manager at deploy time (tmpfs — never touches disk)
2. /etc/sync-service/env           ← non-sensitive env vars: DB host, log level, feature flags
3. /etc/sync-service/application.yml (volume-mounted into container)  ← env-specific Spring config
4. application-{env}.yml embedded in the image  ← non-sensitive per-env defaults
5. application.yml embedded in the image        ← base defaults
```

The container is started with both env files and a volume-mounted config:

```bash
docker run -d \
  --name sync-service \
  --restart unless-stopped \
  -p 8080:8080 \
  -p 8081:8081 \
  --env-file /etc/sync-service/env \
  --env-file /run/sync-service/secrets.env \
  -v /etc/sync-service/application.yml:/app/config/application.yml:ro \
  -v /var/log/sync-service:/app/logs \
  --log-driver=gcplogs \
  --log-opt gcp-project=cloudeagle-prod \
  --memory=2g --memory-swap=2g --cpus=2 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --security-opt=no-new-privileges:true \
  gcr.io/cloudeagle-prod/sync-service:<sha>
```

**Example `/etc/sync-service/env` (non-sensitive, managed in `vm-config` repo):**
```bash
SPRING_PROFILES_ACTIVE=qa
MONGODB_HOST=mongodb-qa.internal:27017
MONGODB_DATABASE=syncdb_qa
SERVER_PORT=8080
MANAGEMENT_PORT=8081
LOG_LEVEL=DEBUG
FEATURE_FLAG_NEW_SYNC=true
```

**`/etc/sync-service/` is managed in a separate `vm-config` repository**, versioned independently from application code. Config changes go through their own PR process and are applied to VMs before the new container starts.

### Environment Promotion

Config is **not promoted** between environments. Each environment has its own `/etc/sync-service/env` with values set deliberately. This prevents QA config from accidentally becoming prod config.

---

## 5. Secrets Handling

### Principle: Zero secrets on disk, in source code, or in Jenkins console output

### Tool: Google Secret Manager + VM Service Account (OS Login)

Each VM runs with a dedicated GCP service account that has `roles/secretmanager.secretAccessor` scoped only to that environment's secrets. At deploy time, `deploy.sh` SSHes into each VM and calls `fetch-secrets.sh` (running as root) **before** starting the container. Secrets are written to a **tmpfs-backed** file that is never written to persistent disk.

```
Jenkins deploy.sh SSHes into VM via IAP
  │
  ├── sudo /opt/sync-service/fetch-secrets.sh
  │       │
  │       ├── gcloud secrets versions access latest \
  │       │     --secret=sync-service-{env}-mongodb-password → /run/sync-service/secrets.env
  │       │
  │       └── /run/sync-service/ is a tmpfs mount (RAM only, cleared on reboot)
  │
  └── docker run --env-file /run/sync-service/secrets.env ...
          │
          └── Spring Boot reads MONGODB_PASSWORD from container environment
```

**`/opt/sync-service/fetch-secrets.sh`** (deployed once, owned by root, chmod 700):
```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /run/sync-service
chmod 700 /run/sync-service

# Pull each secret from Secret Manager (VM SA has secretAccessor role)
MONGODB_PASSWORD=$(gcloud secrets versions access latest \
  --secret="sync-service-${SPRING_PROFILES_ACTIVE}-mongodb-password" \
  --project="cloudeagle-prod")

MONGODB_USERNAME=$(gcloud secrets versions access latest \
  --secret="sync-service-${SPRING_PROFILES_ACTIVE}-mongodb-username" \
  --project="cloudeagle-prod")

EXTERNAL_API_KEY=$(gcloud secrets versions access latest \
  --secret="sync-service-${SPRING_PROFILES_ACTIVE}-external-api-key" \
  --project="cloudeagle-prod")

# Write to tmpfs — readable only by the sync user
printf 'MONGODB_PASSWORD=%s\nMONGODB_USERNAME=%s\nEXTERNAL_API_KEY=%s\n' \
  "${MONGODB_PASSWORD}" "${MONGODB_USERNAME}" "${EXTERNAL_API_KEY}" \
  > /run/sync-service/secrets.env

chown sync:sync /run/sync-service/secrets.env
chmod 400 /run/sync-service/secrets.env
```

### Secret Storage in Google Secret Manager

All secrets stored with naming convention:

```
projects/cloudeagle-prod/secrets/sync-service-{env}-{key}

Examples:
  sync-service-prod-mongodb-password
  sync-service-prod-mongodb-username
  sync-service-prod-external-api-key
  sync-service-staging-mongodb-password
  sync-service-qa-mongodb-password
```

### Jenkins Secrets

Jenkins itself uses the **Jenkins Credentials Store** (backed by GCP Secret Manager via the Jenkins Secret Manager plugin). The pipeline references credentials by ID (`credentials('sonarqube-token')`), never by value. Console output masks secret values automatically.

### Secret Rotation

- MongoDB passwords rotated every 90 days via a Cloud Scheduler → Cloud Function job
- API keys rotated when a team member leaves or on demand
- On rotation: new version created in Secret Manager; **next container restart automatically picks it up** via `fetch-secrets.sh` in `deploy.sh`
- For immediate propagation without a full deploy: SSH into the VM, run `sudo /opt/sync-service/fetch-secrets.sh`, then `docker restart sync-service`
- Zero downtime: old version remains valid in Secret Manager until explicitly disabled

---

## 6. Deployment Strategy

### Target: GCP Compute Engine VMs (Managed Instance Groups) — Docker containers

The service runs as a **Docker container** on GCP Compute Engine instances grouped into Managed Instance Groups (MIGs). The container image is built by Jenkins and stored in Google Container Registry (GCR). The full deployment flow is:

```
Jenkins
  │
  ├─ 1. Maven builds sync-service.jar
  │
  ├─ 2. Docker image built: gcr.io/cloudeagle-prod/sync-service:{sha}
  │       FROM eclipse-temurin:17-jre-alpine
  │       Non-root sync user (UID 1001), read-only rootfs
  │
  ├─ 3. Trivy scans the Docker image for OS package + dependency CVEs
  │       Fails the build on any unfixed HIGH or CRITICAL CVE
  │
  ├─ 4. Docker image pushed to GCR (immutable, SHA-tagged)
  │       gcr.io/cloudeagle-prod/sync-service:{sha}
  │       gcr.io/cloudeagle-prod/sync-service:{env}-latest  (floating convenience tag)
  │
  └─ 5. Jenkins SSHes into VMs via Cloud IAP tunnel (OS Login)
          VMs pull image from GCR → docker stop old container → docker run new container
```

**Why GCR as the image registry?**
- VMs pull the image using their own SA credentials via `gcloud auth configure-docker` (GCE metadata server) — Jenkins never transfers files directly to VMs
- Every release image is permanently addressable by an immutable commit SHA tag — rollback is `docker run` with the previous tag
- GCR vulnerability scanning can be enabled for an additional layer of registry-level CVE detection
- IAM-controlled access: only the Jenkins SA can push; VM SAs can only pull

### Production: Blue/Green (Two MIGs + Load Balancer backend switch)

**Why Blue/Green for production?**

| Criterion | Blue/Green | Rolling | Recreate |
|---|---|---|---|
| Downtime | Zero | Near-zero | ~1–5 min |
| Rollback speed | Instant (LB switch, < 5s) | All VMs one-by-one (mins) | Full redeploy |
| Extra resources | 2× VMs during deploy | ~1 extra VM | None |
| Mixed versions serving traffic | No | Yes (during rollout) | No |
| Suitable for | Production | Staging / QA | Dev / local |

Blue/green is preferred for production because:
- **Instant rollback**: one `gcloud compute backend-services update` flips traffic back — no container operations needed on any VM.
- **No mixed versions**: during a rolling update, old and new containers both serve traffic simultaneously, which can cause issues if MongoDB schema or API contract changed.
- **Pre-warmed and pre-tested**: the new MIG's containers are fully started and health-checked before a single user request reaches them.

**Mechanics on GCP VMs:**

```
         ┌────────────────────────────────────────────────────┐
         │  GCP HTTP(S) Load Balancer — backend service       │
         │  active backend: sync-service-prod-blue (MIG)      │
         └──────────────────────┬─────────────────────────────┘
                                │ 100% user traffic
              ┌─────────────────┴──────────────────┐
              │                                    │
  ┌───────────▼────────────┐        ┌──────────────▼──────────┐
  │  MIG: prod-blue        │        │  MIG: prod-green        │
  │  3× VMs running        │        │  3× VMs — idle / old    │
  │  image:v1.2.3          │        │  image:v1.2.2           │
  │  ACTIVE (live traffic) │        │  IDLE  (no traffic)     │
  └────────────────────────┘        └─────────────────────────┘

  Step 1: SSH into each green VM in parallel (IAP tunnel)
          → docker pull gcr.io/.../sync-service:v1.2.4
          → sudo /opt/sync-service/fetch-secrets.sh
          → docker stop --time=30 sync-service
          → docker rm sync-service
          → docker run -d --name sync-service --env-file … image:v1.2.4
  Step 2: Health-check all green VMs directly via SSH (zero traffic risk)
          → docker inspect .State.Status == "running"
          → /actuator/health UP?  /liveness 200?  /readiness 200?  MongoDB UP?
  Step 3: gcloud compute backend-services update → switch LB to green MIG  (< 5s)
  Step 4: Write active-slot.json to GCS (rollback metadata)
  Step 5: Blue MIG stays running for 24h — instant rollback available at any time
```

### Staging & QA: Rolling Update (same MIG, VM-by-VM)

- Update VMs **one at a time** within the single MIG
- On each VM: `docker pull` → `fetch-secrets.sh` → `docker stop` → `docker rm` → `docker run`
- Health-check each VM via SSH (`docker inspect` + actuator probes) **before** moving to the next one
- If a VM fails health check → re-deploy previous image tag on that VM immediately, abort the rest of the rollout
- No LB backend switch needed — the same MIG stays in service throughout

### Zero-Downtime Guarantees (Docker-specific)

1. **Graceful shutdown**: `docker stop --time=30` sends SIGTERM and waits 30 seconds. Spring Boot is configured with `server.shutdown=graceful` and `spring.lifecycle.timeout-per-shutdown-phase=30s` — in-flight requests drain before the JVM exits.
2. **LB connection draining**: The GCP backend service has `connectionDraining.drainingTimeoutSec=60` — the LB keeps sending responses for existing connections up to 60s after a VM is removed from rotation.
3. **Readiness gate before re-adding to LB**: VMs only re-enter the LB backend after `/actuator/health/readiness` returns HTTP 200 (GCP LB health check configured against this endpoint).
4. **Max unavailable cap**: MIG rolling update policy sets `maxUnavailable=1` and `maxSurge=1` — never more than one VM's container offline at a time.
5. **Docker HEALTHCHECK**: `part1-cicd/Dockerfile` defines a `HEALTHCHECK` against `/actuator/health`. The health-check script reports Docker health status and treats the Actuator readiness/liveness probes as the deployment gate.

---

## 7. Rollback Strategy

### Prod Rollback (Blue/Green — LB backend flip, < 5 seconds)

Rollback is a **Load Balancer backend swap**, not a re-deployment. The old MIG with the old Docker containers is already running with zero traffic:

```bash
# rollback.sh prod
# Reads active-slot.json from GCS, flips the LB backend to the previous MIG.
# No docker operations. No SSH required. Completes in < 5 seconds.
./scripts/rollback.sh prod
```

Internally:
```bash
gcloud compute backend-services update sync-service-backend-prod \
    --global \
    --backends="group=<previous-mig-url>,balancing-mode=UTILIZATION,capacity-scaler=1"
```

**Automated rollback**: If `health-check.sh prod` exits non-zero after the traffic switch, the Jenkins `post { failure }` block calls `rollback.sh prod` automatically before the stage exits.

**Manual rollback**: `scripts/rollback.sh prod` can be run from any machine that has `gcloud` credentials and `compute.backendServices.update` permission. No Jenkins build required.

### Non-Prod Rollback (Rolling — re-run previous Docker image tag via SSH)

```bash
# Roll back to the automatically saved previous image (reads from /etc/sync-service/previous-image-tag on each VM)
./scripts/rollback.sh qa

# Roll back to a specific image tag
./scripts/rollback.sh staging gcr.io/cloudeagle-prod/sync-service:abc1234
```

`deploy.sh` writes the previous active image tag to `/etc/sync-service/previous-image-tag` on each VM before replacing it, giving a guaranteed one-step rollback target. Rollback is `docker stop` → `docker rm` → `docker run` with the previous tag (already cached locally on the VM from the last deploy).

### Rollback Decision Tree

```
Deployment completes
        │
        ▼
health-check.sh passes?
    ├─ Yes → Deployment verified.
    │         Prod:     old MIG stays running for 24h (instant rollback window)
    │         Non-prod: previous image tag preserved on VM (/etc/sync-service/previous-image-tag)
    │
    └─ No  → Automated rollback triggered
              │
              ├─ Prod:     LB backend flipped back to old MIG (< 5s, no docker ops)
              │
              └─ Non-prod: previous Docker image re-run via SSH on all VMs (< 2 min)
                           │
                           ▼
                     health-check.sh passes again?
                         ├─ Yes → Slack alert: "Rollback succeeded — investigate root cause"
                         └─ No  → PagerDuty P1 alert + on-call escalation
```

### Image Retention Policy (GCR)

| Tag / label | Retention | Purpose |
|---|---|---|
| `gcr.io/.../sync-service:<sha>` (prod) | 90 days | Immutable prod images, audit trail |
| `gcr.io/.../sync-service:<sha>` (staging) | 30 days | Staging images |
| `gcr.io/.../sync-service:<sha>` (qa) | 7 days | QA images — short-lived |
| `gcr.io/.../sync-service:{env}-latest` | Always (floating) | Points to most recent push for that environment |
| `gs://.../prod/active-slot.json` | Always (overwritten on each deploy) | Current blue/green MIG state |

GCR lifecycle policies (configured via `gcloud container images`) automatically delete untagged digests older than 7 days and purge QA/staging tags past their retention window.

---

## 8. Security Considerations

### SSH Access — Zero Static Keys

- All VM SSH access goes through **Cloud IAP tunnel** (`gcloud compute ssh --tunnel-through-iap`)
- VMs have **no public IP** — unreachable from the internet directly
- Jenkins authenticates via **OS Login** (`roles/compute.osAdminLogin` on the Jenkins SA) — GCP generates ephemeral SSH certificates valid for 10 minutes, no long-lived SSH keys distributed anywhere
- Developers get `roles/compute.osLogin` (non-admin) on QA/staging only — scoped by IAM condition

### Docker Container Hardening

Every container started by `deploy.sh` (and the production `part1-cicd/Dockerfile`) enforces the following:

| Flag | Effect |
|---|---|
| `--read-only` | Container root filesystem is read-only — an attacker cannot write malware to the container filesystem |
| `--tmpfs /tmp:rw,noexec,nosuid,size=256m` | Grants a small writable RAM-backed `/tmp`; `noexec` prevents executing binaries from it |
| `--security-opt=no-new-privileges:true` | Prevents `setuid`/`setgid` escalation — the JVM process cannot gain additional privileges |
| `--memory=2g --memory-swap=2g` | Hard memory ceiling — prevents a memory leak from starving other processes or escaping the container |
| `--cpus=2` | CPU cap — prevents runaway threads from consuming all cores |
| `USER sync` (Dockerfile) | Container process runs as non-root `sync` user (UID 1001) — OS-level privilege boundary |
| `--restart unless-stopped` | Container auto-restarts on crash or VM reboot — no manual intervention needed |

### VM Hardening

- The `sync` user inside the container is UID 1001 — same UID is created on the host VM, owning the log volume mount (`/var/log/sync-service`)
- `/opt/sync-service/fetch-secrets.sh` is owned by `root`, `chmod 700` — the `sync` user cannot read or modify it
- Secrets file at `/run/sync-service/secrets.env` lives in **tmpfs** (RAM) — not written to any disk, cleared on reboot, readable only by `sync` user (`chmod 400`)
- OS login audit logs (who SSHed in, when, from where) sent to Cloud Logging automatically

### Network Security

- VMs sit in a **private VPC subnet** with no ingress from the internet
- Only the GCP Load Balancer health check IPs (`35.191.0.0/16`, `130.211.0.0/22`) can reach port 8080
- Port 8081 (actuator/management) is blocked at the VPC firewall — accessible only from within the VPC via IAP SSH
- MongoDB connection goes over the private VPC to Atlas via Private Service Connect — never traverses the public internet

### Artifact Integrity (Docker images in GCR)

- GCR repository has **IAM-only access** — only the Jenkins SA (`roles/storage.objectAdmin` on the GCR bucket) can push; VM SAs have `roles/storage.objectViewer`
- Images are deployed by **immutable commit SHA tag** (`:<sha>`) in `deploy.sh` — floating `*-latest` tags are never used for deployment
- **Trivy image scan** in the pipeline fails on any unfixed HIGH or CRITICAL CVE before the image is pushed to GCR
- GCR Container Analysis can be enabled for continuous post-push scanning of stored images

### Audit Trail

- Production deployments write structured rollback metadata to GCS (`active-slot.json`) with active/previous MIG, current/previous image tag, build number, approver, change ticket, and timestamp
- Jenkins build history, archived scan reports, Slack notifications, and GCS rollback metadata together provide the deployment audit trail
- For stricter compliance, the same JSON event can be mirrored to Cloud Logging with a 7-year-retention audit bucket

---

## Appendix: Environment Variables Reference

| Variable | Source in container | Description |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `--env-file /etc/sync-service/env` | Active Spring profile |
| `MONGODB_HOST` | `--env-file /etc/sync-service/env` | MongoDB connection host |
| `MONGODB_DATABASE` | `--env-file /etc/sync-service/env` | Target database name |
| `SERVER_PORT` | `--env-file /etc/sync-service/env` | HTTP server port (default: 8080) |
| `MANAGEMENT_PORT` | `--env-file /etc/sync-service/env` | Actuator port (default: 8081) |
| `LOG_LEVEL` | `--env-file /etc/sync-service/env` | Root log level |
| `FEATURE_FLAG_*` | `--env-file /etc/sync-service/env` | Feature flags |
| `MONGODB_PASSWORD` | `--env-file /run/sync-service/secrets.env` (tmpfs) | MongoDB auth password — from Secret Manager |
| `MONGODB_USERNAME` | `--env-file /run/sync-service/secrets.env` (tmpfs) | MongoDB auth username — from Secret Manager |
| `EXTERNAL_API_KEY` | `--env-file /run/sync-service/secrets.env` (tmpfs) | Third-party API key — from Secret Manager |

## Appendix: Docker Image Naming Convention

```
Registry  : gcr.io
Project   : cloudeagle-prod
Repo      : sync-service

Full tag  : gcr.io/cloudeagle-prod/sync-service:<tag>

Tag formats:
  <sha>              → gcr.io/cloudeagle-prod/sync-service:a1b2c3d4       (deployed to QA/staging/prod)
  pr-<n>-<sha>       → gcr.io/cloudeagle-prod/sync-service:pr-42-a1b2c3d4 (built locally for PRs — never pushed)
  <env>-latest       → gcr.io/cloudeagle-prod/sync-service:prod-latest     (floating convenience tag)
```

Images are **always deployed by SHA tag**, never by `*-latest`, to guarantee that what was tested is exactly what runs in production.
