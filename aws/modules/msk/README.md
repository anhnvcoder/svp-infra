# Module `msk`

Một cluster Amazon MSK provisioned cho một env: broker KRaft, client chỉ vào được bằng SASL/SCRAM-SHA-512 trên TLS cổng 9096, mỗi client
một user SCRAM, mật khẩu sinh và ghi trong cùng apply mà không qua plan hay state, storage autoscaling và alarm CloudWatch. Module ghi
mật khẩu vào hai entry `kafka-admin`, `kafka-users` mà module `external-secrets` tạo vỏ. Root `aws/envs/<env>` gọi module; lý do, cách
đổi mật khẩu và bẫy ở [chương 11. Dữ liệu](../../../docs/handbook/11-data.md); test: `make test DIRS=aws/modules/msk`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, rút gọn (đối số log tuỳ chọn ở bảng Inputs), giá trị là placeholder:

```hcl
module "msk" {
  source = "../../modules/msk"

  name                    = "svp-stg"
  vpc_id                  = "vpc-<id>"
  subnet_ids              = ["subnet-<a>", "subnet-<b>"]
  allowed_security_groups = { node = "sg-<node>", cluster = "sg-<cluster>" }
  broker_count            = 2
  broker_instance_type    = "kafka.m7g.large"
  broker_volume_max_size  = 20
  replication_factor      = 2
  min_insync_replicas     = 1
  password_version        = 1
  kafka_admin_secret_id   = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/kafka-admin-<suffix>"
  kafka_users_secret_id   = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/kafka-users-<suffix>"
  alarm_topic_arn         = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}
```

## Tham chiếu

- [Chương 11. Dữ liệu](../../../docs/handbook/11-data.md): ghi chú thiết kế mà `main.tf`, `alarms.tf` trỏ tới.
- [ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) §2, §5, §6, §12: cluster,
  user, replication, mật khẩu.
- [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) §2, §4: bảng alarm, storage
  autoscaling.

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
| [aws_appautoscaling_policy.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_msk_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/msk_cluster) | resource |
| [aws_msk_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/msk_configuration) | resource |
| [aws_msk_scram_secret_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/msk_scram_secret_association) | resource |
| [aws_secretsmanager_secret.scram](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.kafka_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.kafka_users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.scram](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.scram](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic every CloudWatch alarm of the cluster notifies, when it fires and when it clears. | `string` | n/a | yes |
| allowed\_security\_groups | Security groups whose members may connect on 9096, the SASL/SCRAM port (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| broker\_count | Number of brokers: a multiple of the number of subnets, since MSK puts the same number of brokers in each zone (one per zone in this lab). | `number` | n/a | yes |
| broker\_instance\_type | Instance type of every broker: a Standard broker of the m5, m7g or m8g family, the ones MSK accepts for a KRaft cluster (kafka.m7g.large in every env). | `string` | `"kafka.m7g.large"` | no |
| broker\_logs\_enabled | Send the broker logs to the CloudWatch log group /aws/msk/<name>, which this module creates. Off by default: ingestion is billed per GB. | `bool` | `false` | no |
| broker\_logs\_retention\_days | Days CloudWatch keeps the broker logs when broker\_logs\_enabled is true. | `number` | `1` | no |
| broker\_storage\_target\_utilization | Percentage of the broker volume in use (KafkaBrokerStorageUtilization) that storage autoscaling keeps the brokers under. | `number` | `60` | no |
| broker\_volume\_max\_size | Ceiling of the EBS volume of each broker, in GiB, up to which storage autoscaling grows it (at least broker\_volume\_size, at most 16384). | `number` | n/a | yes |
| broker\_volume\_size | Size of the EBS volume of each broker, in GiB (1 to 16384). | `number` | `10` | no |
| kafka\_admin\_secret\_id | ARN of the External Secrets entry svp/<env>/kafka-admin (output secret\_arns of the external-secrets module); this module writes its value, key SVP\_KAFKA\_ADMIN\_PASSWORD. | `string` | n/a | yes |
| kafka\_users\_secret\_id | ARN of the External Secrets entry svp/<env>/kafka-users (output secret\_arns of the external-secrets module); this module writes its value, one key SVP\_KAFKA\_<USER>\_PASSWORD per user other than svp-admin. | `string` | n/a | yes |
| kafka\_version | Apache Kafka version of the cluster, in the form <major>.<minor>.x.kraft: KRaft metadata mode, and MSK applies the patch releases of that line itself. | `string` | `"4.1.x.kraft"` | no |
| min\_insync\_replicas | Replicas that must hold a write acknowledged with acks=all (min.insync.replicas, and transaction.state.log.min.isr): below the replication factor, so that losing one broker still accepts writes; 1 when the replication factor is 1. | `number` | n/a | yes |
| name | Name of the MSK cluster (svp-stg, svp-prd), also the prefix of its security group, configuration, KMS alias, log group and SCRAM secrets (AmazonMSK\_<name>-<user>). | `string` | n/a | yes |
| password\_version | Version of the Kafka passwords. Terraform writes new random passwords, to the SCRAM secrets and to the two External Secrets entries together, only when this number changes: raise it to rotate every password. | `number` | `1` | no |
| replication\_factor | Replication factor of every topic (default.replication.factor; topics are created without one) and of the internal topics of consumer offsets and transactions. | `number` | n/a | yes |
| subnet\_ids | Database subnets of the brokers (the tier of the VPC with no route to the internet), one per availability zone (MSK takes two or three, and spreads the brokers evenly over them). | `list(string)` | n/a | yes |
| vpc\_id | VPC of the brokers and of their security group. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| bootstrap\_brokers | Bootstrap brokers for SASL/SCRAM over TLS, host:9096 of each broker separated by commas: key kafkaBrokers of the cluster values. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
