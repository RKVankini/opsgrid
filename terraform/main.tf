terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }

  backend "s3" {
    bucket         = "opsgrid-terraform-state-prod"
    key            = "prod/eks/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "opsgrid"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "devops-team"
    }
  }
}

# ─── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "vpc-opsgrid-${var.environment}"
  cidr = "10.0.0.0/16"

  azs             = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false  # HA: one per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                         = 1
    "kubernetes.io/cluster/eks-prod-ap-south-1"      = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                = 1
    "kubernetes.io/cluster/eks-prod-ap-south-1"      = "shared"
  }
}

# ─── EKS CLUSTER ───────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "eks-prod-ap-south-1"
  cluster_version = "1.29"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    control_plane = {
      name           = "control-plane-ng"
      instance_types = ["m5.xlarge"]
      min_size       = 3
      max_size       = 3
      desired_size   = 3

      labels = {
        role = "control-plane"
      }
    }

    workers = {
      name           = "worker-ng"
      instance_types = ["t3.2xlarge"]
      min_size       = 2
      max_size       = 6
      desired_size   = 3

      labels = {
        role = "worker"
      }

      taints = []
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true
}

# ─── RDS POSTGRESQL ────────────────────────────────────────────────────────────
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "rds-postgres-${var.environment}"

  engine               = "postgres"
  engine_version       = "15.4"
  family               = "postgres15"
  major_engine_version = "15"
  instance_class       = "db.r6g.large"

  allocated_storage     = 100
  max_allocated_storage = 1000
  storage_encrypted     = true

  db_name  = "opsgrid"
  username = "opsgrid_admin"
  port     = 5432

  # High Availability
  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  backup_retention_period = 7
  deletion_protection     = true

  performance_insights_enabled = true
  monitoring_interval          = 60
}

resource "aws_db_subnet_group" "this" {
  name       = "opsgrid-${var.environment}-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-sg-${var.environment}"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── ELASTICACHE REDIS ─────────────────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "this" {
  name       = "opsgrid-${var.environment}-redis"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "opsgrid-redis-${var.environment}"
  description          = "Redis cluster for opsgrid session cache"

  node_type            = "cache.t4g.medium"
  num_cache_clusters   = 2
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis_sg.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  automatic_failover_enabled = true
}

resource "aws_security_group" "redis_sg" {
  name   = "redis-sg-${var.environment}"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

# ─── ECR REPOSITORIES ──────────────────────────────────────────────────────────
locals {
  services = [
    "api-gateway", "payment-svc", "auth-service",
    "order-service", "notification-svc", "image-svc", "frontend"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ─── OUTPUTS ───────────────────────────────────────────────────────────────────
output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  value     = module.rds.db_instance_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = aws_elasticache_replication_group.redis.primary_endpoint_address
  sensitive = true
}
