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

run "defaults" {
  command = apply

  assert {
    condition     = aws_s3_bucket.state.bucket == "tf-module-tfstate-123456789012-us-east-1"
    error_message = "Default bucket name is wrong."
  }

  assert {
    condition     = length(aws_kms_key.state) == 1
    error_message = "A KMS key should be created when kms_key_arn is null."
  }

  assert {
    condition     = length(aws_dynamodb_table.lock) == 0
    error_message = "DynamoDB table should be off by default."
  }

  assert {
    condition     = aws_iam_policy.access[0].name == "tf-module-tfstate-access-us-east-1"
    error_message = "IAM policy name should include the region."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.access[0].statement[0].condition) == 0
    error_message = "ListBucket must not be prefix-restricted when access_prefixes is empty."
  }

  assert {
    condition     = strcontains(output.backend_config, "use_lockfile = true")
    error_message = "backend_config should use S3-native locking by default."
  }
}

run "scoped_prefixes" {
  command = apply

  variables {
    access_prefixes = ["dev", "prod/network"]
  }

  assert {
    condition = toset(tolist(data.aws_iam_policy_document.access[0].statement[0].condition)[0].values) == toset([
      "dev", "dev/*", "prod/network", "prod/network/*",
    ])
    error_message = "ListBucket prefixes are wrong."
  }

  assert {
    condition = toset(data.aws_iam_policy_document.access[0].statement[1].resources) == toset([
      "arn:aws:s3:::mock-bucket/dev/*", "arn:aws:s3:::mock-bucket/prod/network/*",
    ])
    error_message = "Object ARNs are wrong."
  }
}

run "existing_kms_and_dynamodb" {
  command = apply

  variables {
    kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/existing"
    create_dynamodb_table = true
  }

  assert {
    condition     = length(aws_kms_key.state) == 0
    error_message = "No KMS key should be created when kms_key_arn is given."
  }

  assert {
    condition     = output.kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/existing"
    error_message = "kms_key_arn output should pass through the given key."
  }

  assert {
    condition     = strcontains(output.backend_config, "dynamodb_table = \"tf-module-tfstate-lock\"")
    error_message = "backend_config should reference the DynamoDB table."
  }
}

run "bucket_name_too_long" {
  command = plan

  variables {
    project = "a-very-long-project-name-abcdefgh"
  }

  expect_failures = [var.project]
}

run "generated_name_over_63_chars" {
  command = plan

  # 29-char project + "-tfstate-" + 12-digit account + "-ap-southeast-2" = 65 chars
  override_data {
    target = data.aws_region.current
    values = { region = "ap-southeast-2" }
  }

  variables {
    project = "long-project-name-abcdefghijk"
  }

  expect_failures = [aws_s3_bucket.state]
}

run "invalid_prefix" {
  command = plan

  variables {
    access_prefixes = ["/dev/"]
  }

  expect_failures = [var.access_prefixes]
}
