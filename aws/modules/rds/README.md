# Module `rds`

Một instance RDS PostgreSQL cho mọi service của một env (mỗi service vẫn một database và cặp role riêng, do Job bootstrap của cluster
tạo; module không tạo database nào). Thiết kế: [ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md)
mục 9 và 11.

Tạo: DB subnet group (subnet database của VPC, không route ra Internet), security group chỉ nhận TCP 5432 từ các security group
truyền vào (không rule egress), parameter group `postgres<major>` với `rds.force_ssl = 1` (kết nối không TLS bị từ chối), instance gp3
mã hoá bằng key AWS quản lý của RDS, không public, master username cố định `postgres`, mật khẩu master do RDS tạo và giữ ở Secrets
Manager (`manage_master_user_password`: không đi qua Terraform, không có trong plan hay state). Minor tự nâng trong cửa sổ bảo trì, major
không bao giờ tự nâng.

Giám sát ngoài Prometheus của cluster, mỗi thứ tắt mặc định (tốn tiền; lab đọc Prometheus), prd bật qua biến:

- **CloudWatch Database Insights chế độ Standard** (chế độ RDS bật mặc định, không phí theo vCPU như Advanced; module ghi tường minh).
  `performance_insights_enabled` bật Performance Insights trong chế độ đó, `performance_insights_retention_period` mặc định 7 ngày (mức
  miễn phí; Advanced đòi tối thiểu 465 ngày). Với PostgreSQL không giới hạn instance class (ngoại lệ `db.t4g.micro`, `small` chỉ áp cho
  MariaDB, MySQL). Nguồn (đọc 2026-11-05):
  [Database Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.html),
  [bật chế độ Standard](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.TurningOnStandard.html),
  [lưu ý](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.Considerations.html),
  [engine](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.Engines.html),
  [chi phí Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.Overview.cost.html).
- **Enhanced monitoring:** `monitoring_interval` khác 0 thì module tạo role `<name>-rds-monitoring`, trust policy theo hướng dẫn RDS (chỉ
  `monitoring.rds.amazonaws.com`, điều kiện `aws:SourceArn` là ARN của instance này và `aws:SourceAccount` là account này), gắn policy AWS
  quản lý `AmazonRDSEnhancedMonitoringRole`.
- **Export log:** `cloudwatch_logs_exports` (`postgresql`, `upgrade`, `iam-db-auth-error`); module tạo trước log group
  `/aws/rds/instance/<name>/<loại>` với retention `cloudwatch_logs_retention_days`, nên RDS không tự tạo group không hạn và `destroy` gỡ được.

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
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.postgres](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_id.final_snapshot](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allocated\_storage | Size of the gp3 volume, in GiB (20 is the gp3 minimum of RDS PostgreSQL). | `number` | `20` | no |
| allowed\_security\_groups | Security groups whose members may connect on 5432 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| backup\_retention\_period | Days of automated backups and point-in-time recovery. At least 1: 0 turns backups off. | `number` | `1` | no |
| cloudwatch\_logs\_exports | PostgreSQL logs RDS exports to CloudWatch Logs (postgresql, upgrade, iam-db-auth-error), each into a log group /aws/rds/instance/<name>/<type> this module creates. Empty (the default) exports nothing: ingestion is billed per GB. | `list(string)` | `[]` | no |
| cloudwatch\_logs\_retention\_days | Days CloudWatch keeps the exported logs when cloudwatch\_logs\_exports is not empty, and the OS metrics of enhanced monitoring when monitoring\_interval is not 0. | `number` | `1` | no |
| delete\_automated\_backups | Delete the automated backups, and with them the point-in-time recovery window, together with the instance, so a destroyed lab instance leaves no billed backup behind. Production keeps them (false): after a deletion they stay restorable to any second of the retention period, where the final snapshot alone holds one moment. | `bool` | `true` | no |
| deletion\_protection | Refuse to delete the instance until this is turned off by an apply. Off where the instance is destroyed at the end of every session, on for production. | `bool` | n/a | yes |
| engine\_major\_version | Major version of PostgreSQL. RDS picks the newest minor of it and upgrades minors in the maintenance window; a major upgrade is a change of its own. | `string` | `"15"` | no |
| instance\_class | DB instance class. | `string` | `"db.t4g.small"` | no |
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

## Giá trị theo env

| Biến | stg | prd |
| --- | --- | --- |
| `name` | `svp-stg` | `svp-prd` |
| `vpc_id` | VPC của module `network` | như stg |
| `subnet_ids` | subnet database, ≥ 2 AZ | subnet database, 3 AZ |
| `allowed_security_groups` | `{ node = …, cluster = … }` của EKS | như stg |
| `engine_major_version` | `"15"` | `"15"` |
| `instance_class` | `db.t4g.small` | theo số đo khi dựng prd |
| `allocated_storage` | `20` | theo số đo khi dựng prd |
| `multi_az` | `false` | `true` |
| `backup_retention_period` | `1` | ≥ 7, chốt khi dựng prd |
| `delete_automated_backups` | `true` | `false` |
| `deletion_protection` | `false` | `true` |
| `skip_final_snapshot` | `true` | `false` |

Hai biến bảo vệ dữ liệu không có mặc định: quên đặt thì hoặc mất dữ liệu prd, hoặc buổi stg không destroy được, nên mỗi env phải ghi rõ.
Snapshot cuối (khi `skip_final_snapshot = false`) tên `<name>-final-<8 hex>`, hậu tố ngẫu nhiên sống cùng instance, nên dựng lại rồi destroy
lần hai không trùng tên snapshot cũ.

## Mật khẩu master xoay vòng

Secrets Manager xoay mật khẩu master do RDS quản lý theo chu kỳ mặc định 7 ngày. Script buổi AWS đọc mật khẩu từ `master_user_secret_arn`
**ngay trước** khi nạp secret nguồn `pg-superuser` của cluster (chỉ `password`; username luôn `postgres`), không ra file, không in. Một
lần xoay giữa buổi làm secret trong cluster cũ đi: Job bootstrap chạy lại sẽ không đăng nhập được tới khi nạp lại. Script buổi không tính
tới buổi dài hơn chu kỳ xoay.

## Chi phí theo giờ (`ap-southeast-1`, giá đọc 2026-10-31, nguồn ở ADR-0034 [N7], [N11])

| Tài nguyên | Giá | Mỗi giờ |
| --- | --- | --- |
| Instance `db.t4g.small` single-AZ | $0,051/giờ (Multi-AZ $0,102/giờ) | $0,051 |
| gp3 20 GB | $0,138/GB-tháng | ~$0,004 (Multi-AZ tính theo giá Multi-AZ của trang giá, chưa ghi số ở đây) |
| Backup tự động | Miễn phí tới bằng dung lượng database mỗi region (trang giá [N7]); retention 1 ngày ở stg | ~$0 |
| Secret master (Secrets Manager) | $0,40/secret-tháng, $0,05/10 000 API | ~$0,0006 |
| Subnet group, security group, parameter group | Không tính tiền | $0 |

stg ~$0,055/giờ. Snapshot cuối của prd tính theo giá lưu trữ backup tới khi xoá tay.

## Có thể sót sau destroy

- **Secret master của RDS** (Secrets Manager, tên bắt đầu `rds!db-`): đi theo instance, chưa kiểm trên account; destroy dở (instance chưa
  xoá xong) thì còn. Quét Secrets Manager kể cả secret đang chờ xoá.
- **Snapshot cuối** `<name>-final-<hex>` khi `skip_final_snapshot = false` (prd): cố ý giữ lại, xoá tay khi không cần. stg không có.
- **Backup tự động:** stg `delete_automated_backups = true` nên xoá cùng instance; prd `false` nên còn lại sau destroy tới hết
  `backup_retention_period` (cố ý, tính tiền lưu trữ backup), xoá sớm bằng tay. `copy_tags_to_snapshot = true` nên snapshot mang tag
  `Project=svp` của root, quét được theo tag.
- **Instance còn `deletion_protection = true`:** `terraform destroy` dừng ở instance; phải `apply` với `false` trước.
