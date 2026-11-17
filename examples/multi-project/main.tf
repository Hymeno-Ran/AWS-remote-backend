# One bootstrap stack, one isolated backend (bucket + KMS key + policy)
# per project. Add a project to the map and re-apply.

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
    tags = optional(map(string), {})
  }))
  default = {
    "tf-module" = { tags = { Team = "platform" } }
    "other-app" = { tags = { Team = "app" } }
  }
}

module "state_backend" {
  source   = "../.."
  for_each = var.projects

  project = each.key
  tags    = each.value.tags
}

output "backend_configs" {
  value = { for k, m in module.state_backend : k => m.backend_config }
}

output "access_policy_arns" {
  value = { for k, m in module.state_backend : k => m.access_policy_arn }
}
