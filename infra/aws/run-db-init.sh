#!/usr/bin/env bash
set -euo pipefail

region=us-east-1
expected_account=077510937834
network_stack=openboxes-demo-network
data_stack=openboxes-demo-data
log_group=/openboxes-demo/db-init

print_command() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run_capture() {
  print_command "$@"
  "$@"
}

stack_output() {
  local stack_name="$1"
  local output_key="$2"
  run_capture aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text
}

run_restore() {
  local force_restore="$1"
  local account
  local cluster
  local task_definition
  local subnet
  local security_group
  local admin_secret_arn
  local registered_task_definition
  local task_arn
  local task_status
  local exit_code
  local task_id
  local stream_prefix
  local stream_name
  local _attempt
  local restore_command
  local overrides_file
  local task_definition_file
  local log_messages

  if [[ -z "${RESTORE_PRESIGNED_URL:-}" ]]; then
    echo 'RESTORE_PRESIGNED_URL is required for restore mode.' >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo 'jq is required for restore mode.' >&2
    return 127
  fi

  account="$(run_capture aws sts get-caller-identity --region "$region" --query Account --output text)"
  if [[ "$account" != "$expected_account" ]]; then
    printf 'Refusing task in account %s; expected %s\n' "$account" "$expected_account" >&2
    return 1
  fi

  cluster="$(stack_output "$data_stack" ClusterName)"
  task_definition="$(stack_output "$data_stack" DbInitTaskDefinition)"
  subnet="$(stack_output "$network_stack" PublicSubnetA)"
  security_group="$(stack_output "$network_stack" OneshotSg)"
  admin_secret_arn="$(run_capture aws secretsmanager describe-secret \
    --secret-id openboxes-demo/admin-ui \
    --region "$region" \
    --query ARN \
    --output text)"
  if [[ -z "$cluster" || "$cluster" == None || -z "$task_definition" || "$task_definition" == None ||
        -z "$subnet" || "$subnet" == None || -z "$security_group" || "$security_group" == None ||
        -z "$admin_secret_arn" || "$admin_secret_arn" == None ]]; then
    echo 'Required restore stack output or admin secret is missing.' >&2
    return 1
  fi

  umask 077
  restore_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/openboxes-db-restore.XXXXXX")"
  trap 'if [[ -n "${restore_temporary_directory:-}" ]]; then rm -rf -- "$restore_temporary_directory"; fi' EXIT
  task_definition_file="$restore_temporary_directory/task-definition.json"
  overrides_file="$restore_temporary_directory/overrides.json"

  print_command aws ecs describe-task-definition \
    --task-definition "$task_definition" \
    --region "$region" \
    --query taskDefinition \
    --output json
  aws ecs describe-task-definition \
    --task-definition "$task_definition" \
    --region "$region" \
    --query taskDefinition \
    --output json > "$task_definition_file"
  jq --arg secret "$admin_secret_arn" '
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy)
    | .containerDefinitions |= map(
        if .name == "db-init" then
          .secrets = ((.secrets // []) + [{name: "ADMIN_UI_PASSWORD", valueFrom: $secret}])
        else
          .
        end
      )
  ' "$task_definition_file" > "$restore_temporary_directory/register-task-definition.json"
  registered_task_definition="$(run_capture aws ecs register-task-definition \
    --cli-input-json "file://$restore_temporary_directory/register-task-definition.json" \
    --region "$region" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)"
  if [[ -z "$registered_task_definition" || "$registered_task_definition" == None ]]; then
    echo 'ECS did not return the restore task definition ARN.' >&2
    return 1
  fi
  printf 'Registered restore task definition revision: %s\n' "$registered_task_definition"

  read -r -d '' restore_command <<'RESTORE_COMMAND' || true
set -eu
bundle=/tmp/us-east-1-bundle.pem
dump=/tmp/openboxes.sql.gz
curl --fail --silent --show-error --location https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem -o "$bundle"
curl --fail --silent --show-error --location "$RESTORE_PRESIGNED_URL" -o "$dump"
unset RESTORE_PRESIGNED_URL
gzip -t "$dump"
tables="$(MYSQL_PWD="$MASTER_PASSWORD" mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca="$bundle" -h "$DB_HOST" -u "$MASTER_USER" --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'openboxes';")"
if [ "$tables" -gt 0 ]; then
  if [ "${FORCE_RESTORE:-0}" != 1 ]; then
    printf 'Refusing restore: openboxes schema already has %s tables; pass --force to replace it.\n' "$tables" >&2
    exit 1
  fi
  printf '%s\n' 'DROP DATABASE IF EXISTS openboxes; CREATE DATABASE openboxes CHARACTER SET utf8 COLLATE utf8_general_ci;' |
    MYSQL_PWD="$MASTER_PASSWORD" mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca="$bundle" -h "$DB_HOST" -u "$MASTER_USER"
fi
gzip -dc "$dump" |
  MYSQL_PWD="$APP_PASSWORD" mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca="$bundle" -h "$DB_HOST" -u openboxes openboxes
updated_rows="$(
  printf "UPDATE user SET password = TO_BASE64(UNHEX(SHA1('%s'))) WHERE username = 'admin';\nSELECT ROW_COUNT();\n" "$ADMIN_UI_PASSWORD" |
    MYSQL_PWD="$APP_PASSWORD" mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca="$bundle" -h "$DB_HOST" -u openboxes --batch --skip-column-names openboxes
)"
if [ "$updated_rows" != 1 ]; then
  printf 'Expected one admin password row update; got %s.\n' "$updated_rows" >&2
  exit 1
fi
printf '%s\n' 'Database restore and admin password rotation completed.'
RESTORE_COMMAND

  jq -n \
    --arg url "$RESTORE_PRESIGNED_URL" \
    --arg force "$force_restore" \
    --arg command "$restore_command" \
    '{
      containerOverrides: [{
        name: "db-init",
        command: [$command],
        environment: [
          {name: "RESTORE_PRESIGNED_URL", value: $url},
          {name: "FORCE_RESTORE", value: $force}
        ]
      }]
    }' > "$overrides_file"

  network_configuration="awsvpcConfiguration={subnets=[$subnet],securityGroups=[$security_group],assignPublicIp=ENABLED}"
  task_arn="$(run_capture aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$registered_task_definition" \
    --launch-type FARGATE \
    --network-configuration "$network_configuration" \
    --overrides "file://$overrides_file" \
    --region "$region" \
    --query 'tasks[0].taskArn' \
    --output text)"
  if [[ -z "$task_arn" || "$task_arn" == None ]]; then
    echo 'ECS did not return a restore task ARN.' >&2
    return 1
  fi
  run_capture aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn" --region "$region"
  task_status="$(run_capture aws ecs describe-tasks \
    --cluster "$cluster" \
    --tasks "$task_arn" \
    --region "$region" \
    --query 'tasks[0].lastStatus' \
    --output text)"
  exit_code="$(run_capture aws ecs describe-tasks \
    --cluster "$cluster" \
    --tasks "$task_arn" \
    --region "$region" \
    --query "tasks[0].containers[?name=='db-init'].exitCode | [0]" \
    --output text)"
  if [[ "$task_status" != STOPPED || "$exit_code" == None || -z "$exit_code" ]]; then
    printf 'Unexpected restore task state: status=%s exitCode=%s task=%s\n' "$task_status" "$exit_code" "$task_arn" >&2
    return 1
  fi

  task_id="${task_arn##*/}"
  stream_prefix="db-init/db-init/$task_id"
  stream_name=
  for _attempt in $(seq 1 30); do
    stream_name="$(run_capture aws logs describe-log-streams \
      --log-group-name "$log_group" \
      --log-stream-name-prefix "$stream_prefix" \
      --region "$region" \
      --query 'logStreams[0].logStreamName' \
      --output text)"
    if [[ -n "$stream_name" && "$stream_name" != None ]]; then
      break
    fi
    sleep 2
  done
  if [[ -z "$stream_name" || "$stream_name" == None ]]; then
    printf 'CloudWatch log stream not found for restore task %s\n' "$task_arn" >&2
    return 1
  fi

  log_messages="$(run_capture aws logs get-log-events \
    --log-group-name "$log_group" \
    --log-stream-name "$stream_name" \
    --start-from-head \
    --region "$region" \
    --query 'events[].message' \
    --output text)"
  printf '%s\n' "$log_messages"
  printf 'task=%s status=%s exit_code=%s\n' "$task_arn" "$task_status" "$exit_code"

  run_capture aws ecs deregister-task-definition \
    --task-definition "$registered_task_definition" \
    --region "$region" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text
  run_capture aws ecs delete-task-definitions \
    --task-definitions "$registered_task_definition" \
    --region "$region" \
    --query 'taskDefinitions[0].taskDefinitionArn' \
    --output text
  if [[ "$exit_code" != 0 ]]; then
    return "$exit_code"
  fi
}

if [[ "${1:-}" == "--restore" ]]; then
  shift
  force_restore=0
  if [[ "${1:-}" == "--force" ]]; then
    force_restore=1
    shift
  fi
  if [[ "$#" -ne 0 ]]; then
    echo 'Usage: run-db-init.sh [--restore [--force]]' >&2
    exit 2
  fi
  run_restore "$force_restore"
  exit $?
fi
if [[ "$#" -ne 0 ]]; then
  echo 'Usage: run-db-init.sh [--restore [--force]]' >&2
  exit 2
fi

account="$(run_capture aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing task in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

cluster="$(stack_output "$data_stack" ClusterName)"
task_definition="$(stack_output "$data_stack" DbInitTaskDefinition)"
subnet="$(stack_output "$network_stack" PublicSubnetA)"
security_group="$(stack_output "$network_stack" OneshotSg)"
if [[ -z "$cluster" || "$cluster" == None || -z "$task_definition" || "$task_definition" == None ||
      -z "$subnet" || "$subnet" == None || -z "$security_group" || "$security_group" == None ]]; then
  echo 'Required stack output is missing' >&2
  exit 1
fi

network_configuration="awsvpcConfiguration={subnets=[$subnet],securityGroups=[$security_group],assignPublicIp=ENABLED}"
task_arn="$(run_capture aws ecs run-task \
  --cluster "$cluster" \
  --task-definition "$task_definition" \
  --launch-type FARGATE \
  --network-configuration "$network_configuration" \
  --region "$region" \
  --query 'tasks[0].taskArn' \
  --output text)"
if [[ -z "$task_arn" || "$task_arn" == None ]]; then
  echo 'ECS did not return a task ARN' >&2
  exit 1
fi

run_capture aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn" --region "$region"
task_status="$(run_capture aws ecs describe-tasks \
  --cluster "$cluster" \
  --tasks "$task_arn" \
  --region "$region" \
  --query 'tasks[0].lastStatus' \
  --output text)"
exit_code="$(run_capture aws ecs describe-tasks \
  --cluster "$cluster" \
  --tasks "$task_arn" \
  --region "$region" \
  --query 'tasks[0].containers[0].exitCode' \
  --output text)"
if [[ "$task_status" != STOPPED || "$exit_code" == None || -z "$exit_code" ]]; then
  printf 'Unexpected task state: status=%s exitCode=%s task=%s\n' "$task_status" "$exit_code" "$task_arn" >&2
  exit 1
fi

task_id="${task_arn##*/}"
stream_prefix="db-init/db-init/$task_id"
stream_name=
for _attempt in $(seq 1 30); do
  stream_name="$(run_capture aws logs describe-log-streams \
    --log-group-name "$log_group" \
    --log-stream-name-prefix "$stream_prefix" \
    --region "$region" \
    --query 'logStreams[0].logStreamName' \
    --output text)"
  if [[ -n "$stream_name" && "$stream_name" != None ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$stream_name" || "$stream_name" == None ]]; then
  printf 'CloudWatch log stream not found for task %s\n' "$task_arn" >&2
  exit 1
fi

run_capture aws logs get-log-events \
  --log-group-name "$log_group" \
  --log-stream-name "$stream_name" \
  --start-from-head \
  --region "$region" \
  --query 'events[].message' \
  --output text
printf 'task=%s status=%s exit_code=%s\n' "$task_arn" "$task_status" "$exit_code"
if [[ "$exit_code" != 0 ]]; then
  exit "$exit_code"
fi
