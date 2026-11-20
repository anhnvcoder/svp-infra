# Module `media`

Hai bucket S3 của một env (`uploads` mã hoá bằng KMS key riêng, `media`), distribution CloudFront `<name_prefix>-media` ở `media.<domain>`
với key group kiểm URL ký, gói flat-rate Free hay pay-as-you-go theo `flat_rate_free`, plan GuardDuty Malware Protection for S3 trên
`uploads`, hai policy IAM (JSON) cho video-service, media-worker. Root `aws/envs/<env>` gọi module; lý do, quyền và bẫy gỡ ở
[chương 12. Media và edge](../../../docs/handbook/12-media-edge.md); test: `make test DIRS=aws/modules/media`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder:

```hcl
module "media" {
  source = "../../modules/media"

  name_prefix            = "svp-stg"
  account_id             = "000000000000"
  region                 = "ap-southeast-1"
  cors_allowed_origins   = ["https://svp.example"]
  force_destroy          = true
  versioning_enabled     = true
  access_logging_enabled = true

  domain                       = "svp.example"
  hosted_zone_id               = "Z<id>"
  flat_rate_free               = true
  web_acl_arn                  = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-media/<id>"
  log_delivery_destination_arn = "arn:aws:logs:us-east-1:000000000000:delivery-destination:svp-cloudfront-stg"
  signing_public_keys          = { a = "-----BEGIN PUBLIC KEY-----\n<PEM>\n-----END PUBLIC KEY-----\n" }
}
```

## Tham chiếu

- [Chương 12. Media và edge](../../../docs/handbook/12-media-edge.md): ghi chú thiết kế mà `cloudfront.tf`, `iam.tf`,
  `malware-protection.tf` trỏ tới.
- [ADR-0073](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0073-premium-playback.md) §7, §8: behavior premium, khoá ký;
  [ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md): gói Free.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.69 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.69 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_cloudfront_distribution.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_key_group.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_key_group) | resource |
| [aws_cloudfront_origin_access_control.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_cloudfront_public_key.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_public_key) | resource |
| [aws_cloudfront_response_headers_policy.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_response_headers_policy) | resource |
| [aws_cloudwatch_log_delivery.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery) | resource |
| [aws_cloudwatch_log_delivery_source.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery_source) | resource |
| [aws_guardduty_malware_protection_plan.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_malware_protection_plan) | resource |
| [aws_iam_role.malware_protection](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.malware_protection](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_pricingplanmanager_subscription.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/pricingplanmanager_subscription) | resource |
| [aws_route53_record.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_cors_configuration.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_cors_configuration) | resource |
| [aws_s3_bucket_cors_configuration.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_cors_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.uptime_probe](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_response_headers_policy.simple_cors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_response_headers_policy) | data source |
| [aws_iam_policy_document.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.malware_protection](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.media_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.tls_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.video_service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| access\_logging\_enabled | Write S3 server access logs of both buckets to a third bucket, <name\_prefix>-logs-<account\_id>-<region>, which this module creates (private, TLS only, SSE-S3, logs deleted after 90 days). Off by default. | `bool` | `false` | no |
| account\_id | The AWS account of the buckets (12 digits), part of their names. The root passes its own account\_id, which never goes into a committed file. | `string` | n/a | yes |
| cors\_allowed\_origins | Origins of the web client (https://<domain>) that the CORS rules of the two buckets allow: POST of upload forms to the uploads bucket, GET and HEAD on the media bucket. Off the flat-rate Free plan the distribution allows the same origins for GET and HEAD; on it, every origin. | `list(string)` | n/a | yes |
| domain | Name of the env's hosted zone (svp.example): the distribution answers at `media.<domain>`, with its own certificate. | `string` | n/a | yes |
| flat\_rate\_free | Subscribe the distribution to the CloudFront flat-rate Free plan (managed Managed-SimpleCORS headers policy, no access log). false: pay-as-you-go, with the module's own CORS and security headers policy and standard logs to log\_delivery\_destination\_arn. | `bool` | n/a | yes |
| force\_destroy | Let terraform destroy delete both buckets with every object in them. Without it destroy fails on a bucket that is not empty. | `bool` | n/a | yes |
| hosted\_zone\_id | ID of the Route 53 public hosted zone of domain: the module writes the ACM validation record and the A and AAAA alias records of `media.<domain>` there. | `string` | n/a | yes |
| log\_delivery\_destination\_arn | ARN of the CloudWatch Logs delivery destination (us-east-1, in the Log Archive account) that receives the standard logs of the distribution, `arn:aws:logs:us-east-1:<account>:delivery-destination:svp-cloudfront-<env>`. Required when flat\_rate\_free is false; unused when it is true (the Free plan has no access log). | `string` | `null` | no |
| name\_prefix | Fixed start of every name (svp-stg, svp-prd): buckets are <name\_prefix>-uploads-<account\_id>-<region> and <name\_prefix>-media-<account\_id>-<region>. | `string` | n/a | yes |
| region | Region of the buckets, part of their names; the root passes the region of its provider. | `string` | n/a | yes |
| signing\_public\_keys | Public keys (PEM, `-----BEGIN PUBLIC KEY-----`, RSA 2048) that sign URLs of the distribution outside the public `media/*` and `preview/*` (`premium/`), by slot: `a`, `b`, one or two of them. Two slots let a new key enter the key group before the old one leaves. Each slot becomes a CloudFront public key named `<name_prefix>-media-<slot>-<first 8 hex of sha256(PEM)>`, so a new PEM is a new key, created before the old one is deleted; the key group `<name_prefix>-media` holds every key. | `map(string)` | n/a | yes |
| versioning\_enabled | Keep earlier versions of overwritten and deleted objects in both buckets, each for 30 days after it was replaced (a lifecycle rule then deletes it). Off by default: objects are written once, and kept versions keep deleted bytes billed. | `bool` | `false` | no |
| web\_acl\_arn | ARN of the AWS WAF web ACL of scope CLOUDFRONT (in us-east-1, output web\_acl\_arn of the waf module) in front of the distribution. With flat\_rate\_free the plan requires one and covers it, and AWS refuses to detach or replace it while the plan lasts. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| media\_bucket | Name of the media bucket. |
| media\_distribution\_arn | ARN of the CloudFront distribution in front of the media bucket. |
| media\_domain | Public name of the media, `media.<domain>`: MEDIA\_PUBLIC\_BASE\_URL of the gateway and MEDIA\_ORIGIN of the web are https://<media\_domain>. |
| media\_worker\_policy\_json | S3 and uploads key part of the IAM policy of media-worker, the MediaConvert bridge on AWS (JSON), for the role of its Pod Identity association. |
| signing\_key\_ids | ID of the CloudFront public key of each slot of signing\_public\_keys (`a`, `b`): the Key-Pair-Id that a URL signed with the private key of that slot carries (MEDIA\_SIGNING\_KEY\_ID of video-service). |
| uploads\_bucket | Name of the uploads bucket (the web posts upload forms to https://<name>.s3.<region>.amazonaws.com). |
| uploads\_kms\_key\_arn | ARN of the KMS key alias/<name\_prefix>-uploads, the default encryption of the uploads bucket: every role that reads or writes uploads needs it (MediaConvert through the transcode module). |
| video\_service\_policy\_json | IAM policy of video-service (JSON) for the role of its Pod Identity association. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
