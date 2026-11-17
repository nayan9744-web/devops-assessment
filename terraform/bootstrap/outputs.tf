output "state_bucket" {
  description = "S3 bucket for Terraform remote state. Put it in environment/envs/*.s3.tfbackend."
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  description = "ECR repository URL. Set as the ECR_REPOSITORY GitHub variable (name part)."
  value       = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Role ARN to set as the AWS_ROLE_ARN GitHub Actions variable."
  value       = aws_iam_role.github_actions.arn
}
