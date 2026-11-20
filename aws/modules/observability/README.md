# Module `observability`

Nơi nhận telemetry của một account env (`svp-stg`, `svp-prd`): workspace AMP `svp-<env>`, log group `/svp/<env>/otel` và stream
`otel-collector`, Transaction Search của X-Ray, key `alias/svp-<env>-observability`; khi `grafana_enabled`, workspace Amazon Managed Grafana
`svp-<env>`, role của nó, hai gán nhóm, service account `svp-grafana-operator` và tham số SSM `/svp/<env>/grafana-workspace-id`.
Root `aws/accounts/<env>` ([README](../../accounts/README.md)) gọi module nên metric, log, span sống qua `destroy` của buổi; luồng
telemetry và lý do: [08. Account env](../../../docs/handbook/08-accounts.md#amazon-managed-service-for-prometheus). Test:
`make test DIRS=aws/modules/observability`.

## Ví dụ

Lời gọi của `aws/accounts/stg/main.tf` (ở đó retention lấy từ `locals`, `grafana_enabled` tính từ cờ `managed_grafana` và
`session_open`), giá trị là placeholder:

```hcl
module "observability" {
  source = "../../modules/observability"

  env                      = "stg"
  amp_retention_days       = 31
  log_retention_days       = 7
  span_retention_days      = 7
  platform_admin_group_id  = "<id nhóm svp-platform-admins>"
  platform_viewer_group_id = "<id nhóm svp-platform-viewers>"
  grafana_enabled          = false
}
```

Output `amp_workspace_id`, `amp_endpoint`, `log_group_name`, `grafana_url` là khoá `ampWorkspaceId`, `ampEndpoint`, `logGroup`,
`grafanaUrl` của cluster values. Retention của `aws/spans` đặt tay một lần mỗi account bằng lệnh của output `spans_retention_command`.

## Tham chiếu

- [08. Account env](../../../docs/handbook/08-accounts.md): AMP, CloudWatch Logs, X-Ray, AMG; key, `aws/spans`, endpoint AMP ở mục Đọc
  sâu (ghi chú thiết kế mà `main.tf` trỏ tới).
- [ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md): metric, log, trace, Grafana,
  retention; key policy và nguồn ở
  [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0063-managed-observability.md).
- [`platform-setup.md`, bước (10)](../../../docs/runbooks/platform-setup.md#bước-10-retention-của-awsspans): retention của `aws/spans`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.46 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.46 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.otel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.xray_spans](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_cloudwatch_log_stream.otel_collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_stream) | resource |
| [aws_grafana_role_association.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/grafana_role_association) | resource |
| [aws_grafana_role_association.viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/grafana_role_association) | resource |
| [aws_grafana_workspace.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/grafana_workspace) | resource |
| [aws_grafana_workspace_service_account.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/grafana_workspace_service_account) | resource |
| [aws_iam_role.grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.observability](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.observability](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_prometheus_workspace.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/prometheus_workspace) | resource |
| [aws_prometheus_workspace_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/prometheus_workspace_configuration) | resource |
| [aws_ssm_parameter.grafana_workspace_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_xray_indexing_rule.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/xray_indexing_rule) | resource |
| [aws_xray_trace_segment_destination.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/xray_trace_segment_destination) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.grafana_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.observability_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.xray_spans](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| amp\_retention\_days | Days the Prometheus workspace keeps metrics (1 to 1095, the range of Amazon Managed Service for Prometheus). | `number` | n/a | yes |
| env | Environment of the account (stg, prd): names the workspaces `svp-<env>`, the log group `/svp/<env>/otel`, the KMS key `alias/svp-<env>-observability` and the role `svp-<env>-grafana`. | `string` | n/a | yes |
| grafana\_enabled | Whether the Amazon Managed Grafana workspace `svp-<env>` exists, with its role `svp-<env>-grafana`, group role associations, service account svp-grafana-operator and SSM parameter `/svp/<env>/grafana-workspace-id`. The Prometheus workspace, the key, the log groups and X-Ray stay at either value. | `bool` | `true` | no |
| log\_retention\_days | Days the log group `/svp/<env>/otel` keeps the application logs; one of the retention values CloudWatch Logs accepts. | `number` | n/a | yes |
| platform\_admin\_group\_id | Id of the IAM Identity Center group svp-platform-admins, given the ADMIN role of the Grafana workspace. Kept out of committed files: the root reads it from its uncommitted `<env>.auto.tfvars`. | `string` | n/a | yes |
| platform\_viewer\_group\_id | Id of the IAM Identity Center group svp-platform-viewers, given the VIEWER role of the Grafana workspace. Kept out of committed files like platform\_admin\_group\_id. | `string` | n/a | yes |
| span\_retention\_days | Days the log group aws/spans, which X-Ray creates, keeps the spans; one of the retention values CloudWatch Logs accepts. Terraform cannot manage that group: the value goes into the command of the spans\_retention\_command output, run once per account. | `number` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| amp\_endpoint | Base URL of the Prometheus workspace, ending in /: ampEndpoint of the cluster values; api/v1/remote\_write and api/v1/query are appended to it. |
| amp\_workspace\_arn | ARN of the Prometheus workspace, for the Pod Identity roles that write, query or manage rules on it. |
| amp\_workspace\_id | Id of the Prometheus workspace `svp-<env>` (`ws-<uuid>`): ampWorkspaceId of the cluster values. |
| grafana\_url | URL of the Grafana workspace, https:// and its endpoint, no trailing slash: grafanaUrl of the cluster values. Null when grafana\_enabled is false. |
| kms\_key\_arn | ARN of the key `alias/svp-<env>-observability`, for the Collector's permission to write the encrypted log group. |
| log\_group\_arn | ARN of the application log group, without the :* suffix; its stream otel-collector is `<arn>:log-stream:otel-collector`. |
| log\_group\_name | Name of the application log group `/svp/<env>/otel`: logGroup of the cluster values. |
| spans\_retention\_command | Command the learner runs once per account, after X-Ray has created the log group aws/spans, to set its retention to span\_retention\_days: Terraform cannot create or adopt a log group whose name starts with aws/. |
<!-- END_TF_DOCS -->
