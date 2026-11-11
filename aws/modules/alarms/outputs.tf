output "topic_arn" {
  description = "ARN of the SNS topic <name>-alarms: alarm_actions and ok_actions of every CloudWatch alarm of the env (alarm_topic_arn of the rds, msk and elasticache modules)."
  value       = aws_sns_topic.this.arn
}
