# Playbook: OpenBoxes demo — CloudWatch alarm investigation (read-only)

## Overview
A CloudWatch alarm in the synthetic `openboxes-demo` AWS environment changed to ALARM, and EventBridge posted the raw
"CloudWatch Alarm State Change" event to this session. Investigate with read-only AWS access, correlate the alarm with
probe, application, ECS, and database evidence, and record the findings in ONE deduplicated GitHub issue on
AMHesch/cognition-demo (private incident tracker; the public AMHesch/openboxes fork holds code only). Recommend a mitigation and a rollback or fix for a human to approve. Never change AWS, deploy, or remediate.

## What's Needed From User
- Nothing to start: the triggering event JSON is appended to the prompt (`id`, `time`, `resources[0]` = alarm ARN, `detail.alarmName`, `detail.state.value|reason|timestamp`, `detail.previousState`).
- Human approval before any mitigation, rollback, or deployment. Humans run those commands, not this session.

## Procedure
1. **Gate the event.** Continue only if `detail.alarmName` starts with `openboxes-demo-`, `detail.state.value` is `ALARM`, and the account is `077510937834` in `us-east-1`. Otherwise end the session with a one-line note and do not touch GitHub. Record `T0 = detail.state.timestamp` and `eventId = id`.
2. **Deduplicate first.** List open issues in AMHesch/cognition-demo whose title starts with `[incident][<alarmName>]` (`gh issue list --repo AMHesch/cognition-demo --state open --search "in:title [incident][<alarmName>]"`). If one exists and already mentions `eventId`, stop: this event was already handled. If one exists without it, you will append a comment to it in step 9 instead of creating a new issue.
3. **Drop to the read-only role.** Run `aws sts assume-role --role-arn arn:aws:iam::077510937834:role/openboxes-demo-investigator --role-session-name incident-<first 8 chars of eventId>`, export the three credentials, and confirm with `aws sts get-caller-identity` that the ARN contains `assumed-role/openboxes-demo-investigator`. Use only these credentials for every AWS call that follows. If the assume-role call fails, stop and record the verbatim error in the issue.
4. **Characterise the alarm.** Run `describe-alarms` and `describe-alarm-history` for the alarm over the last 2 h. Pull `get-metric-data` (1-minute resolution) from T0−30m to now for:
   - `OpenBoxesDemo/Probe`: `LoginFailure`, `LoginSuccess`, `LoginLatencyMs`
   - `OpenBoxesDemo/App`: `LockWaitTimeouts`, `AppErrorLines`
   - ALB: `HTTPCode_Target_5XX_Count`, `TargetResponseTime` p95, `HealthyHostCount`
   - ECS service: CPU and memory
   - RDS `openboxes-demo-db`: `CPUUtilization`, `DatabaseConnections`
   Note when each metric first deviated.
5. **Read the symptom and the error.** In `/openboxes-demo/probe`, find the failing `login_probe` records (`failed_step`, `http_status`, `LoginLatencyMs`). In `/openboxes-demo/app` (T0−15m to now), use Logs Insights to find ERROR lines and exceptions. Quote the first occurrence and the count of each distinct error, including the Java class and controller/action from the stack trace. Judge app health from `HealthyHostCount`/target health, not by calling the app.
6. **Inspect ECS.** Get the service's deployments, recent events, running and desired counts, and task-definition revision. Then run `list-tasks` for the whole `openboxes-demo` cluster and `describe-tasks` for every task that is not the service's (`startedBy`, `group`, `startedAt`, command family). Read the CloudWatch logs of any one-shot task that started within T0−30m. Note whether an app deployment or task replacement happened in that window.
7. **Inspect the database and change history.** Check `rds describe-db-instances` status and `describe-events` for the window. Read the `/aws/rds/instance/openboxes-demo-db/error` and `slowquery` log groups when present. Run `cloudtrail lookup-events` for `RunTask`, `StopTask`, `UpdateService`, `RegisterTaskDefinition`, and `ModifyDBInstance` in the window to see who started what. CloudTrail can lag 5–15 min; say so if it is empty.
8. **Correlate and conclude.** Build a UTC timeline from steps 4–7. State the most likely cause and your confidence, separating what the evidence shows from what you infer. Name the discriminating check whenever confidence is not high. Choose a mitigation and a rollback or fix from the Advice section, each written as the exact command a human would run.
9. **Write the issue.**
   - **No open issue from step 2:** create one in AMHesch/cognition-demo (`gh issue create --repo AMHesch/cognition-demo`) titled `[incident][<alarmName>] <≤8-word cause>`, with label `incident` (create the label if it's missing) and a body following the template in Specifications.
   - **Open issue exists:** add a comment titled `Re-fired <T0>` that contains the same sections, abbreviated.
   - **Proposed fix:** only when a concrete code or config change is warranted, open a DRAFT PR in AMHesch/openboxes against the branch that contains `infra/aws/`, and link it from the issue. Never merge it.
10. **Hand off to a human.** End with a message giving the issue URL, the one-line cause, the mitigation command, and "Awaiting human approval; I have not changed anything." If a human later says the mitigation has been applied, re-check (read-only) the alarm state, the latest probe results, and `LockWaitTimeouts`. Then post a `Recovery verified <UTC>` comment with that evidence, or `Not yet recovered` with what is still failing. Leave the issue open for a human to close.

## Specifications
- Exactly one open issue per alarm name. A repeated event produces at most one comment, and nothing if its `eventId` is already recorded.
- Issue body template:
  ```
  <!-- incident-key: <alarmName> --> <!-- event-ids: <eventId> -->
  ## Summary        — 2–3 sentences: user impact, since when, likely cause, confidence
  ## Alarm          — name, ARN, state reason, T0, console link https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#alarmsV2:alarm/<alarmName>
  ## Timeline (UTC) — bullet per event, each with its source
  ## Evidence       — metric values, quoted log lines (≤10 lines each), ECS/RDS/CloudTrail facts; link the dashboard https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/openboxes-demo
  ## Likely cause   — evidence vs inference, confidence, what would confirm it
  ## Recommended mitigation (needs human approval) — exact command(s), expected effect, how to verify
  ## Rollback / proposed fix — command or draft PR link; runbook: infra/aws/README.md#observability-and-incident-drill
  ## Investigation  — this Devin session URL; the investigator role used; "read-only; no changes made"
  ```
- Validation: before finishing, re-read the issue. Every claim in Likely cause must trace to an item in Evidence, and there must be no secrets, cookies, passwords, or presigned URLs anywhere in it.

## Advice and Pointers
- The alarm fed to this workflow is `openboxes-demo-login-probe-failing`, a synthetic login through CloudFront every minute. `/openboxes/health` can stay UP while logins fail, so don't conclude "healthy" from ECS alone.
- `Lock wait timeout exceeded` means a transaction is waiting over 50 s on a row lock held by another session. Look for a long-running or unexpected DB client (e.g. a one-shot ECS task) that started just before the first failure.
  - If that client is an ECS task started by `openboxes-demo-incident-drill`, the mitigation is `./infra/aws/drill.sh stop` (or `aws ecs stop-task --cluster openboxes-demo --task <arn>`), and the lock then releases.
  - For an unknown client, the mitigation is to identify and stop it. That means DB access, which is outside this role.
- If a new app deployment or task-definition revision lines up with T0, the rollback is to redeploy the previous image digest with `APP_IMAGE_URI=<previous digest URI> ./infra/aws/deploy.sh`.
- The ECS service is intentionally a single task (in-memory Quartz scheduler). Never recommend scaling it above 1.
- The environment is a synthetic demo. Don't describe it as production or as bank-approved.

## Forbidden Actions
- Any AWS write: stopping or running tasks, updating the service, deploying, modifying alarms, disabling rules or schedules, or putting metric data. Don't use the default `devin-sessions` credentials for anything except the single `assume-role` call.
- Reading secrets (Secrets Manager, SSM, the `openboxes-demo/*` secrets), S3 objects, or the database directly. Logging in to the OpenBoxes UI.
- Creating issues in any repository other than AMHesch/cognition-demo, creating a second issue for the same alarm name, closing issues, merging PRs, or pushing to any branch other than a new draft-PR branch.
- Re-triggering the drill or the alarm, and posting to Slack or anywhere other than the GitHub issue.
