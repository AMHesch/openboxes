#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
region=us-east-1
expected_account=077510937834
data_stack=openboxes-demo-data
app_stack=openboxes-demo-app
force_restore=0

if [[ "${1:-}" == "--force" ]]; then
  force_restore=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo 'Usage: migrate.sh [--force]' >&2
  exit 2
fi

for tool in aws docker gzip sed mktemp date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 127
  fi
done

account="$(aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing migration in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

app_status="$(aws cloudformation describe-stacks \
  --stack-name "$app_stack" \
  --region "$region" \
  --query 'Stacks[0].StackStatus' \
  --output text)"
if [[ "$app_status" != CREATE_COMPLETE && "$app_status" != UPDATE_COMPLETE ]]; then
  printf 'App stack must be deployed before migration; current status is %s\n' "$app_status" >&2
  exit 1
fi

desired_count="$(aws cloudformation describe-stacks \
  --stack-name "$app_stack" \
  --region "$region" \
  --query "Stacks[0].Parameters[?ParameterKey=='DesiredCount'].ParameterValue | [0]" \
  --output text)"
if [[ "$desired_count" != 0 ]]; then
  printf 'Refusing cutover unless DesiredCount is 0; current value is %s\n' "$desired_count" >&2
  exit 1
fi

uploads_bucket="$(aws cloudformation describe-stacks \
  --stack-name "$data_stack" \
  --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='UploadsBucket'].OutputValue | [0]" \
  --output text)"
image_uri="$(aws cloudformation describe-stacks \
  --stack-name "$app_stack" \
  --region "$region" \
  --query "Stacks[0].Parameters[?ParameterKey=='ImageUri'].ParameterValue | [0]" \
  --output text)"
cluster="$(aws cloudformation describe-stacks \
  --stack-name "$data_stack" \
  --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue | [0]" \
  --output text)"
if [[ -z "$uploads_bucket" || "$uploads_bucket" == None ||
      -z "$image_uri" || "$image_uri" == None ||
      -z "$cluster" || "$cluster" == None ]]; then
  echo 'Required data/app stack value is missing.' >&2
  exit 1
fi

container_running="$(docker inspect --format '{{.State.Running}}' baseline-mysql)"
if [[ "$container_running" != true ]]; then
  echo 'Refusing migration because baseline-mysql is not running.' >&2
  exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/openboxes-migrate.XXXXXX")"
trap 'rm -rf -- "$temporary_directory"' EXIT
dump_file="$temporary_directory/openboxes.sql.gz"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
object_key="migration/$timestamp/openboxes.sql.gz"
object_uri="s3://$uploads_bucket/$object_key"

printf 'Creating read-only dump from baseline-mysql for %s\n' "$object_uri"
# shellcheck disable=SC2016
docker exec baseline-mysql sh -c '
  export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is unavailable}"
  exec mysqldump \
    --single-transaction \
    --routines=false \
    --triggers \
    --no-tablespaces \
    --set-gtid-purged=OFF \
    --default-character-set=utf8mb4 \
    --user=root \
    openboxes
' |
  sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' |
  gzip -c > "$dump_file"

aws s3 cp "$dump_file" "$object_uri" --region "$region" --only-show-errors
printf 'Uploaded migration dump to %s\n' "$object_uri"

presigned_url="$(aws s3 presign "$object_uri" --expires-in 900 --region "$region")"
if [[ -z "$presigned_url" ]]; then
  echo 'S3 did not return a presigned migration URL.' >&2
  exit 1
fi

if [[ "$force_restore" -eq 1 ]]; then
  RESTORE_PRESIGNED_URL="$presigned_url" "$script_dir/run-db-init.sh" --restore --force
else
  RESTORE_PRESIGNED_URL="$presigned_url" "$script_dir/run-db-init.sh" --restore
fi
unset presigned_url

aws s3api delete-object \
  --bucket "$uploads_bucket" \
  --key "$object_key" \
  --region "$region" \
  --output json > "$temporary_directory/delete-dump.json"
printf 'Deleted migration dump object %s\n' "$object_uri"

APP_IMAGE_URI="$image_uri" DESIRED_COUNT=1 SKIP_PREFLIGHT=1 "$script_dir/deploy.sh"
aws ecs wait services-stable \
  --cluster "$cluster" \
  --services openboxes-demo-app \
  --region "$region"
printf 'ECS service openboxes-demo-app is stable with DesiredCount=1.\n'
