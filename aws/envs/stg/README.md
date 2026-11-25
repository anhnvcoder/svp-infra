# `aws/envs/stg`: env stg của một buổi: mạng, cluster EKS, dữ liệu, đường vào và transcode

**Account** `svp-stg` · **region** `ap-southeast-1` (web ACL, cert, log CloudFront ở `us-east-1`) · **profile** `anhnv-stg` · **state**
bucket của `aws/accounts/stg` (`../../backend-stg.hcl`), key `aws/stg/terraform.tfstate`

Giải thích: [09. Env và mạng](../../../docs/handbook/09-envs-network.md), [10. EKS](../../../docs/handbook/10-eks.md); dữ liệu ở
[11. Dữ liệu](../../../docs/handbook/11-data.md), đường vào, media, transcode ở chương [12. Media và
edge](../../../docs/handbook/12-media-edge.md), backup của env ở chương [07. Backup](../../../docs/handbook/07-backup.md).

Chạy root này tạo gì: mục [`aws/envs/stg`](../../../docs/reference/inventory.md#awsenvsstg) của
[inventory](../../../docs/reference/inventory.md) (số tài nguyên theo phần, theo loại, kèm sơ đồ).

## Dựng gì

Root dựng đầu buổi và gỡ cuối buổi. Ứng dụng trong cluster không ở đây: Argo CD triển khai từ `svp-gitops`, qua root `aws/gitops/stg`.
Root prd chép thư mục này: mọi `*.tf` giống hệt trừ dòng `env` của `locals` (`main.tf`).

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `module.network` | `svp-stg`, `ap-southeast-1` | VPC `svp-stg` bốn tầng, NAT, S3 gateway endpoint, interface endpoint, flow log về Log Archive |
| `module.ssm_bastion` (`ssm-bastion.tf`) | `svp-stg`, `ap-southeast-1` | Bastion `svp-stg-ssm-bastion`, đầu xa của tunnel tới endpoint private của API |
| `module.eks` | `svp-stg`, `ap-southeast-1` | Cluster `svp-stg`, nhóm node `system`, IAM và hàng đợi Karpenter, add-on, role Pod Identity của controller |
| `module.external_secrets` | `svp-stg`, `ap-southeast-1` | Vỏ entry `svp/stg/<entry>`, role `svp-stg-external-secrets` và role mỗi namespace |
| `aws_iam_role.service`, `aws_eks_pod_identity_association.service` (`pod-identity.tf`) | `svp-stg`, `ap-southeast-1` | Role `svp-stg-video-service`, `svp-stg-media-worker` cho ServiceAccount cùng tên ở namespace `svp` |
| `module.rds`, `module.msk`, `module.elasticache`, `module.alarms` | `svp-stg`, `ap-southeast-1` | PostgreSQL, Kafka, Valkey ở subnet database; topic `svp-stg-alarms` |
| `module.media`, `module.edge`, `module.transcode` | `svp-stg`, `ap-southeast-1` và `us-east-1` | Bucket, ba distribution CloudFront, ALB internal, MediaConvert |
| `module.waf` ×3 (`waf.tf`) | `svp-stg`, `us-east-1` | Web ACL `svp-stg-web`, `-api`, `-media` |
| `module.backup_alarms` (`backup.tf`) | `svp-stg`, `ap-southeast-1` | Alarm job backup và copy hỏng |
| Data source của `baseline.tf` | `svp-stg`, `ap-southeast-1` | Đọc tài nguyên sống lâu của account (mục dưới) |

Mọi tên bắt đầu bằng `svp-stg`, trừ secret SCRAM của MSK (`AmazonMSK_svp-stg-<user>`: MSK chỉ đọc secret có tiền tố `AmazonMSK_`).
Khác biệt với prd chỉ là dữ liệu của `stg.tfvars`: [09. Env và mạng, mục Hai env, một bộ
code](../../../docs/handbook/09-envs-network.md#hai-env-một-bộ-code).

## Chạy

Người học chạy mọi lệnh; AI chỉ chạy `make check`, `make lock`.

- Điều kiện: `aws/accounts/stg` đã apply và uỷ quyền DNS đã xong (chương [08. Account env](../../../docs/handbook/08-accounts.md)),
  `aws/log-archive` đã có bucket và delivery destination `svp-cloudfront-stg`.
- Mỗi buổi, dựng và gỡ root (`init`, `plan`, `apply`, `destroy` với `-var-file=stg.tfvars` và ba biến `TF_VAR_*` dưới): [trang dựng của
  buổi stg](../../../docs/runbooks/session-stg-deploy.md), [trang gỡ](../../../docs/runbooks/session-stg-teardown.md).
- Mở tunnel tới API và kubeconfig: [09. Env và mạng, Kịch bản thực tế](../../../docs/handbook/09-envs-network.md#kịch-bản-thực-tế).
- Đổi mật khẩu Kafka hay Valkey giữa buổi: `TF_VAR_msk_password_version` (hay `TF_VAR_valkey_password_version`) lớn hơn giá trị đang
  dùng, `plan`, `apply`, rồi `bootstrap.sh stg secrets`; thứ tự ở [mục đổi secret của runbook
  buổi](../../../docs/runbooks/session-stg.md#đổi-một-secret-của-env-đang-chạy).
- Nâng minor EKS: [`eks-upgrade.md`](../../../docs/runbooks/eks-upgrade.md).

## Biến và tệp

| Tệp, biến | Commit | Nội dung |
| --- | --- | --- |
| `stg.tfvars` | có | Cỡ, dự phòng, retention, log, mã hoá, bảo vệ của stg; mỗi nhóm biến một comment nói vì sao |
| `stg.auto.tfvars` | **không** | Giá trị cá nhân, chép từ `example.auto.tfvars.example` |
| `media-signing.auto.tfvars.json` | **không** | Khoá công khai của key group media, do `aws/scripts/media-signing-key.sh stg new <ô>` ghi |
| `../../backend-stg.hcl` | **không** | Phần chung của backend trong account stg, từ output `backend_hcl` của `aws/accounts/stg` |
| `TF_VAR_account_id` | biến trong lệnh, từ `SVP_AWS_STG_ACCOUNT_ID` | Account được phép đổi (`allowed_account_ids`) |
| `TF_VAR_log_archive_account_id` | biến trong lệnh, từ `SVP_AWS_LOG_ACCOUNT_ID` | Chủ bucket flow log, log WAF, delivery destination của log CloudFront |
| `TF_VAR_backup_account_id` | biến trong lệnh, từ `SVP_AWS_BACKUP_ACCOUNT_ID` | Account được dùng key RDS khi copy backup |

**Vì sao `stg.tfvars` mà không `terraform.tfvars`:** repo bỏ qua mọi `terraform.tfvars` và `*.auto.tfvars` (hai tên Terraform tự nạp)
vì chúng là chỗ giá trị cá nhân hay nằm. Tệp cỡ của env cần commit nên mang tên khác và phải truyền bằng `-var-file=stg.tfvars` ở
**mọi** `plan`, `apply`, `destroy`. Quên thì Terraform dừng ở "No value for required variable", không dựng gì sai.

Giá trị cá nhân (`stg.auto.tfvars` hay `TF_VAR_*`): `hosted_zone_id` (output `zone_id` của `aws/accounts/stg`, dán tay), `domain` (tên
zone `stg.aws.<domain>` hay một tên trong zone; plan dừng ở precondition của `cluster_values` nếu khác), `alarm_email` (hộp thư của
topic `svp-stg-alarms`, xác nhận link SNS sau apply). Không có IP của máy người học: endpoint công khai của API tắt. Biến có mặc định mà
`stg.tfvars` không đặt: `region`, `msk_password_version`, `valkey_password_version`.

## Tài nguyên sống lâu của account

Registry, telemetry và Grafana sống qua `destroy` của buổi ở `aws/accounts/stg`. Root này không đọc state của root đó: `baseline.tf`
tìm từng tài nguyên bằng data source theo tên suy từ `svp-stg`; thiếu một cái thì `plan` dừng ở đúng data source đó, nêu tên.

| Tài nguyên | Tìm bằng | Dùng ở |
| --- | --- | --- |
| Workspace AMP `svp-stg` | alias đúng `svp-stg` trong `aws_prometheus_workspaces`; không có thì precondition dừng | `module.eks`, `module.alarms` (publisher `aps`), `ampWorkspaceId`, `ampEndpoint` |
| Log group `/svp/stg/otel` | tên | `module.eks` (role Collector), `logGroup` |
| Repo phát hành `svp-backend/*`, `svp-frontend/*` | tiền tố tên repo | `module.eks` (role Kyverno) |
| Rule pull-through cache `ghcr`, `docker-hub`, `quay`, `k8s`, `ecr-public` | tiền tố, một data source mỗi rule | `module.eks` (quyền cache của role node) |
| Workspace AMG `svp-stg` (cờ `managed_grafana` khác `off`) | id từ tham số SSM `/svp/stg/grafana-workspace-id`; postcondition kiểm tên | `grafanaUrl` |

Với cờ `managed_grafana` `session`, workspace và tham số chỉ có sau bước mở của `aws/scripts/tf.sh stg account plan --open`; thiếu thì
`plan` dừng ở `data.aws_ssm_parameter.grafana_workspace` (`ParameterNotFound`). Với `off`, root không đọc gì, `grafanaUrl` là `""` và
module `external-secrets` không tạo entry `grafana-operator`. Cờ: module [`paid-features`](../../modules/paid-features/README.md).

## Output

| Output | Nội dung |
| --- | --- |
| `cluster_values` | map hợp đồng `cluster.*` (ADR-0034 §7), đọc bằng `terraform output -json cluster_values` |
| `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data` | tên cluster, URL API server, CA (base64 PEM) |
| `rds_master_user_secret_arn` | ARN secret Secrets Manager giữ mật khẩu master của RDS (ARN không phải bí mật) |
| `media_signing_key_ids` | ô → ID CloudFront public key của key group media |
| `api_tunnel_command` | `AWS_PROFILE=anhnv-stg aws ssm start-session --region ap-southeast-1 --target <bastion> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '…'` |
| `kubeconfig_command` | `aws eks update-kubeconfig … --alias svp-stg && kubectl config set-cluster <ARN cluster> --server=https://127.0.0.1:<api_tunnel_port> --tls-server-name=<host endpoint>` |

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
| `edgeCidrs` | `module.network.edge_subnet_cidrs` (subnet edge: chỉ ALB của đường vào có địa chỉ ở đó, nên NetworkPolicy của Envoy nhận đúng các dải này) |
| `edgeTargetGroupArn` | `module.edge.target_group_arn` (target group `svp-stg-envoy`) |
| `domain` | biến cá nhân |
| `rdsAddress` | `module.rds.address` |
| `kafkaBrokers` | `module.msk.bootstrap_brokers`: một chuỗi `host:9096,host:9096` (SASL/SCRAM trên TLS), một mục mỗi broker |
| `valkeyHost` | `module.elasticache.primary_endpoint_address`: tên host của node primary, không cổng (client nối TLS cổng 6379) |
| `uploadsBucket`, `mediaBucket`, `mediaDomain` | `module.media` |
| `s3Cidrs` | `data "aws_ip_ranges"` dịch vụ `s3` của region, sắp xếp: NetworkPolicy của VPC CNI lọc theo địa chỉ, nên pod gọi S3 được mở đúng các dải này cổng 443. Danh sách đọc lại ở mỗi plan; dải AWS thêm giữa buổi chỉ tới được sau lần apply sau |
| `externalSecretsRoles` | output `roles` của `module.external_secrets`: namespace (`svp`, `svp-data`, `svp-obs`, `keda`, `argocd`) → ARN role IAM của SecretStore namespace đó |
| `ecrRegistry` | `<account_id>.dkr.ecr.<region>.amazonaws.com`: registry private của account, nơi cluster kéo image phát hành và image bên thứ ba qua pull-through cache |
| `ampWorkspaceId` | id `ws-<uuid>` của workspace AMP `svp-stg` (`baseline.tf`): luật và Alertmanager của ACK đặt trên workspace này |
| `ampEndpoint` | `prometheus_endpoint` của workspace, kết thúc bằng `/`: `api/v1/remote_write`, `api/v1/query` nối sau |
| `logGroup` | `/svp/stg/otel`: Collector ghi log OTLP của service và web vào đây |
| `grafanaUrl` | `https://` + endpoint của workspace AMG, không `/` cuối: Grafana Operator đẩy dashboard và data source tới đây; chuỗi rỗng `""` khi cờ `managed_grafana` là `off` (chart không dựng phần Grafana nào) |
| `alarmTopicArn` | `module.alarms.topic_arn` (topic `svp-stg-alarms`): Alertmanager của AMP gửi cảnh báo tới đây |
| `mediaconvertQueueArn` | `module.transcode.queue_arn` (queue MediaConvert `svp-stg`): bridge tạo job trên queue này |
| `mediaconvertRoleArn` | `module.transcode.role_arn` (role `svp-stg-mediaconvert`): role mà job chạy với, bridge truyền nó bằng `iam:PassRole` |
| `transcodeEventsQueueUrl` | `module.transcode.events_queue_url` (SQS `svp-stg-transcode-events`): bridge đọc trạng thái cuối của job ở đây |

Dạng từng khoá (regex) là validation của module [`gitops-bridge`](../../modules/gitops-bridge/README.md)
(`variables.tf`); dạng các khoá của AMP, AMG, SNS đối chiếu với tài liệu AWS ở [phụ lục
ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0063-managed-observability.md). Thêm hay
đổi khoá thì sửa mọi nơi giữ hợp đồng: output này ở hai root env, bảng này, `variables.tf` (danh sách khoá, validation
dạng) và test của module `gitops-bridge`, `$shapes` của `argocd/apps/templates/applications.yaml`, mẫu
`platforms/eks/*.values.tpl` và bảng ở `README.md` của `svp-gitops`, fixture `deploy/ci/cluster-values.example.yaml` của
repo code.

## Ngoại lệ trivy

`make trivy DIRS=aws/envs/stg` quét root với `stg.tfvars` (`--tf-vars`). Root không có `#trivy:ignore` nào: endpoint công khai của API tắt
và Secret của EKS mã hoá bằng KMS key riêng như prd. Ngoại lệ chỉ-stg chỉ được cho thành phần thuộc nhóm "được giảm" hay "giảm có điều kiện"
của ADR-0055; luật ghi ngoại lệ ở mục "Ngoại lệ trivy" của [`AGENTS.md`](../../../AGENTS.md).

## Tham chiếu

- [09. Env và mạng](../../../docs/handbook/09-envs-network.md), [10. EKS](../../../docs/handbook/10-eks.md): ghi chú thiết kế của root
  (`baseline.tf`, `outputs.tf` trỏ tới README này).
- [ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §2, §7: tầng platform, hợp đồng `cluster.*`.
- [`docs/reference/operations.md`](../../../docs/reference/operations.md): profile, biến account, `tf.sh`, đọc plan an toàn.
