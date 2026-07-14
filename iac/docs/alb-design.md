# Application Load Balancer Design — `yec-elevator-prod`

**Generated:** 2026-07-12  
**Region:** ap-southeast-1  
**Stack:** `yec-elevator-prod` (clone of `zyl-elevator-prod`)  
**Domain:** yomaelevator.com

---

## Why Both an External and an Internal ALB Are Required

The architecture requires **two ALBs** because there are two distinct traffic paths:

### External ALB — `yec-elevator-prod-alb-external`

Internet users, CloudFront, and the WAF all terminate at this ALB. It is **internet-facing** by definition because it must be reachable from the public internet (CloudFront origin) and, during testing, directly by IP.

### Internal ALB — `yec-elevator-prod-alb-internal`

The Next.js frontend runs a **server-side reverse proxy** (`app/api/[...slug]/route.ts`). When the browser calls `/api/*` on `yomaelevator.com`, it reaches the fe ECS task. The Next.js server then re-issues that request to `API_BASE_URL` — the backend. That server-to-server call must stay inside the VPC:

- It never touches the internet (no NAT hairpin, no CloudFront hop, no public IPs).
- It bypasses the external ALB security group entirely (no CloudFront-only inbound restriction to work around).
- It lets the backend ECS tasks sit in **private subnets with no public ingress at all**.

Without the internal ALB, the only alternative is direct task-to-task DNS via ECS Service Discovery — which is fragile during deployments and gives no health checking, connection draining, or load distribution across multiple backend tasks. The internal ALB provides all of those for free.

**Traffic flow in full:**

```
Browser
  └─► CloudFront (WAFv2 + cache)
        └─► External ALB (HTTPS:443 / HTTP:80 redirect)
              ├─► fe-tg → ECS fe task (Next.js :3000)  [default rule]
              │     └─► [Next.js /api proxy] ──► Internal ALB (HTTP:80)
              │                                         └─► be-tg → ECS be task (NestJS :3001)
              └─► be-tg → ECS be task (NestJS :3001)  [/api/* rule — direct path]
```

The external ALB routes `/api/*` directly to be-tg for efficiency (API calls do not need to transit Next.js), and routes everything else to fe-tg (the React frontend). The frontend's server-side SSR and cookie-exchange flows use the internal ALB path.

---

## ALB 1 — External (Internet-Facing)

### General

| Property | Value |
|---|---|
| **Name** | `yec-elevator-prod-alb-external` |
| **Type** | Application Load Balancer |
| **Scheme** | Internet-facing |
| **Region** | ap-southeast-1 (Singapore) |
| **VPC** | `yec-elevator-prod-vpc` — 172.27.0.0/16 |
| **Availability Zones** | ap-southeast-1a, ap-southeast-1b, ap-southeast-1c |
| **Subnets** | Public-1a (172.27.1.0/24), Public-1b (172.27.2.0/24), Public-1c (172.27.3.0/24) |
| **IP Address Type** | IPv4 |
| **Cross-Zone Load Balancing** | Enabled — the three AZ subnets may have uneven ECS task placement; cross-zone ensures even distribution |
| **Deletion Protection** | **Enabled** — prevents accidental teardown of the production entry point |
| **Idle Timeout** | **120 seconds** — the FE `/api` proxy streams bodies (photos, signatures up to 50 MB); the default 60 s is too short for large uploads |
| **HTTP/2** | Enabled — reduces connection overhead for browser clients making multiple concurrent API calls |
| **HTTP/3** | Not enabled — ALB does not support HTTP/3 natively; CloudFront handles QUIC/HTTP3 at the edge |
| **Access Logs** | Enabled — S3 bucket `yec-elevator-prod-alb-logs`, prefix `external/` |
| **Connection Logs** | Enabled — same bucket, prefix `external-conn/` |
| **WAF Association** | **Not directly** — WAFv2 WebACL `yec-elevator-prod-waf` is attached to the **CloudFront distribution** (scope CLOUDFRONT, us-east-1). ALB is behind CloudFront, so WAF coverage is already enforced upstream. A second WAF on the ALB would double-charge without adding meaningful coverage for the CloudFront-funneled traffic. |
| **CloudFront Origin** | Yes — this ALB is the single origin for the `yomaelevator.com` CloudFront distribution |

> **Port 8000 note:** The source production ALB (`zyl-elevator-prod`) exposes HTTP:8000 as a legacy listener — likely a remnant from a direct-access testing phase before CloudFront was in front. The `yec-elevator-prod` clone **drops port 8000**. All API traffic is on 443 (HTTPS) or 80 (redirect). Exposing an additional unprotected port widens the attack surface and was flagged in the pen test scope.

---

### Listeners

#### Listener 1 — HTTP:80

| Property | Value |
|---|---|
| Port | 80 |
| Protocol | HTTP |
| Default Action | **Redirect** → HTTPS:443 (301 Permanent) |
| SSL Policy | N/A |
| ACM Certificate | N/A |
| Purpose | Ensures any HTTP bookmark or scan hit is silently upgraded to HTTPS; no content is ever served over plaintext from this ALB |

No listener rules are needed on HTTP:80 — the default action handles all traffic uniformly.

#### Listener 2 — HTTPS:443

| Property | Value |
|---|---|
| Port | 443 |
| Protocol | HTTPS |
| SSL Policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` — requires TLS 1.2 minimum, prefers TLS 1.3; eliminates weak ciphers (RC4, 3DES, CBC-mode suites) |
| ACM Certificate | `*.yomaelevator.com` + `yomaelevator.com` — issued in ap-southeast-1 and DNS-validated |
| Default Action | Forward → **fe-tg** (Next.js frontend) |

---

### Listener Rules — HTTPS:443

Rules are evaluated in priority order. First match wins.

#### Rule 1 — Health Check Bypass
| Field | Value |
|---|---|
| Priority | 1 |
| Condition | Path is `/health` |
| Action | Fixed response — HTTP 200, `application/json`, body `{"status":"ok"}` |
| Why | Allows ALB self-health checks and monitoring pings to return 200 instantly without hitting an ECS task. Keeps health-check noise out of application logs. The backend's own `/api` endpoint is used for ECS task health checks — this rule is for ALB-level probes from monitoring tools. |

#### Rule 2 — API Traffic → Backend
| Field | Value |
|---|---|
| Priority | 10 |
| Condition | Path pattern `/api/*` |
| Action | Forward → **be-tg** |
| Why | All REST API calls (`/api/auth/*`, `/api/maintenance-reports/*`, `/api/equipment/*`, etc.) go directly to the NestJS backend without transiting the Next.js layer. This avoids double-proxying (browser → Next.js → backend) for every API call that CloudFront passes through. It also means API rate-limiting (ThrottlerGuard) operates on the real client IP forwarded via `X-Forwarded-For`. |

#### Rule 3 — Swagger Docs → Backend
| Field | Value |
|---|---|
| Priority | 9 |
| Condition | Path pattern `/api/docs*` |
| Action | Forward → **be-tg** |
| Why | Must be listed before Rule 2 (same `/api/*` prefix) with higher priority to ensure Swagger UI assets and the OpenAPI JSON endpoint all route to the backend. In practice this is covered by Rule 2 since `/api/docs*` is a subset of `/api/*`, but explicit ordering is safer if rule ordering changes. |

#### Rule 4 — Default → Frontend
| Field | Value |
|---|---|
| Priority | 100 (default) |
| Condition | Default (matches everything not caught above) |
| Action | Forward → **fe-tg** |
| Why | Every non-API path — `/`, `/login`, `/admin/*`, `/auth/*`, static assets — is a Next.js App Router route served by the fe ECS tasks. Next.js `standalone` output handles routing internally. |

**No authentication rules (OIDC/Cognito) at the ALB level.** The application manages auth entirely via:
- Microsoft Entra ID SSO through NextAuth v5 in the FE container
- Hand-signed HS256 JWTs issued by the NestJS backend
- httpOnly cookies (`access_token`, `refresh_token`) scoped to `/api`

Adding ALB-level OIDC would create a duplicate auth layer that conflicts with the FE's NextAuth flow and the backend's cookie-based JWT. It would also block the technician login path (local email/password) and the MS id_token exchange (`/api/auth/ms-login`).

---

### Security Groups — External ALB

#### `yec-elevator-prod-sg-alb-external`

**Inbound rules:**

| Rule | Port | Protocol | Source | Reason |
|---|---|---|---|---|
| HTTPS from CloudFront | 443 | TCP | `com.amazonaws.global.cloudfront.origin-facing` (AWS managed prefix list) | Restricts HTTPS to CloudFront IPs only — prevents bypassing WAF by hitting the ALB directly. Use the CloudFront managed prefix list, not 0.0.0.0/0. |
| HTTP for redirect | 80 | TCP | 0.0.0.0/0 | HTTP:80 only issues a 301 redirect; no content served. Must be open to all so that any HTTP hit gets upgraded. CloudFront also hits :80 for redirect-chain testing. |

**Outbound rules:**

| Rule | Port | Protocol | Destination | Reason |
|---|---|---|---|---|
| Frontend target | 3000 | TCP | `yec-elevator-prod-sg-fe-task` | ALB health checks and forwarded requests to Next.js tasks |
| Backend target | 3001 | TCP | `yec-elevator-prod-sg-be-task` | ALB health checks and forwarded `/api/*` requests to NestJS tasks |

**Why least privilege:** The ALB SG never needs to reach the database (SG `rds`), the S3 VPC endpoint, or any other service. Outbound is locked to exactly the two container ports.

---

## ALB 2 — Internal

### General

| Property | Value |
|---|---|
| **Name** | `yec-elevator-prod-alb-internal` |
| **Type** | Application Load Balancer |
| **Scheme** | Internal |
| **Region** | ap-southeast-1 |
| **VPC** | `yec-elevator-prod-vpc` — 172.27.0.0/16 |
| **Availability Zones** | ap-southeast-1a, ap-southeast-1b, ap-southeast-1c |
| **Subnets** | Private-1a (172.27.4.0/24), Private-1b (172.27.5.0/24), Private-1c (172.27.6.0/24) |
| **IP Address Type** | IPv4 |
| **Cross-Zone Load Balancing** | Enabled — same reasoning as external; backend tasks may be distributed unevenly across AZs |
| **Deletion Protection** | Enabled |
| **Idle Timeout** | **120 seconds** — matches external ALB. The Next.js proxy streams request bodies to the backend (50 MB photos/signatures); the upstream timeout on the internal ALB must be at least as long as the external ALB's timeout. |
| **HTTP/2** | Enabled |
| **HTTP/3** | N/A — HTTP/3 is a CloudFront edge feature |
| **Access Logs** | Enabled — S3 bucket `yec-elevator-prod-alb-logs`, prefix `internal/` |
| **Connection Logs** | Enabled — prefix `internal-conn/` |
| **WAF Association** | None — traffic on this ALB originates exclusively from the fe ECS tasks inside the VPC. WAF is already applied at CloudFront. Adding WAF here would double-charge and inspect already-scrubbed traffic. |
| **CloudFront Origin** | None — this ALB has no public DNS record and is never referenced from outside the VPC |

---

### Listeners

#### Listener — HTTP:80

| Property | Value |
|---|---|
| Port | 80 |
| Protocol | HTTP (no TLS) |
| Default Action | Forward → **be-tg** |
| SSL Policy | N/A |
| ACM Certificate | N/A |
| Why HTTP not HTTPS | Traffic never leaves the VPC. TLS termination on the internal ALB adds latency and certificate management overhead with no security benefit — the network between private subnets is AWS-managed and not exposed. The fe task → internal ALB connection is equivalent to localhost-to-localhost in terms of network trust boundary. |

---

### Listener Rules — HTTP:80

#### Rule 1 — Health Check Bypass
| Field | Value |
|---|---|
| Priority | 1 |
| Condition | Path is `/api` or `/api/` |
| Action | Fixed response — HTTP 200, body `{"status":"ok"}` |
| Why | The backend's root `/api` endpoint returns `{status:'ok', timestamp}` (verified in `app.controller.ts`). A fixed response at the ALB level saves a container invocation for ALB health pings. |

#### Rule 2 — Default → Backend
| Field | Value |
|---|---|
| Priority | 100 (default) |
| Condition | Default |
| Action | Forward → **be-tg** |
| Why | Every request on this ALB comes from the fe task's Next.js proxy and is always destined for the NestJS API. No path-splitting needed. |

---

### Security Groups — Internal ALB

#### `yec-elevator-prod-sg-alb-internal`

**Inbound rules:**

| Rule | Port | Protocol | Source | Reason |
|---|---|---|---|---|
| HTTP from fe tasks | 80 | TCP | `yec-elevator-prod-sg-fe-task` | Only the Next.js frontend tasks are permitted to call this ALB. Nothing else in the VPC (bastion, RDS, etc.) needs to reach it. |

**Outbound rules:**

| Rule | Port | Protocol | Destination | Reason |
|---|---|---|---|---|
| Backend target | 3001 | TCP | `yec-elevator-prod-sg-be-task` | All traffic exits to NestJS tasks on their container port |

---

## Supporting Security Group Rules (ECS Tasks)

For completeness, the ALB-facing rules on the ECS task SGs:

#### `yec-elevator-prod-sg-fe-task`

| Direction | Port | Source/Dest | Reason |
|---|---|---|---|
| Inbound | 3000 | `yec-elevator-prod-sg-alb-external` | External ALB → Next.js container |
| Outbound | 80 | `yec-elevator-prod-sg-alb-internal` | Next.js proxy → internal ALB |
| Outbound | 443 | 0.0.0.0/0 | Entra ID JWKS endpoint, NextAuth upstream, S3 presign calls during SSR |

#### `yec-elevator-prod-sg-be-task`

| Direction | Port | Source/Dest | Reason |
|---|---|---|---|
| Inbound | 3001 | `yec-elevator-prod-sg-alb-external` | Direct API path from external ALB |
| Inbound | 3001 | `yec-elevator-prod-sg-alb-internal` | Proxied path via internal ALB from fe tasks |
| Outbound | 5432 | `yec-elevator-prod-sg-rds` | PostgreSQL (RDS private subnet) |
| Outbound | 443 | 0.0.0.0/0 | S3 API (uploads bucket), Secrets Manager, ECR image pulls, Entra JWKS |

---

## Logging

### Access Logs

**Both ALBs: Enabled.**

The application processes maintenance reports with sensitive data (building/equipment records, technician signatures). Access logs are essential for security investigations, pen-test evidence, and compliance audits (the pen test report — `rpt.ysh-yoma-elevator-cloud-pentest-prelim.20260204.pdf` — is already in this repo, implying ongoing security review).

| Setting | Value |
|---|---|
| S3 Bucket | `yec-elevator-prod-alb-logs` |
| Bucket Policy | ALB delivery principal (`elasticloadbalancing.amazonaws.com`) allowed `s3:PutObject` on `arn:aws:s3:::yec-elevator-prod-alb-logs/*` |
| Server-Side Encryption | SSE-S3 (AES-256) |
| Versioning | Enabled on the bucket |
| External prefix | `external/AWSLogs/470656906159/elasticloadbalancing/ap-southeast-1/` |
| Internal prefix | `internal/AWSLogs/470656906159/elasticloadbalancing/ap-southeast-1/` |
| Retention | 90 days — S3 lifecycle rule moves to Glacier after 30 days, expires at 90 days. Matches a standard security-audit retention window without unbounded cost. |

### Connection Logs

Enabled on both ALBs. Connection logs capture TLS negotiation failures and TCP-level anomalies not visible in access logs — important for diagnosing CloudFront origin handshake issues.

### CloudWatch Metrics

ALB publishes the following metrics to CloudWatch automatically (no configuration required):

| Metric | Alarm Threshold | Reason |
|---|---|---|
| `HTTPCode_ELB_5XX_Count` | > 10 per 5 min | Upstream failures (be-tg or fe-tg unreachable) |
| `HTTPCode_Target_5XX_Count` | > 10 per 5 min | Application errors from ECS tasks |
| `TargetResponseTime` (p99) | > 5 s | Catches slow database queries or large file uploads stalling |
| `UnHealthyHostCount` (be-tg + fe-tg) | > 0 for 2 periods | ECS task health degraded |
| `RequestCount` | Spike > 3× baseline | Abnormal traffic (DDoS indicator) |
| `ActiveConnectionCount` | > 5000 | Connection exhaustion risk |

### Recommended Monitoring

1. **CloudWatch Dashboard** — single pane showing both ALBs, both target groups, ECS task CPU/memory, and RDS connections.
2. **ALB + WAF combined view** — correlate WAF block counts against `RequestCount` spikes to distinguish bot traffic from real load.
3. **Alarm SNS topic** → email/Slack for on-call. At minimum alert on UnHealthyHostCount and 5XX spikes.
4. **Log Insights query** — weekly query on access logs to surface any direct-IP hits to the external ALB (bypass attempts, CloudFront-excluded IPs).

---

## Performance

### External ALB

| Setting | Value | Reason |
|---|---|---|
| **Connection Draining / Deregistration Delay** | **60 seconds** | The FE and BE are Fargate tasks with `desired_count=1` today. During a deployment the old task must finish in-flight requests (especially the 50 MB photo uploads) before ECS deregisters it. 60 s balances graceful drain against slow rollout speed. Increase to 120 s if large uploads are common. |
| **Request Timeout** | 120 s (via Idle Timeout) | ALB idle timeout and target response timeout are controlled by the same `idle_timeout` attribute. Set to 120 s to cover the worst-case photo upload path: browser → CloudFront → ALB → be-tg (50 MB base64 body). |
| **Slow Start** | 30 seconds on **be-tg** | When a new backend task registers, NestJS runs `migration:run:prod` before accepting requests (see Dockerfile CMD). Slow start prevents the ALB from flooding the new task with full traffic immediately after it passes the health check but before migrations complete. Minimum 30 s warm-up. |
| **Slow Start (fe-tg)** | Disabled | Next.js `standalone` starts quickly; no migration phase. |
| **Sticky Sessions** | **Disabled** | Auth state lives in httpOnly cookies validated against a stateless JWT (HS256). No server-side session store means any task can handle any request. Stickiness would only concentrate load on one task unnecessarily. ⚠️ Exception: if token revocation is moved to an in-memory Redis (current plan per `authentication-and-rbac.md`), stickiness would be required until the shared revocation store is in place. |
| **Compression** | Disabled at ALB | CloudFront handles gzip/Brotli compression at the edge. Enabling compression at both ALB and CloudFront leads to double-compression bugs. Next.js also compresses its own responses natively. Leave ALB compression off. |

### Internal ALB

| Setting | Value | Reason |
|---|---|---|
| **Deregistration Delay** | 30 seconds | Internal traffic is server-to-server; requests are short-lived API calls (no large uploads on this path — the browser's upload goes via the external ALB). 30 s is sufficient. |
| **Request Timeout** | 120 s (Idle Timeout) | Matches external ALB to avoid mid-chain timeout mismatches on the few large-body paths that do go through the fe proxy. |
| **Slow Start** | 30 seconds on **be-tg** | Same reasoning as external ALB — new backend tasks need migration warm-up. |
| **Sticky Sessions** | Disabled | Same stateless-JWT reasoning. |
| **Compression** | Disabled | Internal JSON payloads are small; overhead of compression/decompression inside the VPC is not worthwhile. |

---

## Target Groups (referenced above)

| Name | Protocol | Port | Health Check Path | Healthy Threshold | Unhealthy Threshold | Timeout | Interval |
|---|---|---|---|---|---|---|---|
| `yec-elevator-prod-be-tg` | HTTP | 3001 | `/api` (returns `{status:'ok'}`) | 2 | 3 | 5 s | 30 s |
| `yec-elevator-prod-fe-tg` | HTTP | 3000 | `/` (Next.js root, returns 200) | 2 | 3 | 5 s | 30 s |

Both target groups use the **IP target type** (required for Fargate awsvpc networking — tasks have no EC2 instance to register).

---

## Summary Table

| | External ALB | Internal ALB |
|---|---|---|
| Scheme | Internet-facing | Internal |
| Subnets | Public (172.27.1–3.0/24) | Private (172.27.4–6.0/24) |
| Listeners | HTTP:80 (redirect), HTTPS:443 | HTTP:80 |
| SSL | TLS13-1-2-2021-06 + ACM cert | None (VPC-internal) |
| Default target | fe-tg (Next.js :3000) | be-tg (NestJS :3001) |
| `/api/*` target | be-tg (NestJS :3001) | be-tg (NestJS :3001) |
| WAF | Via CloudFront upstream | None |
| Inbound sources | CloudFront prefix list + :80 all | fe-task SG only |
| Idle Timeout | 120 s | 120 s |
| Deletion Protection | Yes | Yes |
| Access Logs | Yes (S3 `external/`) | Yes (S3 `internal/`) |
| Slow Start (be-tg) | 30 s | 30 s |
| Sticky Sessions | Disabled | Disabled |
