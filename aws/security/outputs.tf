output "security_event_bus_arn" {
  description = "ARN of the bus svp-security-events: target of the svp-security-* rules of every account (security_event_bus_arn of the security-baseline module in aws/baseline)."
  value       = aws_cloudwatch_event_bus.security.arn
}

output "security_alert_topic_arn" {
  description = "ARN of the SNS topic svp-security-alarms, whose email subscription must be confirmed after the first apply."
  value       = module.alarms.topic_arn
}
