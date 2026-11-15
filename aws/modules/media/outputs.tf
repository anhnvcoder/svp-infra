output "uploads_bucket" {
  description = "Name of the uploads bucket (the web posts upload forms to https://<name>.s3.<region>.amazonaws.com)."
  value       = aws_s3_bucket.this["uploads"].id
}

output "uploads_kms_key_arn" {
  description = "ARN of the KMS key alias/<name_prefix>-uploads, the default encryption of the uploads bucket: every role that reads or writes uploads needs it (MediaConvert through the transcode module)."
  value       = aws_kms_key.uploads.arn
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
  description = "S3 and uploads key part of the IAM policy of media-worker, the MediaConvert bridge on AWS (JSON), for the role of its Pod Identity association."
  value       = data.aws_iam_policy_document.media_worker.json
}

output "signing_key_ids" {
  description = "ID of the CloudFront public key of each slot of signing_public_keys (`a`, `b`): the Key-Pair-Id that a URL signed with the private key of that slot carries (MEDIA_SIGNING_KEY_ID of video-service)."
  value       = { for slot, key in aws_cloudfront_public_key.media : slot => key.id }
}
