# OpenBoxes on AWS: executive demo runbook

This is a synthetic, temporary environment built for a 10–15 minute demo. It is not bank-approved infrastructure, holds no customer data, and has not been reviewed against any bank's controls. Account `077510937834`, region `us-east-1`.

## Story

1. **Forward-deployed engineer (about 6 min).** Devin took the OpenBoxes application from a local, on-premises-style MySQL deployment to AWS. It defined the environment as CloudFormation, migrated the data, and proved the same browser journey on both environments.
2. **SRE (about 8 min).** A deliberate, safe database-lock fault breaks logins while `/health` stays green. CloudWatch fires an alarm, EventBridge starts a Devin investigation, and Devin correlates the evidence read-only and files one deduplicated issue in the private tracker. A human approves and runs the mitigation, and Devin-style read-only checks verify recovery.

## Architecture (as deployed)

```
Browser --HTTPS--> CloudFront (dzyqgt7ow5g6a.cloudfront.net)
          --HTTP 80, origin-facing prefix list + X-Origin-Verify header--> ALB (2 public subnets)
          --HTTP 8080, ALB security group only--> ECS Fargate, exactly 1 task (1 vCPU / 4 GiB, public IP, no NAT)
               |--TLS 3306 (VERIFY_IDENTITY), app SG only--> RDS MySQL 8.4.11 db.t4g.micro (private subnets, encrypted, 7-day backups)
               |--NFS/TLS 2049--> S3 Files mount at /app/uploads --> versioned, SSE-S3 uploads bucket
               '--HTTPS 443--> ECR, Secrets Manager, CloudWatch Logs
Lambda login probe (every minute) --> CloudWatch metrics/alarms/dashboard
    alarm openboxes-demo-login-probe-failing (ALARM only) --> EventBridge --> Devin automation webhook --> read-only investigator role
```

Stacks: `openboxes-demo-network`, `openboxes-demo-data`, `openboxes-demo-app`, `openboxes-demo-observability`. PRs: AMHesch/openboxes #1 (journey), #2 (network and data), #3 (app and migration), #4 (observability, drill, and investigator). Incident issues go to the private AMHesch/cognition-demo repository, never the public fork.

## Before the demo

Do all of this at least 30 minutes before the meeting.

1. **No deploys within 30 minutes of the demo.** Any app deploy stops the single task before starting the new one (to avoid duplicate in-memory Quartz jobs). That means about 5–7 minutes of 502/503 and a real login-probe alarm.
2. **Leave at least 1 hour between rehearsals and the demo.** The Devin automation allows at most 3 runs per hour, 1 at a time, with no queue, so an alarm during a running investigation is dropped.
3. **Health check:**
   ```bash
   aws cloudwatch describe-alarms --alarm-name-prefix openboxes-demo- --query 'MetricAlarms[].[AlarmName,StateValue]' --output text   # all OK
   aws ecs describe-services --cluster openboxes-demo --services openboxes-demo-app --query 'services[0].[runningCount,deployments[0].rolloutState]'   # 1, COMPLETED
   ./infra/aws/drill.sh status   # no drill running
   curl -s https://dzyqgt7ow5g6a.cloudfront.net/openboxes/health   # {"status":"UP"}
   ```
4. **Close the open incident issue** in AMHesch/cognition-demo if you want the demo to create a fresh issue. While an issue for the alarm is open, a new event becomes a comment on it instead.
5. **Open these tabs:**
   - The app (admin password is in Secrets Manager `openboxes-demo/admin-ui`; do not show it on screen).
   - The CloudWatch dashboard `openboxes-demo`.
   - The alarm `openboxes-demo-login-probe-failing`.
   - Devin sessions filtered by the tag `incident`.
   - AMHesch/cognition-demo issues.
   - PR #4.

## Live sequence (T = drill start)

Start the drill at the beginning of the talk, so the investigation is ready by the SRE segment:

```bash
./infra/aws/drill.sh start --seconds 900
```

| T + | What happens (measured 2026-09-29) | What to show |
| --- | --- | --- |
| 0:00 | Drill task starts: one-shot Fargate task, `SELECT ... FOR UPDATE` on the `admin` user row | Migration story, PRs, smoke-test video |
| ~1:30 | First probe failure: `choose_location` returns HTTP 500 after about 51 s; `/health` stays UP | Dashboard: login failures and lock waits rising, health still green |
| ~3:00 | `openboxes-demo-lock-wait-timeouts` goes to ALARM | |
| ~3:45 | `openboxes-demo-login-probe-failing` goes to ALARM; EventBridge invokes the Devin webhook | The alarm and its routing rule |
| ~5:00 | The Devin session assumes `openboxes-demo-investigator` (read-only) | The live Devin session |
| ~9:30 | Issue or comment in AMHesch/cognition-demo: cause, evidence vs inference, confidence, mitigation command | The issue |
| ~10:00 | **Human approval:** the presenter reads the recommendation and runs `./infra/aws/drill.sh stop` | The approval moment |
| ~10:35 | Next probe succeeds | Dashboard |
| ~13:00 | Both alarms back to OK; verify read-only and post `Recovery verified <UTC>` on the issue | Alarm and issue |

A 900 s drill ends on its own at about T+15:00. With 600 s, the drill expired before the approval step in rehearsal, so use 900 s for the live demo.

**Recovery verification** is read-only:

```bash
aws cloudwatch describe-alarms --alarm-names openboxes-demo-login-probe-failing openboxes-demo-lock-wait-timeouts --query 'MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' --output text
aws logs filter-log-events --log-group-name /openboxes-demo/probe --start-time $(( ($(date +%s)-300)*1000 )) --filter-pattern '"outcome"' --query 'events[].message' --output text
```

## If something goes wrong live

| Symptom | Action |
| --- | --- |
| No Devin session within 3 minutes of the ALARM | Check EventBridge `FailedInvocations` and the DLQ `openboxes-demo-incident-dlq`. Then show the rehearsal issue AMHesch/cognition-demo#1 as the recorded result. |
| The investigation is slow | Continue the narrative. The drill holds the lock for 15 minutes, so there is time; stop the drill whenever you need to. |
| The alarm fires with no drill running | A real event: most likely a task replacement. The investigator distinguishes this (see the 18:05 re-fire on issue #1). |
| The app is down after a deploy | Wait 5–7 minutes for JVM startup. Do not scale above 1 task. |

## Rollback

- **Stop the drill:** `./infra/aws/drill.sh stop`. The transaction rolls back and no data changes.
- **Pause the alarm-to-Devin route:** `aws events disable-rule --name openboxes-demo-alarm-to-devin`. Re-enable it with `enable-rule`.
- **Pause the probe:** `PROBE_STATE=DISABLED ./infra/aws/deploy-observability.sh`, passing the current `WEBHOOK_URL`.
- **Park the app** (keeps data): `APP_IMAGE_URI=<current digest URI> DESIRED_COUNT=0 SKIP_PREFLIGHT=1 ./infra/aws/deploy.sh`. Scale back with `DESIRED_COUNT=1`, which takes about 5–7 minutes.
- **Roll back the image:** redeploy with the previous digest URI. Images are immutable, digest-pinned, and never `latest`.
- **Roll back the database:** restore from the automated backups (7 days) or the final snapshot kept on stack deletion.

## Cost

These are estimates from us-east-1 on-demand list prices. The `Project=openboxes-demo` cost-allocation tag must be activated in Billing before Cost Explorer can show actual tagged spend. A USD 150/month budget alerts (it does not cap) at 80% actual and 100% forecast.

| Resource | Running / month | Parked (0 tasks) / month |
| --- | --- | --- |
| Fargate, 1 vCPU / 4 GiB x86, 24x7 | ~$42.50 | $0 |
| ALB, including LCUs | ~$18–22 | ~$17 |
| Public IPv4 (ALB x2 + task) | ~$10.95 | ~$7.30 |
| RDS db.t4g.micro, 20 GB gp3, single AZ | ~$14 | ~$14 |
| CloudWatch: Container Insights, logs, 4 alarms, dashboard, probe metrics | ~$6–10 | ~$2–4 |
| 6 Secrets Manager secrets | ~$2.40 | ~$2.40 |
| S3, S3 Files, ECR (0.6 GB), CloudFront, Lambda, Scheduler, EventBridge, SQS | ~$1–3 | ~$1 |
| **Total** | **~$95–105 (~$3.20–3.50/day)** | **~$35–45** |

There is no NAT Gateway, which saves about $34/month; the trade-off is the task's public IP. Devin usage (ACUs) is billed separately.

## Cleanup

```bash
./infra/aws/cleanup.sh --yes
```

The script:
1. Deletes the observability stack and the webhook secret.
2. Empties the ALB access-log bucket and deletes the app stack.
3. Disables RDS deletion protection, empties the versioned uploads bucket, deletes ECR images, and deletes the data stack. RDS keeps a final snapshot; the script prints the command to delete it.
4. Deletes the leftover RDS and Container Insights log groups, then the network stack.

Outside AWS stacks, remove these by hand when the demo is retired:
- The Devin automation "OpenBoxes demo — CloudWatch alarm investigation".
- The playbook `!openboxes_incident`.
- The inline IAM policy `openboxes-demo-iam` on `devin-sessions`.
- The incident issues in AMHesch/cognition-demo.

## Security limitations

These are known and accepted for a synthetic demo:
- **Public IP on the app task, no NAT.** Inbound traffic is limited to the ALB security group, and egress to 443, 3306 and 2049. It is still below best practice; production would use private subnets with VPC endpoints or NAT.
- **CloudFront to ALB is HTTP on port 80 over the internet.** It is restricted by the CloudFront origin-facing prefix list and a secret `X-Origin-Verify` header. There is no custom domain, ACM certificate on the ALB, or AWS WAF. Production would use HTTPS to the origin, or a CloudFront VPC origin with an internal ALB, plus WAF.
- **Single task and single-AZ RDS.** There is no high availability: deploys and task replacements cause 5–7 minute outages. Background jobs run in memory, which is why the app runs exactly one task.
- **The synthetic probe logs in as `admin`** with the Secrets Manager password. Production would use a dedicated low-privilege probe user.
- **Devin is an external control and data plane.** Alarm events and read-only AWS evidence (metrics, logs, ECS/RDS metadata, CloudTrail) leave the account to Devin's hosted service and GitHub. This is not suitable for a bank that has not approved an external data plane, or that allows inference only through Amazon Bedrock, without a separate architecture review.
- **Investigator guardrails.** Devin's default role can assume `openboxes-demo-investigator`, which has read-only CloudWatch, Logs, ECS, RDS, ELB, CloudTrail, EventBridge and Scheduler access, and no Secrets Manager, SSM, S3 object, database, or write access. Guardrails are IAM plus the playbook's instructions. Mitigation is always human-approved and human-run.
- **Deploy role.** The deployment role `devin-sessions` has broad create permissions in the account, with IAM limited to `openboxes-demo-*` roles. Production would use a pipeline role with change approval.
- **The webhook is authenticated with a shared header secret** held in Secrets Manager and referenced by the EventBridge connection. It was never printed or committed.
- **Audit.** CloudTrail event history plus the existing account trail; ALB access logs are kept 14 days and app/probe logs 14 days. There is no centralized SIEM.
- **Data.** Synthetic only. RDS and S3 are encrypted at rest with AWS-managed keys (no customer-managed KMS), and the database connection uses TLS with identity verification. The database character set is 3-byte `utf8` for upstream compatibility.
- **Known upstream and ops quirk.** S3 Files stores objects under `uploads/uploads/` because of the access-point root.
