variable "aws_region" {
  description = "AWS region for all shared resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "devops-task"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI role, in owner/name form."
  type        = string
  default     = "nayan9744/devops-assessment"
}

variable "create_github_oidc_provider" {
  description = "Set to false if the account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}

variable "ecr_keep_last_images" {
  description = "Number of tagged images kept in ECR by the lifecycle policy."
  type        = number
  default     = 30
}
