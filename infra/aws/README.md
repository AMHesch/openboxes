# OpenBoxes AWS demo: network and data

[Executive demo runbook](DEMO-RUNBOOK.md) — narrative, rehearsal checklist, and recovery steps.

These stacks provide a synthetic, temporary OpenBoxes demo VPC, private MySQL 8.4.11 RDS instance, application database secret, versioned uploads bucket and S3 Files file system, ECR repository, ECS cluster, one-shot database initialization task, application service, CloudFront distribution, and monthly budget. This is a synthetic demo environment, not a bank-approved deployment.

## Deploy

Use the default OIDC-backed AWS CLI credentials in account `077510937834`. The scripts target `us-east-1` and refuse to run against another account. The preflight requires AWS CLI v2, `jq`, and `cfn-lint` 1.57.0; put `cfn-lint` on `PATH` or set `CFN_LINT` to its executable path.

```bash
./infra/aws/deploy.sh
./infra/aws/run-db-init.sh
./infra/aws/run-db-init.sh
```

`deploy.sh` runs `preflight.sh` before deploying. The preflight fetches CloudFormation registry schemas for every resource in `network.yaml` and `data.yaml`, and also `app.yaml` when present, then lints those templates. It asks ECS to validate temporary task-definition revisions for the DB-init and application task when the data stack and `APP_IMAGE_URI` provide real values. The app registration uses the existing DB-init execution role only for this API-side shape check; the app task and execution roles are created by the first app-stack deployment. It is not run as a task. The CloudFront URL in this temporary definition is a placeholder because CloudFront creates that hostname. With the pinned `cfn-lint` 1.57.0, the registry-schema run ignores E1020, E6101, and E1041 because the downloaded AWS schemas raise `anyOf` exceptions for intrinsic references and mischeck the DB-init log-group `Ref`. It also ignores W3010 for the fixed Availability Zones required by the spec. Set `SKIP_PREFLIGHT=1` only when intentionally bypassing these checks.

The acceptance check confirmed that this `cfn-lint` version does not reject `S3FilesFileSystem.Bucket: !Ref UploadsBucket`; CloudFormation's registry rejects that bucket-name form. Keep the ARN-valued `!GetAtt UploadsBucket.Arn` in `data.yaml`.

The network stack is deployed before the data stack. The one-shot task receives a public IP in a public subnet so it can pull the public MySQL image and RDS CA bundle; it has no inbound rules. App task ingress is limited to the ALB security group, ALB ingress is limited to the CloudFront origin-facing prefix list, and the database uses private subnets.

The container health check probes `http://127.0.0.1:8080/openboxes/health` with a 10-second timeout and five retries; the investigator can read the RDS `error` and `slowquery` logs.

For a diagnostic data- or app-stack deployment that preserves resources if creation fails, opt in with `DISABLE_ROLLBACK=1`. The default deploy behavior is unchanged; use this only when you need to inspect and manually recover a failed deployment.

The initialization task is safe to repeat. It creates the `openboxes` schema using `utf8`/`utf8_general_ci`, creates the SSL-required application user with only the schema grants needed by OpenBoxes, and prints connection/schema verification results without printing passwords.

## Verify and rollback

Run `./infra/aws/run-db-init.sh` twice and confirm both executions exit successfully. Inspect the exported outputs with `aws cloudformation describe-stacks --stack-name openboxes-demo-data --region us-east-1 --query 'Stacks[0].Outputs'`. CloudFormation rolls back a failed create/update automatically. To retire the demo, run the cleanup command below; it removes the dependent app and observability stacks itself.

## Outputs

The data stack exports the DB endpoint and port, master and app secret ARNs, uploads bucket name, S3 Files file system and access point ARNs, ECR repository URI, ECS cluster name, and DB-init task definition ARN. The network stack exports its VPC, subnet, and security-group IDs for later demo stacks. The app stack outputs the CloudFront domain and URL, ALB DNS name, ECS service and task-definition names, and application log group.

## Cost and cleanup

The monthly budget is USD 150, with an actual-cost alert above 80% and a forecast alert above 100%, sent to `amhesch@gmail.com`. These are alerts, not a spending cap. ECS tasks use public IPs in public subnets rather than a NAT gateway to keep this temporary demo smaller and less expensive; inbound access remains restricted by security groups. The `Project` cost-allocation tag must be activated once in Billing before tagged costs appear in the budget; this script does not change that account setting. Charges continue while resources remain deployed.

Start cleanup explicitly when the demo is retired:

```bash
./infra/aws/cleanup.sh --yes
```

Cleanup deletes the observability stack and its webhook secret, empties the unversioned ALB access-log bucket if the app stack exists, then deletes the app stack. It disables DB deletion protection, empties uploads object versions and delete markers, removes ECR images, and deletes the data stack before deleting the leftover RDS `error`/`slowquery` and Container Insights log groups and the network stack. The RDS deletion policy retains a final snapshot; the script prints its identifier and a separate command to delete it if appropriate. Do not run cleanup while later PRs still depend on these stacks.

## Build, deploy, and cut over the application

Build and push the existing WAR without rebuilding it when it is already present. The script builds the upstream base image from `build/docker`, adds the RDS CA truststore, pushes an immutable Git-SHA/timestamp tag, and prints the ECR digest URI. Use that digest for every deployment:

```bash
IMAGE_URI="$(./infra/aws/build-push.sh)"
APP_IMAGE_URI="$IMAGE_URI" DESIRED_COUNT=0 DISABLE_ROLLBACK=1 ./infra/aws/deploy.sh
./infra/aws/migrate.sh
```

The app deploy first creates `openboxes-demo-app` with zero tasks. `migrate.sh` performs a read-only dump from the running `baseline-mysql`, strips DEFINER clauses, compresses and uploads it under `migration/<timestamp>/` (outside the S3 Files `uploads/` prefix), presigns it for 15 minutes, then runs the DB-init task in restore mode with TLS identity verification. On success, it deletes the dump object, updates the app stack's `DesiredCount` to 1, and waits for ECS stability. The default restore refuses to overwrite an `openboxes` schema with tables; use `./infra/aws/migrate.sh --force` only when intentionally replacing that schema. The restore task registers a temporary revision in the existing DB-init family to inject the generated admin UI password as an ECS secret, then deregisters and deletes that revision after the task stops.

The app stack generates the admin UI password at `openboxes-demo/admin-ui`; retrieve it from Secrets Manager only when needed, and never put it in shell history or logs. The generated value replaces the default `admin/password` account credential during restore.

The app uses Java 8-compatible heap bounds (`-Xms2048m -Xmx2867m`) for its 4-GiB task. The upstream Temurin 8u504 image rejects `InitialRAMPercentage` and `MaxRAMPercentage`; these fixed bounds preserve the specified 50% initial / 70% maximum sizing.

The pool configuration sets `maxActive=20`. The local concurrency check did not prove the requested `maxIdle=10` cap, so that property is intentionally omitted.

Use the PR 1 browser journey in a separate worktree, without merging it into this branch:

```bash
git worktree add /home/ubuntu/journey-wt devin/1790640578-baseline-journey
cd /home/ubuntu/journey-wt/e2e/demo-journey
npm install
BASE_URL="https://<CloudFrontDomain>/openboxes" OB_USER=admin OB_PASSWORD="<admin-ui-secret>" npm test
BASE_URL="https://<CloudFrontDomain>/openboxes" OB_USER=admin OB_PASSWORD="<admin-ui-secret>" PRODUCT_CODE="<baseline-product-code>" npm run test:verify
```

The journey state records the product code; use it for the persistence check after restarting the ECS service task. Keep the Playwright screenshots, video, trace, and HTML report as deployment evidence.

## Application verification and rollback

Verify the app stack is `CREATE_COMPLETE` and the ECS service is stable with exactly one running task. Confirm `https://<CloudFrontDomain>/openboxes/health` returns `{"status":"UP"}`; `/openboxes/dbconsole`, `/openboxes/console`, `/openboxes/env`, and `/openboxes/info` return 403 through CloudFront; direct ALB requests time out from outside CloudFront's origin-facing prefix list (requests from CloudFront without `X-Origin-Verify` get the listener's default 403); and the task public IP is not reachable on port 8080. Confirm `admin/password` cannot log in. Inspect the app logs for successful Liquibase startup, no startup stack traces, `sslMode=VERIFY_IDENTITY`, and no `allowPublicKeyRetrieval`. Force a new ECS deployment, confirm the task ARN changes, and rerun the Playwright persistence spec. A one-off app task should write an `uploads/probe-<timestamp>.txt` file through `/app/uploads`; record how long it takes to appear in the bucket, then delete the probe. Objects land under `uploads/uploads/` because the file system prefix is `uploads/` and the access point root is `/uploads`; about 66 seconds was observed.

Use `DISABLE_ROLLBACK=1` for the initial app-stack create so failed creates remain available for inspection. CloudFormation rejects task-definition replacement updates when rollback is disabled; if an update is left in `UPDATE_FAILED`, run `aws cloudformation rollback-stack --stack-name openboxes-demo-app`, wait for `UPDATE_ROLLBACK_COMPLETE`, and retry with rollback enabled. Inspect events and update the existing stack after correcting a mechanical issue; do not delete and recreate it unless an update cannot recover it. If restore fails, keep the service at zero and retain the uploaded migration object for diagnosis or retry. Once restore and cutover succeed, scaling the service back to zero is a reversible rollback that leaves the app and data stacks intact:

```bash
APP_IMAGE_URI="<current-image-digest-uri>" DESIRED_COUNT=0 SKIP_PREFLIGHT=1 ./infra/aws/deploy.sh
```

Do not run `cleanup.sh` while this app stack or any later stack depends on the network/data stacks.

## Observability and incident drill

The observability stack is deployed after the application stack and leaves the application service running:

```bash
./infra/aws/deploy-observability.sh
```

The helper resolves the CloudFront application URL, ALB and target-group CloudWatch dimensions, and uses the documented Main Warehouse location id `1` unless `LOCATION_ID` is supplied. The id was determined from the deployed login flow: after a successful login, the Main Warehouse link is `/openboxes/dashboard/chooseLocation/1?targetUri=`. Set `PROBE_STATE=DISABLED` only when intentionally pausing the one-minute schedule. Set `WEBHOOK_URL` only after creating `openboxes-demo/devin-webhook`; the helper verifies that secret with `describe-secret` and never reads or prints its value.

Resources include the 14-day `/openboxes-demo/probe` log group, a Python 3.12 Lambda login probe, a least-privilege probe role, an EventBridge Scheduler schedule (`rate(1 minute)` with retries disabled), lock-wait and Spring Boot error metric filters on `/openboxes-demo/app`, six child CloudWatch alarms and the `openboxes-demo-user-impact` composite alarm, the `openboxes-demo` dashboard, and the read-only `openboxes-demo-investigator` role. The probe reads only `openboxes-demo/admin-ui-*`, uses an HTTP cookie jar, submits the deployed form at `/auth/handleLogin`, selects the configured location, and emits one EMF JSON line per invocation. It never logs the password, cookies, or response bodies.

| Alarm | Metric and threshold | Missing data |
| --- | --- | --- |
| `openboxes-demo-login-probe-failing` | `LoginFailure >= 1` in 2 of 3 one-minute periods | Not breaching |
| `openboxes-demo-lock-wait-timeouts` | `LockWaitTimeouts >= 1` in 1 of 1 one-minute period | Not breaching |
| `openboxes-demo-login-probe-slow` | `LoginLatencyMs >= 10000` in 2 of 3 one-minute periods | Not breaching |
| `openboxes-demo-app-errors` | `AppErrorLines >= 3` in 2 of 3 one-minute periods | Not breaching |
| `openboxes-demo-alb-target-5xx` | ALB target 5xx `>= 3` in 2 of 3 one-minute periods | Not breaching |
| `openboxes-demo-no-healthy-target` | `HealthyHostCount < 1` in 3 of 3 one-minute periods | Breaching |
| `openboxes-demo-user-impact` | Composite: any of the six child alarms is in ALARM | Derived from child alarms |

Devin is alerted by the `openboxes-demo-user-impact` composite alarm, which enters ALARM when any of its six children does: `openboxes-demo-login-probe-failing`, `openboxes-demo-login-probe-slow`, `openboxes-demo-lock-wait-timeouts`, `openboxes-demo-app-errors`, `openboxes-demo-alb-target-5xx`, or `openboxes-demo-no-healthy-target`. When `WEBHOOK_URL` is supplied, the stack creates the API-key connection using the dynamic reference `openboxes-demo/devin-webhook`, a one-request-per-second destination, an SSE-enabled four-day SQS DLQ, and a rule that forwards only the composite alarm's `ALARM` state-change event with two retries and a 3,600-second maximum event age. The complete CloudWatch event is sent as the request body without an input transformer.

The dashboard includes alarm state, probe success/failure/latency and Lambda errors, application lock/error metrics, ALB request/5xx/latency metrics, ECS CPU/memory, RDS CPU/connections/freeable memory, and Logs Insights views for application and drill events. The investigator role trusts only `arn:aws:iam::077510937834:role/devin-sessions`; it permits read-only CloudWatch, Logs, ECS describe/list, RDS describe/log, ELB describe, EC2 security-group/network-interface describe, CloudTrail lookup, EventBridge describe/list, Scheduler get, and probe Lambda configuration reads. It does not grant Secrets Manager, S3, SSM, ECS execute-command/run-task/stop-task/update-service, or any write action.

### Incident drill

The drill uses the existing DB-init Fargate task definition and the same public subnets, one-shot security group, public IP, TLS CA bundle, and application secret wiring as `run-db-init.sh`. It starts a transaction, locks the `admin` row with `SELECT id ... FOR UPDATE`, emits a JSON lock-acquired event, sleeps, rolls back, and emits a JSON lock-released event. It does not modify data.

```bash
./infra/aws/drill.sh start [--seconds N]  # 60 through 900; default 600
./infra/aws/drill.sh status
./infra/aws/drill.sh stop
```

The expected sequence is task start, lock acquisition in `/openboxes-demo/db-init`, the next probe failure, the first `LockWaitTimeouts` datapoint, a child alarm and the `openboxes-demo-user-impact` composite entering `ALARM`, then `drill.sh stop`, probe recovery, and all active alarms returning to `OK`. The measured UTC timeline is recorded with the PR verification evidence and should be used rather than assuming fixed propagation times. `/openboxes/health` should remain up and the ECS application task ARN should remain unchanged. In the verified run, the first probe failure came about 80 s after the drill task started (`choose_location` returned HTTP 500 after about 57 s), the lock-wait alarm fired about 2 min in, and the probe alarm about 3 min in. After `drill.sh stop`, the next probe succeeded within about 35 s and both alarms returned to `OK` within about 3 min.

The Devin investigation playbook is versioned at `infra/aws/incident/playbook.md`. It is read-only: it assumes `openboxes-demo-investigator`, deduplicates by the earliest-triggering child's `incidentKey`, and leaves every mitigation to a human.

Known limitations: CloudWatch metric filters and alarms are intentionally fixed to the thresholds above; the direct ALB is not reachable from an external runner when ingress is limited to the CloudFront origin-facing prefix list; and Lambda `Errors` appears on the dashboard to expose probe-runtime failures even though the synthetic `LoginFailure` alarm treats missing data as not breaching.
