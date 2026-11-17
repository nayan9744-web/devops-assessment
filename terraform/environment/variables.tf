variable "environment" {
  description = "Deployment environment."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be either \"staging\" or \"production\"."
  }
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name (must match the bootstrap stack)."
  type        = string
  default     = "devops-task"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "allowed_http_cidrs" {
  description = "CIDR ranges allowed to reach the app on HTTP. Restrict this outside of demos."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_port" {
  description = "Port exposed on the instance; forwarded to the container's 8080."
  type        = number
  default     = 80
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository created by the bootstrap stack."
  type        = string
  default     = "devops-task"
}

variable "image_tag" {
  description = "Image tag deployed on first boot. Subsequent deploys are done by CI via SSM."
  type        = string
  default     = "1.0.0"
}

variable "log_level" {
  description = "Application log level."
  type        = string
  default     = "INFO"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for container logs."
  type        = number
  default     = 14
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch Logs."
  }
}

variable "detailed_monitoring" {
  description = "Enable 1-minute EC2 detailed monitoring (extra cost)."
  type        = bool
  default     = false
}
