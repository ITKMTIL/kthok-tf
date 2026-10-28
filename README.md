# K-Thok AWS infrastructure (Terraform)

This repository is the infrastructure as code for the K-Thok cloud project. Keep it beside `kthok-client/` and `kthok-core/`:

```text
kthok/
├── kthok-tf/       # Terraform, local state, deployment instructions
├── kthok-client/   # Next.js frontend source and Dockerfile
└── kthok-core/     # NestJS backend source, Prisma migrations, Dockerfile
```

Terraform creates one VPC in two AZs, an internet-facing ALB with HTTPS, Route 53, ACM, WAF, two private Fargate workloads, ECR, private Multi-AZ RDS PostgreSQL, Secrets Manager, CloudWatch, and AWS Backup. The frontend has **three fixed tasks**; the backend has **one fixed task** because chat and Socket.IO state are in its memory. Docker builds the application images locally and pushes them to ECR; Terraform then points ECS task definitions at those ECR tags. No application source files need to be edited for this infrastructure workflow.

## Where to work and what to keep private

- Run `terraform init`, `plan`, `show`, `apply`, and `output` from `kthok-tf/`. Do not run Terraform from the former `infra/aws` path. From the parent `kthok/` directory, use `terraform -chdir=kthok-tf ...`.
- `terraform.tfvars` holds deployment settings, including image tags; `.env` holds temporary AWS CLI credentials. Both are local and Git ignored. `.env.example` and `terraform.tfvars.example` are safe starting templates. Never commit `.env`, `terraform.tfvars`, `*.tfstate*`, or `*.tfplan`.
- The repository's earlier commit tracked `infra/aws/terraform.tfstate`, `terraform.tfvars`, and saved plans. Moving those files and adding `.gitignore` does **not** erase the old Git history. Before publishing or sharing this repository, remove sensitive historical blobs from its history and rotate any credentials or secrets that were exposed. Do not use `git add -f` on the ignored files.
- This deployment currently uses **local Terraform state** in `kthok-tf/terraform.tfstate`. Preserve and securely back up that file before moving computers; losing it can make Terraform propose duplicate resources. Historical saved `.tfplan` files are stale and must never be reapplied. Generate a new plan for each change.
- `.terraform/` and `darwin_arm64/` are local provider files, not project source. They are ignored. Run `terraform init` to download the provider if the cache is missing.

### Current lab pause (recorded 27 October 2026)

The last recorded apply set `enable_services = false` and removed the two ECS services. A stop request for `kthok-prod-postgres` was accepted; its last observed status was `stopping`. This is historical information: check live AWS status before any new plan. The existing ECR repositories and images, Terraform state, DNS, ALB, NAT gateways, secrets, and database resource were retained. See **Pause and resume** below. Fixed resources still incur charges while the app is paused.

## Make an infrastructure change in the existing deployment

1. Start the Learner Lab and replace the three credentials in `.env`. Load them as shown below; verify `aws sts get-caller-identity` returns the expected account `490721063071`.
2. From `kthok-tf/`, change the relevant `.tf` file or `terraform.tfvars`. Keep the current `terraform.tfstate` in this directory. For application code changes, build and push new ECR images using section 4 first, then change the image tags in `terraform.tfvars`.
3. Run these commands in `kthok-tf/`:

   ```sh
   terraform init -lockfile=readonly
   terraform fmt -check -recursive
   terraform validate
   terraform plan -out=change.tfplan
   terraform show -no-color change.tfplan
   # Apply only after checking every add, change, and destroy in the plan.
   terraform apply change.tfplan
   ```

4. Verify the affected AWS resource and the application. If a plan or apply fails, diagnose the error and create a **new** plan; saved plans are tied to the state at the time they were created. Terraform manages the ECS task definitions and services; the Docker push itself is done by Docker after `aws ecr get-login-password` authenticates it.

## Pause and resume the existing website

To pause the app while retaining data, set `enable_services = false` in `terraform.tfvars`, create and review a fresh plan, then apply it. The expected service change is removal of the client and core ECS services. Once ECS reports zero running tasks, stop RDS separately:

```sh
terraform plan -out=pause.tfplan
terraform show -no-color pause.tfplan
terraform apply pause.tfplan
aws rds stop-db-instance --region us-east-1 --db-instance-identifier kthok-prod-postgres
aws rds describe-db-instances --region us-east-1 --db-instance-identifier kthok-prod-postgres \
  --query 'DBInstances[0].DBInstanceStatus' --output text
```

Do not repeat the stop command if the instance is already `stopping` or `stopped`. For the existing deployment, the ECS removal and RDS stop request were performed on 27 October 2026. Confirm live status before repeating anything. Stopped RDS still incurs storage and backup charges and automatically starts after seven days; NAT gateways, ALB, and WAF continue to incur charges.

To resume, refresh `.env` with the new lab credentials and load it in the current terminal. Check RDS status. If `stopped`, start it; if `available`, skip the start command. Wait until it is available, then set `enable_services = true` in `terraform.tfvars` and review a new plan before applying:

```sh
aws rds describe-db-instances --region us-east-1 --db-instance-identifier kthok-prod-postgres \
  --query 'DBInstances[0].DBInstanceStatus' --output text
aws rds start-db-instance --region us-east-1 --db-instance-identifier kthok-prod-postgres # only if stopped
aws rds wait db-instance-available --region us-east-1 --db-instance-identifier kthok-prod-postgres
terraform plan -out=resume.tfplan
terraform show -no-color resume.tfplan
terraform apply resume.tfplan
aws ecs describe-services --region us-east-1 --cluster kthok-prod \
  --services kthok-prod-client kthok-prod-core \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount}'
```

Expect three running client tasks and one running core task. Existing images remain in ECR, so resuming does not require Docker. Open `https://k-thok.space` and test login and a database-backed action after the tasks become healthy.

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

### Local Learner Lab credentials

To use the current temporary lab credentials without editing `~/.aws/credentials`, paste the three values from the Learner Lab AWS Details page into `kthok-tf/.env`. Keep the single quotes around each value; if a value contains a single quote, use shell-safe quoting instead. The file is ignored by Git and should have permissions `600`. From a new terminal, load it before using Terraform or the AWS CLI:

```sh
cd kthok-tf
chmod 600 .env
unset AWS_PROFILE
set -a
source ./.env
set +a
aws sts get-caller-identity
```

Run `source ./.env` again in each new terminal, or after changing the file. When the lab issues new credentials, replace the three values in `.env`; the old session token will expire. These credentials authorize your terminal only. ECS tasks use their configured IAM role and do not need this file to keep serving the site.

1. Have an AWS account, a deployment identity with permissions to create the listed resources and pass IAM roles, and AWS CLI credentials (prefer IAM Identity Center or another temporary-credential flow). Confirm the account with `aws sts get-caller-identity` and use `us-east-1` for this lab deployment.
2. Install Terraform 1.10+, AWS CLI v2, Docker with Buildx, and `jq`. On Apple Silicon, build images for `linux/amd64`, matching these Fargate task definitions.
3. The domain is registered at Namecheap. Use `k-thok.space` for the frontend and `api.k-thok.space` for the backend. Terraform creates the **public Route 53 hosted zone**, site/API A aliases, and DNS-validated ACM certificate. AWS assigns four name servers to the zone. Enter those four at Namecheap's **Domain List → Manage → Nameservers → Custom DNS**. Terraform cannot change Namecheap registrar settings with this AWS-only configuration. See [AWS's delegation guide](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-new-domain.html) and [Namecheap's Custom DNS steps](https://www.namecheap.com/support/knowledgebase/article.aspx/767/10/how-to-change-dns-for-a-domain/). Copy any existing Namecheap DNS records that still matter (especially email records) into Route 53 before switching name servers; they are not copied automatically.
4. Create a Google OAuth **Web** client if login is intended. Its authorized JavaScript origin must contain the frontend's `https://` origin. Give the same client ID to Terraform's `google_client_id`; it is embedded into the frontend image at build time. An empty ID intentionally enables the app's demo mode. Review Google's consent screen and app verification requirements separately.
5. Decide who can run migrations and who owns backups. The migration image is built from the existing `kthok-core/Dockerfile` `migrate` stage; no third ECR repository is created.
6. This existing deployment uses local state. For team use, plan an explicit migration to remote encrypted Terraform state and locking; do not just copy `backend.tf.example` into an existing deployment and run a fresh apply. Create a private S3 state bucket separately, enable bucket versioning and server-side encryption, and restrict IAM access to its state object and `.tflock` object. [Terraform's S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3) supports `use_lockfile = true`. Do not commit state, secret values, or `terraform.tfvars`.

## 1. Create the Route 53 zone and delegate the domain

**First deployment only.** From `kthok-tf/`; do not overwrite the existing `terraform.tfvars` or rerun this targeted plan for the already delegated `k-thok.space` zone:

```sh
cp terraform.tfvars.example terraform.tfvars
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

**First deployment only.** After the registrar uses the Route 53 name servers, run from `kthok-tf/`:

```sh
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

The first apply has `enable_services = false`. It creates ECR, networking, RDS, ALB, DNS, certificate, and task definitions, but no ECS services that would try to pull missing images. ACM issuance can wait for DNS propagation and the RDS deployment can take a while. Read the full plan and cost estimate before applying. This project has already passed this stage; use a fresh plan against its existing state for later changes.

If an apply fails partway through, do not reuse its saved `.tfplan` file. Terraform keeps successfully created resources in state. Fix the cause, run `terraform plan -out=bootstrap.tfplan` again, review the remaining changes, and apply that **new** plan. In the restricted lab account, the initial apply reached RDS but failed at `iam:CreateRole`; `existing_lab_role_arn` is the supported fallback.

## 3. Store application secrets

Use the AWS Secrets Manager console to set a long independent random **plain string** value for each secret output below. Terraform creates the secret containers only, and intentionally never writes secret contents to Terraform state. Do this before enabling the core service. Keep both values stable: changing the user hash secret changes user identity hashes; changing the session secret invalidates sessions and affects stored encrypted report evidence.

```sh
terraform output session_secret_arn
terraform output user_hash_secret_arn
```

You can generate each value locally with `openssl rand -hex 32`. Do not paste secret values into `.tf` or `.tfvars` files. The RDS master secret is created and populated by RDS automatically. The ECS execution role reads these secrets when a task starts.

## 4. Build and push all images

Run from the **workspace root** (`kthok/`) after loading AWS credentials in the same terminal. Use a new unique tag for each image build because ECR tags are immutable; a timestamp suffix also permits rebuilding the same source commit with different frontend build variables. The two repos may have different SHAs. Put the matching tags into `terraform.tfvars`. The frontend's `NEXT_PUBLIC_*` variables are baked into its image at build time; changing only ECS environment variables does not change the browser bundle.

```sh
AWS_REGION=us-east-1                    # match terraform.tfvars
SITE_DOMAIN=k-thok.space
API_DOMAIN=api.k-thok.space
GOOGLE_CLIENT_ID=your-existing-web-client-id # same value as google_client_id in terraform.tfvars
BUILD_ID=$(date +%Y%m%d%H%M%S)
CLIENT_TAG=$(git -C kthok-client rev-parse --short=12 HEAD)-$BUILD_ID
CORE_TAG=$(git -C kthok-core rev-parse --short=12 HEAD)-$BUILD_ID
CLIENT_REPO=$(terraform -chdir=kthok-tf output -raw client_repository_url)
CORE_REPO=$(terraform -chdir=kthok-tf output -raw core_repository_url)
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

For a first deployment, keep `enable_services = false`; set `client_image_tag = "<CLIENT_TAG>"`, `core_image_tag = "<CORE_TAG>"`, and `migrate_image_tag = "<CORE_TAG>-migrate"` in `terraform.tfvars`. Generate and review a fresh plan, then apply it to register the image task definitions. Set the secrets and run section 5's migration task before enabling services.

For an existing running deployment **with a new Prisma migration**, update only `migrate_image_tag` first, plan and apply, then run the migration task in section 5 and confirm exit code 0. After that, update `core_image_tag` and `client_image_tag`, plan and apply again to roll out the new app images. For a release without a migration, update the app image tags and apply one reviewed plan. A pushed image does not update a running ECS service by itself. If the code did not change and you only want to resume the paused site, **skip the build and push step** and reuse the ECR tags already configured in `terraform.tfvars`.

## 5. Run the database migration once

From `kthok-tf/`, after the migration image is pushed and task definitions have been updated:

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

For later releases, follow section 4's migration ordering and use new image tags. The frontend image must be rebuilt if any public URL or Google client ID changes. After a database password rotation, restart the core so ECS injects the new version of the RDS secret:

```sh
aws ecs update-service --region "$REGION" \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --service "$(terraform output -raw core_service_name)" \
  --force-new-deployment
```

## Scope of the Terraform files

| File | Resources |
| --- | --- |
| `versions.tf` | Terraform and AWS provider versions, Region, default tags |
| `variables.tf` / `terraform.tfvars` | Input definitions and local deployment values |
| `network.tf` | VPC, six subnets, IGW, one NAT per AZ, route tables, security groups |
| `edge.tf` | Public Route 53 zone, ACM, DNS records, ALB HTTPS and host routing, WAF |
| `data.tf` | One Multi-AZ PostgreSQL instance, subnet group, AWS Backup |
| `compute.tf` | ECR, ECS, CloudWatch logs, IAM, Secrets Manager containers |
| `outputs.tf` | Site/API URLs, ECR URLs, ECS names, RDS endpoint, and related IDs |
| `backend.tf.example` | Optional S3 remote-state configuration template; this deployed stack currently uses local state |

The database resources model the standard **one primary plus one standby RDS DB instance** with `multi_az = true`; AWS manages replication and failover. The frontend has no database security-group access. App subnets route outbound through their own AZ's NAT. ALB traffic goes directly to target groups in the private app subnets.
