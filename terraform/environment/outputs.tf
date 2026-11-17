output "instance_id" {
  description = "EC2 instance ID (deploy target for SSM)."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the instance."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "URL of the deployed application."
  value       = "http://${aws_instance.app.public_dns}${var.http_port == 80 ? "" : ":${var.http_port}"}"
}

output "log_group" {
  description = "CloudWatch Logs group receiving container logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "security_group_id" {
  description = "Security group attached to the instance."
  value       = aws_security_group.app.id
}
