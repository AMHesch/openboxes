#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
region=us-east-1
expected_account=077510937834
network_stack=openboxes-demo-network
data_stack=openboxes-demo-data
app_stack=openboxes-demo-app
app_image_uri="${APP_IMAGE_URI:-}"
desired_count="${DESIRED_COUNT:-1}"
tags=(
  Project=openboxes-demo
  Environment=dev
  Purpose=temporary-demo
  Owner=AMHesch
  ManagedBy=cloudformation
  DeleteAfter=2026-10-31
)
stack_templates=("$network_stack:network.yaml" "$data_stack:data.yaml")

if [[ -n "$app_image_uri" ]]; then
  if [[ ! "$app_image_uri" =~ @sha256:[[:xdigit:]]{64}$ ]]; then
    printf 'APP_IMAGE_URI must be an ECR digest URI: %s\n' "$app_image_uri" >&2
    exit 1
  fi
  if [[ ! "$desired_count" =~ ^[0-9]+$ ]]; then
    printf 'DESIRED_COUNT must be a non-negative integer: %s\n' "$desired_count" >&2
    exit 1
  fi
  stack_templates+=("$app_stack:app.yaml")
fi

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

print_command aws sts get-caller-identity --region "$region" --query Account --output text
account="$(aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing deployment in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

if [[ "${SKIP_PREFLIGHT:-}" == "1" ]]; then
  echo 'Skipping infrastructure preflight because SKIP_PREFLIGHT=1'
else
  print_command "$script_dir/preflight.sh"
  "$script_dir/preflight.sh"
fi

for stack_template in "${stack_templates[@]}"; do
  stack_name="${stack_template%%:*}"
  template_name="${stack_template#*:}"
  command=(
    aws cloudformation deploy
    --template-file "$script_dir/$template_name"
    --stack-name "$stack_name"
    --region "$region"
    --no-fail-on-empty-changeset
    --capabilities CAPABILITY_NAMED_IAM
    --tags "${tags[@]}"
  )
  if [[ "$stack_name" == "$app_stack" ]]; then
    command+=(--parameter-overrides "ImageUri=$app_image_uri" "DesiredCount=$desired_count")
  fi
  if [[ "$stack_name" != "$network_stack" && "${DISABLE_ROLLBACK:-}" == "1" ]]; then
    command+=(--disable-rollback)
  fi
  print_command "${command[@]}"
  "${command[@]}"
  output_command=(
    aws cloudformation describe-stacks
    --stack-name "$stack_name"
    --region "$region"
    --query 'Stacks[0].Outputs'
    --output table
  )
  print_command "${output_command[@]}"
  "${output_command[@]}"
done
