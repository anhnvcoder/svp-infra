# Module `rds`

Một instance RDS for PostgreSQL cho mọi service của một env: subnet group, security group chỉ nhận 5432 từ security group truyền vào,
parameter group bắt TLS và ghi log, KMS key riêng, alarm CloudWatch gửi topic của module `alarms`. Mỗi service một database và cặp role,
do Job bootstrap của cluster tạo; module không tạo database nào. Root `aws/envs/<env>` gọi module; lý do, alarm, khác nhau giữa stg và
prd ở [chương 11. Dữ liệu](../../../docs/handbook/11-data.md); test: `make test DIRS=aws/modules/rds`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, rút gọn (đối số giám sát và log tuỳ chọn ở bảng Inputs), giá trị là placeholder:

```hcl
module "rds" {
  source = "../../modules/rds"

  name                     = "svp-stg"
  vpc_id                   = "vpc-<id>"
  subnet_ids               = ["subnet-<a>", "subnet-<b>"]
  allowed_security_groups  = { node = "sg-<node>", cluster = "sg-<cluster>" }
  instance_class           = "db.t4g.small"
  max_allocated_storage    = 40
  multi_az                 = false
  backup_retention_period  = 1
  delete_automated_backups = true
  deletion_protection      = false
  skip_final_snapshot      = true
  backup_copy_account_id   = "000000000000"
  alarm_topic_arn          = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}
```

## Tham chiếu

- [Chương 11. Dữ liệu](../../../docs/handbook/11-data.md): ghi chú thiết kế mà `main.tf`, `alarms.tf` trỏ tới.
- [ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md): PostgreSQL 17, TLS, RDS
  chuẩn; [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) §2, §3: bảng alarm.
- [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §6: key policy cho bản copy backup.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| random | ~> 3.9 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |
| random | ~> 3.9 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.os_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.postgres](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_id.final_snapshot](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic every CloudWatch alarm of the instance notifies, when it fires and when it clears. | `string` | n/a | yes |
| allocated\_storage | Size of the gp3 volume, in GiB (20 is the gp3 minimum of RDS PostgreSQL). | `number` | `20` | no |
| allowed\_security\_groups | Security groups whose members may connect on 5432 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| backup\_copy\_account\_id | AWS account (12 digits) that receives the cross-account copies of the instance's backups. The key policy of the instance's KMS key lets this account decrypt the snapshots and create grants for AWS resources, which a copy across accounts needs. | `string` | n/a | yes |
| backup\_retention\_period | Days of automated backups and point-in-time recovery. At least 1: 0 turns backups off. | `number` | `1` | no |
| cloudwatch\_logs\_exports | PostgreSQL logs RDS exports to CloudWatch Logs (postgresql, upgrade, iam-db-auth-error), each into a log group /aws/rds/instance/<name>/<type> this module creates. Empty (the default) exports nothing: ingestion is billed per GB. | `list(string)` | `[]` | no |
| cloudwatch\_logs\_retention\_days | Days CloudWatch keeps the exported logs when cloudwatch\_logs\_exports is not empty, and the OS metrics of enhanced monitoring when monitoring\_interval is not 0. | `number` | `1` | no |
| delete\_automated\_backups | Delete the automated backups, and with them the point-in-time recovery window, together with the instance, so a destroyed lab instance leaves no billed backup behind. Production keeps them (false): after a deletion they stay restorable to any second of the retention period, where the final snapshot alone holds one moment. | `bool` | `true` | no |
| deletion\_protection | Refuse to delete the instance until this is turned off by an apply. Off where the instance is destroyed at the end of every session, on for production. | `bool` | n/a | yes |
| engine\_major\_version | Major version of PostgreSQL. RDS picks the newest minor of it and upgrades minors in the maintenance window; a major upgrade is a change of its own. | `string` | `"17"` | no |
| instance\_class | DB instance class: db.t4g.small (stg) or db.m7g.large (prd), the classes whose memory, vCPU count and default max\_connections the alarm thresholds are written for. | `string` | `"db.t4g.small"` | no |
| max\_allocated\_storage | Upper limit, in GiB, up to which storage autoscaling grows the volume when free space runs low. At least 26 % above allocated\_storage, so RDS does not warn that the limit is too close. | `number` | `40` | no |
| monitoring\_interval | Seconds between two enhanced monitoring samples of the operating system; 0 (the default) turns enhanced monitoring off and creates no IAM role. Any other value creates the role <name>-rds-monitoring and the log group RDSOSMetrics of the account and region, which RDS writes the OS metrics to: no other instance of that account and region may have enhanced monitoring on. | `number` | `0` | no |
| multi\_az | Keep a synchronous standby in a second availability zone, which takes over on failure (twice the instance cost). Off for a lab env that lives a few hours, on for production. | `bool` | `false` | no |
| name | Identifier of the DB instance (svp-stg, svp-prd), also the prefix of its security group, subnet group and parameter group. | `string` | n/a | yes |
| performance\_insights\_enabled | Turn on Performance Insights (database load by wait event, SQL and host) within Database Insights in Standard mode. Off by default: the lab reads the cluster's Prometheus. | `bool` | `false` | no |
| performance\_insights\_retention\_period | Days of Performance Insights history when performance\_insights\_enabled is true: 7 (the free retention), a multiple of 31 up to 713 (months), or 731. | `number` | `7` | no |
| skip\_final\_snapshot | Delete the instance without a last manual snapshot. A final snapshot outlives the instance, is billed as backup storage and must be deleted by hand; skip it only where the data is disposable. | `bool` | n/a | yes |
| subnet\_ids | Database subnets of the DB subnet group (the tier of the VPC with no route to the internet), in at least two availability zones (RDS requires two even for a single-AZ instance, and a Multi-AZ standby goes in the other one). | `list(string)` | n/a | yes |
| vpc\_id | VPC of the instance and of its security group. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| address | Host name of the instance (resolves to its private address inside the VPC). |
| master\_user\_secret\_arn | ARN of the Secrets Manager secret in which RDS keeps the master password (JSON with username and password). Not a secret itself; reading the value takes secretsmanager:GetSecretValue. |
| port | Port of the instance. |
| security\_group\_id | Security group of the instance; network policies and egress rules of the cluster point at it. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
