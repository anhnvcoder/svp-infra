# Module `transcode`

Transcode video của một env bằng AWS Elemental MediaConvert: queue on-demand `svp-<env>`, role `svp-<env>-mediaconvert` mà job chạy
với, rule EventBridge đưa trạng thái cuối của job vào SQS `svp-<env>-transcode-events` có dead-letter queue và alarm, cộng policy IAM
(JSON) của bridge `media-worker mediaconvert`. Root `aws/envs/<env>` gọi module với ARN bucket và key của module `media`, topic của
module `alarms`; lý do ở [chương 12. Media và edge](../../../docs/handbook/12-media-edge.md); test: `make test DIRS=aws/modules/transcode`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder:

```hcl
module "transcode" {
  source = "../../modules/transcode"

  env                 = "stg"
  uploads_bucket_arn  = "arn:aws:s3:::svp-stg-uploads-000000000000-ap-southeast-1"
  uploads_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  media_bucket_arn    = "arn:aws:s3:::svp-stg-media-000000000000-ap-southeast-1"
  alarm_topic_arn     = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}
```

## Policy của bridge

Output `bridge_policy_json` là các dòng MediaConvert, `iam:PassRole`, SQS của bảng "Quyền bridge" ở phụ lục §9; dòng S3 do module `media`
giữ (`media_worker_policy_json`). Root env gộp hai JSON vào role Pod Identity `svp-<env>-media-worker`.

| Statement | Action | Resource | Điều kiện |
| --- | --- | --- | --- |
| `CreateJobs` | `mediaconvert:CreateJob` | ARN queue `svp-<env>` | — |
| `ReadJobs` | `mediaconvert:GetJob` | `arn:aws:mediaconvert:<region>:<account>:jobs/*` (ID job chỉ có sau khi tạo) | — |
| `ProbeInputs` | `mediaconvert:Probe` | `*` (action không có resource type) | — |
| `PassMediaConvertRole` | `iam:PassRole` | ARN role `svp-<env>-mediaconvert` | `StringEquals` `iam:PassedToService` `mediaconvert.amazonaws.com` |
| `ConsumeJobStates` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` | ARN `svp-<env>-transcode-events` | — |

## Tham chiếu

- [Chương 12. Media và edge](../../../docs/handbook/12-media-edge.md): ghi chú thiết kế mà `main.tf` trỏ tới.
- [ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md) §1, §7, §9 và
  [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md) (§7, §9, "Control
  FSBP"): bảng quyền, giá trị, control.

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
| [aws_cloudwatch_event_rule.job_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.job_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_media_convert_queue.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/media_convert_queue) | resource |
| [aws_sqs_queue.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.mediaconvert_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.queue](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic the alarm of the dead-letter queue notifies, when it fires and when it clears (output topic\_arn of the alarms module). | `string` | n/a | yes |
| env | Environment (stg, prd): every name of the module starts with svp-<env>. | `string` | n/a | yes |
| media\_bucket\_arn | ARN of the media bucket of the env (arn:aws:s3:::<name>): MediaConvert writes the output of a job under media/, or premium/ for a premium video, with its role. | `string` | n/a | yes |
| uploads\_bucket\_arn | ARN of the uploads bucket of the env (arn:aws:s3:::<name>): MediaConvert reads the input of a job under uploads/ with its role. | `string` | n/a | yes |
| uploads\_kms\_key\_arn | ARN of the KMS key that encrypts the uploads bucket (output uploads\_kms\_key\_arn of the media module): MediaConvert decrypts the input of a job with its role. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| bridge\_policy\_json | IAM policy (JSON) of the bridge for MediaConvert, iam:PassRole and SQS; the env root joins it with media\_worker\_policy\_json of the media module in the Pod Identity role of media-worker. |
| events\_queue\_url | URL of the SQS queue svp-<env>-transcode-events of the job states: key transcodeEventsQueueUrl of the cluster values. |
| queue\_arn | ARN of the MediaConvert queue svp-<env>: key mediaconvertQueueArn of the cluster values. |
| role\_arn | ARN of the role svp-<env>-mediaconvert that jobs run with: key mediaconvertRoleArn of the cluster values. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
