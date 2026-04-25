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

## Deployment Flow

```mermaid
sequenceDiagram
    participant Jenkins
    participant AR as Artifact Registry
    participant CR as Cloud Run
    participant NewRev as New Revision
    participant OldRev as Previous Revision
    participant Atlas as MongoDB Atlas

    Jenkins->>AR: Push image sync-service:<sha>
    Jenkins->>CR: Deploy new revision with 0% traffic
    CR->>NewRev: Start revision
    NewRev->>Atlas: Verify MongoDB connectivity through PSC
    Jenkins->>NewRev: Smoke test tagged revision URL

    alt Smoke tests pass
        Jenkins->>CR: Shift 10% traffic to new revision
        Jenkins->>CR: Shift 50% traffic
        Jenkins->>CR: Shift 100% traffic
        CR-->>NewRev: New revision active
    else Smoke tests fail
        Jenkins->>CR: Keep 100% traffic on previous revision
        CR-->>OldRev: No user traffic sent to failed revision
    end

    alt Post-deploy health fails
        Jenkins->>CR: Roll back traffic to previous revision
    end
```
