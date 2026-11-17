environment         = "production"
instance_type       = "t3.small"
root_volume_size_gb = 30
log_retention_days  = 30
log_level           = "INFO"
detailed_monitoring = true
# In real production put an ALB / CloudFront in front and restrict this to its security group.
allowed_http_cidrs = ["0.0.0.0/0"]
