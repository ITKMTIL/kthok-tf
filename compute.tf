data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "client" {
  name                 = "kthok-client"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "core" {
  name                 = "kthok-core"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_cloudwatch_log_group" "client" {
  name              = "/ecs/${local.prefix}/client"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "core" {
  name              = "/ecs/${local.prefix}/core"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${local.prefix}/migrate"
  retention_in_days = 30
}

resource "aws_secretsmanager_secret" "session" {
  name                    = "${local.prefix}/session-secret"
  description             = "Set a random value outside Terraform before starting core"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "user_hash" {
  name                    = "${local.prefix}/user-hash-secret"
  description             = "Set a different random value outside Terraform; keep it stable"
  recovery_window_in_days = 30
}

resource "aws_iam_role" "execution" {
  count = var.existing_lab_role_arn == null ? 1 : 0
  name  = "${local.prefix}-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  count      = var.existing_lab_role_arn == null ? 1 : 0
  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_secrets" {
  count = var.existing_lab_role_arn == null ? 1 : 0
  name  = "${local.prefix}-read-secrets"
  role  = aws_iam_role.execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_db_instance.postgres.master_user_secret[0].secret_arn,
        aws_secretsmanager_secret.session.arn,
        aws_secretsmanager_secret.user_hash.arn
      ]
    }]
  })
}

resource "aws_iam_role" "task" {
  count = var.existing_lab_role_arn == null ? 1 : 0
  name  = "${local.prefix}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

locals {
  execution_role_arn = var.existing_lab_role_arn == null ? aws_iam_role.execution[0].arn : var.existing_lab_role_arn
  task_role_arn      = var.existing_lab_role_arn == null ? aws_iam_role.task[0].arn : null
  backup_role_arn    = var.existing_lab_role_arn == null ? aws_iam_role.backup[0].arn : var.existing_lab_role_arn
}

resource "aws_ecs_cluster" "main" {
  name = local.prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  # RDS rotates its master password. ECS resolves the current secret version each time
  # a task starts, then Node builds Prisma's URL without storing a password in state.
  database_url_js = <<-JS
    const u = new URL('postgresql://' + process.env.DB_HOST + ':' + process.env.DB_PORT + '/' + process.env.DB_NAME);
    u.username = process.env.DB_USER;
    u.password = process.env.DB_PASSWORD;
    u.searchParams.set('schema', 'public');
    if (process.env.DB_SSL === 'true') u.searchParams.set('sslmode', 'require');
    process.env.DATABASE_URL = u.toString();
    delete process.env.DB_PASSWORD;
    delete process.env.DB_USER;
  JS

  db_environment = [
    { name = "DB_HOST", value = aws_db_instance.postgres.address },
    { name = "DB_PORT", value = tostring(aws_db_instance.postgres.port) },
    { name = "DB_NAME", value = aws_db_instance.postgres.db_name },
    { name = "DB_SSL", value = tostring(var.force_ssl_db) }
  ]

  db_secrets = [
    { name = "DB_USER", valueFrom = "${aws_db_instance.postgres.master_user_secret[0].secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${aws_db_instance.postgres.master_user_secret[0].secret_arn}:password::" }
  ]
}

resource "aws_ecs_task_definition" "client" {
  family                   = "${local.prefix}-client"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([{
    name         = "client"
    image        = "${aws_ecr_repository.client.repository_url}:${var.client_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 3000, hostPort = 3000, protocol = "tcp" }]
    environment  = [{ name = "NEXT_PUBLIC_SITE_URL", value = "https://${var.site_domain}" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.client.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "core" {
  family                   = "${local.prefix}-core"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([{
    name         = "core"
    image        = "${aws_ecr_repository.core.repository_url}:${var.core_image_tag}"
    essential    = true
    entryPoint   = ["node", "-e"]
    command      = ["${local.database_url_js}\nrequire('./dist/main');"]
    portMappings = [{ containerPort = 3001, hostPort = 3001, protocol = "tcp" }]
    environment = concat(local.db_environment, [
      { name = "PORT", value = "3001" },
      { name = "CLIENT_ORIGIN", value = "https://${var.site_domain}" },
      { name = "GOOGLE_CLIENT_ID", value = var.google_client_id },
      { name = "ADMIN_STUDENT_IDS", value = var.admin_student_ids }
    ])
    secrets = concat(local.db_secrets, [
      { name = "SESSION_SECRET", valueFrom = aws_secretsmanager_secret.session.arn },
      { name = "USER_HASH_SECRET", valueFrom = aws_secretsmanager_secret.user_hash.arn }
    ])
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.core.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.prefix}-migrate"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([{
    name        = "migrate"
    image       = "${aws_ecr_repository.core.repository_url}:${var.migrate_image_tag}"
    essential   = true
    entryPoint  = ["node", "-e"]
    command     = ["${local.database_url_js}\nconst r = require('node:child_process').spawnSync('pnpm', ['exec', 'prisma', 'migrate', 'deploy'], { stdio: 'inherit', env: process.env }); process.exit(r.status ?? 1);"]
    environment = local.db_environment
    secrets     = local.db_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "client" {
  count                             = var.enable_services ? 1 : 0
  name                              = "${local.prefix}-client"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.client.arn
  desired_count                     = 3
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60
  enable_execute_command            = false
  wait_for_steady_state             = true

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.client.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.client.arn
    container_name   = "client"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener_rule.site, aws_iam_role_policy_attachment.execution]
}

resource "aws_ecs_service" "core" {
  count                              = var.enable_services ? 1 : 0
  name                               = "${local.prefix}-core"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.core.arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = 90
  enable_execute_command             = false
  wait_for_steady_state              = true
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.core.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.core.arn
    container_name   = "core"
    container_port   = 3001
  }

  depends_on = [aws_lb_listener_rule.api, aws_iam_role_policy.read_secrets]
}
