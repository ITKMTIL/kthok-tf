locals {
  prefix = "${var.name}-${var.environment}"

  subnet_cidrs = {
    public_a = "10.0.1.0/24"
    public_b = "10.0.2.0/24"
    app_a    = "10.0.11.0/24"
    app_b    = "10.0.12.0/24"
    db_a     = "10.0.21.0/24"
    db_b     = "10.0.22.0/24"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = local.subnet_cidrs[count.index == 0 ? "public_a" : "public_b"]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-public-${count.index + 1}" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = local.subnet_cidrs[count.index == 0 ? "app_a" : "app_b"]
  tags              = { Name = "${local.prefix}-app-${count.index + 1}" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = local.subnet_cidrs[count.index == 0 ? "db_a" : "db_b"]
  tags              = { Name = "${local.prefix}-db-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${local.prefix}-nat-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count         = 2
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id
  tags          = { Name = "${local.prefix}-nat-${count.index + 1}" }

  depends_on = [aws_route.public_internet]
}

resource "aws_route_table" "app" {
  count  = 2
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-app-${count.index + 1}" }
}

resource "aws_route" "app_internet" {
  count                  = 2
  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-db" }
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb"
  description = "Public HTTPS ALB"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_security_group" "client" {
  name        = "${local.prefix}-client"
  description = "Frontend Fargate tasks"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "core" {
  name        = "${local.prefix}-core"
  description = "Single backend Fargate task"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds"
  description = "PostgreSQL from backend only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "alb_client" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.client.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_core" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.core.id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "client_from_alb" {
  security_group_id            = aws_security_group.client.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "core_from_alb" {
  security_group_id            = aws_security_group.core.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_core" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.core.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "client_outbound" {
  security_group_id = aws_security_group.client.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "core_outbound" {
  security_group_id = aws_security_group.core.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
