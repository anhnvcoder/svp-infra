output "web_acl_arn" {
  description = "ARN of the web ACL, for the one CloudFront distribution it protects (web_acl_id of a distribution takes the ARN of a WAF web ACL)."
  value       = aws_wafv2_web_acl.this.arn
}
