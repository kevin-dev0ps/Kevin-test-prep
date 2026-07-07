# zyl-elevator IaC migration — Phase 1: AWS inventory

Goal: capture the existing, manually-created AWS environment as JSON, with **zero
changes** to live infrastructure. Inventory becomes the source of truth that later
phases validate against.

## Staged workflow

```
1  Environment check        (auth, tooling)
2  AWS inventory            <-- this script (read-only, parallel)
3  Inventory validation     (review reports/, manifest.json)
4  Terraformer export
5  Terraform validation     (fmt + validate)
6  Resource mapping         (manifest vs terraform export)
7  Refactor to modules
8  terraform plan           (must show NO changes against prod)
9  Prepare dev / preprod / prod
```

## Why you run this, not the assistant

The assistant works in an isolated sandbox with **no AWS CLI, no access to your
`KEVIN-ZYL` credentials, and no network route to AWS**. Collection runs on your
machine; you hand the resulting `inventory/` back for Phase 2 onward.

## Safety

`scripts/collect_inventory.sh` uses **only** `describe* / list* / get*` calls —
verified zero mutating verbs. It never touches Terraform state and never reads
secret/parameter **values** (Secrets Manager & SSM are metadata-only).

## Prerequisites

- AWS CLI v2 and `jq`
- Profile `KEVIN-ZYL` with read access

## Run

```bash
cd iac
chmod +x scripts/collect_inventory.sh
./scripts/collect_inventory.sh
# or override:
AWS_PROFILE=KEVIN-ZYL REGIONS="ap-southeast-1 us-east-1" \
  PREFIX=zyl-elevator-prod ./scripts/collect_inventory.sh
```

`REGIONS` is space-separated. Add `us-east-1` to capture ACM certificates and
CloudFront-scoped WAF that live there. Global services (IAM, CloudFront,
Route53, OIDC) are collected once regardless of region.

### Speed: enum vs DEEP

Terraformer extracts full resource config itself, so by default this script runs
a **fast enumeration pass** — one `list`/`describe` per service, enough to know
what exists and drive Terraformer's `--resources`/`--filter`. It skips the slow
per-item loops and all runtime-only calls.

```bash
./scripts/collect_inventory.sh                 # DEEP=0 (default) — fast
DEEP=1 ./scripts/collect_inventory.sh          # full per-item config export
```

`DEEP=1` adds, per matching resource: all ECS task-def revisions, S3 per-bucket
config (10 calls/bucket), ALB listeners/rules/attributes, IAM policy docs +
`list-entities-for-policy` + role detail, KMS key policies, CloudFront configs,
WAF `get-web-acl`, Route53 records/tags, ACM + Secret describes. Use it later for
audit / Phase-3 validation, not for the Terraformer clone.

Dropped entirely (runtime state, useless for cloning): `ecs list-tasks`,
`elbv2 describe-target-health`.

### What's downloaded (and what isn't)

To avoid pulling account-wide data you don't need for a clone:

- **EC2** (VPC/subnet/RT/IGW/NAT/SG/NACL/endpoints/EIP) uses a server-side tag
  filter (`Name=tag-value,Values=*zyl-elevator-prod*`), so only matching
  resources download. Note: an EC2 resource with **no** tag containing the prefix
  won't match — tag it, or use `DEEP=1`, if you hit that.
- **SSM** parameters filtered server-side (`Contains zyl-elevator-prod`).
- **CloudWatch log groups are skipped by default** (an unscoped list pulls the
  whole account). Collect them only when scoped:

  ```bash
  LOG_PREFIX=/ecs/zyl-elevator-prod ./scripts/collect_inventory.sh
  ```
- **One region by default** (`ap-southeast-1`). Only add `us-east-1` if CloudFront
  uses an ACM cert there.
- A **run-lock** prevents accidental parallel launches. If a run was killed and the
  lock is stale: `rm -rf inventory/_meta/.lock`.

Account-wide `list` calls that can't be server-filtered (IAM roles/policies,
CloudWatch alarms, SNS) are single paginated calls and stay; they're normally fast.

## Output layout

```
inventory/
  raw/          untouched API responses (source of truth)
  filtered/     only items whose name/tag/ARN contains the prefix
  reports/      inventory-summary.md, missing-tags.md
  logs/         per-domain + aggregate collect.log
  manifest.json resource counts (compare against terraform export in Phase 6)
  _meta/        caller-identity.json
```

Domains under `raw/` and `filtered/`: `network`, `compute`, `loadbalancing`,
`database`, `storage`, `security`, `edge`, `monitoring`. Regional resources are
namespaced by region (e.g. `raw/network/ap-southeast-1/vpcs.json`).

### Coverage highlights (v2)

- Pagination: CLI auto-pagination forced on (`AWS_PAGER=""`, no `--max-items`) so
  all pages are aggregated.
- Tag matching: broad `resourcegroupstaggingapi` sweep, filtered locally on tag
  **key or value** (not a single hard-coded tag).
- ECS: cluster settings + capacity providers, services, and **all active
  task-definition revisions** (rollback history).
- Load balancing: listeners, listener rules, LB attributes, **target health**.
- Edge: CloudFront distribution + config + cache/origin/response policies; WAF
  `get-web-acl` for both CLOUDFRONT and REGIONAL scopes; Route53 records + tags.
- IAM: role/policy docs plus **`list-entities-for-policy`** (who uses each policy).
- ACM certificates (regional; use `us-east-1` for CloudFront certs).

## Hand back for Phase 2

Return the `inventory/` folder — it's in this workspace. Check
`inventory/logs/collect.log` for `FAIL` lines first; a FAIL usually means the
service isn't used or the profile lacks read permission there (note and move on).
Then review `reports/inventory-summary.md` and `manifest.json`.
