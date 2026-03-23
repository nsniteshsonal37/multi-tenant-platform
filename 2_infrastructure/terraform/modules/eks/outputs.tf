output "cluster_name"     { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_ca"       { value = aws_eks_cluster.this.certificate_authority[0].data }
output "cluster_oidc_issuer" {
  value = aws_iam_openid_connect_provider.eks.url
}
output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}
