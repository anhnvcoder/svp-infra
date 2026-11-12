output "target_group_arn" {
  description = "ARN of the target group `<name>-envoy`: edgeTargetGroupArn of the cluster values, where the TargetGroupBinding of Envoy registers its pods."
  value       = aws_lb_target_group.envoy.arn
}

output "alb_security_group_id" {
  description = "Security group of the internal ALB: the only source the module lets in on the Envoy ports of the node security group."
  value       = aws_security_group.alb.id
}

output "distribution_domains" {
  description = "Domain names (`<id>.cloudfront.net`) of the distributions, keyed web and api; `<domain>` and `api.<domain>` are alias records to them."
  value       = { for k, d in aws_cloudfront_distribution.this : k => d.domain_name }
}
