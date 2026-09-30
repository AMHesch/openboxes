#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || "$1" != --yes ]]; then
  echo 'Usage: ./infra/aws/cleanup.sh --yes' >&2
  echo 'This removes the OpenBoxes demo stacks and their temporary resources.' >&2
  exit 2
fi

region=us-east-1
expected_account=077510937834
network_stack=openboxes-demo-network
data_stack=openboxes-demo-data
app_stack=openboxes-demo-app
observability_stack=openboxes-demo-observability
database_identifier=openboxes-demo-db
ecr_repository=openboxes-demo

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run_capture() {
  print_command "$@" >&2
  "$@"
}

stack_exists() {
  local stack_name="$1"
  local output status
  if output="$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" 2>&1)"; then
    return 0
  else
    status=$?
  fi
  if [[ "$output" == *'does not exist'* || "$output" == *'not found'* ]]; then
    return 1
  fi
  printf '%s\n' "$output" >&2
  return "$status"
}

delete_stack_if_present() {
  local stack_name="$1"
  local status
  if stack_exists "$stack_name"; then
    print_command aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
    aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
    print_command aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"
  else
    status=$?
    if [[ "$status" -eq 1 ]]; then
      printf 'Stack %s does not exist; skipping\n' "$stack_name"
    else
      return "$status"
    fi
  fi
}

delete_secret_if_present() {
  local secret_id="$1"
  local secret_info
  if secret_info="$(aws secretsmanager describe-secret \
    --secret-id "$secret_id" \
    --region "$region" \
    --output json 2>&1)"; then
    printf 'Deleting stack-owned secret %s\n' "$secret_id"
    run_capture aws secretsmanager delete-secret \
      --secret-id "$secret_id" \
      --force-delete-without-recovery \
      --region "$region"
  elif [[ "$secret_info" == *'ResourceNotFoundException'* || "$secret_info" == *'not found'* ]]; then
    printf 'Secret %s does not exist; skipping\n' "$secret_id"
  else
    printf '%s\n' "$secret_info" >&2
    return 1
  fi
}

empty_alb_log_bucket_if_present() {
  local bucket="$1"
  local output
  if output="$(aws s3api head-bucket --bucket "$bucket" --region "$region" 2>&1)"; then
    run_capture aws s3 rm "s3://${bucket}" --recursive --region "$region"
  elif [[ "$output" == *'(404)'* || "$output" == *'NoSuchBucket'* || "$output" == *'Not Found'* ]]; then
    printf 'Bucket %s does not exist; skipping\n' "$bucket"
  else
    printf '%s\n' "$output" >&2
    return 1
  fi
}

delete_log_group_if_present() {
  local log_group="$1"
  local output
  print_command aws logs delete-log-group --log-group-name "$log_group" --region "$region"
  if output="$(aws logs delete-log-group --log-group-name "$log_group" --region "$region" 2>&1)"; then
    printf 'Deleted log group %s\n' "$log_group"
  elif [[ "$output" == *'ResourceNotFoundException'* ]]; then
    printf 'Log group %s does not exist; skipping\n' "$log_group"
  else
    printf '%s\n' "$output" >&2
    return 1
  fi
}

account="$(run_capture aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing cleanup in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

delete_stack_if_present "$observability_stack"
delete_secret_if_present openboxes-demo/devin-webhook
if stack_exists "$app_stack"; then
  empty_alb_log_bucket_if_present "openboxes-demo-alb-logs-${account}"
else
  status=$?
  if [[ "$status" -eq 1 ]]; then
    printf 'App stack %s does not exist; skipping ALB log bucket cleanup\n' "$app_stack"
  else
    exit "$status"
  fi
fi
delete_stack_if_present "$app_stack"

if stack_exists "$data_stack"; then
  printf 'Disabling RDS deletion protection for %s\n' "$database_identifier"
  if db_info="$(aws rds describe-db-instances \
    --db-instance-identifier "$database_identifier" \
    --region "$region" \
    --output json 2>&1)"; then
    deletion_protection="$(printf '%s' "$db_info" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["DBInstances"][0]["DeletionProtection"]).lower())')"
    if [[ "$deletion_protection" == true ]]; then
      print_command aws rds modify-db-instance --db-instance-identifier "$database_identifier" --no-deletion-protection --apply-immediately --region "$region"
      aws rds modify-db-instance --db-instance-identifier "$database_identifier" --no-deletion-protection --apply-immediately --region "$region"
      print_command aws rds wait db-instance-available --db-instance-identifier "$database_identifier" --region "$region"
      aws rds wait db-instance-available --db-instance-identifier "$database_identifier" --region "$region"
    else
      printf 'Deletion protection is already disabled for %s\n' "$database_identifier"
    fi
  elif [[ "$db_info" == *'DBInstanceNotFound'* || "$db_info" == *'not found'* ]]; then
    printf 'DB instance %s does not exist; skipping protection change\n' "$database_identifier"
  else
    printf '%s\n' "$db_info" >&2
    exit 1
  fi

  uploads_bucket="$(run_capture aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='UploadsBucket'].OutputValue | [0]" \
    --output text)"
  if [[ -n "$uploads_bucket" && "$uploads_bucket" != None ]]; then
    printf 'Emptying all object versions and delete markers from bucket %s\n' "$uploads_bucket"
    python3 - "$uploads_bucket" "$region" <<'PY'
import json
import subprocess
import sys

bucket, region = sys.argv[1:]
key_marker = None
version_marker = None

def run_json(args):
    print("+ " + " ".join(args), flush=True)
    return json.loads(subprocess.check_output(["aws", *args], text=True))

while True:
    args = [
        "s3api", "list-object-versions",
        "--bucket", bucket,
        "--region", region,
        "--no-paginate",
        "--output", "json",
    ]
    if key_marker:
        args.extend(["--key-marker", key_marker])
    if version_marker:
        args.extend(["--version-id-marker", version_marker])
    page = run_json(args)
    objects = [
        {"Key": item["Key"], "VersionId": item["VersionId"]}
        for item in page.get("Versions", []) + page.get("DeleteMarkers", [])
    ]
    for offset in range(0, len(objects), 1000):
        batch = objects[offset:offset + 1000]
        delete = json.dumps({"Objects": batch, "Quiet": True})
        result = run_json([
            "s3api", "delete-objects",
            "--bucket", bucket,
            "--region", region,
            "--delete", delete,
            "--output", "json",
        ])
        if result.get("Errors"):
            raise SystemExit("S3 returned errors while deleting object versions")
    if not page.get("IsTruncated"):
        break
    key_marker = page.get("NextKeyMarker")
    version_marker = page.get("NextVersionIdMarker")
    if not key_marker:
        raise SystemExit("S3 returned a truncated version list without a next key marker")
PY
  fi

  printf 'Deleting images from ECR repository %s\n' "$ecr_repository"
  python3 - "$ecr_repository" "$region" <<'PY'
import json
import subprocess
import sys

repository, region = sys.argv[1:]
image_ids = json.loads(subprocess.check_output([
    "aws", "ecr", "list-images",
    "--repository-name", repository,
    "--region", region,
    "--query", "imageIds",
    "--output", "json",
], text=True))
for offset in range(0, len(image_ids), 100):
    batch = image_ids[offset:offset + 100]
    print(f"+ aws ecr batch-delete-image --repository-name {repository} --region {region} ({len(batch)} image IDs)", flush=True)
    subprocess.run([
        "aws", "ecr", "batch-delete-image",
        "--repository-name", repository,
        "--region", region,
        "--image-ids", json.dumps(batch),
    ], check=True)
PY

  print_command aws cloudformation delete-stack --stack-name "$data_stack" --region "$region"
  aws cloudformation delete-stack --stack-name "$data_stack" --region "$region"
  print_command aws cloudformation wait stack-delete-complete --stack-name "$data_stack" --region "$region"
  aws cloudformation wait stack-delete-complete --stack-name "$data_stack" --region "$region"
  snapshots="$(run_capture aws rds describe-db-snapshots \
    --db-instance-identifier "$database_identifier" \
    --snapshot-type manual \
    --region "$region" \
    --query "DBSnapshots[?Status=='available'].DBSnapshotIdentifier" \
    --output text)"
  if [[ -n "$snapshots" && "$snapshots" != None ]]; then
    for snapshot in $snapshots; do
      printf 'Snapshot retained: %s\n' "$snapshot"
      printf 'Delete only when no longer needed: aws rds delete-db-snapshot --db-snapshot-identifier %q --region %q\n' "$snapshot" "$region"
    done
  else
    echo 'No available manual database snapshots found'
  fi
else
  status=$?
  if [[ "$status" -eq 1 ]]; then
    printf 'Stack %s does not exist; skipping data cleanup\n' "$data_stack"
  else
    exit "$status"
  fi
fi

delete_log_group_if_present /aws/rds/instance/openboxes-demo-db/error
delete_log_group_if_present /aws/rds/instance/openboxes-demo-db/slowquery
delete_log_group_if_present /aws/ecs/containerinsights/openboxes-demo/performance

delete_stack_if_present "$network_stack"

echo 'Remaining resources tagged Project=openboxes-demo:'
if ! aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=openboxes-demo \
  --region "$region" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text; then
  echo 'Could not list residual tagged resources; inspect the account before considering cleanup complete.' >&2
fi
