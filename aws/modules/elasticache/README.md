# Module `elasticache`

Một replication group ElastiCache for Valkey cho một env: cluster mode tắt, chỉ nhận TLS, mỗi client đăng nhập một user RBAC chỉ vào
được db và tiền tố khoá của nó, mật khẩu sinh và ghi trong cùng apply mà không qua plan hay state, slow-log và alarm CloudWatch. Module
ghi mật khẩu vào entry `valkey-users` mà module `external-secrets` tạo vỏ. Root `aws/envs/<env>` gọi module; lý do và bẫy ở
[chương 11. Dữ liệu](../../../docs/handbook/11-data.md); test: `make test DIRS=aws/modules/elasticache`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder (root đọc chúng từ `stg.tfvars`):

```hcl
module "elasticache" {
  source = "../../modules/elasticache"

  name                    = "svp-stg"
  vpc_id                  = "vpc-<id>"
  subnet_ids              = ["subnet-<a>", "subnet-<b>"]
  allowed_security_groups = { node = "sg-<node>", cluster = "sg-<cluster>" }
  node_type               = "cache.t4g.micro"
  node_count              = 1
  apply_immediately       = true
  slow_log_retention_days = 1
  password_version        = 1
  valkey_users_secret_id  = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/valkey-users-<suffix>"
  alarm_topic_arn         = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}
```

## Tham chiếu

- [Chương 11. Dữ liệu](../../../docs/handbook/11-data.md): ghi chú thiết kế mà `main.tf`, `alarms.tf` trỏ tới.
- [ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) §7, §9, §12: replication
  group, access string, mật khẩu.
- [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) §2, §5: bảng alarm, bảo trì,
  slow-log.

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

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.slow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_elasticache_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_parameter_group) | resource |
| [aws_elasticache_replication_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group) | resource |
| [aws_elasticache_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_subnet_group) | resource |
| [aws_elasticache_user.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_user) | resource |
| [aws_elasticache_user_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_user_group) | resource |
| [aws_secretsmanager_secret_version.valkey_users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.valkey](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic every CloudWatch alarm of the replication group notifies, when it fires and when it clears. | `string` | n/a | yes |
| allowed\_security\_groups | Security groups whose members may connect on 6379 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| apply\_immediately | Apply a change of the replication group at once (true) or in the next maintenance window (false), where a plan shows it as pending until then. | `bool` | n/a | yes |
| engine\_version | Valkey version, <major>.<minor>, at least 9.1: the first version whose ACL limits a user to databases (db=). ElastiCache applies the patch releases itself. | `string` | `"9.1"` | no |
| name | ID of the replication group (svp-stg, svp-prd), also the name of its subnet group and user group, the prefix of its security group, parameter group and user IDs (<name>-gateway). It appears in the public Certificate Transparency logs through the TLS certificate of the nodes. | `string` | n/a | yes |
| node\_count | Nodes of the replication group, the primary included (1 to 6). With 2 or more the group runs Multi-AZ with automatic failover to a replica; 1 has no replica and no failover. | `number` | n/a | yes |
| node\_type | Node type of every node (cache.t4g.micro for a lab env, cache.m7g.large for production). | `string` | `"cache.t4g.micro"` | no |
| password\_version | Version of the Valkey passwords. Terraform writes new random passwords, to the ElastiCache users and to the External Secrets entry together, only when this number changes: raise it to rotate every password. | `number` | `1` | no |
| slow\_log\_retention\_days | Days CloudWatch keeps the slow log of the engine, sent to the log group /aws/elasticache/<name>/slow-log that this module creates. | `number` | n/a | yes |
| subnet\_ids | Database subnets of the cache subnet group (the tier of the VPC with no route to the internet), in at least two availability zones (a replica goes in another zone than the primary). | `list(string)` | n/a | yes |
| valkey\_users\_secret\_id | ID or ARN of the Secrets Manager entry svp/<env>/valkey-users (made by the external-secrets module), into which the module writes the password of each user under SVP\_VALKEY\_<USER>\_PASSWORD. | `string` | n/a | yes |
| vpc\_id | VPC of the nodes and of their security group. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| primary\_endpoint\_address | Host name of the primary node, without port (clients connect on 6379 over TLS): key valkeyHost of the cluster values. |
<!-- END_TF_DOCS -->
