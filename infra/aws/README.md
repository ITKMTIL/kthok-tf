# K-Thok on AWS

This directory is a deployable Terraform starting point for the supplied diagram. It is separate from `kthok-client/` and `kthok-core/`; no files in either application repository need to be edited. It creates one VPC in two AZs, an internet-facing ALB with HTTPS, Route 53, ACM, WAF, two private Fargate workloads, ECR, private Multi-AZ RDS PostgreSQL, Secrets Manager, CloudWatch, and AWS Backup. The frontend has **three fixed tasks**; the backend has **one fixed task** because chat and Socket.IO state are in its memory.

## Decisions and costs to review first

- The example uses `us-east-1`; choose your actual Region and two AZs in `terraform.tfvars`. AWS account AZ letters are account-specific. The domain and public Route 53 hosted zone must be yours; no domain is supplied by this package.
- This topology is relatively expensive even without users: two NAT gateways, ALB, WAF, four Fargate tasks, and Multi-AZ RDS all have ongoing charges. Check the [AWS Pricing Calculator](https://calculator.aws/) and quotas before applying.
- `db_deletion_protection = true` and ALB deletion protection are on. Avoid `terraform destroy` until data and DNS migration are planned.
- The backend's single task can be rescheduled to either AZ but existing rooms and calls lose server memory on restart, failover, or deployment. Its ECS rollout keeps only one backend task and can cause a short outage. It is not an HA chat backend.
- The RDS master credential is used by the application in this starter. For production, create a separate database role with only the required privileges and change the task credentials. RDS-managed secrets rotate every seven days by default. ECS only injects secrets at task start, so set an operations reminder or automation to force a new core deployment after each rotation and check database-backed features; otherwise a reconnect can fail with the old password.
- `sslmode=require` encrypts the PostgreSQL connection. Set up CA verification if your security requirements require server identity verification; this app image does not currently bundle an explicit RDS CA configuration.
- WAF uses AWS Common Rules and a 2,000 requests per IP rate rule. Review sampled requests and tune it for real users and campus NATs. AWS Backup retains a daily backup for 30 days; RDS also retains one day of automated backup.
- No ECS auto scaling, remote Terraform state, VPC endpoints, push-key setup, TURN service, or CloudWatch alarms are included. The frontend's 3 tasks are fixed. Those are separate operational choices, not required to follow the diagram.
- Restricted Vocareum/AWS Academy labs may deny `iam:CreateRole`. In that case, set `existing_lab_role_arn` to the account's pre-existing `LabRole` ARN. The configuration then reuses that broad role for ECS execution and AWS Backup; the containers receive no task role in this lab mode. It does not try to create or attach IAM roles/policies. This is a lab compatibility option, not a least-privilege production design. The role must already trust ECS tasks and AWS Backup and have permissions to pull ECR images, write CloudWatch logs, retrieve Secrets Manager secrets, and run backups. You also need `iam:PassRole` for this role. If any of those permissions are denied, the lab administrator must provide an appropriate role or adjust the lab policy.

## Prerequisites outside Terraform

1. Have an AWS account, a deployment identity with permissions to create the listed resources and pass IAM roles, and AWS CLI credentials (prefer IAM Identity Center or another temporary-credential flow). Confirm the account and Region with `aws sts get-caller-identity` and `aws configure get region`.
2. Install Terraform 1.10+, AWS CLI v2, Docker with Buildx, and `jq`. On Apple Silicon, build images for `linux/amd64`, matching these Fargate task definitions.
3. The domain is registered at Namecheap. Use `k-thok.space` for the frontend and `api.k-thok.space` for the backend. Terraform creates the **public Route 53 hosted zone**, site/API A aliases, and DNS-validated ACM certificate. AWS assigns four name servers to the zone. Enter those four at Namecheap's **Domain List → Manage → Nameservers → Custom DNS**. Terraform cannot change Namecheap registrar settings with this AWS-only configuration. See [AWS's delegation guide](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-new-domain.html) and [Namecheap's Custom DNS steps](https://www.namecheap.com/support/knowledgebase/article.aspx/767/10/how-to-change-dns-for-a-domain/). Copy any existing Namecheap DNS records that still matter (especially email records) into Route 53 before switching name servers; they are not copied automatically.
4. Create a Google OAuth **Web** client if login is intended. Its authorized JavaScript origin must contain the frontend's `https://` origin. Give the same client ID to Terraform's `google_client_id`; it is embedded into the frontend image at build time. An empty ID intentionally enables the app's demo mode. Review Google's consent screen and app verification requirements separately.
5. Decide who can run migrations and who owns backups. The migration image is built from the existing `kthok-core/Dockerfile` `migrate` stage; no third ECR repository is created.
6. Configure remote encrypted Terraform state and locking for team use **before the first apply**. Terraform's local state is acceptable only for a personal short-lived setup. Create a private S3 state bucket separately, enable bucket versioning and server-side encryption, and restrict IAM access to its state object and `.tflock` object. Copy `backend.tf.example` to `backend.tf`, replace its bucket and Region, then run `terraform init`. [Terraform's S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3) supports `use_lockfile = true`. Do not commit state, secret values, or `terraform.tfvars`.

## 1. Create the Route 53 zone and delegate the domain

From `infra/aws`:

```sh
cp terraform.tfvars.example terraform.tfvars
# For remote state, also copy backend.tf.example to backend.tf and edit it.
# Edit region, availability_zones, google_client_id, and image tags.
# Leave hosted_zone_id unset to let Terraform create the public zone.
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -target=aws_route53_zone.main -out=dns.tfplan
terraform apply dns.tfplan
terraform output route53_name_servers
```

This one-time targeted apply creates **only the public hosted zone** and prints its assigned name servers. In Namecheap, select `k-thok.space` → **Manage** → **Nameservers** → **Custom DNS**, paste the four values, and save. Do not replace Route 53's NS record with Namecheap's values; the direction is from Route 53 to Namecheap. Keep the zone ID and Terraform state; recreating the zone would assign different name servers. If the domain already has records needed for email or another site, copy them to Route 53 before changing Namecheap's name servers. DNS propagation may take time.

If an existing Route 53 public zone is already delegated, set `hosted_zone_id` in `terraform.tfvars` and skip the targeted apply. Never create a duplicate public zone for the same domain and then delegate to a different set of name servers.

## 2. Create the remaining infrastructure

After the registrar uses the Route 53 name servers, run from `infra/aws`:

```sh
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

The first apply has `enable_services = false`. It creates ECR, networking, RDS, ALB, DNS, certificate, and task definitions, but no ECS services that would try to pull missing images. ACM issuance can wait for DNS propagation and the RDS deployment can take a while. Read the full plan and cost estimate before applying. No AWS apply was performed when this package was written.

If an apply fails partway through, do not reuse its saved `.tfplan` file. Terraform keeps successfully created resources in state. Fix the cause, run `terraform plan -out=bootstrap.tfplan` again, review the remaining changes, and apply that **new** plan. In the restricted lab account, the initial apply reached RDS but failed at `iam:CreateRole`; `existing_lab_role_arn` is the supported fallback.

## 3. Store application secrets

Use the AWS Secrets Manager console to set a long independent random **plain string** value for each secret output below. Terraform creates the secret containers only, and intentionally never writes secret contents to Terraform state. Do this before enabling the core service. Keep both values stable: changing the user hash secret changes user identity hashes; changing the session secret invalidates sessions and affects stored encrypted report evidence.

```sh
terraform output session_secret_arn
terraform output user_hash_secret_arn
```

You can generate each value locally with `openssl rand -hex 32`. Do not paste secret values into `.tf` or `.tfvars` files. The RDS master secret is created and populated by RDS automatically. The ECS execution role reads these secrets when a task starts.

## 4. Build and push all images

Run from the **workspace root** (`kthok/`). Use an immutable tag such as each repo's commit SHA. The two repos may have different SHAs; put the matching tags into `terraform.tfvars`. The frontend's `NEXT_PUBLIC_*` variables are baked into its image at build time; changing only ECS environment variables does not change the browser bundle.

```sh
AWS_REGION=us-east-1                    # match terraform.tfvars
SITE_DOMAIN=chat.example.com            # replace with yours
API_DOMAIN=api.example.com              # replace with yours
GOOGLE_CLIENT_ID=your-web-client-id     # use '' only for demo mode
CLIENT_TAG=$(git -C kthok-client rev-parse --short=12 HEAD)
CORE_TAG=$(git -C kthok-core rev-parse --short=12 HEAD)
CLIENT_REPO=$(terraform -chdir=infra/aws output -raw client_repository_url)
CORE_REPO=$(terraform -chdir=infra/aws output -raw core_repository_url)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker buildx build --platform linux/amd64 --target runner \
  --build-arg NEXT_PUBLIC_CORE_URL="https://$API_DOMAIN" \
  --build-arg NEXT_PUBLIC_SITE_URL="https://$SITE_DOMAIN" \
  --build-arg NEXT_PUBLIC_GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" \
  -t "$CLIENT_REPO:$CLIENT_TAG" --push ./kthok-client

docker buildx build --platform linux/amd64 --target runner \
  -t "$CORE_REPO:$CORE_TAG" --push ./kthok-core

docker buildx build --platform linux/amd64 --target migrate \
  -t "$CORE_REPO:$CORE_TAG-migrate" --push ./kthok-core
```

Set `client_image_tag = "<CLIENT_TAG>"`, `core_image_tag = "<CORE_TAG>"`, and `migrate_image_tag = "<CORE_TAG>-migrate"` in `terraform.tfvars`, then apply again with `enable_services = false` to register the real task definitions. ECR tags are immutable; use new tags on each release. A pushed image does not update a running ECS service by itself.

## 5. Run the database migration once

From `infra/aws`, after the migration image is pushed and task definitions have been updated:

```sh
REGION=us-east-1 # match terraform.tfvars
CLUSTER=$(terraform output -raw ecs_cluster_name)
MIGRATE_TASK=$(terraform output -raw migrate_task_definition_arn)
SUBNET1=$(terraform output -json private_app_subnet_ids | jq -r '.[0]')
SUBNET2=$(terraform output -json private_app_subnet_ids | jq -r '.[1]')
CORE_SG=$(terraform output -raw core_security_group_id)

RUN_TASK_ARN=$(aws ecs run-task --region "$REGION" \
  --cluster "$CLUSTER" --launch-type FARGATE \
  --task-definition "$MIGRATE_TASK" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET1,$SUBNET2],securityGroups=[$CORE_SG],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$RUN_TASK_ARN"
aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$RUN_TASK_ARN" \
  --query 'tasks[0].{stoppedReason:stoppedReason,containers:containers[*].{name:name,exitCode:exitCode,reason:reason}}'
```

Require `migrate` exit code **0** and inspect `/ecs/<name>-<environment>/migrate` CloudWatch logs before starting the backend. If `run-task` returns failures or no task ARN, stop and inspect the AWS error. Run the migration on every release containing new Prisma migrations, before updating the core image. This is a one-off Fargate task, not another service or ECR repository.

## 6. Start services and verify

Set `enable_services = true`, then:

```sh
terraform plan -out=services.tfplan
terraform apply services.tfplan
terraform output site_url
terraform output api_url
```

Check both ECS services reach their desired counts, both ALB target groups become healthy, `https://<api-domain>/` responds, the site opens, Google login works, and a pair of clients can establish Socket.IO chat over WSS. Check `/ecs/<name>-<environment>/core` for database connection errors. The core can start and appear healthy even if its database connection fails, because the current app catches that error; logs and a database-backed feature must be checked. Verify RDS has no public access and its security group permits 5432 only from the core security group. Confirm the first AWS Backup job succeeds and test restoring a backup to a **separate** DB before relying on the plan.

For later releases, push new images under new tags, run any new migrations, update the three image tags in `terraform.tfvars`, then `terraform plan` and `terraform apply`. The frontend image must be rebuilt if any public URL or Google client ID changes. After a database password rotation, restart the core so ECS injects the new version of the RDS secret:

```sh
aws ecs update-service --region "$REGION" \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --service "$(terraform output -raw core_service_name)" \
  --force-new-deployment
```

## Scope of the Terraform files

| File | Resources |
| --- | --- |
| `network.tf` | VPC, six subnets, IGW, one NAT per AZ, route tables, security groups |
| `edge.tf` | Public Route 53 zone, ACM, DNS records, ALB HTTPS and host routing, WAF |
| `data.tf` | One Multi-AZ PostgreSQL instance, subnet group, AWS Backup |
| `compute.tf` | ECR, ECS, CloudWatch logs, IAM, Secrets Manager containers |

The database resources model the standard **one primary plus one standby RDS DB instance** with `multi_az = true`; AWS manages replication and failover. The frontend has no database security-group access. App subnets route outbound through their own AZ's NAT. ALB traffic goes directly to target groups in the private app subnets.
