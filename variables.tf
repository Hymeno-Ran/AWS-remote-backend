variable "project" {
  type        = string
  description = "Project name. Used in resource names, tags and the generated backend config."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project))
    error_message = "project must be 3-32 chars of lowercase letters, digits and hyphens."
  }
}

variable "bucket_name" {
  type        = string
  description = "Explicit S3 bucket name. Defaults to <project>-tfstate-<account_id>-<region>."
  default     = null
}

variable "force_destroy" {
  type        = bool
  description = "Allow destroying the bucket even if it still holds state files. Keep false outside of throwaway sandboxes."
  default     = false
}

variable "kms_key_arn" {
  type        = string
  description = "Existing KMS key ARN for bucket encryption. When null, the module creates a dedicated key."
  default     = null
}

variable "kms_deletion_window_in_days" {
  type        = number
  description = "Waiting period before a module-created KMS key is deleted."
  default     = 30
}

variable "noncurrent_version_expiration_days" {
  type        = number
  description = "Days to keep old (noncurrent) versions of state files before they expire."
  default     = 90
}

variable "noncurrent_versions_to_keep" {
  type        = number
  description = "Number of most recent noncurrent versions always kept regardless of age."
  default     = 10
}

variable "access_log_bucket" {
  type        = string
  description = "Optional bucket name that receives S3 server access logs for the state bucket."
  default     = null
}

variable "create_dynamodb_table" {
  type        = bool
  description = "Create a DynamoDB lock table. Not needed with Terraform >= 1.10 and use_lockfile = true."
  default     = false
}

variable "create_access_policy" {
  type        = bool
  description = "Create an IAM managed policy granting read/write access to the state paths under access_prefixes."
  default     = true
}

variable "access_prefixes" {
  type        = list(string)
  description = "Key prefixes (without leading/trailing slash) the access policy is scoped to, e.g. [\"dev\", \"prod/network\"]. Empty list = whole bucket."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged into every resource."
  default     = {}
}
