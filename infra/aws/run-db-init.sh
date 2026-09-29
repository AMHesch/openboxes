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
