# Module `elasticache`

Một replication group ElastiCache for Valkey cho một env: node-based, cluster mode tắt (client nói giao thức Valkey thường, không giao thức
cluster, như Valkey local), chỉ nhận kết nối TLS, mỗi client đăng nhập một user RBAC chỉ vào được db và tiền tố khoá của nó. Thiết kế:
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) §7, §9, §12.

Tạo:

- Cache subnet group (subnet database) và security group chỉ nhận TCP 6379 từ các security group truyền vào (`allowed_security_groups`, node
  SG và cluster primary SG của EKS), không rule egress.
- Parameter group họ `valkey<major>` (tên `<name>-valkey<major>`) với `maxmemory-policy noeviction`: khoá là bộ đếm rate limit, session,
  cache mà service chờ đọc lại, đầy bộ nhớ thì lệnh ghi lỗi rõ thay vì âm thầm bỏ khoá (mặc định `volatile-lru`).
- `aws_elasticache_replication_group` id `<name>`, `engine = "valkey"`, `engine_version` (mặc định `9.1`, tối thiểu 9.1: bản đầu có `db=`
  trong ACL), `node_count` node `node_type`; `transit_encryption_mode = "required"` (RBAC cần TLS; kết nối không TLS bị từ chối),
  at-rest bật (key AWS quản lý của ElastiCache), không AUTH token, không IAM; `snapshot_retention_limit = 0`, không final snapshot (dữ liệu
  dựng lại được); `apply_immediately` vì env sống một buổi, thay đổi chờ cửa sổ bảo trì sẽ không bao giờ thấy.
- `automatic_failover_enabled` và `multi_az_enabled` bật khi `node_count` ≥ 2, tắt khi 1 node (không có replica để chuyển sang): suy ra
  từ số node, không biến riêng, nên không có tổ hợp "Multi-AZ một node". stg 1 × `cache.t4g.micro`; prd 2 × `cache.m7g.large`.
- Bốn `aws_elasticache_user` engine `valkey` và một `aws_elasticache_user_group` id `<name>` engine `valkey` gắn vào replication group.

Tên `<name>` (replication group id) vào log Certificate Transparency công khai qua cert TLS của node: chỉ đặt `svp-<env>`.

## User

| User (`user_name`) | `user_id` | Khoá trong entry | Access string |
| ---- | ---- | ---- | ---- |
| `svp-gateway` | `<name>-gateway` | `SVP_VALKEY_GATEWAY_PASSWORD` | `on ~svp:gw:* resetchannels db=10 -@all +select +client\|setinfo +eval +evalsha +time +get +set +del` |
| `svp-feed-service` | `<name>-feed-service` | `SVP_VALKEY_FEED_SERVICE_PASSWORD` | `on ~svp:feed:* resetchannels db=14 -@all +select +client\|setinfo +get +set` |
| `svp-web` | `<name>-web` | `SVP_VALKEY_WEB_PASSWORD` | `on ~svp:web:* resetchannels db=9 -@all +select +client\|setinfo +eval +get +set +del +exists` |
| `svp-ops` | `<name>-ops` | `SVP_VALKEY_OPS_PASSWORD` | `on ~svp:* resetchannels db=9,10,14 -@all +select +ping +time +scan +get +mget +pttl (~svp:gw:rl:register:* resetchannels db=10 -@all +del) (~svp:feed:explore:* resetchannels db=14 -@all +del)` |

- Access string nguyên văn ADR-0053 §9, cùng chuỗi với aclfile local (`backend/deploy/valkey/`). Đổi một quyền thì đổi cả hai nơi và ADR.
- `user_id` duy nhất trong account và region, còn `user_name` (tên client đăng nhập) giống nhau ở mọi env, nên id mang tên env.
- Không tạo user `default`: user group engine VALKEY không cần nó, và ElastiCache tắt `default` khi gắn group
  ([RBAC](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.RBAC.html), đọc 2026-11-08).

## Mật khẩu

- Ephemeral `random_password` (32 ký tự, chỉ chữ và số: mật khẩu chèn thẳng, không thoát, vào `REDIS_URL` và aclfile) sinh mỗi lần plan,
  apply, không lưu ở đâu; chỉ ghi qua đối số write-only: `passwords_wo` của `aws_elasticache_user` và `secret_string_wo` của
  `aws_secretsmanager_secret_version`, nên không nằm trong plan hay state. Output không có mật khẩu nào.
- Ephemeral của provider `random` chứ không `aws_secretsmanager_random_password`: cùng bảng ký tự, độ dài, và mock provider AWS của
  `terraform test` không mở được ephemeral resource của nó.
- Mỗi lần apply mật khẩu sinh lại, nhưng chỉ được ghi khi `password_version` đổi (`passwords_wo_version`, `secret_string_wo_version`). Bốn
  user và entry `svp/<env>/valkey-users` (biến `valkey_users_secret_id`, vỏ do module `external-secrets` tạo) dùng cùng version và cùng lần
  mở ephemeral, nên sau một apply trọn, user và entry cùng giá trị.
- Apply dừng giữa chừng (vd. ElastiCache từ chối một access string, sửa chuỗi rồi apply lại) làm lệch: user nhận giá trị của lần mở mới,
  entry giữ giá trị cũ vì version không đổi, và `plan` sau đó vẫn `No changes`; client bị từ chối. Gỡ: tăng `password_version` rồi apply.
- Đổi mật khẩu: tăng `password_version` rồi apply; mọi user đổi cùng lúc vì entry là một. Đổi access string hay mật khẩu sửa user tại chỗ
  (`access_string`, `passwords_wo_version` không buộc tạo lại), user group và replication group giữ nguyên; pod chưa đọc mật khẩu mới bị từ
  chối ở kết nối mới tới khi restart.
- `make eks-secrets` của repo code không ghi `valkey-users`: module này là nơi duy nhất ghi.

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
| allowed\_security\_groups | Security groups whose members may connect on 6379 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not. | `map(string)` | n/a | yes |
| engine\_version | Valkey version, <major>.<minor>, at least 9.1: the first version whose ACL limits a user to databases (db=). ElastiCache applies the patch releases itself. | `string` | `"9.1"` | no |
| name | ID of the replication group (svp-stg, svp-prd), also the name of its subnet group and user group, the prefix of its security group, parameter group and user IDs (<name>-gateway). It appears in the public Certificate Transparency logs through the TLS certificate of the nodes. | `string` | n/a | yes |
| node\_count | Nodes of the replication group, the primary included (1 to 6). With 2 or more the group runs Multi-AZ with automatic failover to a replica; 1 has no replica and no failover. | `number` | n/a | yes |
| node\_type | Node type of every node (cache.t4g.micro for a lab env, cache.m7g.large for production). | `string` | `"cache.t4g.micro"` | no |
| password\_version | Version of the Valkey passwords. Terraform writes new random passwords, to the ElastiCache users and to the External Secrets entry together, only when this number changes: raise it to rotate every password. | `number` | `1` | no |
| subnet\_ids | Database subnets of the cache subnet group (the tier of the VPC with no route to the internet), in at least two availability zones (a replica goes in another zone than the primary). | `list(string)` | n/a | yes |
| valkey\_users\_secret\_id | ID or ARN of the Secrets Manager entry svp/<env>/valkey-users (made by the external-secrets module), into which the module writes the password of each user under SVP\_VALKEY\_<USER>\_PASSWORD. | `string` | n/a | yes |
| vpc\_id | VPC of the nodes and of their security group. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| primary\_endpoint\_address | Host name of the primary node, without port (clients connect on 6379 over TLS): key valkeyHost of the cluster values. |
<!-- END_TF_DOCS -->
