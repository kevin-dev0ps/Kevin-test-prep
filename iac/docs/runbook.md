# elevator-yec clone — Operations Runbook

Single reference for standing up / operating the `elevator-yec-prod` clone.
**Working mode:** paste a log or error → get root cause → impact → exact fix steps.
Commands are marked **[read-only]** (safe) or **[CHANGE]** (confirm first).

---

## 0. Environment facts (memorize)

| Thing | Value |
|---|---|
| Project / Env | `elevator-yec` / `prod` |
| Region | `ap-southeast-1` (WAF + CloudFront cert: `us-east-1`) |
| AWS profile | `KEVIN-ZYL` |
| Account | `470656906159` |
| Clone VPC | `172.27.0.0/16` (isolated from live `172.25.0.0/16`) |
| Naming | `elevator-yec-prod-*` (services `-be` / `-fe`) |
| DB (from snapshot) | user `zyl_admin`, db `yecl_maintenance`, postgres 15.17 |
| Live DB (source, never touch) | `zyl-elevator-prod-rds` |
| TF dir | `iac/environments/yec-prod` |
| State backend | S3 `elevator-yec-production-tfstate`, key `prod/terraform.tfstate` |

**Golden rules:** never touch live `zyl-elevator-prod-*` / starcity `scla-*`; secret VALUES never in Terraform/git (only ARNs, values set out of band).

---

## 1. Standard apply loop

```bash
cd iac/environments/yec-prod
terraform plan -out=tfplan          # [read-only] review the diff
terraform apply "tfplan"            # [CHANGE] confirm first
```
Always read the plan summary line: `X to add, Y to change, Z to destroy`. If `destroy` touches anything you didn't expect, STOP.

---

## 2. RDS restore-from-snapshot (the current workflow)

**Concept:** the `rds` module restores from `snapshot_identifier`. On restore, `username`/`db_name`/`engine_version` are inherited from the snapshot (→ `zyl_admin` / `yecl_maintenance`). `snapshot_identifier` is a **create-only** attribute with `ignore_changes`, so changing it only takes effect on a fresh create or `-replace`.

**Pick a valid snapshot** [read-only]:
```bash
aws rds describe-db-snapshots --db-instance-identifier zyl-elevator-prod-rds \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[].[DBSnapshotIdentifier,SnapshotType,Status,SnapshotCreateTime]' \
  --output table --profile KEVIN-ZYL --region ap-southeast-1
```
- `rds:` prefix = **automated** snapshot → expires at your 7-day retention. Don't pin to one near expiry.
- Best practice = **manual** snapshot (never expires):
  ```bash
  # [CHANGE] safe on live (brief I/O, no downtime)
  aws rds create-db-snapshot --db-instance-identifier zyl-elevator-prod-rds \
    --db-snapshot-identifier zyl-elevator-prod-rds-clone-$(date +%Y%m%d) \
    --profile KEVIN-ZYL --region ap-southeast-1
  ```

**Set the ID** in `terraform.tfvars`: `rds_snapshot_identifier = "<snapshot-id>"`, then apply (§1).
- If the DB is **absent from state** → plain `terraform apply` creates it.
- If an **empty DB already exists in state** → `terraform plan -replace="module.rds.aws_db_instance.this" -out=tfplan` (disable deletion protection first, see §4).

**After restore completes — 3 steps** [CHANGE, confirm each]:
```bash
# 1. Copy the new RDS-managed master password into the app's SSM param
SEC=$(aws rds describe-db-instances --db-instance-identifier elevator-yec-prod-rds \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text --profile KEVIN-ZYL --region ap-southeast-1)
PW=$(aws secretsmanager get-secret-value --secret-id "$SEC" --query SecretString --output text \
  --profile KEVIN-ZYL --region ap-southeast-1 | jq -r .password)
aws ssm put-parameter --name /elevator-yec/prod/rds/password --type SecureString \
  --value "$PW" --overwrite --profile KEVIN-ZYL --region ap-southeast-1

# 2. Set the other out-of-band secrets (once):
#    /elevator-yec/prod/app/jwt-secret, /app/admin-password, and the -be-sso-key secret

# 3. Force BE to reconnect
aws ecs update-service --cluster elevator-yec-prod-ecs --service elevator-yec-prod-be \
  --force-new-deployment --profile KEVIN-ZYL --region ap-southeast-1
```

---

## 3. Testing with NO domain (CloudFront default URL)

Path: `User → CloudFront (*.cloudfront.net, default cert) → ALB:80 → ECS → RDS`.
Get URLs: `terraform output cloudfront_domain` and `terraform output alb_dns_name` [read-only].

Test order:
1. **ALB direct** `curl -i http://<alb_dns_name>/` — confirms app+DB (no edge).
2. **CloudFront** `https://<cloudfront_domain>/` — confirms edge+WAF+cache.

Expected limitations on the temp URL (not bugs):
- **CORS/cookies fail** — app has `FRONTEND_ORIGIN=https://yomaelevator.com`. Temp fix: point it at the CloudFront URL, then revert.
- **SSO login fails** — Azure redirect URI expects the real domain.
- **Check `/api/*` cache behavior = CachingDisabled + all methods** or writes break.

---

## 4. Troubleshooting playbook (symptom → cause → fix)

**`DBSnapshotNotFound: rds:...`**
Automated snapshot expired (7-day retention). → Pick an in-window one or make a manual snapshot (§2).

**`ECONNREFUSED 127.0.0.1:5432` in BE logs**
BE has no `DATABASE_HOST`/creds, or password param wrong. → Confirm `app-config.tf` wires `be_secrets`, the `/rds/*` SSM params are filled, `/rds/password` matches the RDS master password, then force-redeploy BE (§2 step 3).

**ALB name error `... must be ≤32 chars`**
`environment` too long. → Must be `prod` (not `production`). Check `terraform.tfvars`.

**Plan shows only SSM changes, RDS not restoring**
Empty DB already in state + create-only `snapshot_identifier`. → Use `-replace` (§2). Disable deletion protection first:
```bash
# [CHANGE]
aws rds modify-db-instance --db-instance-identifier elevator-yec-prod-rds \
  --no-deletion-protection --apply-immediately --profile KEVIN-ZYL --region ap-southeast-1
```

**Backend `NoSuchBucket`**
State bucket missing. → Create `elevator-yec-production-tfstate` first, then `terraform init -reconfigure`.

**`terraform destroy` does nothing**
State is empty (resources are orphaned/created outside this state). → Import or delete manually; don't assume destroy will find them.

**WAF/CloudFront apply fails on region**
WAF `CLOUDFRONT` scope + its ACM cert must be in `us-east-1` (via the `aws.us_east_1` provider alias).

---

## 5. Domain cutover (later)

1. ACM cert in **us-east-1** for the domain (DNS-validated).
2. ACM cert in **ap-southeast-1** for the ALB; set `enable_https=true`.
3. `terraform.tfvars`: `cloudfront_aliases=["yomaelevator.com"]`, `cloudfront_certificate_arn=<us-east-1 arn>`, `origin_protocol_policy="https-only"`.
4. Revert temp `FRONTEND_ORIGIN` / Azure redirect changes.
5. DNS: apex = **ALIAS** (not CNAME) → CloudFront domain.
