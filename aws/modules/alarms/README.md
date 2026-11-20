# Module `alarms`

Topic SNS `<name>-alarms` mà alarm hay cảnh báo gửi tới, mã hoá bằng KMS key của module, topic policy chỉ cho đúng dịch vụ của
`publisher_services` gửi vào, và subscription email `alarm_email` (người nhận xác nhận sau apply). Ba root gọi module: `aws/envs/<env>`
(alarm của RDS, MSK, ElastiCache và Alertmanager của AMP), `aws/security` (sự kiện bảo mật qua EventBridge), `aws/accounts/prd` (alarm
DNSSEC, `region = "us-east-1"`). Mặc định chỉ CloudWatch gửi được. Lý do ở [chương 11. Dữ liệu](../../../docs/handbook/11-data.md);
test: `make test DIRS=aws/modules/alarms`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder:

```hcl
module "alarms" {
  source = "../../modules/alarms"

  name        = "svp-stg"
  alarm_email = "ops@svp.example"

  publisher_services = ["cloudwatch.amazonaws.com", "aps.amazonaws.com"]
  aps_workspace_arn  = "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-<id>"
}
```

## Tham chiếu

- [Chương 11. Dữ liệu](../../../docs/handbook/11-data.md): đường alarm tới email, KMS key và điều kiện confused deputy theo publisher,
  subscription chưa xác nhận sau destroy (ghi chú thiết kế mà `main.tf` trỏ tới).
- [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) §1: tên, mức, đích của alarm;
  [ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) §5: Alertmanager của AMP.
- [Chương 05. Bảo mật](../../../docs/handbook/05-security.md): topic `svp-security-alarms` của sự kiện bảo mật
  ([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §10).

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
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_sns_topic.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.topic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_email | Email address subscribed to the topic; SNS sends it a confirmation link and delivers nothing until the link is opened. | `string` | n/a | yes |
| aps\_workspace\_arn | ARN of the Amazon Managed Service for Prometheus workspace whose Alertmanager publishes to the topic (aws:SourceArn of the aps.amazonaws.com statement). Null: Prometheus does not publish. | `string` | `null` | no |
| name | Name of the env or stack (svp-stg, svp-prd, svp-security): prefix of the SNS topic <name>-alarms and of the KMS alias alias/<name>-alarms. | `string` | n/a | yes |
| publisher\_services | Service principals that publish to the topic and use its key, each limited to its own resources of this account and region: cloudwatch.amazonaws.com (alarms), events.amazonaws.com (EventBridge rules), aps.amazonaws.com (Alertmanager of the Prometheus workspace aps\_workspace\_arn). | `list(string)` | <pre>[<br/>  "cloudwatch.amazonaws.com"<br/>]</pre> | no |
| region | Region of the topic, its key and the alarms that may notify it (CloudWatch alarm actions reach a topic of their own region only). Null: the region of the provider. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| topic\_arn | ARN of the SNS topic <name>-alarms: alarm\_actions and ok\_actions of every CloudWatch alarm of the env (alarm\_topic\_arn of the rds, msk and elasticache modules). |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
