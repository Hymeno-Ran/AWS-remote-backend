# Encryption mode tests (separate file = fresh state per file)
# Unit tests with a mocked AWS provider: no credentials or real resources needed.
# Run: terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/mock" }
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/mock" }
  }
}

variables {
  project = "tf-module"
}

run "aws_managed_kms" {
  command = apply

  variables {
    encryption_type       = "aws-kms"
    create_dynamodb_table = true
  }

  assert {
    condition     = length(aws_kms_key.state) == 0 && output.kms_key_arn == null
    error_message = "aws-kms must not create or reference a customer managed key."
  }

  assert {
    # kms_master_key_id / kms_key_arn are Optional+Computed, so the mock
    # provider fills them with random values after apply; check the value the
    # module passes in (local.kms_key_arn) instead.
    condition = (
      tolist(tolist(aws_s3_bucket_server_side_encryption_configuration.state.rule)[0].apply_server_side_encryption_by_default)[0].sse_algorithm == "aws:kms" &&
      local.kms_key_arn == null
    )
    error_message = "aws-kms should use aws:kms without a key ID (aws/s3 managed key)."
  }

  assert {
    condition     = aws_dynamodb_table.lock[0].server_side_encryption[0].enabled && local.kms_key_arn == null
    error_message = "DynamoDB should use the AWS managed key aws/dynamodb."
  }

  assert {
    condition     = !anytrue([for s in data.aws_iam_policy_document.access[0].statement : s.sid == "UseStateKmsKey"])
    error_message = "Access policy must not contain a KMS statement for aws-kms."
  }

  assert {
    condition     = strcontains(output.backend_config, "encrypt      = false") && !strcontains(output.backend_config, "kms_key_id")
    error_message = "aws-kms backend_config must set encrypt = false and no kms_key_id."
  }
}

run "sse_s3" {
  command = apply

  variables {
    encryption_type       = "sse-s3"
    create_dynamodb_table = true
  }

  assert {
    condition     = length(aws_kms_key.state) == 0 && output.kms_key_arn == null
    error_message = "sse-s3 must not create a KMS key."
  }

  assert {
    condition     = tolist(tolist(aws_s3_bucket_server_side_encryption_configuration.state.rule)[0].apply_server_side_encryption_by_default)[0].sse_algorithm == "AES256"
    error_message = "sse-s3 should use AES256."
  }

  assert {
    condition     = !aws_dynamodb_table.lock[0].server_side_encryption[0].enabled
    error_message = "DynamoDB should fall back to the AWS owned key."
  }

  assert {
    condition     = !anytrue([for s in data.aws_iam_policy_document.access[0].statement : s.sid == "UseStateKmsKey"])
    error_message = "Access policy must not contain a KMS statement for sse-s3."
  }

  assert {
    condition     = strcontains(output.backend_config, "encrypt      = true") && !strcontains(output.backend_config, "kms_key_id")
    error_message = "sse-s3 backend_config must set encrypt = true and no kms_key_id."
  }
}

run "invalid_encryption_type" {
  command = plan

  variables {
    encryption_type = "none"
  }

  expect_failures = [var.encryption_type]
}

run "kms_key_arn_with_non_cmk" {
  command = plan

  variables {
    encryption_type = "sse-s3"
    kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/existing"
  }

  expect_failures = [aws_s3_bucket.state]
}
