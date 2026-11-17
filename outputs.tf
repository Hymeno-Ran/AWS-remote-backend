output "bucket_name" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the state."
  value       = local.kms_key_arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB lock table, or null if not created."
  value       = try(aws_dynamodb_table.lock[0].name, null)
}

output "access_policy_arn" {
  description = "ARN of the IAM policy granting access to the state, or null if not created."
  value       = try(aws_iam_policy.access[0].arn, null)
}

output "region" {
  description = "Region the backend lives in."
  value       = local.region
}

output "backend_config" {
  description = "Ready-to-use .tfbackend content. Replace <KEY> with the state path, e.g. dev/network/terraform.tfstate."
  value = join("\n", compact([
    "bucket       = \"${aws_s3_bucket.state.id}\"",
    "key          = \"<KEY>\"",
    "region       = \"${local.region}\"",
    "encrypt      = true",
    "kms_key_id   = \"${local.kms_key_arn}\"",
    var.create_dynamodb_table ? "dynamodb_table = \"${aws_dynamodb_table.lock[0].name}\"" : "use_lockfile = true",
  ]))
}
