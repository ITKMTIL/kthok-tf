resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "postgres" {
  identifier                   = "${local.prefix}-postgres"
  engine                       = "postgres"
  instance_class               = var.db_instance_class
  allocated_storage            = var.db_allocated_storage
  max_allocated_storage        = var.db_max_allocated_storage
  storage_type                 = "gp3"
  storage_encrypted            = true
  db_name                      = "kthok"
  username                     = "kthok_admin"
  manage_master_user_password  = true
  multi_az                     = true
  db_subnet_group_name         = aws_db_subnet_group.main.name
  vpc_security_group_ids       = [aws_security_group.rds.id]
  publicly_accessible          = false
  backup_retention_period      = 1
  deletion_protection          = var.db_deletion_protection
  skip_final_snapshot          = false
  final_snapshot_identifier    = "${local.prefix}-final"
  auto_minor_version_upgrade   = true
  performance_insights_enabled = false
  apply_immediately            = false
  copy_tags_to_snapshot        = true
}

resource "aws_iam_role" "backup" {
  count = var.existing_lab_role_arn == null ? 1 : 0
  name  = "${local.prefix}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.existing_lab_role_arn == null ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_vault" "main" {
  name = "${local.prefix}-vault"
}

resource "aws_backup_plan" "rds" {
  name = "${local.prefix}-rds"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = 30
    }
  }
}

resource "aws_backup_selection" "rds" {
  name         = "${local.prefix}-rds"
  plan_id      = aws_backup_plan.rds.id
  iam_role_arn = local.backup_role_arn
  resources    = [aws_db_instance.postgres.arn]

  depends_on = [aws_iam_role_policy_attachment.backup]
}
