# Bootstrap a backend for one project.
#
# 1. terraform init && terraform apply   (state is local at first)
# 2. Uncomment the backend block, fill in the bucket from the output,
#    then: terraform init -migrate-state

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  # backend "s3" {
  #   bucket       = "tf-module-tfstate-<account_id>-us-east-1"
  #   key          = "_bootstrap/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = "us-east-1"
}

module "state_backend" {
  source = "../.."

  project = "tf-module"
  tags    = { Team = "platform" }
}

output "backend_config" {
  value = module.state_backend.backend_config
}

output "access_policy_arn" {
  value = module.state_backend.access_policy_arn
}
