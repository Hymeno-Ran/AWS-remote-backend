# One bootstrap stack, one isolated backend (bucket + optional KMS key +
# policy) per project/environment. Add an entry to the map and re-apply.
# encryption_type can differ per entry, e.g. KMS for prod, SSE-S3 for SIT.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "projects" {
  type = map(object({
    encryption_type = optional(string, "customer-kms")
    tags            = optional(map(string), {})
  }))
  default = {
    "tf-module-prod" = { tags = { Team = "platform" } }
    "tf-module-sit"  = { encryption_type = "sse-s3", tags = { Team = "platform" } }
    "other-app"      = { encryption_type = "aws-kms", tags = { Team = "app" } }
  }
}

module "state_backend" {
  source   = "../.."
  for_each = var.projects

  project         = each.key
  encryption_type = each.value.encryption_type
  tags            = each.value.tags
}

output "backend_configs" {
  value = { for k, m in module.state_backend : k => m.backend_config }
}

output "access_policy_arns" {
  value = { for k, m in module.state_backend : k => m.access_policy_arn }
}
