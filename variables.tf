variable "name" {
  type    = string
  default = "kthok"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zones" {
  type        = list(string)
  description = "Two different AZ names in the selected region."
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) == 2 && var.availability_zones[0] != var.availability_zones[1]
    error_message = "Choose exactly two distinct AZs."
  }
}

variable "hosted_zone_id" {
  type        = string
  description = "Existing public Route 53 hosted zone ID. Leave null to create the zone with Terraform."
  default     = null
}

variable "root_domain" {
  type        = string
  description = "Registered apex domain whose public hosted zone Terraform creates when hosted_zone_id is null."
  default     = "k-thok.space"
}

variable "existing_lab_role_arn" {
  type        = string
  description = "Optional pre-existing role for restricted labs; it must trust ecs-tasks.amazonaws.com and backup.amazonaws.com and allow ECR, Logs, Secrets Manager, and Backup actions."
  default     = null
}

variable "site_domain" {
  type        = string
  description = "Full public frontend hostname, for example chat.example.com."
}

variable "api_domain" {
  type        = string
  description = "Full public backend hostname, for example api.example.com."
}

variable "google_client_id" {
  type        = string
  description = "Google OAuth web client ID. Leave empty only for the application's demo mode."
  default     = ""
}

variable "admin_student_ids" {
  type        = string
  description = "Optional comma-separated admin student IDs."
  default     = "66070070,66070207,66070024"
}

variable "enable_services" {
  type        = bool
  description = "Set true only after image tags are pushed and app secrets have values."
  default     = false
}

variable "client_image_tag" {
  type    = string
  default = "bootstrap"
}

variable "core_image_tag" {
  type    = string
  default = "bootstrap"
}

variable "migrate_image_tag" {
  type    = string
  default = "bootstrap-migrate"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "force_ssl_db" {
  type        = bool
  description = "Use sslmode=require in Prisma URLs. Keep true for RDS PostgreSQL."
  default     = true
}
