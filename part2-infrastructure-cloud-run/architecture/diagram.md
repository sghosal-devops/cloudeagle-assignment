# Architecture Diagram — Cloud Run Option

## Rendered Diagram

Open this SVG in a browser or embed it in the README:

[sync-service-cloud-run-architecture.svg](sync-service-cloud-run-architecture.svg)

```mermaid
graph TB
    subgraph USERS["Users / API Clients"]
        CLIENT[Client Applications]
    end

    subgraph GCP["GCP Project"]
        subgraph EDGE["Ingress"]
            DOMAIN[Custom Domain / HTTPS]
            ARMOR[Cloud Armor<br/>optional WAF + rate limit]
            LB[External HTTPS Load Balancer<br/>optional for WAF/serverless NEG]
        end

        subgraph RUN["Cloud Run"]
            SERVICE[sync-service<br/>containerized Spring Boot API]
            REV1[Revision N<br/>active traffic]
            REV2[Revision N+1<br/>canary / rollback candidate]
        end

        subgraph VPC["sync-vpc"]
            CONNECTOR[Serverless VPC Access Connector]
            PSC[Private Service Connect Endpoint]
            NAT[Cloud NAT<br/>optional controlled egress]
        end

        subgraph SECRETS["Secrets & IAM"]
            SM[Google Secret Manager]
            SA[Cloud Run Service Account<br/>least privilege]
        end

        subgraph ARTIFACTS["Build Artifacts"]
            AR[Artifact Registry<br/>sync-service images]
        end

        subgraph OBS["Observability"]
            LOG[Cloud Logging]
            MON[Cloud Monitoring]
            TRACE[Cloud Trace / Error Reporting]
            ALERT[Alerting<br/>Slack / PagerDuty]
        end
    end

    subgraph ATLAS["MongoDB Atlas on GCP"]
        MONGO[(MongoDB Replica Set<br/>private endpoint)]
    end

    CLIENT --> DOMAIN
    DOMAIN --> ARMOR
    ARMOR --> LB
    LB --> SERVICE

    SERVICE --> REV1
    SERVICE -.canary traffic.-> REV2

    SERVICE -->|pull image at deploy| AR
    SERVICE -->|runtime identity| SA
    SA -->|read secrets| SM
    SERVICE -->|private egress| CONNECTOR
    CONNECTOR --> PSC
    PSC --> MONGO
    CONNECTOR --> NAT

    SERVICE --> LOG
    SERVICE --> MON
    SERVICE --> TRACE
    MON --> ALERT
```

## Full CI/CD → Cloud Run Deployment Flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant Jenkins
    participant SQ as SonarQube
    participant Trivy
    participant AR as GCR / Artifact Registry
    participant CR as Cloud Run
    participant NewRev as New Revision
    participant OldRev as Previous Revision
    participant Atlas as MongoDB Atlas (PSC)
    participant Slack

    Dev->>GH: git push → PR opened
    GH->>Jenkins: webhook → Jenkinsfile.pr
    Jenkins->>Jenkins: mvn clean package
    par parallel
        Jenkins->>Jenkins: mvn test (unit tests + JaCoCo)
    and
        Jenkins->>SQ: mvn sonar:sonar (PR decoration)
    and
        Jenkins->>Jenkins: OWASP dependency-check
    end
    Jenkins->>Jenkins: docker build (local only — not pushed)
    Jenkins->>Trivy: trivy image (HIGH/CRITICAL CVE scan)
    Trivy-->>Jenkins: SARIF report
    Jenkins->>GH: post check status (pass/fail)

    Dev->>GH: PR approved → merge to main
    GH->>Jenkins: webhook → Jenkinsfile
    Jenkins->>Jenkins: mvn clean package -DskipTests
    Jenkins->>Jenkins: mvn test + sonar + owasp (parallel)
    Jenkins->>SQ: waitForQualityGate
    Jenkins->>Jenkins: docker build → gcr.io/.../sync-service:<sha>
    Jenkins->>Trivy: trivy image scan (fail pipeline on CVE)
    Jenkins->>AR: docker push gcr.io/.../sync-service:<sha>

    Note over Jenkins: Manual approval gate (release-managers + change ticket)

    Jenkins->>CR: gcloud run deploy --no-traffic --tag=candidate
    CR->>NewRev: Start new revision (0% traffic)
    NewRev->>Atlas: MongoDB connectivity check via PSC
    Jenkins->>NewRev: curl smoke test on tagged revision URL
    NewRev-->>Jenkins: HTTP 200 + status=UP

    Jenkins->>CR: update-traffic --to-revisions=NEW=10,OLD=90
    Jenkins->>CR: update-traffic --to-revisions=NEW=50,OLD=50
    Jenkins->>CR: update-traffic --to-latest (100%)
    CR-->>NewRev: New revision serves all traffic
    Jenkins->>Slack: Deployment complete notification

    alt Any step fails
        Jenkins->>CR: update-traffic --to-revisions=OLD=100
        CR-->>OldRev: Full rollback in <2 seconds
        Jenkins->>Slack: Rollback alert with failure details
    end
```

## Secrets Injection Flow

```mermaid
graph LR
    SM[Google Secret Manager<br/>sync-service-prod-mongodb-password]
    SA[Cloud Run Service Account<br/>sync-service-prod@...]
    CR[Cloud Run revision<br/>sync-service]
    APP[Spring Boot app<br/>reads MONGODB_PASSWORD<br/>from env]

    SA -->|roles/secretmanager.secretAccessor| SM
    SM -->|injected as env var at revision start| CR
    CR --> APP
```
