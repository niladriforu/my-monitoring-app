# Activity Monitoring

React terminal-style UI (Bloomberg look) + Python (FastAPI) backend, designed for AWS.

```
am-platform/
  backend/    FastAPI API, JWT/RBAC, masked data, tests, Dockerfile
  frontend/   React (Vite) terminal UI
  infra/      Terraform for AWS (VPC, ECS Fargate, RDS, Cognito, WAF, CloudFront, KMS)
  docs/       ARCHITECTURE.md
```

## Run locally

```bash
# API  (http://localhost:8000/docs)
cd backend && pip install -r requirements.txt && uvicorn app.main:app --reload
# UI   (http://localhost:5173)
cd frontend && npm install && npm run dev
# tests
cd backend && pytest
```
Or `docker compose up`.

## Terminal controls

Type a command and press Enter: `KPI`, `EVT`, `ALR`, `THR`, `CHN`, `ALL`, `HELP`.
Function keys F1–F6 jump to panels, F8 or Esc returns to the full view. Click a panel title to maximize.

## Deploy to AWS

1. Create ECR repo, build & push `backend/` image.
2. `cd infra && terraform init && terraform apply` (set `domain_name`, `web_domain`, ACM cert ARNs, `container_image`).
3. `cd frontend && npm run build && aws s3 sync dist s3://<web_bucket> --delete`.
4. Create users in Cognito and add them to the `viewer` / `analyst` / `admin` groups.

## Before production

- Wire the frontend to Cognito Hosted UI (Authorization Code + PKCE) — `src/api.js` currently uses the dev token, which the backend disables when `ENV=prod`.
- Replace `backend/app/data.py` (simulated data) with a PostgreSQL repository and your event feed (SQS/Kinesis/Kafka).
- Terraform in `infra/` has not been applied or validated against a live account; run `terraform validate` and review with your security team.
