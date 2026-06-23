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

output "inventory_service_discovery_dns_name" {
  # 输出 Cloud Map DNS name，方便 product service 或人肉 debug 时知道该调用哪个内部地址。
  # 完整调用地址会是 http://inventory.demo.local:8080/api/inventory/{productId}。
  description = "Cloud Map DNS name product service can use to call inventory service."
  value       = "${aws_service_discovery_service.inventory.name}.${data.aws_service_discovery_dns_namespace.demo.name}"
}
