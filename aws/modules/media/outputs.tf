output "uploads_bucket" {
  description = "Name of the uploads bucket (the web posts upload forms to https://<name>.s3.<region>.amazonaws.com)."
  value       = aws_s3_bucket.this["uploads"].id
}

output "media_bucket" {
  description = "Name of the media bucket."
  value       = aws_s3_bucket.this["media"].id
}

output "media_domain" {
  description = "Public name of the media, `media.<domain>`: MEDIA_PUBLIC_BASE_URL of the gateway and MEDIA_ORIGIN of the web are https://<media_domain>."
  # Taken from the alias record, so nothing reads the name before it resolves to the distribution.
  value = aws_route53_record.media["A"].name
}

output "media_distribution_arn" {
  description = "ARN of the CloudFront distribution in front of the media bucket."
  value       = aws_cloudfront_distribution.media.arn
}

output "video_service_policy_json" {
  description = "IAM policy of video-service (JSON) for the role of its Pod Identity association."
  value       = data.aws_iam_policy_document.video_service.json
}

output "media_worker_policy_json" {
  description = "IAM policy of media-worker (JSON) for the role of its Pod Identity association."
  value       = data.aws_iam_policy_document.media_worker.json
}
