#!/usr/bin/env bash
###############################################################################
# export_terraform.sh  — Phase 2: export existing AWS infra with Terraformer
#
# SAFETY CONTRACT:
#   * EXPORT ONLY. Runs `terraformer import` (read-only against AWS) + `terraform
#     init` for the provider plugin. It NEVER runs plan/apply/destroy and issues
#     NO create/update/delete AWS calls.
#   * Writes the pristine export to generated/terraformer/ — do not edit it.
#
# Driven off the Phase-1 inventory: the target VPC id is read from
# inventory/, so network resources are scoped to the project's VPC.
#
# Usage:
#   AWS_PROFILE=KEVIN-ZYL ./scripts/export_terraform.sh
#   FILTER=none ./scripts/export_terraform.sh      # export all region resources
###############################################################################
set -uo pipefail

PROFILE="${AWS_PROFILE:-KEVIN-ZYL}"
REGION="${REGION:-ap-southeast-1}"
PREFIX="${PREFIX:-zyl-elevator-prod}"
FILTER="${FILTER:-tag}"          # tag | vpc | none
INVDIR="${INVDIR:-inventory}"
OUT="generated/terraformer"

# Terraformer AWS resource groups, split into REGIONAL and GLOBAL passes.
# They MUST run as separate terraformer invocations: terraformer's global pass
# (iam/cloudfront/route53) leaks its global region into the regional clients,
# which then sign for aws-global/us-east-1 and import 0 regional resources.
# NOTE: wafv2 is NOT supported by terraformer 0.8.30 — rebuilt by hand in Phase 4.
REG_RESOURCES="${REG_RESOURCES:-vpc,subnet,route_table,igw,nat,sg,nacl,eip,\
elb,alb,ecs,rds,elasticache,s3,ecr,sns,cloudwatch,logs,acm,kms}"
GLOB_RESOURCES="${GLOB_RESOURCES:-iam,cloudfront,route53}"

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------------"; }

# ----------------------------------------------------------------------------
# Preflight: tools
# ----------------------------------------------------------------------------
missing=0
if ! command -v terraform >/dev/null 2>&1; then
  missing=1
  say "MISSING: terraform"
  say "  macOS: brew tap hashicorp/tap && brew install hashicorp/tap/terraform"
fi
if ! command -v terraformer >/dev/null 2>&1; then
  missing=1
  say "MISSING: terraformer"
  say "  macOS: brew install terraformer"
  say "  (or)   https://github.com/GoogleCloudPlatform/terraformer/releases"
fi
if [ "$missing" = 1 ]; then
  hr; say "Install the tools above, then re-run this script. Nothing was changed."
  exit 1
fi
say "terraform:  $(terraform version | head -1)"
say "terraformer: $(terraformer version 2>/dev/null | head -1)"
hr

# ----------------------------------------------------------------------------
# Provider plugin (terraformer needs it available via terraform init)
# ----------------------------------------------------------------------------
mkdir -p "$OUT"
if [ ! -f "$OUT/versions.tf" ]; then
  cat > "$OUT/versions.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
provider "aws" {}
EOF
fi
say "Initialising AWS provider plugin (no state changes)…"
( cd "$OUT" && terraform init -input=false -backend=false >/dev/null ) \
  || { say "terraform init failed"; exit 1; }

# Terraformer (0.8.x) looks for the provider under ~/.terraform.d/plugins, but
# modern terraform init puts it under $OUT/.terraform/providers. Bridge them by
# symlinking the downloaded binary into both the legacy and versioned locations.
PLATFORM="$(terraform version -json 2>/dev/null | jq -r '.platform // empty')"
[ -z "$PLATFORM" ] && PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
PROV_BIN="$(find "$OUT/.terraform/providers" -type f -name 'terraform-provider-aws*' 2>/dev/null | head -1)"
if [ -n "$PROV_BIN" ]; then
  # Absolute path — a relative symlink target would resolve against the symlink's
  # own directory (~/.terraform.d/...) and dangle.
  PROV_ABS="$(cd "$(dirname "$PROV_BIN")" && pwd -P)/$(basename "$PROV_BIN")"
  PVER="$(printf '%s' "$PROV_BIN" | sed -E 's#.*/aws/([0-9][0-9.]*)/.*#\1#')"
  PBASE="$HOME/.terraform.d/plugins"
  mkdir -p "$PBASE/$PLATFORM" "$PBASE/registry.terraform.io/hashicorp/aws/$PVER/$PLATFORM"
  ln -sf "$PROV_ABS" "$PBASE/$PLATFORM/"
  ln -sf "$PROV_ABS" "$PBASE/registry.terraform.io/hashicorp/aws/$PVER/$PLATFORM/"
  say "Bridged AWS provider v$PVER ($PLATFORM) for terraformer."
else
  say "WARN: could not locate the downloaded AWS provider binary; terraformer may"
  say "      fail with a plugins path error. See generated/terraformer/.terraform/."
fi

# ----------------------------------------------------------------------------
# Preflight: profile MUST have a region. Terraformer 0.8.30 builds its AWS
# clients from the profile's configured region (it ignores --regions / AWS_REGION
# for client construction). Without it, regional calls hit us-east-1 / aws-global
# and return 0 resources.
# ----------------------------------------------------------------------------
PROFILE_REGION="$(aws configure get region --profile "$PROFILE" 2>/dev/null)"
if [ -z "$PROFILE_REGION" ]; then
  say "MISSING: profile '$PROFILE' has no region set — terraformer will import 0"
  say "regional resources. Fix it once (writes ~/.aws/config only, no AWS change):"
  say ""
  say "    aws configure set region $REGION --profile $PROFILE"
  say ""
  say "Then re-run this script."
  exit 1
elif [ "$PROFILE_REGION" != "$REGION" ]; then
  say "NOTE: profile region is '$PROFILE_REGION' but you asked for '$REGION'."
  say "      Terraformer will use the profile region. Align them if unintended:"
  say "      aws configure set region $REGION --profile $PROFILE"
fi

# ----------------------------------------------------------------------------
# Build the Terraformer filter
# ----------------------------------------------------------------------------
FILTER_ARGS=()
case "$FILTER" in
  tag)
    # Only resources tagged Project=<prefix>. NOTE: untagged network resources
    # won't match; use FILTER=vpc or FILTER=none if the plan looks short.
    FILTER_ARGS=(--filter="Name=tags.Project;Value=$PREFIX")
    say "Filter: tag Project=$PREFIX"
    ;;
  vpc)
    VPCID="$(jq -r '.Vpcs[0].VpcId // empty' "$INVDIR"/raw/network/"$REGION"/vpcs.json 2>/dev/null)"
    if [ -z "$VPCID" ]; then say "Could not read VPC id from inventory; run Phase 1 first."; exit 1; fi
    FILTER_ARGS=(--filter="vpc=$VPCID")
    say "Filter: vpc=$VPCID"
    ;;
  none)
    say "Filter: none (all $REGION resources of the selected types)"
    ;;
  *) say "Unknown FILTER='$FILTER' (use tag|vpc|none)"; exit 1;;
esac

# ----------------------------------------------------------------------------
# Export (read-only import) — two isolated passes.
# ----------------------------------------------------------------------------
run_pass() {  # <label> <resources-csv>
  local label="$1" res="$2"
  hr
  say "Pass: $label  (resources: $res)"
  hr
  # shellcheck disable=SC2086
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
  terraformer import aws \
    --resources="$res" \
    --regions="$REGION" \
    --profile="$PROFILE" \
    --path-output="$OUT" \
    --compact \
    ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}
  return $?
}

# REGIONAL pass FIRST, in its own process, so no global region context leaks in.
run_pass "regional" "$REG_RESOURCES"; rc_reg=$?
# GLOBAL pass SECOND, separate process.
run_pass "global"   "$GLOB_RESOURCES"; rc_glob=$?

hr
if [ "$rc_reg" -eq 0 ] && [ "$rc_glob" -eq 0 ]; then
  say "Export complete. Pristine files in $OUT/ — DO NOT EDIT them."
  say "Next: Phase 3 — analyse the export against inventory/ (reports/analysis.md)."
else
  say "One or more passes failed (regional=$rc_reg global=$rc_glob). Partial output in $OUT/."
  say "Check the 'Number of resources' lines above; a service showing 0 that should"
  say "have data is the one to isolate (re-run with REG_RESOURCES=that_service)."
fi
[ "$rc_reg" -eq 0 ] && [ "$rc_glob" -eq 0 ]
