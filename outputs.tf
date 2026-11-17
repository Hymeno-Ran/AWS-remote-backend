output "bucket_name" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "encryption_type" {
  description = "Encryption mode in use: customer-kms, aws-kms or sse-s3."
  value       = var.encryption_type
}

output "kms_key_arn" {
  description = "ARN of the customer managed KMS key encrypting the state, or null for aws-kms / sse-s3."
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

# The S3 backend sends an explicit SSE header when encrypt = true:
#   - with kms_key_id  -> aws:kms with that key
#   - without          -> AES256, which OVERRIDES the bucket default.
# So for aws-kms we emit encrypt = false and let the bucket default
# encryption (aws/s3 key) apply; the object is still encrypted at rest.
output "backend_config" {
  description = "Ready-to-use .tfbackend content. Replace <KEY> with the state path, e.g. dev/network/terraform.tfstate."
  value = join("\n", compact([
    "bucket       = \"${aws_s3_bucket.state.id}\"",
    "key          = \"<KEY>\"",
    "region       = \"${local.region}\"",
    var.encryption_type == "customer-kms" ? "encrypt      = true" : "",
    var.encryption_type == "customer-kms" ? "kms_key_id   = \"${local.kms_key_arn}\"" : "",
    var.encryption_type == "aws-kms" ? "# bucket default encryption (aws/s3 KMS key) applies" : "",
    var.encryption_type == "aws-kms" ? "encrypt      = false" : "",
    var.encryption_type == "sse-s3" ? "encrypt      = true" : "",
    var.create_dynamodb_table ? "dynamodb_table = \"${aws_dynamodb_table.lock[0].name}\"" : "use_lockfile = true",
  ]))
}
