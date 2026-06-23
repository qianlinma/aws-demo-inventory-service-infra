provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "demo" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.demo.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.private_subnet_name_prefix}*"]
  }
}

data "aws_ecs_cluster" "demo" {
  cluster_name = var.ecs_cluster_name
}

# 查找已经存在的 Cloud Map private DNS namespace。
# 这个 namespace 是 product infra 创建的 demo.local。
# Inventory service 不自己创建 namespace，只加入同一个微服务命名空间。
data "aws_service_discovery_dns_namespace" "demo" {
  # 要查找的 namespace 名字，默认是 demo.local。
  name = var.service_discovery_namespace_name

  # DNS_PRIVATE 表示这个 namespace 只在 VPC 内部可解析。
  # 外网用户不能通过 inventory.demo.local 访问它。
  type = "DNS_PRIVATE"
}

data "aws_security_group" "backend_task" {
  name   = var.backend_task_security_group_name
  vpc_id = data.aws_vpc.demo.id
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_ecr_repository" "inventory_service" {
  name                 = var.inventory_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "demo-inventory-ecs-task-execution-role-tf"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "demo-inventory-ecs-task-role-tf"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_dynamodb_table" "inventory" {
  name         = var.inventory_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "productId"

  attribute {
    name = "productId"
    type = "N"
  }
}

resource "aws_dynamodb_table_item" "inventory_1" {
  table_name = aws_dynamodb_table.inventory.name
  hash_key   = aws_dynamodb_table.inventory.hash_key

  item = jsonencode({
    productId         = { N = "1" }
    quantityAvailable = { N = "42" }
    warehouseRegion   = { S = "us-west" }
  })
}

resource "aws_dynamodb_table_item" "inventory_2" {
  table_name = aws_dynamodb_table.inventory.name
  hash_key   = aws_dynamodb_table.inventory.hash_key

  item = jsonencode({
    productId         = { N = "2" }
    quantityAvailable = { N = "8" }
    warehouseRegion   = { S = "us-west" }
  })
}

resource "aws_dynamodb_table_item" "inventory_3" {
  table_name = aws_dynamodb_table.inventory.name
  hash_key   = aws_dynamodb_table.inventory.hash_key

  item = jsonencode({
    productId         = { N = "3" }
    quantityAvailable = { N = "0" }
    warehouseRegion   = { S = "us-east" }
  })
}

resource "aws_iam_role_policy" "ecs_task_dynamodb_read" {
  name = "demo-inventory-dynamodb-read-tf"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.inventory.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "inventory_service" {
  name              = "/ecs/demo-inventory-service-tf"
  retention_in_days = 7
}

resource "aws_security_group" "inventory_alb" {
  name        = "demo-inventory-alb-sg-tf"
  description = "Allow product backend tasks to call the internal inventory service ALB"
  vpc_id      = data.aws_vpc.demo.id

  ingress {
    description     = "Allow product service HTTP access to inventory service"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [data.aws_security_group.backend_task.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "inventory_task" {
  name        = "demo-inventory-ecs-task-sg-tf"
  description = "Allow internal inventory service ALB to reach the inventory service task"
  vpc_id      = data.aws_vpc.demo.id

  ingress {
    description     = "Allow ALB access to Spring Boot inventory service"
    from_port       = var.inventory_container_port
    to_port         = var.inventory_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.inventory_alb.id]
  }

  # 允许 product backend task 直接访问 inventory task 的 8080 端口。
  # 这是给 Cloud Map 服务发现路径用的：
  # product -> inventory.demo.local -> inventory task private IP:8080。
  ingress {
    # 这条规则的说明，会显示在 AWS Security Group Console 里。
    description = "Allow product service direct access through Cloud Map"
    # 允许访问的起始端口，默认是 Spring Boot 的 8080。
    from_port = var.inventory_container_port
    # 允许访问的结束端口；和 from_port 相同表示只开放一个端口。
    to_port = var.inventory_container_port
    # HTTP REST 跑在 TCP 上。
    protocol = "tcp"
    # 只允许 product/backend ECS task 的 security group 访问。
    # 这样不是整个 VPC 都能调用 inventory，范围更小。
    security_groups = [data.aws_security_group.backend_task.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "inventory_service" {
  name               = "demo-inventory-alb-tf"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.inventory_alb.id]
  subnets            = data.aws_subnets.private.ids
}

resource "aws_lb_target_group" "inventory_service" {
  name        = "demo-inventory-tg-tf"
  port        = var.inventory_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.demo.id

  health_check {
    enabled             = true
    path                = "/status"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "inventory_http" {
  load_balancer_arn = aws_lb.inventory_service.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.inventory_service.arn
  }
}

# 在 Cloud Map 里创建一个 service discovery service。
# 它不是业务代码里的 InventoryService，而是 AWS 里的“服务名注册记录”。
resource "aws_service_discovery_service" "inventory" {
  # Cloud Map service 的名字，默认是 inventory。
  # 配合 namespace demo.local，最终 DNS name 会是 inventory.demo.local。
  name = var.inventory_service_discovery_name

  # 配置这个 Cloud Map service 要怎么生成 DNS 记录。
  dns_config {
    # 指定这个 service 属于哪个 private DNS namespace。
    # 这里引用的是 product infra 创建的 demo.local namespace。
    namespace_id = data.aws_service_discovery_dns_namespace.demo.id

    # MULTIVALUE 表示 DNS 查询可以返回多个健康 task IP。
    # 如果 inventory service 未来有多个 ECS task，product service 可以拿到多个 IP。
    routing_policy = "MULTIVALUE"

    # 定义 Cloud Map 要创建哪种 DNS record。
    dns_records {
      # DNS 缓存时间，单位是秒。
      # 10 秒表示 task IP 变化后，客户端最多大约缓存 10 秒。
      ttl = 10

      # A record 表示 DNS name 会解析到 IPv4 地址。
      # ECS Fargate awsvpc 模式下，每个 task 都有自己的 private IP。
      type = "A"
    }
  }

  # 使用 ECS 自定义健康检查。
  # ECS 会根据 task 是否健康来决定是否把它保留在 Cloud Map 注册表里。
  health_check_custom_config {
    # 失败阈值，设置为 1 表示 ECS 判断实例不健康后会比较快从服务发现里移除。
    failure_threshold = 1
  }
}

resource "aws_ecs_task_definition" "inventory_service" {
  family                   = "demo-inventory-task-tf"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = var.inventory_container_name
      image     = "${aws_ecr_repository.inventory_service.repository_url}:latest"
      essential = true

      environment = [
        {
          name  = "INVENTORY_TABLE_NAME"
          value = aws_dynamodb_table.inventory.name
        }
      ]

      portMappings = [
        {
          containerPort = var.inventory_container_port
          hostPort      = var.inventory_container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.inventory_service.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "inventory_service" {
  depends_on = [aws_lb_listener.inventory_http]

  name            = "demo-inventory-service-tf"
  cluster         = data.aws_ecs_cluster.demo.arn
  task_definition = aws_ecs_task_definition.inventory_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = aws_lb_target_group.inventory_service.arn
    container_name   = var.inventory_container_name
    container_port   = var.inventory_container_port
  }

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.inventory_task.id]
    assign_public_ip = false
  }

  # 把这个 ECS service 注册到 Cloud Map。
  # ECS 会把运行中的 inventory task private IP 写入 Cloud Map。
  # 这样 product service 查询 inventory.demo.local 时，就能解析到 inventory task。
  service_registries {
    # 指向上面创建的 aws_service_discovery_service.inventory。
    # 也就是把 ECS service 和 Cloud Map service 绑定起来。
    registry_arn = aws_service_discovery_service.inventory.arn
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}
