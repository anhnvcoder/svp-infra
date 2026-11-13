# Module `backup-alarms`

Hai CloudWatch alarm cho job AWS Backup thất bại trong account của một env. Thiết kế:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §5. Root `aws/envs/<env>` gọi
module với `alarm_topic_arn` là topic của module [`alarms`](../alarms/README.md) của root đó.

| Alarm | Query Metrics Insights | Nghĩa |
| --- | --- | --- |
| `<name>-backup-job-failed` | `SELECT SUM(NumberOfBackupJobsFailed) FROM "AWS/Backup"` | Có backup job của account ở trạng thái `FAILED` |
| `<name>-backup-copy-failed` | `SELECT SUM(NumberOfCopyJobsFailed) FROM "AWS/Backup"` | Có copy job chéo account hay chéo region không hoàn tất |

Chung cho cả hai:

- Chu kỳ 300 giây (AWS Backup đẩy metric mỗi 5 phút), một chu kỳ, ngưỡng `> 0`, `treat_missing_data = "notBreaching"`:
  chu kỳ không có điểm dữ liệu (không job nào chạy) tính là không có job thất bại.
- Query không lọc dimension: tài liệu AWS Backup chỉ nêu dimension làm ví dụ (loại tài nguyên, tên vault; vault của copy
  job là vault đích), nên alarm cộng metric trên mọi tập dimension của namespace thay vì một metric mỗi tập dimension.
- Tag `Severity=ticket`: không có runbook riêng; job thất bại và lý do đọc ở mục Jobs của console AWS Backup trong
  account env.
- `alarm_actions` và `ok_actions` là `alarm_topic_arn`.

Nguồn (đọc 2026-11-13): [metric AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/cloudwatch.html),
[alarm trên query Metrics Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch-metrics-insights-alarms.html).

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
