data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket_name = coalesce(var.bucket_name, "${var.project}-tfstate-${local.account_id}-${local.region}")
  kms_key_arn = var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.state[0].arn
  lock_table  = "${var.project}-tfstate-lock"

  common_tags = merge(var.tags, {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  })

  # Object ARNs / ListBucket prefixes the access policy is scoped to.
  object_arns = length(var.access_prefixes) == 0 ? ["${aws_s3_bucket.state.arn}/*"] : [
    for p in var.access_prefixes : "${aws_s3_bucket.state.arn}/${p}/*"
  ]
  list_prefixes = length(var.access_prefixes) == 0 ? ["*"] : flatten([
    for p in var.access_prefixes : [p, "${p}/*"]
  ])
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------

resource "aws_kms_key" "state" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "Terraform state encryption - ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_in_days

  tags = merge(local.common_tags, { Name = "${var.project}-tfstate" })
}

resource "aws_kms_alias" "state" {
  count = var.kms_key_arn == null ? 1 : 0

  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

# ---------------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_expiration_days
      newer_noncurrent_versions = var.noncurrent_versions_to_keep
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_logging" "state" {
  count = var.access_log_bucket == null ? 0 : 1

  bucket        = aws_s3_bucket.state.id
  target_bucket = var.access_log_bucket
  target_prefix = "${local.bucket_name}/"
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# DynamoDB lock table (legacy locking, optional)
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  count = var.create_dynamodb_table ? 1 : 0

  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  tags = merge(local.common_tags, { Name = local.lock_table })
}

# ---------------------------------------------------------------------------
# IAM access policy (attach to CI / developer roles)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "access" {
  count = var.create_access_policy ? 1 : 0

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = local.list_prefixes
    }
  }

  # Covers both terraform.tfstate and the S3-native .tflock file.
  statement {
    sid       = "ReadWriteStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.object_arns
  }

  statement {
    sid       = "UseStateKmsKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [local.kms_key_arn]
  }

  dynamic "statement" {
    for_each = var.create_dynamodb_table ? [1] : []
    content {
      sid       = "UseLockTable"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
      resources = [aws_dynamodb_table.lock[0].arn]
    }
  }
}

resource "aws_iam_policy" "access" {
  count = var.create_access_policy ? 1 : 0

  name        = "${var.project}-tfstate-access"
  description = "Read/write access to Terraform state for ${var.project}"
  policy      = data.aws_iam_policy_document.access[0].json

  tags = local.common_tags
}
