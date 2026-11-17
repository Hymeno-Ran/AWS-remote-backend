# =============================================================================
# terraform-aws-state-backend
#
# BUILD REQUIREMENTS (for the principal running `terraform apply`):
#   - Valid AWS credentials for the target account/region (provider "aws").
#   - IAM permissions, at minimum:
#       sts:GetCallerIdentity
#       kms:CreateKey, kms:CreateAlias, kms:EnableKeyRotation, kms:TagResource,
#       kms:DescribeKey, kms:GetKeyPolicy, kms:GetKeyRotationStatus,
#       kms:ListResourceTags, kms:ScheduleKeyDeletion, kms:DeleteAlias
#         (only when encryption_type = customer-kms and no kms_key_arn)
#       s3:CreateBucket, s3:DeleteBucket, s3:Put*/Get* on the bucket config
#         (Versioning, Encryption, PublicAccessBlock, OwnershipControls,
#          LifecycleConfiguration, BucketPolicy, BucketLogging, BucketTagging)
#       iam:CreatePolicy, iam:GetPolicy, iam:GetPolicyVersion,
#         iam:CreatePolicyVersion, iam:DeletePolicy, iam:TagPolicy
#       dynamodb:CreateTable, dynamodb:DescribeTable, dynamodb:UpdateTable,
#         dynamodb:UpdateContinuousBackups, dynamodb:TagResource
#         (only when create_dynamodb_table = true)
#   - Service Control Policies (AWS Organizations) must not block the
#     actions/region above.
#   - This stack cannot store its own state in the bucket on the first run:
#     apply with local state first, then `terraform init -migrate-state`.
# =============================================================================

# Requires: sts:GetCallerIdentity (no special permission, works for any
# authenticated principal).
data "aws_caller_identity" "current" {}

# Region comes from the provider configuration (provider "aws" { region }),
# or AWS_REGION / AWS_DEFAULT_REGION.
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket_name = coalesce(var.bucket_name, "${var.project}-tfstate-${local.account_id}-${local.region}")
  lock_table  = "${var.project}-tfstate-lock"

  # Encryption selection (see var.encryption_type).
  use_cmk        = var.encryption_type == "customer-kms"
  create_kms_key = local.use_cmk && var.kms_key_arn == null
  # Customer managed key ARN; null for aws-kms (S3/DynamoDB pick the AWS
  # managed key themselves) and for sse-s3.
  kms_key_arn = !local.use_cmk ? null : (
    var.kms_key_arn != null ? var.kms_key_arn : try(aws_kms_key.state[0].arn, null)
  )

  common_tags = merge(var.tags, {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  })

  # Object ARNs / ListBucket prefixes the access policy is scoped to.
  object_arns = length(var.access_prefixes) == 0 ? ["${aws_s3_bucket.state.arn}/*"] : [
    for p in var.access_prefixes : "${aws_s3_bucket.state.arn}/${p}/*"
  ]
  list_prefixes = flatten([
    for p in var.access_prefixes : [p, "${p}/*"]
  ])
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------

# Created only when encryption_type = customer-kms and var.kms_key_arn is null.
# Requires:
#   - kms:CreateKey, kms:EnableKeyRotation, kms:TagResource.
#   - No explicit key policy is set, so AWS applies the default policy that
#     delegates access to IAM in this account. Principals using the backend
#     therefore only need IAM permissions (see aws_iam_policy.access).
# Notes:
#   - Destroy only schedules deletion (7-30 days, kms_deletion_window_in_days);
#     state encrypted with it becomes unreadable once the key is deleted.
#   - Costs ~1 USD/month per key.
resource "aws_kms_key" "state" {
  count = local.create_kms_key ? 1 : 0

  description             = "Terraform state encryption - ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_in_days

  tags = merge(local.common_tags, { Name = "${var.project}-tfstate" })
}

# Requires:
#   - kms:CreateAlias on both the alias and the key.
#   - Alias name must be unique per account + region: two modules with the
#     same `project` in the same region will collide.
resource "aws_kms_alias" "state" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

# ---------------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------------

# Requires:
#   - s3:CreateBucket, s3:PutBucketTagging.
#   - Bucket name must be GLOBALLY unique across all AWS accounts, 3-63 chars,
#     lowercase letters, digits and hyphens. The default name embeds the
#     account ID and region to make collisions unlikely; a custom
#     bucket_name may fail with BucketAlreadyExists.
#   - Bucket names are reserved for a while after deletion, so re-creating a
#     just-deleted bucket with the same name can fail temporarily.
# Notes:
#   - force_destroy = false makes `terraform destroy` fail while state
#     objects (including old versions) still exist - intended protection.
resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, { Name = local.bucket_name })

  lifecycle {
    precondition {
      condition     = length(local.bucket_name) <= 63
      error_message = "Bucket name \"${local.bucket_name}\" exceeds 63 characters. Shorten project or set bucket_name explicitly."
    }

    # Cross-variable check kept here (not in variables.tf) so the module
    # still supports Terraform < 1.9.
    precondition {
      condition     = var.kms_key_arn == null || local.use_cmk
      error_message = "kms_key_arn can only be set when encryption_type = \"customer-kms\"."
    }
  }
}

# Requires: s3:PutBucketOwnershipControls.
# BucketOwnerEnforced disables ACLs entirely; access is controlled only by
# IAM and the bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Requires: s3:PutBucketPublicAccessBlock.
# Must be applied before the bucket policy (see depends_on there).
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Requires: s3:PutBucketVersioning.
# Notes:
#   - Once enabled, versioning can only be suspended, never fully disabled.
#   - Old versions are what lets you roll back a corrupted state file:
#     aws s3api list-object-versions --bucket <bucket> --prefix <key>
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Requires: s3:PutEncryptionConfiguration.
# Per encryption_type:
#   customer-kms - aws:kms with the customer managed key.
#     When var.kms_key_arn is set (bring-your-own key):
#       - Must be a symmetric key in the SAME region as the bucket.
#       - Its key policy must allow the principals that use the backend (and
#         the principal running this apply) kms:GenerateDataKey, kms:Decrypt,
#         kms:DescribeKey - either directly or by delegating to IAM.
#       - For a key in another account, the IAM policy alone is not enough:
#         the key policy must explicitly grant those accounts/roles.
#   aws-kms - aws:kms without a key ID, so S3 uses the AWS managed key
#     aws/s3 (auto-created on first use). Its key policy already allows every
#     principal in this account via S3, so no KMS IAM permission is needed.
#     Cannot be shared cross-account and its key policy cannot be changed.
#   sse-s3 - AES256, keys fully handled by S3. No KMS cost, but anyone with
#     s3:GetObject on the state can read it (no second layer of access
#     control, no CloudTrail decrypt events).
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.encryption_type == "sse-s3" ? "AES256" : "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    bucket_key_enabled = var.encryption_type != "sse-s3"
  }
}

# Requires: s3:PutLifecycleConfiguration.
# Notes:
#   - Needs versioning enabled first (depends_on below).
#   - newer_noncurrent_versions is limited to 1-100 by S3.
#   - Lifecycle rules are evaluated asynchronously; expiry can lag ~1-2 days.
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

# Created only when var.access_log_bucket is set.
# Requires (on the TARGET bucket, which must exist beforehand):
#   - Same account and same region as the state bucket.
#   - Must NOT be the state bucket itself (would log its own logs).
#   - Bucket policy allowing the service principal logging.s3.amazonaws.com
#     s3:PutObject on <target>/<state-bucket-name>/*, conditioned on
#     aws:SourceAccount = this account.
#   - Default encryption SSE-S3; SSE-KMS is not supported as a server access
#     log destination.
#   - Caller needs s3:PutBucketLogging on the state bucket.
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

# Requires: s3:PutBucketPolicy, s3:GetBucketPolicy.
# Notes:
#   - The Deny applies to every principal, including admins, but only for
#     plain-HTTP requests; Terraform, AWS CLI and SDKs use HTTPS by default.
#   - Applied after the public access block so S3 never sees the bucket in
#     a half-configured state.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# DynamoDB lock table (legacy locking, optional)
# ---------------------------------------------------------------------------

# Created only when var.create_dynamodb_table = true. Not needed for
# Terraform >= 1.10 with `use_lockfile = true`.
# Requires:
#   - dynamodb:CreateTable, dynamodb:DescribeTable, dynamodb:TagResource,
#     dynamodb:UpdateContinuousBackups (for point-in-time recovery).
#   - Encryption follows encryption_type:
#       customer-kms - the state KMS key; the caller needs kms:CreateGrant and
#                      kms:DescribeKey on it (DynamoDB creates a grant).
#       aws-kms      - AWS managed key aws/dynamodb.
#       sse-s3       - AWS owned key (free, the DynamoDB default).
#   - Table name must be unique per account + region.
# Notes:
#   - deletion_protection_enabled = true: to destroy, first set it to false
#     and apply, then destroy.
resource "aws_dynamodb_table" "lock" {
  count = var.create_dynamodb_table ? 1 : 0

  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  deletion_protection_enabled = true

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # enabled = false means "AWS owned key", not "unencrypted".
  server_side_encryption {
    enabled     = var.encryption_type != "sse-s3"
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

    # Only scope listing when prefixes are given; a StringLike on a missing
    # s3:prefix key would otherwise deny un-prefixed ListBucket calls.
    dynamic "condition" {
      for_each = length(local.list_prefixes) > 0 ? [1] : []
      content {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = local.list_prefixes
      }
    }
  }

  # Covers both terraform.tfstate and the S3-native .tflock file.
  statement {
    sid       = "ReadWriteStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.object_arns
  }

  # Only for customer-kms: the aws/s3 managed key already trusts the account
  # via S3, and sse-s3 uses no KMS at all.
  dynamic "statement" {
    for_each = local.use_cmk ? [1] : []
    content {
      sid       = "UseStateKmsKey"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [local.kms_key_arn]
    }
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

# Created only when var.create_access_policy = true.
# Requires: iam:CreatePolicy, iam:GetPolicy, iam:GetPolicyVersion,
#   iam:ListPolicyVersions, iam:CreatePolicyVersion, iam:DeletePolicyVersion,
#   iam:TagPolicy.
# Notes:
#   - The module only CREATES the policy; attach it yourself to the CI /
#     developer roles (aws_iam_role_policy_attachment) using access_policy_arn.
#   - Workspaces: with the default workspace_key_prefix "env:", non-default
#     workspaces live under env:/<workspace>/... - add "env:" to
#     access_prefixes if you scope the policy and use workspaces.
resource "aws_iam_policy" "access" {
  count = var.create_access_policy ? 1 : 0

  # IAM is global: include the region so the same project can have a
  # backend in several regions of one account.
  name        = "${var.project}-tfstate-access-${local.region}"
  description = "Read/write access to Terraform state for ${var.project}"
  policy      = data.aws_iam_policy_document.access[0].json

  tags = local.common_tags
}
