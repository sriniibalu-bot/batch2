output "vm_app_private_ip" {
  description = "Private IP of the app VM"
  value       = aws_instance.app.private_ip
}

output "vm_db_private_ip" {
  description = "Private IP of the DB VM"
  value       = aws_instance.db.private_ip
}

output "vm_win_private_ip" {
  description = "Private IP of the Windows VM"
  value       = aws_instance.win.private_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.lab.bucket
}

output "eice_endpoint_id" {
  description = "EC2 Instance Connect Endpoint ID — use with: aws ec2-instance-connect ssh --instance-id <id> --os-user ubuntu"
  value       = aws_ec2_instance_connect_endpoint.lab.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.lab.id
}
