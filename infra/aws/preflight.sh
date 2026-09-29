#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
region="${AWS_REGION:-us-east-1}"
expected_account=077510937834
data_stack=openboxes-demo-data
network_template="${NETWORK_TEMPLATE:-$script_dir/network.yaml}"
data_template="${DATA_TEMPLATE:-$script_dir/data.yaml}"
app_template="${APP_TEMPLATE:-$script_dir/app.yaml}"
observability_template="${OBSERVABILITY_TEMPLATE:-$script_dir/observability.yaml}"
cfn_lint="${CFN_LINT:-cfn-lint}"
jq_bin="${JQ:-jq}"
templates=("$network_template" "$data_template")

if [[ -f "$app_template" ]]; then
  templates+=("$app_template")
fi
if [[ -f "$observability_template" ]]; then
  templates+=("$observability_template")
fi

for tool in aws "$cfn_lint" "$jq_bin" awk sort mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 127
  fi
done

for template in "${templates[@]}"; do
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
    for template in "${templates[@]}"; do
      resource_types "$template"
    done
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

printf 'Linting %s templates with %s registry schemas.\n' "${#templates[@]}" "${#types[@]}"
"$cfn_lint" \
  --config-file "$script_dir/.cfnlintrc" \
  --regions "$region" \
  --registry-schemas "$schema_directory" \
  --ignore-checks E1020 E6101 E1041 W3010 \
  --template \
  "${templates[@]}"

for template in "${templates[@]}"; do
  printf 'Validating CloudFormation template: %s\n' "$template"
  aws cloudformation validate-template \
    --template-body "file://$template" \
    --region "$region" \
    --output json >/dev/null
done

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

run_app_ecs_preflight() {
  local app_image_uri="${APP_IMAGE_URI:-}"
  local task_definition_arn
  local db_endpoint
  local app_secret_arn
  local file_system_arn
  local access_point_arn
  local execution_role_arn
  local registered_task_arn

  if [[ -z "$app_image_uri" ]]; then
    echo 'App ECS registration preflight skipped: APP_IMAGE_URI is not set.'
    return 0
  fi

  task_definition_arn="$(aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='DbInitTaskDefinition'].OutputValue | [0]" \
    --output text)"
  db_endpoint="$(aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='DbEndpoint'].OutputValue | [0]" \
    --output text)"
  app_secret_arn="$(aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='AppSecretArn'].OutputValue | [0]" \
    --output text)"
  file_system_arn="$(aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='FileSystemArn'].OutputValue | [0]" \
    --output text)"
  access_point_arn="$(aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='AccessPointArn'].OutputValue | [0]" \
    --output text)"
  execution_role_arn="$(aws ecs describe-task-definition \
    --task-definition "$task_definition_arn" \
    --region "$region" \
    --query 'taskDefinition.executionRoleArn' \
    --output text)"

  for value_name in task_definition_arn db_endpoint app_secret_arn file_system_arn access_point_arn execution_role_arn; do
    if [[ -z "${!value_name}" || "${!value_name}" == None ]]; then
      printf 'Missing required app preflight value: %s\n' "$value_name" >&2
      return 1
    fi
  done
  if [[ ! "$app_image_uri" =~ @sha256:[[:xdigit:]]{64}$ ]]; then
    printf 'APP_IMAGE_URI must be an ECR digest URI: %s\n' "$app_image_uri" >&2
    return 1
  fi

  # shellcheck disable=SC2016
  "$jq_bin" -n \
    --arg image "$app_image_uri" \
    --arg role "$execution_role_arn" \
    --arg endpoint "$db_endpoint" \
    --arg app_secret "$app_secret_arn" \
    --arg file_system "$file_system_arn" \
    --arg access_point "$access_point_arn" \
    '{
      family: "openboxes-demo-preflight-app",
      taskRoleArn: $role,
      executionRoleArn: $role,
      networkMode: "awsvpc",
      requiresCompatibilities: ["FARGATE"],
      cpu: "1024",
      memory: "4096",
      runtimePlatform: {cpuArchitecture: "X86_64", operatingSystemFamily: "LINUX"},
      containerDefinitions: [{
        name: "openboxes",
        image: $image,
        essential: true,
        portMappings: [{containerPort: 8080, protocol: "tcp"}],
        environment: [
          {name: "DATASOURCE_URL", value: ("jdbc:mysql://" + $endpoint + ":3306/openboxes?serverTimezone=UTC&sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:/app/rds-ca.p12&trustCertificateKeyStoreType=PKCS12&trustCertificateKeyStorePassword=changeit")},
          {name: "DATASOURCE_USERNAME", value: "openboxes"},
          {name: "GRAILS_SERVER_URL", value: "https://preflight.invalid/openboxes"}
        ],
        secrets: [{name: "DATASOURCE_PASSWORD", valueFrom: ($app_secret + ":password::")}],
        mountPoints: [{sourceVolume: "uploads", containerPath: "/app/uploads", readOnly: false}]
      }],
      volumes: [{
        name: "uploads",
        s3filesVolumeConfiguration: {
          fileSystemArn: $file_system,
          accessPointArn: $access_point
        }
      }]
    }' > "$temporary_directory/register-app-task-definition.json"

  aws ecs register-task-definition \
    --cli-input-json "file://$temporary_directory/register-app-task-definition.json" \
    --region "$region" \
    --output json > "$temporary_directory/register-app-task-definition.json.response"
  registered_task_arn="$("$jq_bin" -r '.taskDefinition.taskDefinitionArn // empty' \
    "$temporary_directory/register-app-task-definition.json.response")"
  if [[ -z "$registered_task_arn" ]]; then
    echo 'ECS did not return the app preflight task definition ARN.' >&2
    return 1
  fi

  printf 'Registered temporary app ECS task definition: %s\n' "$registered_task_arn"
  aws ecs deregister-task-definition \
    --task-definition "$registered_task_arn" \
    --region "$region" \
    --output json > "$temporary_directory/deregister-app-task-definition.json"
  aws ecs delete-task-definitions \
    --task-definitions "$registered_task_arn" \
    --region "$region" \
    --output json > "$temporary_directory/delete-app-task-definition.json"
  if ! "$jq_bin" -e '.failures | length == 0' \
    "$temporary_directory/delete-app-task-definition.json" >/dev/null; then
    echo 'ECS did not delete the temporary app task definition cleanly.' >&2
    cat "$temporary_directory/delete-app-task-definition.json" >&2
    return 1
  fi
  printf 'Deleted temporary app ECS task definition: %s\n' "$registered_task_arn"
}

run_app_ecs_preflight
