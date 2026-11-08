# `aws/envs/stg`: cấu hình gốc của env stg

Tầng platform của stg trên AWS (ADR-0034 §2, ADR-0024 §6A, ADR-0048, ADR-0053): ghép các module `network`, `eks`, `rds`, `msk`,
`elasticache`, `media`, `external-secrets`, thêm role IAM và Pod Identity association cho `svp/video-service`, `svp/media-worker`, xuất output `cluster_values`
theo hợp đồng `cluster.*` và các output của cluster cho root bootstrap `aws/gitops/stg`. Ứng dụng trong cluster không ở đây: Argo CD
triển khai từ `svp-gitops`.

## Account, profile, state

| Mục | Giá trị |
| --- | --- |
| Account | `svp-stg`, account thành viên của org (OU `Workloads`), không phải management account |
| Profile SSO | `anhnv-stg` (permission set `SvpAdmin`), người học tự tạo bằng `aws configure sso` |
| Biến account | `SVP_AWS_STG_ACCOUNT_ID`, export trong terminal của buổi; mọi lệnh đặt `TF_VAR_account_id` từ nó (`allowed_account_ids`) |
| Backend | `../../backend-stg.hcl` (bucket `svp-tfstate-<account stg>-<region>`, KMS key `alias/svp-tfstate`, lock file S3), sinh từ output `backend_hcl` của `aws/accounts/stg`, dạng ở `backend.hcl.example` |
| Key của state | `aws/stg/terraform.tfstate`, truyền bằng `-backend-config` thứ hai lúc `init`; khối `backend "s3" {}` trong `versions.tf` trống |
| Zone | `stg.aws.<domain>` của account stg (output `zone_id` của `aws/accounts/stg`), uỷ quyền từ zone `aws.<domain>` của account prd (bản ghi `NS` do `aws/accounts/prd` tạo) |

Root chạy được khi baseline `aws/accounts/stg` đã apply và uỷ quyền DNS đã xong ([`aws/accounts/README.md`](../../accounts/README.md)).

## Cái gì khác giữa các env

Root prd chép thư mục này. Trong `*.tf` chỉ khác dòng `env = "<env>"` của `locals` (`main.tf`) và phần riêng của prd (bastion SSM,
`kubeconfig_command` của `outputs.tf`, `teardown.tfvars`); mọi lời gọi module chỉ tham chiếu biến hay output. Cả hai root có web ACL AWS
WAF trước CloudFront (`waf.tf`, module `waf` tên `svp-<env>-media`, provider alias `us_east_1` ở `providers.tf`: CloudFront chỉ nhận web
ACL ở `us-east-1`), vì gói CloudFront flat-rate Free của distribution media bắt buộc có web ACL
([ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md)). Mọi tên tài nguyên bắt đầu
bằng `svp-<env>` (cluster, role IAM, bucket, instance RDS, cluster MSK, replication group Valkey, entry Secrets Manager), trừ secret SCRAM
của MSK: `AmazonMSK_svp-<env>-<user>` (MSK chỉ đọc secret có tiền tố `AmazonMSK_`). Ngoại lệ trivy chỉ-stg nằm trên lời gọi module của root
này (mục "Ngoại lệ trivy").
Cỡ và mức bảo vệ nằm ở `<env>.tfvars`:

| Tệp | Commit | Nội dung |
| --- | --- | --- |
| `stg.tfvars` | có | cỡ và mức bảo vệ của stg (bảng dưới); không giá trị cá nhân nào |
| `stg.auto.tfvars` | **không** (git bỏ qua) | giá trị cá nhân, chép từ `example.auto.tfvars.example` |
| `../../backend-stg.hcl` | **không** | phần chung của backend trong account stg |
| `TF_VAR_account_id` | biến môi trường, đặt ngay trong lệnh | account được phép đổi (`allowed_account_ids`) |

**Vì sao `stg.tfvars` mà không `terraform.tfvars`:** repo bỏ qua mọi `terraform.tfvars` và `*.auto.tfvars` (hai tên Terraform tự nạp) vì
chúng là chỗ giá trị cá nhân hay nằm. Tệp cỡ của env cần commit nên mang tên khác và phải truyền bằng `-var-file=stg.tfvars` ở **mọi**
`plan`, `apply`, `destroy`. Quên thì Terraform dừng ngay ở "No value for required variable" (các biến cỡ có từ đầu không có mặc định),
không dựng gì sai.

| Biến | stg | prd (`prd.tfvars`) |
| --- | --- | --- |
| `az_count`, `single_nat_gateway`, `flow_log_enabled` | `2`, `true`, `false` | `3`, `false`, `true` |
| `kubernetes_version` | `1.36` | như stg |
| `eks_endpoint_public_access`, `control_plane_log_types` | `true`, `[]` | `false`, `["api", "audit", "authenticator"]` |
| `node_instance_types`, `node_capacity_type` | `m7g.large`, `m6g.large`, `t4g.large`; `SPOT` | Graviton cùng cỡ; `ON_DEMAND` |
| `node_min_size` / `desired` / `max` | `3` / `3` / `5` | `3` / `3` / `6` |
| `rds_instance_class`, `rds_multi_az` | `db.t4g.small`, `false` | `db.t4g.medium`, `true` |
| `rds_backup_retention_period`, `rds_delete_automated_backups` | `1`, `true` | `7`, `false` |
| `rds_deletion_protection`, `rds_skip_final_snapshot` | `false`, `true` | `true`, `false` |
| `msk_broker_instance_type` | `kafka.t3.small` | `kafka.m7g.large` |
| `msk_replication_factor`, `msk_min_insync_replicas` | `2`, `1` | `3`, `2` |
| `msk_broker_logs_enabled` | `false` | `true` |
| `valkey_node_type`, `valkey_node_count` | `cache.t4g.micro`, `1` | `cache.m7g.large`, `2` (Multi-AZ, failover tự động) |
| `media_force_destroy` | `true` | `false` |

Số broker MSK là `az_count` (một broker mỗi AZ); phiên bản Kafka (`4.1.x.kraft`), Valkey (`9.1`) và EBS 10 GiB mỗi broker lấy mặc định
của module, như ADR-0053 §2, §7.

Biến có mặc định (mặc định bằng mặc định của module, giữ hành vi của stg, nên `stg.tfvars` không đặt; prd đặt tường minh, trừ
`msk_password_version`, `valkey_password_version`: cả hai env chỉ đặt chúng qua `TF_VAR_*` hay `*.auto.tfvars` khi xoay mật khẩu):

| Biến | Module | Mặc định |
| --- | --- | --- |
| `flow_log_retention_days` | `network` | `1` |
| `s3_endpoint_restricted`, `s3_endpoint_extra_buckets` | `network` | `false`, `[]`; khi bật, endpoint S3 cho qua bucket `uploads`, `media` của env (root tự thêm), bucket layer ECR của region (module thêm) và các bucket của `s3_endpoint_extra_buckets` |
| `eks_secrets_kms_encryption`, `control_plane_log_retention_days` | `eks` | `false`, `1` |
| `rds_performance_insights_enabled`, `rds_performance_insights_retention_period` | `rds` | `false`, `7` |
| `rds_monitoring_interval`, `rds_cloudwatch_logs_exports`, `rds_cloudwatch_logs_retention_days` | `rds` | `0`, `[]`, `1` |
| `msk_broker_logs_retention_days` | `msk` | `1` |
| `msk_password_version`, `valkey_password_version` | `msk`, `elasticache` | `1`; tăng để đổi mật khẩu (mục "Secret Kafka và Valkey") |
| `media_versioning_enabled`, `media_access_logging_enabled` | `media` | `false`, `false` |

Giá trị cá nhân (`stg.auto.tfvars` hay `TF_VAR_*`):

| Biến | Lấy ở đâu |
| --- | --- |
| `hosted_zone_id` | output `zone_id` của `aws/accounts/stg`, dán tay (root này không đọc state của root khác) |
| `domain` | tên zone stg (`stg.aws.<domain>`, web ở apex) hay một tên trong zone đó; API là `api.<tên này>`; plan dừng ở precondition của `cluster_values` nếu tên khác |
| `acme_email` | email tài khoản Let's Encrypt của cert-manager (biến `sensitive`) |
| `eks_public_access_cidrs` | IP của máy chạy `kubectl`, dạng `/32` |

## Dùng root này

**Người học chạy mọi lệnh dưới đây** (AI chỉ chạy `make check`, `make lock`). Trình tự cả buổi (kiểm DNS, ghi secret, bootstrap Argo CD,
đo, dọn trước destroy, quét) ở runbook [`docs/runbooks/session-stg.md`](../../../docs/runbooks/session-stg.md) và script buổi của
`aws/scripts/`.

Kiểm account trước (cột `Account` phải bằng `$SVP_AWS_STG_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`; khác thì dừng):

```sh
cd infra/aws/envs/stg
AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_STG_ACCOUNT_ID"
```

Dựng:

```sh
cp example.auto.tfvars.example stg.auto.tfvars          # rồi sửa bốn giá trị
AWS_PROFILE=anhnv-stg terraform init -reconfigure -backend-config=../../backend-stg.hcl -backend-config=key=aws/stg/terraform.tfstate
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan -var-file=stg.tfvars -out=stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply stg.tfplan
```

`-reconfigure` bỏ cấu hình backend cũ trong `.terraform` (kể cả của bucket management trước đây) và không migrate state.

Sau `apply`:

```sh
AWS_PROFILE=anhnv-stg $(AWS_PROFILE=anhnv-stg terraform output -raw kubeconfig_command)   # context svp-stg, như CONTEXT=svp-stg của make eks-*
AWS_PROFILE=anhnv-stg terraform output -raw rds_master_user_secret_arn                      # script buổi đọc mật khẩu master từ đây
```

Tiếp theo: ghi giá trị secret (`AWS_PROFILE=anhnv-stg make eks-secrets CONTEXT=svp-stg` ở repo code), rồi apply root `aws/gitops/stg`.

Kết thúc buổi: destroy `aws/gitops/stg` trước, rồi
`AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform destroy -var-file=stg.tfvars` (sau bước dọn trong cluster của
script buổi), rồi lệnh quét tài nguyên sót.

## Output

| Output | Nội dung |
| --- | --- |
| `cluster_values` | map hợp đồng `cluster.*` (ADR-0034 §7), `sensitive` vì có `acmeEmail`: `terraform output` in `<sensitive>`, `terraform output -json cluster_values` in đủ |
| `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data` | tên cluster, URL API server, CA (base64 PEM) |
| `rds_master_user_secret_arn` | ARN secret Secrets Manager giữ mật khẩu master của RDS (ARN không phải bí mật) |
| `kubeconfig_command` | `aws eks update-kubeconfig --region … --name svp-stg --alias svp-stg` |

Root `aws/gitops/stg` đọc state của root này qua `terraform_remote_state` (bucket state của account stg, key `aws/stg/terraform.tfstate`):
`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data` cho provider `helm`, `kubernetes`, và `cluster_values` cho cluster
Secret của Argo CD.

Khoá của `cluster_values`:

| Khoá | Nguồn |
| --- | --- |
| `name` | `module.eks.cluster_name` (`svp-stg`) |
| `region` | `var.region` (`ap-southeast-1`) |
| `vpcId`, `vpcCidr` | `module.network` |
| `serviceCidr` | `module.eks.cluster_service_cidr` |
| `dbCidrs` | `module.network.database_subnet_cidrs` (subnet database của VPC: RDS, broker MSK, node ElastiCache) |
| `domain`, `hostedZoneId`, `acmeEmail` | biến cá nhân |
| `rdsAddress` | `module.rds.address` |
| `kafkaBrokers` | `module.msk.bootstrap_brokers`: một chuỗi `host:9096,host:9096` (SASL/SCRAM trên TLS), một mục mỗi broker |
| `valkeyHost` | `module.elasticache.primary_endpoint_address`: tên host của node primary, không cổng (client nối TLS cổng 6379) |
| `uploadsBucket`, `mediaBucket`, `mediaDomain` | `module.media` |
| `s3Cidrs` | `data "aws_ip_ranges"` dịch vụ `s3` của region, sắp xếp: NetworkPolicy của VPC CNI lọc theo địa chỉ, nên pod gọi S3 được mở đúng các dải này cổng 443. Danh sách đọc lại ở mỗi plan; dải AWS thêm giữa buổi chỉ tới được sau lần apply sau |
| `externalSecretsRoles` | output `roles` của `module.external_secrets`: namespace (`svp`, `svp-data`, `svp-obs`, `keda`, `argocd`) → ARN role IAM của SecretStore namespace đó |

Thêm khoá thì sửa cả bốn nơi của hợp đồng (output này, mẫu `platforms/eks/*.values.tpl` của `svp-gitops`, fixture
`deploy/ci/cluster-values.example.yaml` của repo code, bảng ở ADR-0034 §7).

## Quyền AWS trong cluster

| ServiceAccount (`svp`) | Role | Policy (inline `s3`) |
| --- | --- | --- |
| `video-service` | `svp-stg-video-service` | `video_service_policy_json` của module `media` |
| `media-worker` | `svp-stg-media-worker` | `media_worker_policy_json` của module `media` |

Trust policy như role của controller trong module `eks`: `pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`, condition trên
session tag `eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account` đúng cặp ở bảng. ServiceAccount của chart `svp-service`
mang tên release, nên tên release phải giữ `video-service`, `media-worker`. Chỉ hai service này gọi API AWS.

Secret của cluster: module `external-secrets` tạo vỏ entry `svp/stg/<entry>` (giá trị của `kafka-admin`, `kafka-users`, `valkey-users`
do module `msk`, `elasticache` ghi, mục dưới; entry khác người học ghi bằng `make eks-secrets`), role `svp-stg-external-secrets` của controller External Secrets (Pod Identity, ServiceAccount `external-secrets/external-secrets`) chỉ được
assume năm role `svp-stg-external-secrets-<namespace>`, mỗi role chỉ đọc entry mà namespace đó dùng (README của module).

RDS (5432), MSK (9096) và ElastiCache (6379), cả ba ở subnet database, chỉ nhận từ security group node (pod mang IP của ENI node với VPC
CNI) và security group cluster do EKS tạo. Security group cluster nằm trên ENI của control plane (EKS cũng gắn nó cho thứ chạy không có
security group riêng: pod Fargate, node của nhóm không có launch template); node của root này không mang nó vì launch template của module
`eks` ghi security group node.

### Secret Kafka và Valkey

Module `msk` và `elasticache` sinh mật khẩu của từng user (ephemeral `random_password`, 32 chữ và số) và ghi chúng trong cùng `apply`
bằng đối số write-only, không vào plan hay state: vào secret `AmazonMSK_svp-stg-<user>` (gắn với cluster MSK) và entry `kafka-admin`,
`kafka-users`; vào user ElastiCache và entry `valkey-users`. Root truyền ARN ba entry từ output `secret_arns` của module
`external-secrets`. Mật khẩu Kafka, Valkey trong `.env` của repo code chỉ dùng cho compose và k3d. Đổi mật khẩu giữa buổi: đặt
`TF_VAR_msk_password_version` (hay `TF_VAR_valkey_password_version`) lớn hơn giá trị đang dùng, giữ nó cho tới hết buổi, `plan`, `apply`,
rồi `aws/scripts/bootstrap.sh stg secrets`: ExternalSecret trên cluster chỉ đọc lại entry khi bị dựng lại (`refreshPolicy: OnChange`), nên
`apply` một mình để mật khẩu cũ trong cluster. Mỗi `apply` ở giá trị khác lại ghi mật khẩu mới. Thứ tự và thời gian chờ ở
[mục "Đổi một secret của env đang chạy"](../../../docs/runbooks/session-stg.md#đổi-một-secret-của-env-đang-chạy) của runbook.

## Ngoại lệ trivy

`make trivy DIRS=aws/envs/stg` quét root với `stg.tfvars` (`--tf-vars`). Ba ngoại lệ chỉ-stg nằm ngay trên `module "eks"` ở `main.tf`, lý
do trong comment, không cái nào có ở root prd:

- `AWS-0040` (endpoint public của API bật), `AWS-0041` (endpoint public nhận một dải công khai): endpoint chỉ trả lời dải của
  `eks_public_access_cidrs` (module từ chối dải ngắn hơn `/8`), endpoint private luôn bật; prd tắt endpoint public.
- `AWS-0039` (Secrets không mã hoá bằng KMS key riêng): stg giữ key AWS sở hữu; prd bật `eks_secrets_kms_encryption`. Module `eks` có cùng
  ngoại lệ với điều kiện `create_kms_key=false`, nhưng trivy chỉ khớp điều kiện trên thuộc tính bool khi quét chính module, nên root lặp lại
  ngoại lệ trên lời gọi module.

## Chi phí

Theo bảng ADR-0034 §12 (Singapore): ~$0,40/giờ với node Spot, cộng ~$0,14/giờ của hai broker MSK và node Valkey (ADR-0053 §16): buổi
4 giờ khoảng $3; chi tiết từng module ở README của module.
CloudFront của media và web ACL WAF nằm trong gói flat-rate Free: $0 ([ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md)).
