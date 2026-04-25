CloudEagle - DevOps Assignment
Part 1 – Deployment & CI/CD Design
Scenario
We have a Spring Boot backend service (sync-service) that:
Connects to MongoDB
Is deployed to GCP VMs
Has environments: qa, staging, prod
Is built via Jenkins
Your Task
Design a CI/CD pipeline for this service.
You should cover:
Branching strategy
How do branches map to environments?
How do you avoid accidental prod deployments?


Jenkins pipeline
High-level pipeline stages
What happens on PR vs merge?
Rollback strategy if deployment fails


Configuration management
How do you manage env-specific configs?
Secrets handling (MongoDB creds, API keys)


Deployment strategy
Blue/Green vs Rolling vs Recreate (justify)
Zero/minimal downtime approach


📄 Deliverable - Share a Github project with the following
A short design document (Markdown or PDF)
Jenkinsfile


Part 2 – Infrastructure Design
Scenario
We want to run this service on GCP with:
Auto-scaling
Secure access
Reasonable cost (startup constraints)


Your Task
Propose an infrastructure setup.
You should touch on:
Compute choice (GKE / Compute Engine / Cloud Run — justify)
MongoDB hosting approach
Networking basics (VPC, ingress)
Secrets & IAM
Logging & monitoring stack


📄 Deliverable - Share a Github project with the following
Architecture diagram 
Written explanation of key choices

