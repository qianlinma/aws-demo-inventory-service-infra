output "inventory_service_alb_dns_name" {
  description = "Internal ALB DNS name that product service can call later."
  value       = aws_lb.inventory_service.dns_name
}

output "inventory_service_ecr_repository_url" {
  description = "ECR repository URL for the inventory service image."
  value       = aws_ecr_repository.inventory_service.repository_url
}

output "inventory_table_name" {
  description = "DynamoDB table used by the inventory service."
  value       = aws_dynamodb_table.inventory.name
}
