# Module `backup-alarms`

Hai CloudWatch alarm cho job AWS Backup lỗi trong account của một env: `<name>-backup-job-failed` (metric `NumberOfBackupJobsFailed`) và
`<name>-backup-copy-failed` (`NumberOfCopyJobsFailed`), mỗi alarm một query Metrics Insights trên namespace `AWS/Backup`, tag
`Severity=ticket`. Root `aws/envs/<env>` gọi module ở `backup.tf` với topic của module [`alarms`](../alarms/README.md) của root đó.
Vì sao không lọc dimension, đọc job lỗi ở đâu: [07. Backup](../../../docs/handbook/07-backup.md#amazon-cloudwatch-alarm-job-lỗi);
test: `make test DIRS=aws/modules/backup-alarms`.

## Ví dụ

Lời gọi của `aws/envs/stg/backup.tf`, giá trị là placeholder:

```hcl
module "backup_alarms" {
  source = "../../modules/backup-alarms"

  name            = "svp-stg"
  alarm_topic_arn = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}
```

## Tham chiếu

- [07. Backup](../../../docs/handbook/07-backup.md#amazon-cloudwatch-alarm-job-lỗi): metric, chu kỳ, mức `ticket` (ghi chú thiết kế mà
  `main.tf` trỏ tới).
- [Phụ lục ADR-0067 §5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#5-vault-copy-alarm):
  metric của AWS Backup, alarm trên query Metrics Insights, nguồn.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic both alarms notify, when they fire and when they clear (topic\_arn of the alarms module of the env). | `string` | n/a | yes |
| name | Name of the env (svp-stg, svp-prd): prefix of the alarm names <name>-backup-job-failed and <name>-backup-copy-failed. | `string` | n/a | yes |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
