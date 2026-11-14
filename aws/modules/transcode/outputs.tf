output "queue_arn" {
  description = "ARN of the MediaConvert queue svp-<env>: key mediaconvertQueueArn of the cluster values."
  value       = aws_media_convert_queue.this.arn
}

output "role_arn" {
  description = "ARN of the role svp-<env>-mediaconvert that jobs run with: key mediaconvertRoleArn of the cluster values."
  value       = aws_iam_role.mediaconvert.arn
}

output "events_queue_url" {
  description = "URL of the SQS queue svp-<env>-transcode-events of the job states: key transcodeEventsQueueUrl of the cluster values."
  value       = aws_sqs_queue.events.url
}

output "bridge_policy_json" {
  description = "IAM policy (JSON) of the bridge for MediaConvert, iam:PassRole and SQS; the env root joins it with media_worker_policy_json of the media module in the Pod Identity role of media-worker."
  value       = data.aws_iam_policy_document.bridge.json
}
