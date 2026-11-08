# Module `msk`

Một cluster Amazon MSK provisioned cho một env: broker Standard chế độ KRaft, client chỉ vào được bằng SASL/SCRAM-SHA-512 trên TLS cổng
9096, mỗi client một user SCRAM. Thiết kế: [ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md)
§2, §5, §6, §12.

Tạo:

- Security group chỉ nhận TCP 9096 từ các security group truyền vào (`allowed_security_groups`, node SG và cluster primary SG của EKS),
  không rule egress: không cổng nào khác của MSK mở (9092 plaintext, 9094 TLS không user, 9098 IAM), nên client không lùi về đường khác được.
- `aws_msk_cluster`: `broker_count` broker (bội số của số subnet, MSK chia đều broker cho các AZ; lab đặt một broker mỗi AZ), EBS
  `broker_volume_size` GiB mỗi broker; xác thực chỉ SCRAM (`unauthenticated = false`, không IAM: ACL Kafka không áp lên danh tính IAM; không
  mTLS); `client_broker = "TLS"`, `in_cluster = true`; at-rest bằng KMS key của module.
- `aws_msk_configuration` tên `<name>-<phiên bản>` (ví dụ `svp-stg-4-1-x-kraft`): `auto.create.topics.enable=false`,
  `allow.everyone.if.no.acl.found=true` (mặc định của MSK; MSK không cho đặt `super.users`, nên với `false` không user nào tạo được ACL đầu
  tiên; Job init cấp `svp-admin` ALL trên cluster, mọi topic, group, transactional id trước mọi ACL khác, từ đó user khác chỉ có quyền được
  cấp), `default.replication.factor`, `offsets.topic.replication.factor`, `transaction.state.log.replication.factor` bằng
  `replication_factor`, `min.insync.replicas`, `transaction.state.log.min.isr` bằng `min_insync_replicas` (MSK để hai topic nội bộ ở 3 của
  Apache Kafka, ít broker hơn thì không tạo được).
- Một KMS key customer managed (symmetric, xoay vòng bật, deletion window 7 ngày, alias `alias/<name>-msk-scram`) cho secret SCRAM và volume
  broker: MSK từ chối secret mã hoá bằng key AWS quản lý của Secrets Manager; secret trỏ key bằng ARN, không bằng alias.
- Mỗi user một secret `AmazonMSK_<name>-<user>` (JSON `username`, `password`; `recovery_window_in_days = 0`) và một
  `aws_msk_scram_secret_association` cho cả tám secret.
- Giá trị của hai entry External Secrets do module `external-secrets` tạo vỏ: `svp/<env>/kafka-admin` (khoá `SVP_KAFKA_ADMIN_PASSWORD`),
  `svp/<env>/kafka-users` (khoá `SVP_KAFKA_<USER>_PASSWORD` của bảy user còn lại).
- Log group `/aws/msk/<name>` với retention `broker_logs_retention_days`, chỉ khi `broker_logs_enabled` (MSK không tự tạo đích log; tạo ở
  đây thì `destroy` gỡ được).

User: `svp-admin`, `svp-user-service`, `svp-video-service`, `svp-engagement-service`, `svp-feed-service`, `svp-media-worker`, `svp-keda`,
`svp-otelcol`; khoá trong entry là tên user bỏ `svp-`, viết hoa, `-` thành `_`, kẹp giữa `SVP_KAFKA_` và `_PASSWORD`, cùng tên biến của `.env`
local.

## Mật khẩu

- Ephemeral `random_password` (32 ký tự, chỉ chữ và số: mật khẩu chèn thẳng, không thoát, vào `password="…"` của JAAS, aclfile và URL) sinh
  mỗi lần plan, apply, không lưu ở đâu; chỉ ghi qua đối số write-only `secret_string_wo` của `aws_secretsmanager_secret_version`, nên không
  nằm trong plan hay state. Output không có mật khẩu nào.
- Mỗi lần apply mật khẩu sinh lại, nhưng version write-only chỉ ghi khi `secret_string_wo_version` đổi. Mọi lần ghi (tám secret
  `AmazonMSK_*`, hai entry) dùng cùng `password_version` và cùng lần mở ephemeral, nên sau một apply trọn, secret SCRAM và entry cùng giá trị.
- Các lần ghi lệch nhau khi apply dừng giữa chừng (một `PutSecretValue` lỗi, Ctrl-C) hay khi thêm user vào `local.users` trên env đang
  sống: secret của user đó nhận giá trị của lần mở mới, còn `kafka-users`/`kafka-admin` đã ghi ở version cũ nên giữ giá trị cũ; user đó
  đăng nhập SCRAM thất bại mà `plan` vẫn `No changes`. Gỡ: tăng `password_version` rồi apply, mọi lần ghi cùng chạy lại.
- Đổi mật khẩu: tăng `password_version` rồi apply; mọi user đổi cùng lúc, vì `kafka-users` là một entry chung, đổi riêng một user sẽ ghi giá trị
  mới của các user khác vào entry mà không ghi secret SCRAM của họ. MSK đồng bộ secret tới broker trong tối đa 10 phút: kết nối mới của pod
  chưa đọc mật khẩu mới có thể bị từ chối trong lúc đó.
- `make eks-secrets` của repo code không ghi `kafka-admin`, `kafka-users` nữa: module này là nơi duy nhất ghi.

## Lưu ý vận hành

- `aws_msk_scram_secret_association` giữ độc quyền danh sách secret của cluster: secret nào không có trong nó bị gỡ khỏi cluster. Mọi user ở
  một resource; không tạo resource association thứ hai (hay `aws_msk_single_scram_secret_association`) cho cùng cluster.
- Đổi `server_properties` (biến replication) tạo revision mới của configuration, MSK áp lên từng broker một (rolling restart); đổi dòng
  phiên bản Kafka tạo configuration mới tên theo phiên bản trước khi cluster chuyển sang.
- MSK gắn resource policy của nó vào mỗi secret `AmazonMSK_*`; module không quản policy đó.

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
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
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
| allowed\_security\_groups | Security groups whose members may connect on 9096, the SASL/SCRAM port (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| broker\_count | Number of brokers: a multiple of the number of subnets, since MSK puts the same number of brokers in each zone (one per zone in this lab). | `number` | n/a | yes |
| broker\_instance\_type | Instance type of every broker (kafka.t3.small for a lab env, kafka.m7g.large for production). | `string` | `"kafka.t3.small"` | no |
| broker\_logs\_enabled | Send the broker logs to the CloudWatch log group /aws/msk/<name>, which this module creates. Off by default: ingestion is billed per GB. | `bool` | `false` | no |
| broker\_logs\_retention\_days | Days CloudWatch keeps the broker logs when broker\_logs\_enabled is true. | `number` | `1` | no |
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

## Giá trị theo env

| Biến | stg | prd |
| --- | --- | --- |
| `name` | `svp-stg` | `svp-prd` |
| `subnet_ids` | subnet database, 2 AZ (cùng subnet RDS) | subnet database, 3 AZ |
| `allowed_security_groups` | `{ node = …, cluster = … }` của EKS | như stg |
| `kafka_version` | `4.1.x.kraft` | `4.1.x.kraft` |
| `broker_instance_type` | `kafka.t3.small` | `kafka.m7g.large` |
| `broker_count` | `2` | `3` |
| `broker_volume_size` | `10` | `10` |
| `replication_factor` / `min_insync_replicas` | `2` / `1` | `3` / `2` |
| `broker_logs_enabled` / `broker_logs_retention_days` | `false` / — | `true` / `30` |
| `kafka_admin_secret_id`, `kafka_users_secret_id` | `secret_arns["kafka-admin"]`, `secret_arns["kafka-users"]` của module `external-secrets` | như stg |

Ba biến số broker, replication factor và min ISR không có mặc định: mỗi env ghi rõ, validation từ chối RF lớn hơn số broker, min ISR không nhỏ
hơn RF (khi RF > 1) và số broker không chia hết số subnet.

## Có thể sót sau destroy

- **KMS key:** vào `PendingDeletion` 7 ngày, không tính phí lúc chờ; alias xoá ngay.
- **Secret `AmazonMSK_*`:** xoá ngay (`recovery_window_in_days = 0`); destroy dở thì còn, quét Secrets Manager theo tiền tố `AmazonMSK_svp-`.
- **Configuration MSK:** không xoá được khi cluster còn dùng; destroy dở (cluster chưa xoá xong) thì còn.
