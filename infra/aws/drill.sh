#!/usr/bin/env bash
set -euo pipefail

region=us-east-1
expected_account=077510937834
cluster=openboxes-demo
started_by=openboxes-demo-incident-drill
network_stack=openboxes-demo-network
data_stack=openboxes-demo-data
default_seconds=600

print_command() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run_capture() {
  print_command "$@"
  "$@"
}

account="$(run_capture aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing incident drill in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

stack_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "$data_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue | [0]" \
    --output text
}

active_task_arns() {
  local desired_status="$1"
  aws ecs list-tasks \
    --cluster "$cluster" \
    --desired-status "$desired_status" \
    --started-by "$started_by" \
    --region "$region" \
    --query taskArns \
    --output text
}

refuse_if_active() {
  local desired_status="$1"
  local task_arns
  task_arns="$(active_task_arns "$desired_status")"
  if [[ -n "$task_arns" && "$task_arns" != None ]]; then
    printf 'An incident drill task is already %s: %s\n' "$desired_status" "$task_arns" >&2
    exit 1
  fi
}

start_drill() {
  local seconds="$1"
  local task_definition subnet security_group drill_command
  local overrides_file response_file task_arn started_at

  if [[ ! "$seconds" =~ ^[0-9]+$ || "$seconds" -lt 60 || "$seconds" -gt 900 ]]; then
    printf 'Drill duration must be an integer from 60 through 900 seconds: %s\n' "$seconds" >&2
    exit 2
  fi
  refuse_if_active RUNNING
  refuse_if_active PENDING

  task_definition="$(stack_output DbInitTaskDefinition)"
  subnet="$(aws cloudformation describe-stacks \
    --stack-name "$network_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetA'].OutputValue | [0]" \
    --output text)"
  security_group="$(aws cloudformation describe-stacks \
    --stack-name "$network_stack" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='OneshotSg'].OutputValue | [0]" \
    --output text)"
  for value_name in task_definition subnet security_group; do
    if [[ -z "${!value_name}" || "${!value_name}" == None ]]; then
      printf 'Missing data-stack output for drill: %s\n' "$value_name" >&2
      exit 1
    fi
  done

  overrides_file="$(mktemp "${TMPDIR:-/tmp}/openboxes-drill-overrides.XXXXXX.json")"
  response_file="$(mktemp "${TMPDIR:-/tmp}/openboxes-drill-response.XXXXXX.json")"
  trap 'rm -f -- "$overrides_file" "$response_file"' RETURN
  drill_command="$(cat <<DRILL
set -euo pipefail
bundle=/tmp/us-east-1-bundle.pem
curl --fail --silent --show-error --location https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem -o "\$bundle"
MYSQL_PWD="\$APP_PASSWORD" mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca="\$bundle" -h "\$DB_HOST" -u openboxes --batch --skip-column-names openboxes <<SQL | awk 'substr(\$0, 1, 1) == "{" { print; fflush() }'
START TRANSACTION;
SELECT id FROM user WHERE username = 'admin' FOR UPDATE;
SELECT JSON_OBJECT('event', 'incident_drill_lock_acquired', 'table', 'user', 'row', 'username=admin', 'hold_seconds', $seconds, 'db_ts', UTC_TIMESTAMP(6), 'connection_id', CONNECTION_ID());
SELECT SLEEP($seconds);
ROLLBACK;
SELECT JSON_OBJECT('event', 'incident_drill_lock_released', 'db_ts', UTC_TIMESTAMP(6), 'connection_id', CONNECTION_ID());
SQL
DRILL
)"
  jq -n --arg command "$drill_command" \
    '{containerOverrides: [{name: "db-init", command: [$command]}]}' > "$overrides_file"

  started_at="$(date -u --iso-8601=seconds)"
  print_command aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$task_definition" \
    --started-by "$started_by" \
    --launch-type FARGATE \
    --network-configuration 'awsvpcConfiguration={assignPublicIp=ENABLED,securityGroups=['"$security_group"'],subnets=['"$subnet"']}' \
    --overrides "file://$overrides_file" \
    --region "$region"
  aws ecs run-task \
    --cluster "$cluster" \
    --task-definition "$task_definition" \
    --started-by "$started_by" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={assignPublicIp=ENABLED,securityGroups=[$security_group],subnets=[$subnet]}" \
    --overrides "file://$overrides_file" \
    --region "$region" \
    --output json > "$response_file"
  task_arn="$(jq -r '.tasks[0].taskArn // empty' "$response_file")"
  if [[ -z "$task_arn" ]]; then
    cat "$response_file" >&2
    echo 'ECS did not return an incident drill task ARN.' >&2
    exit 1
  fi
  printf 'Incident drill task ARN: %s\n' "$task_arn"
  printf 'Incident drill UTC start: %s\n' "$started_at"
}

stop_drill() {
  local desired_status task_arns task_arn
  for desired_status in RUNNING PENDING; do
    task_arns="$(active_task_arns "$desired_status")"
    if [[ -z "$task_arns" || "$task_arns" == None ]]; then
      continue
    fi
    for task_arn in $task_arns; do
      run_capture aws ecs stop-task \
        --cluster "$cluster" \
        --task "$task_arn" \
        --reason 'incident drill stopped by operator' \
        --region "$region" \
        --output json >/dev/null
      run_capture aws ecs wait tasks-stopped \
        --cluster "$cluster" \
        --tasks "$task_arn" \
        --region "$region"
      printf 'Stopped incident drill task: %s\n' "$task_arn"
    done
  done
}

status_drill() {
  local desired_status task_arns task_arn found=0
  for desired_status in RUNNING PENDING STOPPED; do
    task_arns="$(active_task_arns "$desired_status")"
    if [[ -z "$task_arns" || "$task_arns" == None ]]; then
      continue
    fi
    found=1
    for task_arn in $task_arns; do
      aws ecs describe-tasks \
        --cluster "$cluster" \
        --tasks "$task_arn" \
        --region "$region" \
        --query 'tasks[0].{TaskArn:taskArn,LastStatus:lastStatus,DesiredStatus:desiredStatus,StartedAt:startedAt,StoppedReason:stoppedReason}' \
        --output table
    done
  done
  if [[ "$found" -eq 0 ]]; then
    echo 'No running or pending incident drill task.'
  fi
}

usage() {
  echo 'Usage: ./infra/aws/drill.sh start [--seconds N] | stop | status' >&2
  exit 2
}

case "${1:-}" in
  start)
    seconds="$default_seconds"
    if [[ "$#" -eq 3 && "$2" == --seconds ]]; then
      seconds="$3"
    elif [[ "$#" -ne 1 ]]; then
      usage
    fi
    start_drill "$seconds"
    ;;
  stop)
    [[ "$#" -eq 1 ]] || usage
    stop_drill
    ;;
  status)
    [[ "$#" -eq 1 ]] || usage
    status_drill
    ;;
  *)
    usage
    ;;
esac
