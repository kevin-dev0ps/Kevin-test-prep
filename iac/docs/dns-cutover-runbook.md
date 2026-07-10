# DNS + CloudFront + WAF Cutover Runbook — yomaelevator.com → new infra

Goal: serve `https://yomaelevator.com` from the NEW `elevator-yec-prod` CloudFront,
with zero/low downtime. The apex currently points at the OLD (`zyl-elevator`) CloudFront.

## Key facts (read first)

- **Two certs needed:** ALB cert in **ap-southeast-1**; CloudFront cert in **us-east-1**
  (CloudFront only accepts us-east-1 certs).
- **A CNAME alias lives on ONE CloudFront distribution only.** `yomaelevator.com`
  is already attached to the OLD distribution — you must remove/move it before the
  new one can serve it. This is the main gotcha.
- **Apex domains can't be a raw CNAME.** In Route 53 use an **ALIAS A record**; at a
  non‑Route53 registrar use ALIAS/ANAME/flattening, or host `www` as CNAME + redirect apex.
- DNS validation CNAMEs are **one-time + permanent** (keep them so the cert auto-renews);
  they route no traffic and are safe to add anytime.

## Step 1 — Request the ACM validation CNAME (us-east-1)

Send the DNS team a request like this (your template is correct):

> Please add a CNAME on yomaelevator.com for AWS ACM validation (us-east-1),
> to enable CloudFront for the app.
> - Type: CNAME
> - Host: `_5d9794d39bb3ac29bb41d4116d217be4.yomaelevator.com.`
> - Value: `_51950763dfa6dac2188732493c752ede.jkddzztszm.acm-validations.aws.`
> - TTL: 300 · Purpose: ACM DNS validation · App: https://yomaelevator.com

(The exact host/value come from the ACM cert's validation record — see Step 2.)

## Step 2 — Create + validate the certs (Terraform or console)

1. Request an ACM cert for `yomaelevator.com` (and `www` if used) in **us-east-1**.
2. ACM shows the CNAME validation record → that's what goes in the Step‑1 request.
3. Once the CNAME is live, ACM status flips to **Issued** (minutes–hours).
4. Also ensure the **ap-southeast-1** cert exists for the ALB (if you re‑enable HTTPS on the ALB).

Set in `environments/yec-prod/terraform.tfvars`:
```
cloudfront_certificate_arn = "arn:aws:acm:us-east-1:<acct>:certificate/<id>"
cloudfront_aliases         = ["yomaelevator.com"]     # add "www.yomaelevator.com" if needed
alb_certificate_arn        = "arn:aws:acm:ap-southeast-1:<acct>:certificate/<id>"
enable_https               = true                      # once the ALB cert is ready
```

## Step 3 — Build the new CloudFront + WAF (Terraform)

Enable the `waf` and `cloudfront` modules in `main.tf` (uncomment), then:
```
terraform plan -out=tfplan
terraform apply "tfplan"
```
This creates: the WAFv2 WebACL (CLOUDFRONT scope, us-east-1) and the CloudFront
distribution (origin = new ALB, `web_acl_arn` = the WebACL, viewer cert = us-east-1 cert,
aliases = yomaelevator.com). **Adding the alias will fail while it's still on the OLD
distribution** — see Step 4.

## Step 4 — Free the alias from the OLD distribution

The alias `yomaelevator.com` can only be on one distribution. Either:
- **Move it (preferred, minimal gap):** `aws cloudfront associate-alias` moves the
  alias to the new distribution in one call (requires the new dist to have the cert +
  a matching alt-domain slot). Or
- **Remove-then-add:** remove `yomaelevator.com` from the OLD distribution's alternate
  domain names, then add it to the new one.

Until this is done, keep `cloudfront_aliases = []` on the new dist and test it via its
own `dxxxx.cloudfront.net` domain (Step 5).

## Step 5 — Test the new stack BEFORE touching public DNS

- Hit the new CloudFront default domain `https://<dist>.cloudfront.net` with a `Host:
  yomaelevator.com` header (curl `--resolve` or `-H "Host: ..."`), or a temporary test
  subdomain (`new.yomaelevator.com` → new CF).
- Verify: app loads, API works, DB connected, WAF not blocking legit traffic.

## Step 6 — Cutover (public DNS)

1. **Lower TTL** on the `yomaelevator.com` record to 60–300s a day ahead.
2. Complete Step 4 (alias on new dist).
3. Point `yomaelevator.com` at the **new** CloudFront:
   - Route 53: ALIAS A → new distribution.
   - Other registrar: update the CNAME/ALIAS to `<new-dist>.cloudfront.net`.
4. Watch: 5xx rate, WAF blocks, target health, app logs. Propagation minutes (with low TTL).

## Step 7 — After cutover

- Raise TTL back (3600s).
- Keep the OLD stack running a few days as instant rollback (just repoint DNS back).
- Decommission OLD only after a clean window (snapshot RDS first).

## Checkpoints

- [ ] us-east-1 cert = **Issued**; ap-southeast-1 cert Issued (if ALB HTTPS).
- [ ] New ECS services **healthy**, ALB target groups healthy.
- [ ] New CloudFront reachable via its default domain with correct app response.
- [ ] WAF WebACL attached; default action Allow; rate-limit not blocking normal use.
- [ ] Alias removed from OLD dist before adding to NEW.
- [ ] TTL lowered pre-cutover; rollback = repoint DNS to OLD.

## Best practice

- Validate everything on the new stack **before** the DNS change — DNS is the last switch.
- Keep ACM validation CNAMEs permanently (auto-renew).
- Prefer `dev.yomaelevator.com` over a separate `yomaelevator-dev.com` domain; lock dev
  down (WAF IP allow-list, auth, noindex).
- Redirect apex↔www consistently (pick canonical host) so the cert SANs match.
- Rollback is always "repoint DNS to the old distribution" — keep old alive until stable.
