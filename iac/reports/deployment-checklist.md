# Deployment Checklist — `yec-elevator-prod` to Org Production

Target: org production AWS account · region ap-southeast-1 · stack `environments/yec-prod`
Network: dedicated VPC `172.27.0.0/16` (separate from existing `zyl-elevator` `172.25.0.0/16`).

## A. Will anything conflict?

Because the clone is a **new account + new VPC + new names (`yec-elevator-prod-*`)**, it
does **not** touch the existing `zyl-elevator-prod`. The real conflict risks are:

| Risk | Why | Action |
|---|---|---|
| **CloudFront CNAME** | `yomaelevator.com` is already bound to the existing distribution — an alias can live on only ONE distribution across ALL of AWS. | Use a **different domain** for the clone, OR do a planned DNS cutover (retire the alias on the old one first). Keep `cloudfront_aliases = []` until decided. |
| **State backend** | `backend.tf` points at `zyl-elevator-tfstate` (old account). | Create an S3 state bucket + DynamoDB lock table **in the org prod account** and update `backend.tf`. |
| **GitHub OIDC provider** | Only one `token.actions.githubusercontent.com` provider per account. | If enabling `github_oidc`, ensure the provider exists in org prod (create once) and pass its ARN. |
| **S3 uploads bucket name** | `yec-elevator-prod-uploads` is globally unique. | New name — fine; just confirm it's free. |
| **ACM / DNS validation** | Certs must exist in the target account before HTTPS works. | Create + DNS-validate 2 certs (below). |

No resource-name or CIDR collisions with `zyl-elevator-prod` — verified separate.

## B. Prerequisites — create BEFORE `terraform apply`

- [ ] **Correct account/profile**: set `aws_profile` in `yec-prod/terraform.tfvars` to the org-prod profile/SSO role; confirm `aws sts get-caller-identity` shows the prod account.
- [ ] **State backend** in org prod: S3 bucket (versioned, encrypted) + DynamoDB lock table; update `backend.tf` bucket/table names.
- [ ] **ACM certificates** (DNS-validated):
  - `alb_certificate_arn` — in **ap-southeast-1** (for the ALB 443 listener).
  - `cloudfront_certificate_arn` — in **us-east-1** (for CloudFront), only if using an alias.
- [ ] **ECR images**: build & push `be` and `fe` images to the org-prod ECR repos (created by this stack — so do a first apply, then push, then set image tags). Set `be_image` / `fe_image` to the new account's ECR URIs.
- [ ] **Application secrets** (values live outside Terraform): create in Secrets Manager / SSM — DB connection string (points at the NEW RDS endpoint), JWT/app keys, third-party API keys. Pass ARNs via `be_secrets` / `fe_secrets`.
- [ ] **DNS plan**: decide the clone's hostname; know where the zone lives (Route53 in prod, or registrar) to add the ALB/CloudFront record after apply.
- [ ] **Quotas**: confirm org-prod limits for EIP/VPC/NAT/ALB are sufficient (new accounts sometimes throttled).

## C. Recommended apply procedure (staged, low-risk)

1. [ ] `cd iac && terraform fmt -recursive`
2. [ ] `cd environments/yec-prod && terraform init` (with the org-prod backend)
3. [ ] `terraform validate`
4. [ ] **Stage 1 — infra only, no running tasks.** Set ECS `desired_count = 0` (see §E), and keep `cloudfront_aliases = []`. `terraform plan` → review resource-by-resource → `terraform apply`.
5. [ ] Push `be`/`fe` images to the new ECR; create the app secrets referencing the new RDS endpoint.
6. [ ] Run DB schema/migrations against the new RDS (via bastion/SSM or the app's migrate job). Load seed/prod data if this replaces the old DB.
7. [ ] **Stage 2 — bring up services.** Set `be_image`/`fe_image` real tags, `desired_count = 1`, add the cert/alias. `terraform plan` → `apply`.
8. [ ] Add the DNS record (or CloudFront alias) once targets are healthy.

## D. Post-apply verification

- [ ] ECS services reach **steady state**; tasks not crash-looping (check `/ecs/yec-elevator-prod/be`,`/fe` logs).
- [ ] ALB target groups **healthy**: `be-tg` on `:3001` path `/api/docs`, `fe-tg` on `:3000` path `/`. Fix health-check path/port if the app differs.
- [ ] Hit the ALB DNS directly (HTTP/HTTPS) → app responds.
- [ ] CloudFront → app responds; WAF `yec-elevator-prod-waf` attached and not blocking legit traffic (default action = Allow; watch RateLimit).
- [ ] RDS reachable **only** from the be/fe task SGs on 5432; `publicly_accessible = false`.
- [ ] Secrets resolve in the task (no `ResourceInitializationError` for secrets).
- [ ] Tags present: `Project`, `Environment`, `Sub-Tag=Yoma Elevator`, `Component`.

## E. Components to CHANGE / ADD before it serves properly

- [ ] **ECS `desired_count`** — add to the `ecs_be`/`ecs_fe` module calls (Stage 1 = 0, Stage 2 = 1+). Module default is 1.
- [ ] **ALB deletion protection** — `enable_deletion_protection` defaults false; set **true** for prod (add the arg / a variable).
- [ ] **CloudFront managed-policy IDs** — currently hardcoded literals; swap to `data "aws_cloudfront_cache_policy"` / `aws_cloudfront_origin_request_policy` lookups so they're not brittle.
- [ ] **ALB listener rules** — the module ships a sensible default (`/api/*` → be, else fe). Reconcile exact host/path rules against `generated/terraformer/aws/alb/resources.tf` for your routing (the source external ALB had extra rules + port 8000).
- [ ] **Route53 module** — not authored (source DNS returned 0). Add records/zone for the clone's domain.
- [ ] **GitHub Actions CI** — repoint `be`/`fe` pipelines at the new account's ECR + ECS cluster/service names (`yec-elevator-prod-*`); update the deploy role.
- [ ] **App config** — env vars / secrets that reference the OLD env (DB host, bucket name, domain, CORS origins) must be updated to the new `yec-elevator-prod-*` values.
- [ ] **Confirm FE/BE ports & health paths** match the actual apps (be `:3001 /api/docs`, fe `:3000 /`).

## F. Safety / rollback

- [ ] Never `apply` `environments/prod` (source — CloudFormation-owned; guarded).
- [ ] `terraform plan` reviewed and saved (`-out=plan.tfplan`) before every `apply`.
- [ ] Rollback: `terraform destroy` on the clone is safe (isolated account/VPC). RDS has `deletion_protection = true` + final snapshot — expect to disable protection to destroy the DB.
- [ ] No data mutation on the existing `zyl-elevator-prod` at any point.

## Best-practice notes

- Keep prod state **remote + locked**; enable S3 versioning for state recovery.
- One-way door items (create early, validate independently): **ACM certs**, **DNS**, **OIDC provider**, **state backend**.
- Prefer **Secrets Manager** for DB creds (RDS-managed master password is already enabled); the app's own connection secret is created out of band.
- Do Stage 1 (infra) and Stage 2 (services) as **separate applies** so a failure is easy to localize.
