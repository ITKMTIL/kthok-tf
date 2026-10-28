output "client_repository_url" {
  value = aws_ecr_repository.client.repository_url
}

output "route53_hosted_zone_id" {
  value = local.effective_hosted_zone_id
}

output "route53_name_servers" {
  value = var.hosted_zone_id == null ? aws_route53_zone.main[0].name_servers : []
}

output "core_repository_url" {
  value = aws_ecr_repository.core.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "core_service_name" {
  value = "${local.prefix}-core"
}

output "migrate_task_definition_arn" {
  value = aws_ecs_task_definition.migrate.arn
}

output "private_app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "core_security_group_id" {
  value = aws_security_group.core.id
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "rds_master_secret_arn" {
  value = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "session_secret_arn" {
  value = aws_secretsmanager_secret.session.arn
}

output "user_hash_secret_arn" {
  value = aws_secretsmanager_secret.user_hash.arn
}

output "site_url" {
  value = "https://${var.site_domain}"
}

output "api_url" {
  value = "https://${var.api_domain}"
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}
