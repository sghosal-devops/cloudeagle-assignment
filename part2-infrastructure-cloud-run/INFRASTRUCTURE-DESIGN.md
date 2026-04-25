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
VPC: sync-vpc
  ├── serverless-connector-subnet
  │     └── Serverless VPC Access connector
  │
  ├── private-services-subnet
  │     └── Private Service Connect endpoint to MongoDB Atlas
  │
  └── management subnet
        └── optional bastion/admin tooling
```

### Ingress

For production:

- Cloud Run receives HTTPS traffic through a custom domain.
- Cloud Run's managed HTTPS endpoint handles TLS.
- If WAF/rate limiting is required, place an External HTTPS Load Balancer with Cloud Armor in front of Cloud Run using a serverless NEG.

Recommended ingress policy:

| Environment | Ingress |
|---|---|
| QA | Internal or restricted access |
| Staging | Restricted by IAM or Cloud Armor allowlist |
| Prod | Public HTTPS through Cloud Run or Load Balancer + Cloud Armor |

### Egress to MongoDB

Cloud Run uses a **Serverless VPC Access connector** to reach private resources in the VPC. MongoDB Atlas is exposed through **Private Service Connect**, so database traffic stays private and does not traverse the public internet.

Egress settings:

- Route private ranges through the VPC connector.
- Use Cloud NAT only if the service needs controlled outbound internet access to external APIs.
- Keep MongoDB allowlists restricted to private endpoint connectivity, not broad public IPs.

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

Cloud Run deployment creates a new immutable revision for every image.

For QA/staging:

- Deploy new revision.
- Send 100% traffic after health checks or smoke tests.
- Roll back by shifting traffic back to the previous revision.

For production:

- Deploy a new revision with **0% traffic**.
- Run smoke tests against the tagged revision URL.
- If healthy, shift traffic gradually:
  - 10% canary
  - 50%
  - 100%
- Roll back instantly by sending traffic back to the previous revision.

This gives blue/green or canary-style behavior without maintaining two VM groups or a Kubernetes cluster.

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

## 9. When To Move To GKE Later

Cloud Run should be the starting architecture. Move to **GKE Autopilot** later if:

- There are many services with shared platform needs.
- The service has always-on workers that make scale-to-zero irrelevant.
- Advanced traffic control, sidecars, or service mesh are required.
- The team needs Kubernetes-native policies/controllers.
- In-cluster Prometheus/Grafana becomes a hard requirement.

This path avoids premature Kubernetes complexity while keeping the architecture portable because the app is already containerized.

