# OpenBoxes AWS demo: network and data

This stack pair provides a synthetic, temporary OpenBoxes demo VPC, private MySQL 8.4.11 RDS instance, application database secret, versioned uploads bucket and S3 Files file system, ECR repository, ECS cluster, one-shot database initialization task, and monthly budget. This is a synthetic demo environment, not a bank-approved deployment.

## Deploy

Use the default OIDC-backed AWS CLI credentials in account `077510937834`. The scripts target `us-east-1` and refuse to run against another account. The preflight requires AWS CLI v2, `jq`, and `cfn-lint` 1.57.0; put `cfn-lint` on `PATH` or set `CFN_LINT` to its executable path.

```bash
./infra/aws/deploy.sh
./infra/aws/run-db-init.sh
./infra/aws/run-db-init.sh
```

`deploy.sh` runs `preflight.sh` before deploying. The preflight fetches the CloudFormation registry schemas for both templates and lints them, then asks ECS to validate a temporary DB-init task-definition revision when the data stack already provides real values. On the first deployment, the ECS check is skipped until those values exist; run `./infra/aws/preflight.sh` again after deployment to exercise it. With the pinned `cfn-lint` 1.57.0, the registry-schema run ignores E1020, E6101, and E1041 because the downloaded AWS schemas raise `anyOf` exceptions for intrinsic references and mischeck the DB-init log-group `Ref`. It also ignores W3010 for the fixed Availability Zones required by the spec. Set `SKIP_PREFLIGHT=1` only when intentionally bypassing these checks.

The acceptance check confirmed that this `cfn-lint` version does not reject `S3FilesFileSystem.Bucket: !Ref UploadsBucket`; CloudFormation's registry rejects that bucket-name form. Keep the ARN-valued `!GetAtt UploadsBucket.Arn` in `data.yaml`.

The network stack is deployed before the data stack. The one-shot task receives a public IP in a public subnet so it can pull the public MySQL image and RDS CA bundle; it has no inbound rules. App task ingress is limited to the ALB security group, ALB ingress is limited to the CloudFront origin-facing prefix list, and the database uses private subnets.

For a diagnostic data-stack deployment that preserves resources if creation fails, opt in with `DISABLE_ROLLBACK=1 ./infra/aws/deploy.sh`. The default deploy behavior is unchanged; use this only when you need to inspect and manually recover a failed deployment.

The initialization task is safe to repeat. It creates the `openboxes` schema using `utf8`/`utf8_general_ci`, creates the SSL-required application user with only the schema grants needed by OpenBoxes, and prints connection/schema verification results without printing passwords.

## Verify and rollback

Run `./infra/aws/run-db-init.sh` twice and confirm both executions exit successfully. Inspect the exported outputs with `aws cloudformation describe-stacks --stack-name openboxes-demo-data --region us-east-1 --query 'Stacks[0].Outputs'`. CloudFormation rolls back a failed create/update automatically; if the demo should be removed after dependent stacks are gone, use the explicit cleanup command below.

## Outputs

The data stack exports the DB endpoint and port, master and app secret ARNs, uploads bucket name, S3 Files file system and access point ARNs, ECR repository URI, ECS cluster name, and DB-init task definition ARN. The network stack exports its VPC, subnet, and security-group IDs for later demo stacks.

## Cost and cleanup

The monthly budget is USD 150, with an actual-cost alert above 80% and a forecast alert above 100%, sent to `amhesch@gmail.com`. These are alerts, not a spending cap. ECS tasks use public IPs in public subnets rather than a NAT gateway to keep this temporary demo smaller and less expensive; inbound access remains restricted by security groups. The `Project` cost-allocation tag must be activated once in Billing before tagged costs appear in the budget; this script does not change that account setting. Charges continue while resources remain deployed.

After dependent app and observability stacks have been removed, cleanup can be started explicitly:

```bash
./infra/aws/cleanup.sh --yes
```

Cleanup empties uploads object versions and delete markers, removes ECR images, disables DB deletion protection, then deletes the data and network stacks. The RDS deletion policy retains a final snapshot; the script prints its identifier and a separate command to delete it if appropriate. Do not run cleanup while later PRs still depend on these stacks.
