# Infrastructure Design — sync-service on GCP Cloud Run

## 1. Executive Summary

For a startup-constrained setup, I would run `sync-service` on **Cloud Run** instead of starting with GKE. The assignment does not mention an existing Kubernetes platform, multiple services, service mesh, or Kubernetes-specific requirements. Cloud Run gives the best starting point for:

- **Auto-scaling**: scales from zero to many instances automatically.
- **Secure access**: HTTPS ingress, IAM, Secret Manager, private egress through VPC connector.
- **Reasonable cost**: pay-per-use with no always-on cluster/node cost.
- **Low operations overhead**: no node patching, cluster upgrades, or VM maintenance.

The proposed setup is:

```
Cloud Run service
  + MongoDB Atlas on GCP
  + Serverless VPC Access connector
  + Private Service Connect to Atlas
  + Secret Manager
  + Artifact Registry
  + Cloud Logging / Monitoring / Error Reporting
```

This keeps the initial platform simple while still leaving a path to GKE Autopilot later if the product grows into multiple always-on services or needs Kubernetes-native controls.

---

## 2. Compute Choice

### Selected: Cloud Run

`sync-service` is a Spring Boot backend service packaged as a container. With the information given, there is no reason to assume it needs a Kubernetes cluster. Cloud Run is a better first choice for a startup because it removes most infrastructure management and charges based on actual usage.

| Option | Fit | Reasoning |
|---|---|---|
| **Cloud Run** | Best initial choice | Serverless containers, autoscaling, scale-to-zero, HTTPS ingress, IAM integration, lowest ops overhead |
| **GKE Autopilot** | Future option | Good for many services, sidecars, service mesh, complex rollout controls, or always-on workloads |
| **Compute Engine MIG** | Not ideal for new infra | Works, but requires VM patching, autoscaler tuning, image/runtime management, and more operational work |

### Cloud Run Configuration

| Setting | Recommendation |
|---|---|
| Runtime | Containerized Spring Boot app |
| Region | Same GCP region as MongoDB Atlas, e.g. `us-central1` |
| Min instances | `0` for QA/staging, `1` for prod if cold starts are unacceptable |
| Max instances | Start with `20`, tune based on load |
| CPU / memory | Start with `1 vCPU / 1-2 GiB`, tune using metrics |
| Concurrency | Start with `40-80` requests per instance, tune based on latency |
| CPU allocation | CPU during request processing; use always-allocated CPU only if background work is required |
| Autoscaling | Native Cloud Run autoscaling based on request load |

### Cold Start Consideration

Spring Boot has a non-trivial JVM startup time (typically 10–30 seconds). On Cloud Run with `min_instances=0`, the first request after a period of inactivity hits a cold start. Mitigations:

- Set `min_instances=1` in production if cold starts are unacceptable (small fixed cost, eliminates the problem).
- Add JVM flags `-XX:TieredStopAtLevel=1` to reduce startup time by ~30–40% at the cost of peak throughput — acceptable for a startup at low traffic volumes.
- The startup probe (`failure_threshold=30`, `period_seconds=10`) gives the JVM 300 seconds to become healthy before Cloud Run marks the revision as failed.
- For QA/staging, cold starts are acceptable — `min_instances=0` keeps cost at zero when idle.

If `sync-service` has scheduled/background sync jobs, I would split them from the HTTP API:

- Cloud Run service for HTTP/API traffic.
- Cloud Run Jobs or Cloud Scheduler-triggered Cloud Run endpoint for periodic sync work.
- Pub/Sub for asynchronous work if jobs need buffering/retry.

This avoids keeping a full GKE cluster running just for scheduled tasks.

---

## 3. MongoDB Hosting

### Selected: MongoDB Atlas on GCP

MongoDB should be hosted on **MongoDB Atlas in the same GCP region** as Cloud Run. This avoids managing MongoDB backups, replication, patching, and failover manually.

| Environment | Atlas Tier | Notes |
|---|---|---|
| QA | M0/M2/M5 or M10 | Use the cheapest tier that supports required networking/testing |
| Staging | M10/M20 | Close enough to prod for performance validation |
| Production | M30 or higher | 3-node replica set, backups, storage autoscaling |

### Why Atlas

- Managed replica set and failover.
- Automated backups and point-in-time recovery.
- Native MongoDB compatibility.
- Private connectivity support with GCP Private Service Connect.
- Lower operational burden than self-managed MongoDB on VMs.

For strict cost control in early QA environments, a small shared Atlas tier can be used. Production should use a dedicated replica set with backups enabled.

---

## 4. Networking

### VPC Layout

```
VPC: sync-vpc  (10.0.0.0/16)
  │
  ├── serverless-connector-subnet  10.0.1.0/28
  │     └── Serverless VPC Access connector  (e2-micro, min 2 / max 10 instances)
  │           └── Cloud Run egress → this connector → private VPC resources
  │
  ├── private-services-subnet  10.0.2.0/24
  │     └── Private Service Connect endpoint for MongoDB Atlas
  │           └── atlas.internal → 10.0.2.10  (Cloud DNS private zone)
  │
  └── management-subnet  10.0.3.0/28
        └── Cloud NAT gateway  (controlled egress to external APIs)
```

### Ingress

| Environment | Ingress config | Restriction |
|---|---|---|
| QA | Cloud Run managed HTTPS | IAM: `run.invoker` on QA service account only — no public access |
| Staging | Cloud Run managed HTTPS | Cloud Armor allowlist: office IP + CI agent IP only |
| Production | External HTTPS LB + Cloud Armor + serverless NEG | Public HTTPS with WAF, rate limit 500 req/min/IP |

**Production ingress path:**
```
Client → Cloud Armor (WAF + rate limit) → External HTTPS Load Balancer
       → Serverless NEG → Cloud Run revision (managed TLS terminates at LB)
```

A **Serverless Network Endpoint Group (NEG)** is the GCP component that connects the External HTTPS Load Balancer to a Cloud Run service. It is a lightweight pointer — no VMs or persistent infrastructure — that lets Cloud Armor and the LB front any Cloud Run revision. Without it, Cloud Run's built-in managed HTTPS is used directly (sufficient for QA/staging); the Serverless NEG + LB layer is added for production to enable Cloud Armor WAF rules and rate limiting.

Cloud Armor rules applied to production:
- OWASP Core Rule Set (managed rule group)
- Rate limit: 500 requests/minute per source IP
- Block known malicious IP lists (Google Threat Intelligence feed)

### Firewall Rules

| Rule name | Direction | Source | Target | Ports | Purpose |
|---|---|---|---|---|---|
| `allow-connector-to-atlas` | Egress | VPC connector subnet | PSC endpoint | 27017/TCP | MongoDB traffic |
| `allow-connector-to-nat` | Egress | VPC connector subnet | Cloud NAT | 443/TCP | External API calls |
| `deny-all-egress` | Egress | All | All | All | Default deny; above rules are exceptions |
| `allow-health-checks` | Ingress | 35.191.0.0/16, 130.211.0.0/22 | LB backend | 8080/TCP | GCP LB health checks |

### Egress to MongoDB

Cloud Run uses the **Serverless VPC Access connector** to reach the private VPC. MongoDB Atlas is exposed via **Private Service Connect** — a private endpoint in `10.0.2.0/24` that maps to the Atlas cluster. A Cloud DNS private zone resolves `atlas.internal` to `10.0.2.10` inside the VPC. Database traffic never leaves Google's network.

---

## 5. Secrets & IAM

### Secret Storage

All sensitive values live in **Google Secret Manager**:

```
sync-service-prod-mongodb-uri
sync-service-prod-mongodb-username
sync-service-prod-mongodb-password
sync-service-prod-external-api-key
sync-service-staging-mongodb-uri
sync-service-qa-mongodb-uri
```

Cloud Run injects secrets as environment variables or mounted secret volumes. The application reads them at startup using standard Spring Boot configuration.

### Service Accounts

Use separate service accounts per environment:

| Principal | Permissions |
|---|---|
| `sync-service-qa` | Read QA secrets, write logs/metrics |
| `sync-service-staging` | Read staging secrets, write logs/metrics |
| `sync-service-prod` | Read prod secrets only, write logs/metrics |
| `jenkins-deployer` | Deploy Cloud Run revisions, push images to Artifact Registry |
| Developers | Read-only access to QA/staging logs and service metadata |
| Release managers | Permission to approve and deploy prod |

### Least Privilege

- No service account keys.
- Use IAM bindings, not downloaded JSON credentials.
- Cloud Run runtime service account can read only its environment's secrets.
- Jenkins deployer can deploy revisions but should not read production MongoDB passwords unless required.
- Prod deploy permissions should be restricted to CI and release managers.

---

## 6. Deployment & Autoscaling Model

### Connection to Part 1 CI/CD Pipeline

The same Jenkins pipeline from Part 1 builds and pushes the Docker image. The only difference for Cloud Run is the **deploy step**: instead of `deploy.sh` (which SSHes into VMs), the pipeline calls `gcloud run deploy`. The image is identical — no rebuild.

```
Jenkins (Part 1 pipeline)
  │
  ├── mvn clean package
  ├── docker build → gcr.io/cloudeagle-prod/sync-service:<sha>
  ├── trivy image scan (fail on HIGH/CRITICAL CVE)
  ├── docker push gcr.io/cloudeagle-prod/sync-service:<sha>
  │
  └── Deploy to Cloud Run:
        gcloud run deploy sync-service \
          --image=gcr.io/cloudeagle-prod/sync-service:<sha> \
          --region=us-central1 \
          --service-account=sync-service-prod@cloudeagle-prod.iam.gserviceaccount.com \
          --no-traffic \          ← new revision starts with 0% user traffic
          --tag=candidate \       ← gives a stable URL for smoke testing
          --project=cloudeagle-prod
```

### Deployment Flow per Environment

**QA / Staging** — shift 100% traffic immediately after smoke test:

```bash
# 1. Deploy new revision (no traffic)
gcloud run deploy sync-service \
  --image=gcr.io/cloudeagle-prod/sync-service:<sha> \
  --region=us-central1 --no-traffic --tag=candidate

# 2. Smoke test against the tagged revision URL
curl -sf "$(gcloud run services describe sync-service \
  --region=us-central1 --format='value(status.address.url)')-candidate/actuator/health" \
  | grep -q '"status":"UP"'

# 3. Shift all traffic
gcloud run services update-traffic sync-service \
  --region=us-central1 --to-latest
```

**Production** — gradual canary shift with rollback at each step:

```bash
# Step 1: 10% canary
gcloud run services update-traffic sync-service \
  --region=us-central1 \
  --to-revisions=LATEST=10,PREVIOUS=90

# Step 2: 50%
gcloud run services update-traffic sync-service \
  --region=us-central1 \
  --to-revisions=LATEST=50,PREVIOUS=50

# Step 3: 100% (full cutover)
gcloud run services update-traffic sync-service \
  --region=us-central1 --to-latest
```

**Rollback** (any stage — completes in < 2 seconds):

```bash
gcloud run services update-traffic sync-service \
  --region=us-central1 \
  --to-revisions=<previous-revision>=100
```

Cloud Run keeps all previous revisions available indefinitely (or until manually deleted). Rollback requires no image rebuilding — it just updates a traffic split record.

### Why this is better than VM blue/green for a startup

| Aspect | VM Blue/Green (Part 1) | Cloud Run Canary |
|---|---|---|
| Idle resource cost | Second MIG running at all times | Zero — Cloud Run scales to 0 |
| Rollback time | <5s (LB backend flip) | <2s (traffic split update) |
| Mixed-version window | No (atomic switch) | Yes, intentionally (canary) |
| Infrastructure to manage | MIG, LB backend, active-slot.json | Nothing — fully managed |

For a startup, Cloud Run canary is a strict improvement: instant rollback with no always-on idle resources.

---

## 7. Logging & Monitoring

### Logging

Cloud Run automatically sends stdout/stderr to **Cloud Logging**. The Spring Boot app should emit structured JSON logs with:

- `traceId`
- `spanId`
- `environment`
- `requestId`
- `userId` if safe and non-sensitive
- latency and status fields

Retention:

| Log Type | Retention |
|---|---|
| QA/staging app logs | 14-30 days |
| Prod app logs | 30-90 days |
| Audit/security logs | 1-7 years depending on compliance needs |

### Monitoring

Use **Cloud Monitoring** for:

- Request count
- 4xx/5xx error rate
- p50/p95/p99 latency
- Instance count
- Container CPU and memory
- Cold starts
- MongoDB connectivity errors

Application metrics can be exposed through Spring Boot Actuator and exported with OpenTelemetry or Micrometer.

### Alerting

| Alert | Condition | Severity |
|---|---|---|
| High 5xx rate | > 1% for 5 minutes | P1 |
| High latency | p95 > 2s for 5 minutes | P2 |
| MongoDB unavailable | Health check fails for 1 minute | P1 |
| Cloud Run revision failing | New revision returns elevated 5xx | P1 |
| Max instances reached | Service hits max instance count for 10 minutes | P3 |
| Secret access denied | Runtime cannot read Secret Manager values | P1 |

Notifications go to Slack for P2/P3 and PagerDuty for P1.

---

## 8. Cost Controls

Cloud Run is cost-effective for startup workloads because it can scale to zero and has no cluster control-plane or node capacity to manage.

Cost controls:

- Set QA/staging min instances to `0`.
- Keep prod min instances at `0` initially, or `1` only if cold starts are unacceptable.
- Set max instances to prevent runaway cost.
- Use committed use discounts later only after traffic stabilizes.
- Use small Atlas tiers for QA/staging.
- Set log retention intentionally to avoid unnecessary logging cost.
- Use Artifact Registry cleanup policies for old images.

Approximate early-stage monthly profile:

| Component | Cost Shape |
|---|---|
| Cloud Run | Low/variable; pay-per-use |
| MongoDB Atlas | Main fixed cost |
| Secret Manager | Very low |
| Cloud Logging/Monitoring | Low if retention and volume are controlled |
| VPC connector / NAT / LB | Add only where needed |

The main fixed cost is MongoDB Atlas. Compute stays small until traffic grows.

---

## 9. Infrastructure as Code

All Cloud Run resources are fully manageable via Terraform using the `google_cloud_run_v2_service` resource. Key resources to provision:

```hcl
# Cloud Run service
resource "google_cloud_run_v2_service" "sync_service" {
  name     = "sync-service"
  location = var.region
  project  = var.project_id

  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.app.email

    scaling {
      min_instance_count = var.environment == "prod" ? 1 : 0
      max_instance_count = 20
    }

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.app_container_image   # Set by Jenkins on each deploy

      resources {
        limits   = { cpu = "1", memory = "2Gi" }
        cpu_idle = true                 # CPU only allocated during request handling
      }

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = var.environment
      }

      env {
        name = "MONGODB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.mongodb_password.secret_id
            version = "latest"
          }
        }
      }

      liveness_probe {
        http_get { path = "/actuator/health/liveness" }
        initial_delay_seconds = 30
        period_seconds        = 10
      }

      startup_probe {
        http_get { path = "/actuator/health/liveness" }
        failure_threshold = 30
        period_seconds    = 10
      }
    }
  }
}
```

IAM, VPC connector, Private Service Connect endpoint, and Cloud Armor policy are all expressed in Terraform alongside the service, giving full reproducibility across environments.

---

## 10. When To Migrate To GKE Autopilot

Cloud Run should be the starting architecture. Move to **GKE Autopilot** later if:

- There are many services with shared platform needs.
- The service has always-on workers that make scale-to-zero irrelevant.
- Advanced traffic control, sidecars, or service mesh are required.
- The team needs Kubernetes-native policies/controllers.
- In-cluster Prometheus/Grafana becomes a hard requirement.

This path avoids premature Kubernetes complexity while keeping the architecture portable because the app is already containerized.

