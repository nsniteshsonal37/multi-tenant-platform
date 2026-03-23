locals {
  azs = ["${var.aws_region}a", "${var.aws_region}b"]
}

# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name                                            = "${var.name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}"    = "shared"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ── Subnets ───────────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                            = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}"    = "shared"
    "kubernetes.io/role/elb"                       = "1"
  })
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 3)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                                            = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}"    = "owned"
    "kubernetes.io/role/internal-elb"              = "1"
  })
}

# ── NAT Gateway (single AZ — cost optimisation, noted in design trade-offs) ──
resource "aws_eip" "nat" {
  domain     = "vpc"
  tags       = merge(var.tags, { Name = "${var.name}-nat-eip" })
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.name}-natgw" })
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "eks_cluster" {
  name        = "${var.name}-eks-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-eks-cluster-sg" })
}

resource "aws_security_group" "eks_nodes" {
  name        = "${var.name}-eks-nodes-sg"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.this.id

  # Nodes can communicate with each other
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  # Allow ALB to reach pods on any NodePort / pod port
  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-eks-nodes-sg" })
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Shared ALB — allow HTTPS from Internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "RDS PostgreSQL — allow from EKS nodes only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  tags = merge(var.tags, { Name = "${var.name}-rds-sg" })
}
