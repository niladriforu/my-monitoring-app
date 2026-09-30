# AM on AWS — Architecture

Data stores, API catalog, and authentication are specified in [BACKEND-SERVICES.md](BACKEND-SERVICES.md). That document replaces the RDS path below for aggregates (Databricks) and transactions (DynamoDB).

## Context
Existing: Java Spring Boot + React on internal Kubernetes. Target: AWS, keep React, Python backend, banking-grade security. Load is small (~100 users/day), so the design favors **managed, serverless-style services and low operations** over Kubernetes/EKS.

## Recommended design

```
Users ─► CloudFront (+ security headers, TLS1.2+) ─► S3 (private, KMS)      React SPA
   │
   └─ Cognito (MFA, groups, SAML/OIDC to corporate IdP) ─► JWT
   │
   └─► AWS WAF ─► ALB (TLS1.3) ─► ECS Fargate ×2 (private subnets, FastAPI)
                                       │
                                       ├─► RDS PostgreSQL Multi-AZ (private, KMS, IAM auth)
                                       └─► Secrets Manager / KMS
Event sources ─► SQS / Kinesis / MSK ─► ingest worker (Fargate) ─► RDS
```

### Why these choices
| Decision | Rationale |
|---|---|
| FastAPI on ECS Fargate | No cluster to patch; 2 tasks across 2 AZs is plenty for 100 users/day. Can drop to Lambda later if traffic is spiky. EKS is over-scoped here. |
| RDS PostgreSQL Multi-AZ | Relational, auditable, encrypted, PITR backups (14 days). Add Aurora only if scale demands. |
| Cognito | Managed auth with mandatory MFA and groups mapped to RBAC roles. Federate with the bank's existing IdP if there is one. |
| CloudFront + private S3 | Static hosting with no public bucket; OAC restricts access to the distribution. |
| WAF | Managed rules (OWASP-style, SQLi, bad inputs) + IP rate limit. |

## Security controls (banking)
- **Network**: app and DB in private subnets, security-group chain ALB → API → DB, no public DB, VPC flow logs. Add VPC endpoints (S3, ECR, Secrets Manager, Logs) to remove NAT dependency if policy requires.
- **Data**: KMS customer-managed key (rotation on) for RDS, S3, logs, secrets; TLS in transit everywhere; account numbers masked in API responses (`mask()`); consider tokenization or field-level encryption for full PANs / account numbers.
- **Identity & access**: short-lived tokens (15 min), RBAC in the API (`viewer`/`analyst`/`admin`), least-privilege task role, no long-lived keys, DB master password managed and rotated by Secrets Manager.
- **Audit & detection**: CloudTrail (multi-region, log validation), request audit log with request IDs, CloudWatch retention 400 days; enable GuardDuty, Security Hub, AWS Config, Inspector (ECR scanning) at account level.
- **Application hardening**: strict CORS, security headers, docs disabled in prod, container runs as non-root with read-only filesystem, dependency pinning.
- **Resilience**: Multi-AZ, deployment circuit breaker with rollback, RDS deletion protection, backups; add cross-region backup copy if the bank's RTO/RPO requires.
- **Compliance**: map to your regime (PCI-DSS, SOX, GDPR, local regulator). Use AWS Organizations with a dedicated prod account and SCPs.

## Migration plan (Spring Boot → Python)
1. Inventory Spring endpoints and DB schema; freeze the API contract (OpenAPI).
2. Rebuild endpoints in FastAPI, contract-test against the old service using the same React client.
3. Migrate data with AWS DMS (or dump/restore) into RDS; validate with reconciliation queries.
4. Run both in parallel (shadow traffic), then cut over DNS. Keep rollback for one release.

## Cost note
Roughly: 2 small Fargate tasks + t4g.medium Multi-AZ RDS + ALB + NAT + WAF is on the order of a few hundred USD/month; NAT and Multi-AZ RDS are the biggest levers. Verify with the AWS Pricing Calculator.

## Alternatives considered
- **Lambda + API Gateway**: cheaper at very low volume, but cold starts and streaming/websocket needs make Fargate simpler for a live dashboard.
- **EKS**: matches current Kubernetes, but adds operational load unjustified by this scale.
- **App Runner**: simplest, but less network isolation control than banking policy usually wants.
