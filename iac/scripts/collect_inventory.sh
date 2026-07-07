#!/usr/bin/env bash
###############################################################################
# collect_inventory.sh  (v2)
#
# Phase 1 — Read-only AWS inventory collector for the IaC migration.
#
# SAFETY CONTRACT (enforced by design):
#   * Uses ONLY  aws <svc> describe* / list* / get*  calls.
#   * ZERO mutating verbs (create/update/delete/modify/put/apply/run/start/stop).
#   * Never touches Terraform state. Secret & parameter VALUES are never read
#     (Secrets Manager / SSM = metadata only).
#
# v2 improvements over v1 (from architecture review):
#   1. Pagination     — CLI auto-pagination forced on (AWS_PAGER="", no --max-items).
#   2. Tag matching   — broad tag sweep; local match on tag KEY *or* VALUE.
#   3. Multi-region   — REGIONS is an array; global services collected once.
#   4. Parallelism    — domain collectors run concurrently, then `wait`.
#   5. More services  — capacity providers, target-health, CloudFront configs &
#                       policies, WAF get-web-acl, Route53 tags, ALL task-def
#                       revisions, ACM certificates, IAM list-entities-for-policy.
#   6. Layout         — inventory/{raw,filtered,reports,logs}/ + manifest.json.
#   7. Reports        — inventory-summary.md, missing-tags.md, manifest.json.
#
# Requirements: aws CLI v2, jq. Profile with read access (default KEVIN-ZYL).
#
# Usage:
#   ./collect_inventory.sh
#   AWS_PROFILE=KEVIN-ZYL REGIONS="ap-southeast-1 us-east-1" \
#       PREFIX=zyl-elevator-prod ./collect_inventory.sh
###############################################################################
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------
PROFILE="${AWS_PROFILE:-KEVIN-ZYL}"
# Space-separated list; add us-east-1 to capture ACM certs used by CloudFront.
read -r -a REGIONS <<< "${REGIONS:-ap-southeast-1}"
PRIMARY_REGION="${REGIONS[0]}"
PREFIX="${PREFIX:-zyl-elevator-prod}"
OUTDIR="${OUTDIR:-inventory}"
# CloudFront-scoped WAF and CloudFront APIs must be queried in us-east-1.
CF_REGION="us-east-1"

# Collection depth:
#   DEEP=0 (default) — FAST enumeration pass. One list/describe per service, enough
#                      to drive Terraformer (ids/names/arns/tags). Skips per-item
#                      config dumps and all runtime-only calls.
#   DEEP=1           — full per-item config export (audit / Phase-3 validation).
DEEP="${DEEP:-0}"
# Optional: restrict CloudWatch log-group enumeration to a name prefix to avoid
# paginating an account with thousands of groups, e.g. LOG_PREFIX=/ecs/zyl-elevator-prod
LOG_PREFIX="${LOG_PREFIX:-}"

# Force CLI auto-pagination (aggregates NextToken/Marker across ALL pages) and
# disable the pager so output is captured cleanly. Do NOT set --max-items.
export AWS_PAGER=""
LC_PREFIX="$(printf '%s' "$PREFIX" | tr 'A-Z' 'a-z')"

RAW="$OUTDIR/raw"; FILT="$OUTDIR/filtered"; REP="$OUTDIR/reports"; LOGDIR="$OUTDIR/logs"
mkdir -p "$RAW" "$FILT" "$REP" "$LOGDIR" "$OUTDIR/_meta"

# Single-instance lock (mkdir is atomic) — prevents accidental parallel launches
# from hammering the account and duplicating the log.
LOCK="$OUTDIR/_meta/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another collection appears to be running (lock: $LOCK)." >&2
  echo "If that's stale, remove it:  rm -rf '$LOCK'" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

# EC2 server-side tag filter: return only resources with ANY tag value (incl. the
# Name tag) containing the prefix. Drastically cuts data downloaded vs. dumping
# every VPC/subnet/SG in the account. (Untagged-but-named EC2 resources, if any,
# won't match — rare; use DEEP or add tags if you hit that.)
EC2FILTER=(--filters "Name=tag-value,Values=*$PREFIX*")

# Fresh run: clear previous raw/filtered/logs so stale files from earlier runs
# can't inflate counts or resurface old FAILs. (Only our own generated output —
# never AWS, never your source.)
rm -rf "$RAW" "$FILT"; mkdir -p "$RAW" "$FILT"
rm -f "$LOGDIR"/*.log 2>/dev/null || true

MAINLOG="$LOGDIR/collect.log"; : > "$MAINLOG"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# awsr <region> ... : regional read-only call
awsr() { local r="$1"; shift; aws --profile "$PROFILE" --region "$r" --output json "$@"; }
# awsg ...          : global service call (still needs a region endpoint)
awsg() { aws --profile "$PROFILE" --region "$PRIMARY_REGION" --output json "$@"; }

# grab <log> <relpath-no-ext> <jqpath-or-empty> -- <aws command...>
#   Writes raw/<relpath>.json; if jqpath given, also filtered/<relpath>.json
#   keeping only elements whose serialized JSON contains PREFIX (matches name,
#   tag key, tag value, arn, id — the OR filter in one pass).
grab() {
  local log="$1" rel="$2" jqpath="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local raw="$RAW/$rel.json" ferr; ferr="$(mktemp)"
  mkdir -p "$(dirname "$raw")"
  if "$@" > "$raw" 2>"$ferr"; then
    if [ -s "$raw" ]; then echo "  ok    $rel" >>"$log"; else echo "  empty $rel" >>"$log"; fi
  else
    echo "  FAIL  $rel :: $(tr '\n' ' ' <"$ferr" | cut -c1-160)" >>"$log"
    echo '{"_error":"command failed; see logs"}' > "$raw"
  fi
  rm -f "$ferr"
  if [ -n "$jqpath" ]; then
    local f="$FILT/$rel.json"; mkdir -p "$(dirname "$f")"
    jq --arg p "$LC_PREFIX" \
       "[ ($jqpath // [])[] | select( (tostring|ascii_downcase) | contains(\$p) ) ]" \
       "$raw" > "$f" 2>/dev/null || echo '[]' > "$f"
  fi
}

# names_matching <raw.json> <jq-field-expr> : list values containing PREFIX
names_matching() { jq -r "$2 // empty" "$1" 2>/dev/null | grep -i "$PREFIX" || true; }

# ============================================================================
# GLOBAL collectors (run once, not per-region)
# ============================================================================
collect_iam() {
  local L="$LOGDIR/iam.log"; : >"$L"; echo "[security] IAM (global)" >>"$L"
  grab "$L" "security/iam-roles"          ".Roles"    -- awsg iam list-roles
  grab "$L" "security/iam-policies-local" ".Policies" -- awsg iam list-policies --scope Local
  grab "$L" "security/iam-oidc-providers" ".OpenIDConnectProviderList" -- awsg iam list-open-id-connect-providers
  [ "$DEEP" = 1 ] || { echo "  (enum) skipping per-role/policy detail; set DEEP=1 for full export" >>"$L"; return 0; }

  local role
  while IFS= read -r role; do [ -z "$role" ] && continue
    grab "$L" "security/roles/$role"          "" -- awsg iam get-role --role-name "$role"
    grab "$L" "security/roles/$role-attached" "" -- awsg iam list-attached-role-policies --role-name "$role"
    grab "$L" "security/roles/$role-inline"   "" -- awsg iam list-role-policies --role-name "$role"
    local pn
    while IFS= read -r pn; do [ -z "$pn" ] && continue
      grab "$L" "security/roles/$role-inline-$pn" "" -- awsg iam get-role-policy --role-name "$role" --policy-name "$pn"
    done < <(jq -r '.PolicyNames[]?' "$RAW/security/roles/$role-inline.json" 2>/dev/null)
  done < <(names_matching "$RAW/security/iam-roles.json" '.Roles[]?.RoleName')

  local pa pn ver
  while IFS= read -r pa; do [ -z "$pa" ] && continue
    pn="${pa##*/}"
    grab "$L" "security/policies/$pn"           "" -- awsg iam get-policy --policy-arn "$pa"
    grab "$L" "security/policies/$pn-entities"  "" -- awsg iam list-entities-for-policy --policy-arn "$pa"
    ver="$(jq -r '.Policy.DefaultVersionId' "$RAW/security/policies/$pn.json" 2>/dev/null)"
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      grab "$L" "security/policies/$pn-doc" "" -- awsg iam get-policy-version --policy-arn "$pa" --version-id "$ver"
    fi
  done < <(names_matching "$RAW/security/iam-policies-local.json" '.Policies[]?.Arn')

  local o os
  while IFS= read -r o; do [ -z "$o" ] && continue
    os="$(echo "$o" | sed 's#.*/##; s#[/:]#_#g')"
    grab "$L" "security/oidc-$os" "" -- awsg iam get-open-id-connect-provider --open-id-connect-provider-arn "$o"
  done < <(jq -r '.OpenIDConnectProviderList[]?.Arn' "$RAW/security/iam-oidc-providers.json" 2>/dev/null)
}

collect_edge() {
  local L="$LOGDIR/edge.log"; : >"$L"; echo "[edge] CloudFront / WAF / Route53 (global)" >>"$L"
  # CloudFront (global; queried via us-east-1)
  grab "$L" "edge/cloudfront-distributions" ".DistributionList.Items" -- awsr "$CF_REGION" cloudfront list-distributions
  grab "$L" "edge/cf-cache-policies"            "" -- awsr "$CF_REGION" cloudfront list-cache-policies
  grab "$L" "edge/cf-origin-request-policies"   "" -- awsr "$CF_REGION" cloudfront list-origin-request-policies
  grab "$L" "edge/cf-response-headers-policies" "" -- awsr "$CF_REGION" cloudfront list-response-headers-policies
  # WAFv2 — CLOUDFRONT scope (us-east-1) + REGIONAL scope (primary region)
  grab "$L" "edge/wafv2-webacls-cloudfront" ".WebACLs" -- awsr "$CF_REGION" wafv2 list-web-acls --scope CLOUDFRONT
  grab "$L" "edge/wafv2-webacls-regional"   ".WebACLs" -- awsr "$PRIMARY_REGION" wafv2 list-web-acls --scope REGIONAL
  # Route53 hosted zones (enumeration)
  grab "$L" "edge/route53-hosted-zones" ".HostedZones" -- awsg route53 list-hosted-zones

  [ "$DEEP" = 1 ] || { echo "  (enum) skipping CF configs, WAF get-web-acl, R53 records; set DEEP=1 for full export" >>"$L"; return 0; }

  local did
  while IFS= read -r did; do [ -z "$did" ] && continue
    grab "$L" "edge/cf-dist-$did"        "" -- awsr "$CF_REGION" cloudfront get-distribution        --id "$did"
    grab "$L" "edge/cf-dist-$did-config" "" -- awsr "$CF_REGION" cloudfront get-distribution-config --id "$did"
  done < <(jq -r ".DistributionList.Items[]? | select((tostring|ascii_downcase)|contains(\"$LC_PREFIX\")) | .Id" "$RAW/edge/cloudfront-distributions.json" 2>/dev/null)

  local scope reg jqf
  for scope in CLOUDFRONT REGIONAL; do
    if [ "$scope" = CLOUDFRONT ]; then reg="$CF_REGION"; jqf="$RAW/edge/wafv2-webacls-cloudfront.json"; else reg="$PRIMARY_REGION"; jqf="$RAW/edge/wafv2-webacls-regional.json"; fi
    local wid wname
    while IFS=$'\t' read -r wid wname; do [ -z "$wid" ] && continue
      grab "$L" "edge/wafv2-webacl-$scope-$wname" "" -- awsr "$reg" wafv2 get-web-acl --scope "$scope" --id "$wid" --name "$wname"
    done < <(jq -r '.WebACLs[]? | [.Id,.Name] | @tsv' "$jqf" 2>/dev/null)
  done

  local z zid
  while IFS= read -r z; do [ -z "$z" ] && continue
    zid="${z#/hostedzone/}"
    grab "$L" "edge/route53-records-$zid" "" -- awsg route53 list-resource-record-sets --hosted-zone-id "$zid"
    grab "$L" "edge/route53-tags-$zid"    "" -- awsg route53 list-tags-for-resource --resource-type hostedzone --resource-id "$zid"
  done < <(jq -r '.HostedZones[]?.Id' "$RAW/edge/route53-hosted-zones.json" 2>/dev/null)
}

# ============================================================================
# REGIONAL collectors — each takes a region argument
# ============================================================================
collect_network() {
  local r="$1" L="$LOGDIR/network-$1.log"; : >"$L"; echo "[network][$r]" >>"$L"
  # Project-owned security groups (tag-matched).
  grab "$L" "network/$r/security-groups" ".SecurityGroups" -- awsr "$r" ec2 describe-security-groups "${EC2FILTER[@]}"
  # Identify the VPC(s): prefer tag-matched VPCs; otherwise infer from the SGs
  # (VPC/subnets are frequently untagged even when their resources are tagged).
  # NOTE: network resources below are scoped server-side by VPC id, so they are
  # already "the project set" — we do NOT prefix-filter them (the VPC itself is
  # often untagged / named differently, e.g. ZYL-Prod-VPC). jqpath is left empty
  # and raw is mirrored into filtered/ at the end.
  grab "$L" "network/$r/vpcs" "" -- awsr "$r" ec2 describe-vpcs "${EC2FILTER[@]}"
  local vpcids
  vpcids="$(jq -r '.Vpcs[]?.VpcId' "$RAW/network/$r/vpcs.json" 2>/dev/null | sort -u)"
  if [ -z "$vpcids" ]; then
    vpcids="$(jq -r '.SecurityGroups[]?.VpcId' "$RAW/network/$r/security-groups.json" 2>/dev/null | sort -u)"
    if [ -n "$vpcids" ]; then
      # shellcheck disable=SC2086
      grab "$L" "network/$r/vpcs" "" -- awsr "$r" ec2 describe-vpcs --vpc-ids $vpcids
      echo "  (info) VPC(s) inferred from security groups: $(echo $vpcids | tr '\n' ' ')" >>"$L"
    fi
  fi

  if [ -n "$vpcids" ]; then
    local vlist; vlist="$(echo "$vpcids" | paste -sd, -)"
    grab "$L" "network/$r/subnets"           "" -- awsr "$r" ec2 describe-subnets           --filters "Name=vpc-id,Values=$vlist"
    grab "$L" "network/$r/route-tables"      "" -- awsr "$r" ec2 describe-route-tables      --filters "Name=vpc-id,Values=$vlist"
    grab "$L" "network/$r/network-acls"      "" -- awsr "$r" ec2 describe-network-acls      --filters "Name=vpc-id,Values=$vlist"
    grab "$L" "network/$r/vpc-endpoints"     "" -- awsr "$r" ec2 describe-vpc-endpoints     --filters "Name=vpc-id,Values=$vlist"
    grab "$L" "network/$r/internet-gateways" "" -- awsr "$r" ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vlist"
    # NOTE: describe-nat-gateways uses --filter (singular), not --filters.
    grab "$L" "network/$r/nat-gateways"      "" -- awsr "$r" ec2 describe-nat-gateways      --filter "Name=vpc-id,Values=$vlist"
  else
    echo "  (warn) no VPC identified for $r; network resources skipped" >>"$L"
  fi
  grab "$L" "network/$r/eips" ".Addresses" -- awsr "$r" ec2 describe-addresses "${EC2FILTER[@]}"
  # Mirror the VPC-scoped raw files into filtered/ (they ARE the project set).
  mkdir -p "$FILT/network/$r"
  cp -f "$RAW/network/$r/"*.json "$FILT/network/$r/" 2>/dev/null || true
}

collect_compute() {
  local r="$1" L="$LOGDIR/compute-$1.log"; : >"$L"; echo "[compute][$r] ECS + autoscaling" >>"$L"
  grab "$L" "compute/$r/ecs-clusters-arns" "" -- awsr "$r" ecs list-clusters
  grab "$L" "compute/$r/ecs-capacity-providers" "" -- awsr "$r" ecs describe-capacity-providers
  local c cname
  while IFS= read -r c; do [ -z "$c" ] && continue
    cname="${c##*/}"
    grab "$L" "compute/$r/ecs-cluster-$cname" "" -- awsr "$r" ecs describe-clusters --clusters "$c" \
         --include ATTACHMENTS SETTINGS STATISTICS TAGS CONFIGURATIONS
    grab "$L" "compute/$r/ecs-services-arns-$cname" "" -- awsr "$r" ecs list-services --cluster "$c"
    SVCS=()  # init for Bash 3.2 + set -u
    while IFS= read -r _s; do [ -n "$_s" ] && SVCS+=("$_s"); done \
      < <(jq -r '.serviceArns[]?' "$RAW/compute/$r/ecs-services-arns-$cname.json" 2>/dev/null)
    local i=0
    while [ "$i" -lt "${#SVCS[@]}" ]; do
      grab "$L" "compute/$r/ecs-services-$cname-$i" "" -- awsr "$r" ecs describe-services --cluster "$c" \
           --services "${SVCS[@]:$i:10}" --include TAGS
      i=$((i+10))
    done
    # list-tasks is runtime state (not needed to clone) — DEEP only
    [ "$DEEP" = 1 ] && grab "$L" "compute/$r/ecs-tasks-$cname" "" -- awsr "$r" ecs list-tasks --cluster "$c"
  done < <(names_matching "$RAW/compute/$r/ecs-clusters-arns.json" '.clusterArns[]?')

  # Task definitions per matching family.
  #   enum : latest active revision only (what a clone needs)
  #   DEEP : every active revision (rollback history)
  grab "$L" "compute/$r/ecs-taskdef-families" "" -- awsr "$r" ecs list-task-definition-families --status ACTIVE
  local f arn as
  while IFS= read -r f; do [ -z "$f" ] && continue
    if [ "$DEEP" = 1 ]; then
      grab "$L" "compute/$r/ecs-taskdef-revisions-$f" "" -- awsr "$r" ecs list-task-definitions --family-prefix "$f" --status ACTIVE
      while IFS= read -r arn; do [ -z "$arn" ] && continue
        as="${arn##*/}"
        grab "$L" "compute/$r/ecs-taskdef-$as" "" -- awsr "$r" ecs describe-task-definition --task-definition "$arn" --include TAGS
      done < <(jq -r '.taskDefinitionArns[]?' "$RAW/compute/$r/ecs-taskdef-revisions-$f.json" 2>/dev/null)
    else
      # describe-task-definition on the family name resolves to the latest revision
      grab "$L" "compute/$r/ecs-taskdef-$f-latest" "" -- awsr "$r" ecs describe-task-definition --task-definition "$f" --include TAGS
    fi
  done < <(names_matching "$RAW/compute/$r/ecs-taskdef-families.json" '.families[]?')

  grab "$L" "compute/$r/appautoscaling-targets"  "" -- awsr "$r" application-autoscaling describe-scalable-targets  --service-namespace ecs
  grab "$L" "compute/$r/appautoscaling-policies" "" -- awsr "$r" application-autoscaling describe-scaling-policies  --service-namespace ecs
}

collect_lb() {
  local r="$1" L="$LOGDIR/loadbalancing-$1.log"; : >"$L"; echo "[loadbalancing][$r]" >>"$L"
  grab "$L" "loadbalancing/$r/load-balancers" ".LoadBalancers" -- awsr "$r" elbv2 describe-load-balancers
  grab "$L" "loadbalancing/$r/target-groups"  ".TargetGroups"  -- awsr "$r" elbv2 describe-target-groups
  # Listeners/rules are imported by Terraformer; target-health is runtime state.
  [ "$DEEP" = 1 ] || { echo "  (enum) skipping listeners/rules/attributes/target-health; set DEEP=1 for full export" >>"$L"; return 0; }
  local lb lbn ls lsid tg tgn
  while IFS= read -r lb; do [ -z "$lb" ] && continue
    lbn="$(echo "$lb" | sed 's#.*/##')"
    grab "$L" "loadbalancing/$r/lb-$lbn-attributes" "" -- awsr "$r" elbv2 describe-load-balancer-attributes --load-balancer-arn "$lb"
    grab "$L" "loadbalancing/$r/lb-$lbn-listeners" "" -- awsr "$r" elbv2 describe-listeners --load-balancer-arn "$lb"
    while IFS= read -r ls; do [ -z "$ls" ] && continue
      lsid="$(echo "$ls" | sed 's#.*/##')"
      grab "$L" "loadbalancing/$r/lb-$lbn-listener-$lsid-rules" "" -- awsr "$r" elbv2 describe-rules --listener-arn "$ls"
    done < <(jq -r '.Listeners[]?.ListenerArn' "$RAW/loadbalancing/$r/lb-$lbn-listeners.json" 2>/dev/null)
  done < <(jq -r ".LoadBalancers[]? | select((tostring|ascii_downcase)|contains(\"$LC_PREFIX\")) | .LoadBalancerArn" "$RAW/loadbalancing/$r/load-balancers.json" 2>/dev/null)
  # Target health for matching target groups (validates ECS registrations)
  while IFS= read -r tg; do [ -z "$tg" ] && continue
    tgn="$(echo "$tg" | sed 's#.*/##')"
    grab "$L" "loadbalancing/$r/tg-$tgn-health" "" -- awsr "$r" elbv2 describe-target-health --target-group-arn "$tg"
  done < <(jq -r ".TargetGroups[]? | select((tostring|ascii_downcase)|contains(\"$LC_PREFIX\")) | .TargetGroupArn" "$RAW/loadbalancing/$r/target-groups.json" 2>/dev/null)
}

collect_db() {
  local r="$1" L="$LOGDIR/database-$1.log"; : >"$L"; echo "[database][$r] RDS + ElastiCache" >>"$L"
  grab "$L" "database/$r/rds-instances"        ".DBInstances"      -- awsr "$r" rds describe-db-instances
  grab "$L" "database/$r/rds-clusters"         ".DBClusters"       -- awsr "$r" rds describe-db-clusters
  grab "$L" "database/$r/rds-subnet-groups"    ".DBSubnetGroups"   -- awsr "$r" rds describe-db-subnet-groups
  grab "$L" "database/$r/rds-parameter-groups" ".DBParameterGroups" -- awsr "$r" rds describe-db-parameter-groups
  grab "$L" "database/$r/elasticache-clusters"            ".CacheClusters"     -- awsr "$r" elasticache describe-cache-clusters --show-cache-node-info
  grab "$L" "database/$r/elasticache-replication-groups"  ".ReplicationGroups" -- awsr "$r" elasticache describe-replication-groups
  grab "$L" "database/$r/elasticache-subnet-groups"       ".CacheSubnetGroups" -- awsr "$r" elasticache describe-cache-subnet-groups
}

collect_storage() {
  local r="$1" L="$LOGDIR/storage-$1.log"; : >"$L"; echo "[storage][$r] S3 + ECR" >>"$L"
  # S3 is global; collect only once (on the primary region pass).
  if [ "$r" = "$PRIMARY_REGION" ]; then
    grab "$L" "storage/s3-buckets" ".Buckets" -- awsr "$r" s3api list-buckets
    local b
    [ "$DEEP" = 1 ] && while IFS= read -r b; do [ -z "$b" ] && continue
      grab "$L" "storage/s3/$b-location"     "" -- awsr "$r" s3api get-bucket-location             --bucket "$b"
      grab "$L" "storage/s3/$b-policy"       "" -- awsr "$r" s3api get-bucket-policy               --bucket "$b"
      grab "$L" "storage/s3/$b-acl"          "" -- awsr "$r" s3api get-bucket-acl                  --bucket "$b"
      grab "$L" "storage/s3/$b-encryption"   "" -- awsr "$r" s3api get-bucket-encryption           --bucket "$b"
      grab "$L" "storage/s3/$b-versioning"   "" -- awsr "$r" s3api get-bucket-versioning           --bucket "$b"
      grab "$L" "storage/s3/$b-lifecycle"    "" -- awsr "$r" s3api get-bucket-lifecycle-configuration --bucket "$b"
      grab "$L" "storage/s3/$b-cors"         "" -- awsr "$r" s3api get-bucket-cors                 --bucket "$b"
      grab "$L" "storage/s3/$b-tagging"      "" -- awsr "$r" s3api get-bucket-tagging              --bucket "$b"
      grab "$L" "storage/s3/$b-publicaccess" "" -- awsr "$r" s3api get-public-access-block         --bucket "$b"
      grab "$L" "storage/s3/$b-website"      "" -- awsr "$r" s3api get-bucket-website              --bucket "$b"
    done < <(names_matching "$RAW/storage/s3-buckets.json" '.Buckets[]?.Name')
  fi
  # ECR is regional
  grab "$L" "storage/$r/ecr-repositories" ".repositories" -- awsr "$r" ecr describe-repositories
  local repo rs
  [ "$DEEP" = 1 ] && while IFS= read -r repo; do [ -z "$repo" ] && continue
    rs="$(echo "$repo" | tr '/' '_')"
    grab "$L" "storage/$r/ecr-$rs-policy"    "" -- awsr "$r" ecr get-repository-policy --repository-name "$repo"
    grab "$L" "storage/$r/ecr-$rs-lifecycle" "" -- awsr "$r" ecr get-lifecycle-policy  --repository-name "$repo"
  done < <(names_matching "$RAW/storage/$r/ecr-repositories.json" '.repositories[]?.repositoryName')
}

collect_security_regional() {
  local r="$1" L="$LOGDIR/security-$1.log"; : >"$L"; echo "[security][$r] Secrets/SSM/KMS/ACM (metadata only)" >>"$L"
  # Secrets Manager — metadata only; get-secret-value is intentionally NOT called
  grab "$L" "security/$r/secrets-list" ".SecretList" -- awsr "$r" secretsmanager list-secrets
  # SSM Parameter Store — metadata only (values NOT read), server-side name filter
  grab "$L" "security/$r/ssm-parameters" ".Parameters" -- awsr "$r" ssm describe-parameters \
       --parameter-filters "Key=Name,Option=Contains,Values=$PREFIX"
  # KMS + ACM enumeration
  grab "$L" "security/$r/kms-keys"    ""        -- awsr "$r" kms list-keys
  grab "$L" "security/$r/kms-aliases" ".Aliases" -- awsr "$r" kms list-aliases
  grab "$L" "security/$r/acm-certificates" ".CertificateSummaryList" -- awsr "$r" acm list-certificates

  [ "$DEEP" = 1 ] || { echo "  (enum) skipping secret/kms/acm per-item detail; set DEEP=1 for full export" >>"$L"; return 0; }

  local s ss
  while IFS= read -r s; do [ -z "$s" ] && continue
    ss="$(echo "$s" | tr '/' '_')"
    grab "$L" "security/$r/secret-$ss" "" -- awsr "$r" secretsmanager describe-secret --secret-id "$s"
  done < <(names_matching "$RAW/security/$r/secrets-list.json" '.SecretList[]?.Name')
  local k
  while IFS= read -r k; do [ -z "$k" ] && continue
    grab "$L" "security/$r/kms-key-$k"        "" -- awsr "$r" kms describe-key    --key-id "$k"
    grab "$L" "security/$r/kms-key-$k-policy" "" -- awsr "$r" kms get-key-policy  --key-id "$k" --policy-name default
  done < <(jq -r ".Aliases[]? | select((.AliasName|ascii_downcase)|contains(\"$LC_PREFIX\")) | .TargetKeyId" "$RAW/security/$r/kms-aliases.json" 2>/dev/null)
  local ca cs
  while IFS= read -r ca; do [ -z "$ca" ] && continue
    cs="${ca##*/}"
    grab "$L" "security/$r/acm-cert-$cs" "" -- awsr "$r" acm describe-certificate --certificate-arn "$ca"
  done < <(jq -r '.CertificateSummaryList[]?.CertificateArn' "$RAW/security/$r/acm-certificates.json" 2>/dev/null)
}

collect_monitoring() {
  local r="$1" L="$LOGDIR/monitoring-$1.log"; : >"$L"; echo "[monitoring][$r] CloudWatch + SNS" >>"$L"
  grab "$L" "monitoring/$r/cw-alarms"     ".MetricAlarms" -- awsr "$r" cloudwatch describe-alarms
  # Log groups: only collected when scoped by LOG_PREFIX (an unscoped
  # describe-log-groups pulls the whole account and is slow/noisy). Skipped otherwise.
  if [ -n "$LOG_PREFIX" ]; then
    grab "$L" "monitoring/$r/cw-log-groups" ".logGroups" -- awsr "$r" logs describe-log-groups --log-group-name-prefix "$LOG_PREFIX"
  else
    echo "  (skip) cw-log-groups: set LOG_PREFIX=/ecs/$PREFIX to collect" >>"$L"
  fi
  grab "$L" "monitoring/$r/cw-dashboards" ".DashboardEntries" -- awsr "$r" cloudwatch list-dashboards
  grab "$L" "monitoring/$r/sns-topics"        ".Topics" -- awsr "$r" sns list-topics
  grab "$L" "monitoring/$r/sns-subscriptions" ".Subscriptions" -- awsr "$r" sns list-subscriptions
}

# ============================================================================
# Driver
# ============================================================================
{
  echo "AWS inventory collection (v2)"
  echo "  profile=$PROFILE  regions=${REGIONS[*]}  prefix=$PREFIX"
  echo "  mode=$([ "$DEEP" = 1 ] && echo 'DEEP (full config)' || echo 'enum (fast; DEEP=1 for full)')"
  echo "  started=$(date -u +%FT%TZ)"
} | tee -a "$MAINLOG"

# Authenticate first (read-only).
if ! awsr "$PRIMARY_REGION" sts get-caller-identity > "$OUTDIR/_meta/caller-identity.json" 2>"$OUTDIR/_meta/.err"; then
  echo "FATAL: cannot authenticate with profile '$PROFILE'." | tee -a "$MAINLOG"
  cat "$OUTDIR/_meta/.err" | tee -a "$MAINLOG"; rm -f "$OUTDIR/_meta/.err"; exit 1
fi
echo "Authenticated as: $(jq -r '.Arn' "$OUTDIR/_meta/caller-identity.json")" | tee -a "$MAINLOG"

# Tag sweep — cheap cross-service map of prefix-tagged resources. We DON'T dump
# the whole account here; the per-service collectors below do the enumeration.
# (Kept because it's a single call and handy for cross-checking the manifest.)
awsr "$PRIMARY_REGION" resourcegroupstaggingapi get-resources \
    --tag-filters "Key=Project,Values=$PREFIX" > "$RAW/tagged-resources.json" 2>/dev/null \
  || echo '{"ResourceTagMappingList":[]}' > "$RAW/tagged-resources.json"
jq '[ (.ResourceTagMappingList // [])[] ]' "$RAW/tagged-resources.json" \
  > "$FILT/tagged-resources.json" 2>/dev/null || echo '[]' > "$FILT/tagged-resources.json"

echo "Collecting (parallel domains)…" | tee -a "$MAINLOG"

# Global collectors (once).
collect_iam &
collect_edge &

# Regional collectors — one parallel fan-out per region.
for r in "${REGIONS[@]}"; do
  collect_network "$r" &
  collect_compute "$r" &
  collect_lb "$r" &
  collect_db "$r" &
  collect_storage "$r" &
  collect_security_regional "$r" &
  collect_monitoring "$r" &
done

wait
# Fold per-domain logs into the main log (exclude the main log itself).
find "$LOGDIR" -maxdepth 1 -name '*.log' ! -name 'collect.log' -exec cat {} + >> "$MAINLOG" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Reports + manifest
# ----------------------------------------------------------------------------
flen() { jq 'length' "$1" 2>/dev/null || echo 0; }
sum_glob() { local t=0 f; for f in $1; do [ -f "$f" ] && t=$((t + $(flen "$f"))); done; echo "$t"; }
# For network files (JSON objects like {"Vpcs":[...]}) count the array at <path>.
netcount() { local t=0 f; for f in $1; do [ -f "$f" ] && t=$((t + $(jq "(${2})|length" "$f" 2>/dev/null || echo 0))); done; echo "$t"; }

VPCS=$(netcount "$RAW/network/*/vpcs.json" ".Vpcs")
SUBNETS=$(netcount "$RAW/network/*/subnets.json" ".Subnets")
SGS=$(netcount "$RAW/network/*/security-groups.json" ".SecurityGroups")
ALBS=$(sum_glob "$FILT/loadbalancing/*/load-balancers.json")
TGS=$(sum_glob "$FILT/loadbalancing/*/target-groups.json")
CLUSTERS=$(ls "$RAW"/compute/*/ecs-cluster-*.json 2>/dev/null | wc -l | tr -d ' ')
SERVICES=0
for f in "$RAW"/compute/*/ecs-services-*-*.json; do
  [ -f "$f" ] && SERVICES=$((SERVICES + $(jq '[.services[]?]|length' "$f" 2>/dev/null || echo 0)))
done
TASKDEFS=$(find "$RAW"/compute -type f -name 'ecs-taskdef-*.json' 2>/dev/null | grep -vE 'families|revisions' | sort -u | wc -l | tr -d ' ')
RDS=$(sum_glob "$FILT/database/*/rds-instances.json")
RDSCLU=$(sum_glob "$FILT/database/*/rds-clusters.json")
REDIS=$(sum_glob "$FILT/database/*/elasticache-replication-groups.json")
S3=$(flen "$FILT/storage/s3-buckets.json")
ECR=$(sum_glob "$FILT/storage/*/ecr-repositories.json")
CF=$(flen "$FILT/edge/cloudfront-distributions.json")
ROLES=$(flen "$FILT/security/iam-roles.json")
SECRETS=$(sum_glob "$FILT/security/*/secrets-list.json")
ALARMS=$(sum_glob "$FILT/monitoring/*/cw-alarms.json")
LOGGRP=$(sum_glob "$FILT/monitoring/*/cw-log-groups.json")

cat > "$OUTDIR/manifest.json" <<EOF
{
  "profile": "$PROFILE",
  "regions": "$(printf '%s' "${REGIONS[*]}")",
  "prefix": "$PREFIX",
  "generatedAt": "$(date -u +%FT%TZ)",
  "counts": {
    "VPC": $VPCS, "Subnets": $SUBNETS, "SecurityGroups": $SGS,
    "ALB": $ALBS, "TargetGroups": $TGS,
    "ECSClusters": $CLUSTERS, "Services": ${SERVICES:-0}, "TaskDefinitions": ${TASKDEFS:-0},
    "RDSInstances": $RDS, "RDSClusters": $RDSCLU, "Redis": $REDIS,
    "S3Buckets": ${S3:-0}, "ECRRepositories": $ECR,
    "CloudFront": $CF, "IAMRoles": $ROLES, "Secrets": $SECRETS,
    "CloudWatchAlarms": $ALARMS, "LogGroups": $LOGGRP
  }
}
EOF

{
  echo "# Inventory Summary — $PREFIX"
  echo
  echo "Generated: $(date -u +%FT%TZ)  ·  Profile: \`$PROFILE\`  ·  Regions: \`${REGIONS[*]}\`"
  echo
  echo "| Resource | Count |"
  echo "|---|---|"
  jq -r '.counts | to_entries[] | "| \(.key) | \(.value) |"' "$OUTDIR/manifest.json"
  echo
  echo "Counts reflect the filtered set (name/tag contains \`$PREFIX\`). Raw dumps are in \`raw/\`."
} > "$REP/inventory-summary.md"

# missing-tags: resources matched by NAME/ARN but whose tags do NOT contain the
# prefix — flags inconsistent tagging that will complicate Terraform import.
{
  echo "# Missing / Inconsistent Tags — $PREFIX"
  echo
  echo "Resources whose identity matches \`$PREFIX\` but whose tag set does not"
  echo "contain the prefix. Review before import — tagging drives module inputs."
  echo
  echo "| Type | Identifier |"
  echo "|---|---|"
  for f in "$FILT"/network/*/vpcs.json "$FILT"/network/*/subnets.json \
           "$FILT"/network/*/security-groups.json "$FILT"/loadbalancing/*/load-balancers.json \
           "$FILT"/database/*/rds-instances.json; do
    [ -f "$f" ] || continue
    jq -r --arg p "$LC_PREFIX" '.[]?
      | select( ((.Tags // [] | tostring | ascii_downcase) | contains($p)) | not )
      | [ (.VpcId // .SubnetId // .GroupId // .LoadBalancerName // .DBInstanceIdentifier // "?") ]
      | "| resource | \(.[0]) |"' "$f" 2>/dev/null
  done
} > "$REP/missing-tags.md"

{
  echo; echo "finished=$(date -u +%FT%TZ)"
  echo "FAIL lines: $(grep -c 'FAIL ' "$MAINLOG" 2>/dev/null || echo 0)"
  echo "output=$OUTDIR/  (raw/ filtered/ reports/ logs/ manifest.json)"
} | tee -a "$MAINLOG"
rm -f "$OUTDIR/_meta/.err"
echo "Done. See $REP/inventory-summary.md and $OUTDIR/manifest.json"
