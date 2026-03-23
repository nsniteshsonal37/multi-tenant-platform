output "jenkins_url"      { value = "https://jenkins.${var.domain_name}" }
output "jenkins_role_arn" { value = aws_iam_role.jenkins.arn }
