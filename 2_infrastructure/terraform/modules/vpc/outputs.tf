output "vpc_id"             { value = aws_vpc.this.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "cluster_sg_id"      { value = aws_security_group.eks_cluster.id }
output "node_sg_id"         { value = aws_security_group.eks_nodes.id }
output "rds_sg_id"          { value = aws_security_group.rds.id }
output "alb_sg_id"          { value = aws_security_group.alb.id }
