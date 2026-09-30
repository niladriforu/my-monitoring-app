terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

provider "aws" { region = var.region }

variable "region"      { default = "us-east-1" }
variable "name"        { default = "am" }
variable "domain_name" { description = "API hostname, e.g. am-api.example-bank.com" }
variable "web_domain"  { description = "Frontend hostname, e.g. am.example-bank.com" }
variable "acm_cert_arn_alb" { description = "ACM cert (region) for the ALB" }
variable "acm_cert_arn_cf"  { description = "ACM cert (us-east-1) for CloudFront" }
variable "container_image"  { description = "ECR image URI:tag for the API" }

data "aws_availability_zones" "az" { state = "available" }
data "aws_caller_identity" "me" {}

locals {
  azs = slice(data.aws_availability_zones.az.names, 0, 2)
}

# ---------- KMS: one CMK for RDS, S3, logs, secrets ----------
resource "aws_kms_key" "data" {
  description             = "${var.name} data key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

# ---------- Network: private subnets for app + db, public only for ALB/NAT ----------
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}
resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id }

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + count.index)
  availability_zone = local.azs[count.index]
}
resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 20 + count.index)
  availability_zone = local.azs[count.index]
}

resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.igw]
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}
resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# VPC flow logs
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.name}/vpc-flow"
  retention_in_days = 400
  kms_key_id        = aws_kms_key.data.arn
}
resource "aws_iam_role" "flow" {
  name = "${var.name}-flow"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.flow.arn}:*" }] })
}
resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow.arn
  iam_role_arn    = aws_iam_role.flow.arn
}

# ---------- Security groups (least privilege chain: ALB -> API -> DB) ----------
resource "aws_security_group" "alb" {
  vpc_id = aws_vpc.main.id
  ingress {  # tighten to corp CIDRs / CloudFront prefix list if internal-only
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 8000
    to_port = 8000
    protocol = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}
resource "aws_security_group" "api" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 8000
    to_port = 8000
    protocol = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}
resource "aws_security_group" "db" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [aws_security_group.api.id]
  }
}

# ---------- Database: encrypted, Multi-AZ, private, IAM-managed master secret ----------
resource "aws_db_subnet_group" "db" {
  name       = "${var.name}-db"
  subnet_ids = aws_subnet.db[*].id
}
resource "aws_db_instance" "pg" {
  identifier                            = "${var.name}-pg"
  engine                                = "postgres"
  engine_version                        = "16"
  instance_class                        = "db.t4g.medium" # ~100 users/day: small is plenty
  allocated_storage                     = 50
  max_allocated_storage                 = 200
  storage_encrypted                     = true
  kms_key_id                            = aws_kms_key.data.arn
  db_name                               = "am"
  username                              = "am_admin"
  manage_master_user_password           = true # stored & rotated in Secrets Manager
  master_user_secret_kms_key_id         = aws_kms_key.data.arn
  multi_az                              = true
  db_subnet_group_name                  = aws_db_subnet_group.db.name
  vpc_security_group_ids                = [aws_security_group.db.id]
  publicly_accessible                   = false
  backup_retention_period               = 14
  deletion_protection                   = true
  iam_database_authentication_enabled   = true
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.data.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  auto_minor_version_upgrade            = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${var.name}-pg-final"
}

# ---------- Identity: Cognito with MFA ----------
resource "aws_cognito_user_pool" "users" {
  name                     = "${var.name}-users"
  mfa_configuration        = "ON"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  software_token_mfa_configuration { enabled = true }
  password_policy {
    minimum_length = 14
    require_lowercase = true
    require_uppercase = true
    require_numbers = true
    require_symbols = true
  }
  admin_create_user_config { allow_admin_create_user_only = true }
}
resource "aws_cognito_user_group" "groups" {
  for_each     = toset(["viewer", "analyst", "admin"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.users.id
}
resource "aws_cognito_user_pool_client" "spa" {
  name                         = "${var.name}-spa"
  user_pool_id                 = aws_cognito_user_pool.users.id
  generate_secret              = false
  allowed_oauth_flows          = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes         = ["openid", "email"]
  callback_urls                = ["https://${var.web_domain}/"]
  logout_urls                  = ["https://${var.web_domain}/"]
  supported_identity_providers = ["COGNITO"] # add your corporate SAML/OIDC IdP here
  access_token_validity        = 15
  id_token_validity            = 15
  token_validity_units {
    access_token = "minutes"
    id_token = "minutes"
  }
}

# ---------- API on ECS Fargate behind ALB + WAF ----------
resource "aws_ecs_cluster" "main" {
  name = var.name
  setting {
    name = "containerInsights"
    value = "enabled"
  }
}
resource "aws_cloudwatch_log_group" "api" {
  name              = "/${var.name}/api"
  retention_in_days = 400
  kms_key_id        = aws_kms_key.data.arn
}
resource "aws_iam_role" "exec" {
  name = "${var.name}-exec"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name = "${var.name}-task"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_db_instance.pg.master_user_secret[0].secret_arn },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.data.arn }
  ] })
}
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    cpu_architecture = "X86_64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name = "api", image = var.container_image, essential = true,
    portMappings = [{ containerPort = 8000 }],
    readonlyRootFilesystem = true,
    environment = [
      { name = "ENV", value = "prod" },
      { name = "ALLOWED_ORIGINS", value = "https://${var.web_domain}" },
      { name = "COGNITO_JWKS_URL", value = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.users.id}/.well-known/jwks.json" },
      { name = "COGNITO_ISSUER", value = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.users.id}" },
      { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.spa.id },
      { name = "DB_HOST", value = aws_db_instance.pg.address },
      { name = "DB_SECRET_ARN", value = aws_db_instance.pg.master_user_secret[0].secret_arn }
    ],
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = aws_cloudwatch_log_group.api.name, "awslogs-region" = var.region, "awslogs-stream-prefix" = "api" } },
    healthCheck = { command = ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz')\""], interval = 30, timeout = 5, retries = 3 }
  }])
}
resource "aws_lb" "api" {
  name                       = "${var.name}-api"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = true
}
resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check { path = "/healthz" }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn_alb
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }
  deployment_circuit_breaker {
    enable = true
    rollback = true
  }
}

resource "aws_wafv2_web_acl" "api" {
  name  = "${var.name}-api"
  scope = "REGIONAL"
  default_action { allow {} }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name = "${var.name}-waf"
    sampled_requests_enabled = true
  }
  dynamic "rule" {
    for_each = { common = "AWSManagedRulesCommonRuleSet", badinputs = "AWSManagedRulesKnownBadInputsRuleSet", sqli = "AWSManagedRulesSQLiRuleSet" }
    content {
      name     = rule.key
      priority = index(keys({ common = 1, badinputs = 1, sqli = 1 }), rule.key)
      override_action { none {} }
      statement { managed_rule_group_statement { name = rule.value vendor_name = "AWS" } }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name = rule.key
        sampled_requests_enabled = true
      }
    }
  }
  rule {
    name     = "rate-limit"
    priority = 10
    action { block {} }
    statement { rate_based_statement { limit = 1000 aggregate_key_type = "IP" } }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name = "rate"
      sampled_requests_enabled = true
    }
  }
}
resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_lb.api.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

# ---------- React SPA: private S3 bucket behind CloudFront (OAC) ----------
resource "aws_s3_bucket" "web" { bucket = "${var.name}-web-${data.aws_caller_identity.me.account_id}" }
resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.name}-web"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_response_headers_policy" "sec" {
  name = "${var.name}-security"
  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains = true
      override = true
      preload = true
    }
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; connect-src 'self' https://${var.domain_name}; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
      override = true
    }
  }
}
resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.web_domain]
  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }
  default_cache_behavior {
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.sec.id
  }
  custom_error_response {
    error_code = 403
    response_code = 200
    response_page_path = "/index.html"
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate {
    acm_certificate_arn      = var.acm_cert_arn_cf
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "cloudfront.amazonaws.com" }, Action = "s3:GetObject",
    Resource = "${aws_s3_bucket.web.arn}/*",
    Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.web.arn } }
  }] })
}

# ---------- Account-level audit ----------
resource "aws_cloudtrail" "trail" {
  name                          = "${var.name}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.data.arn
  depends_on                    = [aws_s3_bucket_policy.trail]
}
resource "aws_s3_bucket" "trail" { bucket = "${var.name}-trail-${data.aws_caller_identity.me.account_id}" }
resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.trail.arn },
    { Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.me.account_id}/*", Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } } }
  ] })
}

output "api_alb_dns"      { value = aws_lb.api.dns_name }
output "cloudfront_domain" { value = aws_cloudfront_distribution.web.domain_name }
output "cognito_pool_id"  { value = aws_cognito_user_pool.users.id }
output "cognito_client_id" { value = aws_cognito_user_pool_client.spa.id }
output "web_bucket"       { value = aws_s3_bucket.web.id }
