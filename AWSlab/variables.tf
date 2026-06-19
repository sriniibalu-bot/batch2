variable "participant_name" {
  description = "Your participant name (lowercase, no spaces) — used in resource names and S3 bucket"
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "admin_password" {
  description = "Local Administrator password for the Windows VM (set at first boot via EC2Launch)"
  type        = string
  sensitive   = true
}
