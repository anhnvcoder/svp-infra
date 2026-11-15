output "role_arn" {
  description = "ARN of the role svp-ci-terraform-plan, which the plan workflow of svp-infra assumes through OIDC."
  value       = aws_iam_role.this.arn
}
