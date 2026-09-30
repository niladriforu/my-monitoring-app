# Loads the AM simulator snapshot into this AWS account.
# From infra/data: terraform init && terraform apply
# Regenerate seed/*.json with: python3 export_seed.py

data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "kms" {
  statement {
    sid = "EnableIAM"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.me.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid = "AllowDynamoDB"
    principals {
      type        = "Service"
      identifiers = ["dynamodb.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.me.account_id]
    }
  }

  statement {
    sid = "AllowS3"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.me.account_id]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${var.name} observability data"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name}-observability-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "data" {
  bucket = "${var.name}-observability-data-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

locals {
  plain_objects = [
    "events.json",
    "alerts.json",
    "kpis.json",
    "throughput.json",
    "channels.json",
    "geo.json",
  ]
  events     = jsondecode(file("${path.module}/seed/ddb-events.json"))
  alerts     = jsondecode(file("${path.module}/seed/ddb-alerts.json"))
  aggregates = jsondecode(file("${path.module}/seed/ddb-aggregates.json"))
}

resource "aws_s3_object" "snapshot" {
  for_each = toset(local.plain_objects)

  bucket       = aws_s3_bucket.data.id
  key          = "am/${each.value}"
  source       = "${path.module}/seed/${each.value}"
  etag         = filemd5("${path.module}/seed/${each.value}")
  content_type = "application/json"
  kms_key_id   = aws_kms_key.data.arn

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.data]
}

resource "aws_dynamodb_table" "events" {
  name         = "${var.name}_events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
  attribute {
    name = "channel"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "N"
  }

  global_secondary_index {
    name            = "gsi1"
    hash_key        = "channel"
    range_key       = "ts"
    projection_type = "ALL"
  }
  global_secondary_index {
    name            = "gsi2"
    hash_key        = "status"
    range_key       = "ts"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "alerts" {
  name         = "${var.name}_alerts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
  attribute {
    name = "sev"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "N"
  }

  global_secondary_index {
    name            = "gsi1"
    hash_key        = "sev"
    range_key       = "ts"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "aggregates" {
  name         = "${var.name}_aggregates"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table_item" "event" {
  for_each   = local.events
  table_name = aws_dynamodb_table.events.name
  hash_key   = aws_dynamodb_table.events.hash_key
  item       = jsonencode(each.value)
}

resource "aws_dynamodb_table_item" "alert" {
  for_each   = local.alerts
  table_name = aws_dynamodb_table.alerts.name
  hash_key   = aws_dynamodb_table.alerts.hash_key
  item       = jsonencode(each.value)
}

resource "aws_dynamodb_table_item" "aggregate" {
  for_each   = local.aggregates
  table_name = aws_dynamodb_table.aggregates.name
  hash_key   = aws_dynamodb_table.aggregates.hash_key
  item       = jsonencode(each.value)
}
