#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
region="${AWS_REGION:-us-east-1}"
expected_account=077510937834
data_stack=openboxes-demo-data
network_template="${NETWORK_TEMPLATE:-$script_dir/network.yaml}"
data_template="${DATA_TEMPLATE:-$script_dir/data.yaml}"
cfn_lint="${CFN_LINT:-cfn-lint}"
jq_bin="${JQ:-jq}"

for tool in aws "$cfn_lint" "$jq_bin" awk sort mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 127
  fi
done

for template in "$network_template" "$data_template"; do
  if [[ ! -f "$template" ]]; then
    printf 'Template not found: %s\n' "$template" >&2
    exit 1
  fi
done

account="$(aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing preflight in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/openboxes-preflight.XXXXXX")"
trap 'rm -rf -- "$temporary_directory"' EXIT
schema_directory="$temporary_directory/registry-schemas"
mkdir -p "$schema_directory"

resource_types() {
  awk '
    /^Resources:[[:space:]]*$/ {
      in_resources = 1
      next
    }
    in_resources && /^[^[:space:]]/ {
      exit
    }
    in_resources && /^    Type: AWS::/ {
      sub(/^    Type: /, "")
      print
    }
  ' "$1"
}

mapfile -t types < <(
  {
    resource_types "$network_template"
    resource_types "$data_template"
  } | sort -u
)

if [[ "${#types[@]}" -eq 0 ]]; then
  echo 'No CloudFormation resource types were found in the templates.' >&2
  exit 1
fi

for type in "${types[@]}"; do
  printf 'Fetching CloudFormation registry schema: %s\n' "$type"
  aws cloudformation describe-type \
    --type RESOURCE \
    --type-name "$type" \
    --region "$region" \
    --query Schema \
    --output text > "$schema_directory/$type.json"
  if [[ ! -s "$schema_directory/$type.json" ]]; then
    printf 'CloudFormation returned an empty registry schema for %s\n' "$type" >&2
    exit 1
  fi
done

printf 'Linting both templates with %s registry schemas.\n' "${#types[@]}"
"$cfn_lint" \
  --config-file "$script_dir/.cfnlintrc" \
  --regions "$region" \
  --registry-schemas "$schema_directory" \
  --ignore-checks E1020 E6101 E1041 W3010 \
  --template \
  "$network_template" \
  "$data_template"

is_access_denied() {
  local message
  message="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$message" == *accessdenied* ||
    "$message" == *"access denied"* ||
    "$message" == *"not authorized"* ||
    "$message" == *unauthorizedoperation* ]]
}

ecs_cli() {
  local name="$1"
  shift
  local stdout_file="$temporary_directory/$name.stdout"
  local stderr_file="$temporary_directory/$name.stderr"
  local exit_code

  if "$@" > "$stdout_file" 2> "$stderr_file"; then
    return 0
  else
    exit_code=$?
  fi

  if is_access_denied "$(cat "$stderr_file")"; then
    printf 'ECS preflight skipped: IAM denied %s.\n' "$name" >&2
    cat "$stderr_file" >&2
    return 77
  fi

  cat "$stderr_file" >&2
  return "$exit_code"
}

run_ecs_preflight() {
  local task_definition_arn
  local describe_error
  local status
  local registered_task_arn

  if ! task_definition_arn="$(
    aws cloudformation describe-stacks \
      --stack-name "$data_stack" \
      --region "$region" \
      --query "Stacks[0].Outputs[?OutputKey=='DbInitTaskDefinition'].OutputValue | [0]" \
      --output text 2>"$temporary_directory/describe-stack.stderr"
  )"; then
    describe_error="$(cat "$temporary_directory/describe-stack.stderr")"
    if [[ "$describe_error" == *"does not exist"* ]]; then
      printf 'ECS registration preflight skipped: %s has not been deployed yet.\n' "$data_stack"
      return 0
    fi
    if is_access_denied "$describe_error"; then
      printf 'ECS registration preflight skipped: IAM denied reading %s outputs.\n' "$data_stack" >&2
      printf '%s\n' "$describe_error" >&2
      return 0
    fi
    printf '%s\n' "$describe_error" >&2
    return 1
  fi

  if [[ -z "$task_definition_arn" || "$task_definition_arn" == None ]]; then
    printf 'ECS registration preflight skipped: %s has no DbInitTaskDefinition output yet.\n' "$data_stack"
    return 0
  fi

  if ecs_cli describe-task-definition \
    aws ecs describe-task-definition \
      --task-definition "$task_definition_arn" \
      --region "$region" \
      --query taskDefinition \
      --output json; then
    :
  else
    status=$?
    if [[ "$status" -eq 77 ]]; then
      return 0
    fi
    return "$status"
  fi

  if ! "$jq_bin" -e '(.containerDefinitions | length) > 0' \
    "$temporary_directory/describe-task-definition.stdout" >/dev/null; then
    echo 'The deployed DB-init task definition has no container definitions.' >&2
    return 1
  fi

  "$jq_bin" '{
    family: "openboxes-demo-preflight",
    taskRoleArn: .taskRoleArn,
    executionRoleArn: .executionRoleArn,
    networkMode: .networkMode,
    containerDefinitions: .containerDefinitions,
    volumes: .volumes,
    placementConstraints: .placementConstraints,
    requiresCompatibilities: .requiresCompatibilities,
    cpu: .cpu,
    memory: .memory,
    runtimePlatform: .runtimePlatform,
    ephemeralStorage: .ephemeralStorage
  } | with_entries(select(.value != null))' \
    "$temporary_directory/describe-task-definition.stdout" \
    > "$temporary_directory/register-task-definition.json"

  if ecs_cli register-task-definition \
    aws ecs register-task-definition \
      --cli-input-json "file://$temporary_directory/register-task-definition.json" \
      --region "$region" \
      --output json; then
    :
  else
    status=$?
    if [[ "$status" -eq 77 ]]; then
      return 0
    fi
    return "$status"
  fi

  registered_task_arn="$("$jq_bin" -r '.taskDefinition.taskDefinitionArn // empty' \
    "$temporary_directory/register-task-definition.stdout")"
  if [[ -z "$registered_task_arn" ]]; then
    echo 'ECS did not return the preflight task definition ARN.' >&2
    return 1
  fi

  printf 'Registered temporary ECS task definition: %s\n' "$registered_task_arn"
  if ecs_cli deregister-task-definition \
    aws ecs deregister-task-definition \
      --task-definition "$registered_task_arn" \
      --region "$region" \
      --output json; then
    :
  else
    status=$?
    if [[ "$status" -eq 77 ]]; then
      return 0
    fi
    return "$status"
  fi

  if ecs_cli delete-task-definitions \
    aws ecs delete-task-definitions \
      --task-definitions "$registered_task_arn" \
      --region "$region" \
      --output json; then
    :
  else
    status=$?
    if [[ "$status" -eq 77 ]]; then
      return 0
    fi
    return "$status"
  fi

  if ! "$jq_bin" -e '.failures | length == 0' \
    "$temporary_directory/delete-task-definitions.stdout" >/dev/null; then
    echo 'ECS did not delete the temporary inactive task definition cleanly.' >&2
    cat "$temporary_directory/delete-task-definitions.stdout" >&2
    return 1
  fi

  printf 'Deleted temporary ECS task definition: %s\n' "$registered_task_arn"
}

run_ecs_preflight
