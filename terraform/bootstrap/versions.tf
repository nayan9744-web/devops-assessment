terraform {
  required_version = ">= 1.10.0" # S3-native state locking (use_lockfile) needs >= 1.10

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The bootstrap stack creates the state bucket, so it keeps its own (small) state locally.
  # Commit nothing from here except code; back up terraform.tfstate or migrate it into the
  # bucket afterwards with `terraform init -migrate-state` (see README).
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
