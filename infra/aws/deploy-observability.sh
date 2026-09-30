#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
region=us-east-1
expected_account=077510937834
app_stack=openboxes-demo-app
observability_stack=openboxes-demo-observability
template="$script_dir/observability.yaml"
location_id="${LOCATION_ID:-1}"
webhook_url="${WEBHOOK_URL:-}"
probe_state="${PROBE_STATE:-ENABLED}"

tags=(
  Project=openboxes-demo
  Environment=dev
  Purpose=temporary-demo
  Owner=AMHesch
  ManagedBy=cloudformation
  DeleteAfter=2026-10-31
)

print_command() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run_capture() {
  print_command "$@"
  "$@"
}

if [[ ! -f "$template" ]]; then
  printf 'Template not found: %s\n' "$template" >&2
  exit 1
fi
if [[ ! "$location_id" =~ ^[0-9]+$ ]]; then
  printf 'LOCATION_ID must be a numeric location id: %s\n' "$location_id" >&2
  exit 1
fi
if [[ "$probe_state" != ENABLED && "$probe_state" != DISABLED ]]; then
  printf 'PROBE_STATE must be ENABLED or DISABLED: %s\n' "$probe_state" >&2
  exit 1
fi

account="$(run_capture aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing observability deployment in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

app_url="$(run_capture aws cloudformation describe-stacks \
  --stack-name "$app_stack" \
  --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='AppUrl'].OutputValue | [0]" \
  --output text)"
alb_dns_name="$(run_capture aws cloudformation describe-stacks \
  --stack-name "$app_stack" \
  --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue | [0]" \
  --output text)"
if [[ -z "$app_url" || "$app_url" == None || -z "$alb_dns_name" || "$alb_dns_name" == None ]]; then
  echo 'The app stack must provide AppUrl and AlbDnsName outputs.' >&2
  exit 1
fi

alb_arn="$(run_capture aws elbv2 describe-load-balancers \
  --region "$region" \
  --query "LoadBalancers[?DNSName=='$alb_dns_name'].LoadBalancerArn | [0]" \
  --output text)"
if [[ -z "$alb_arn" || "$alb_arn" == None ]]; then
  printf 'Could not resolve an ALB ARN for %s\n' "$alb_dns_name" >&2
  exit 1
fi
alb_full_name="${alb_arn#*loadbalancer/}"

target_group_arn="$(run_capture aws elbv2 describe-target-groups \
  --load-balancer-arn "$alb_arn" \
  --region "$region" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)"
if [[ -z "$target_group_arn" || "$target_group_arn" == None ]]; then
  printf 'Could not resolve a target group for %s\n' "$alb_arn" >&2
  exit 1
fi
target_group_full_name="targetgroup/${target_group_arn#*targetgroup/}"

if [[ -n "$webhook_url" ]]; then
  if ! aws secretsmanager describe-secret \
    --secret-id openboxes-demo/devin-webhook \
    --region "$region" \
    --query ARN \
    --output text >/dev/null; then
    echo 'WEBHOOK_URL is set but openboxes-demo/devin-webhook does not exist.' >&2
    exit 1
  fi
  echo 'WEBHOOK_URL is set; the webhook URL is redacted from command output.' >&2
fi

if [[ "${SKIP_PREFLIGHT:-}" == "1" ]]; then
  echo 'Skipping infrastructure preflight because SKIP_PREFLIGHT=1' >&2
else
  run_capture "$script_dir/preflight.sh"
fi

command=(
  aws cloudformation deploy
  --template-file "$template"
  --stack-name "$observability_stack"
  --region "$region"
  --no-fail-on-empty-changeset
  --capabilities CAPABILITY_NAMED_IAM
  --parameter-overrides
  "AppUrl=$app_url"
  "AlbFullName=$alb_full_name"
  "TargetGroupFullName=$target_group_full_name"
  "LocationId=$location_id"
  "WebhookUrl=$webhook_url"
  "ProbeState=$probe_state"
  --tags "${tags[@]}"
)
if [[ -n "$webhook_url" ]]; then
  echo '+ aws cloudformation deploy ... WebhookUrl=<redacted>' >&2
  "${command[@]}"
else
  run_capture "${command[@]}"
fi

run_capture aws cloudformation describe-stacks \
  --stack-name "$observability_stack" \
  --region "$region" \
  --query 'Stacks[0].Outputs' \
  --output table
