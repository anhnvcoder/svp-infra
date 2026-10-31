output "uploads_bucket" {
  description = "Name of the uploads bucket (the web posts upload forms to https://<name>.s3.<region>.amazonaws.com)."
  value       = aws_s3_bucket.this["uploads"].id
}

output "media_bucket" {
  description = "Name of the media bucket."
  value       = aws_s3_bucket.this["media"].id
}

output "media_domain" {
  description = "Domain of the CloudFront distribution (<id>.cloudfront.net): MEDIA_PUBLIC_BASE_URL of the gateway and MEDIA_ORIGIN of the web are https://<domain>."
  value       = aws_cloudfront_distribution.media.domain_name
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
