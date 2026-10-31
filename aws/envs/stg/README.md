# `aws/envs/stg`: cấu hình gốc của env stg

Tầng platform của stg trên AWS (ADR-0034 §2, ADR-0024 §6A): ghép bốn module `network`, `eks`, `rds`, `media`, thêm role IAM và Pod
Identity association cho `svp/video-service`, `svp/media-worker`, xuất output `cluster_values` theo hợp đồng `cluster.*`. Ứng dụng trong
cluster không ở đây: Argo CD triển khai từ `svp-gitops`.

## Cái gì khác giữa các env

Root prd (7b) là bản sao của thư mục này. Trong code chỉ khác **hai dòng**: `key` của backend (`versions.tf`) và `local.env` (`main.tf`);
mọi tên tài nguyên bắt đầu bằng `svp-<env>` (cluster, role IAM, bucket, instance RDS), nên hai root trong một account không đụng tên
nhau. Cỡ và mức bảo vệ nằm ở `<env>.tfvars`:

| Tệp | Commit | Nội dung |
| --- | --- | --- |
| `stg.tfvars` | có | cỡ và mức bảo vệ của stg (bảng dưới); không giá trị cá nhân nào |
| `stg.auto.tfvars` | **không** (git bỏ qua) | giá trị cá nhân, chép từ `example.auto.tfvars.example` |
| `../../backend.hcl` | **không** | bucket và region của state, sinh từ output `backend_hcl` của `aws/bootstrap` (dạng ở `backend.hcl.example`) |
| `TF_VAR_account_id` | biến môi trường | account được phép đổi (`allowed_account_ids`) |

**Vì sao `stg.tfvars` mà không `terraform.tfvars`:** repo bỏ qua mọi `terraform.tfvars` và `*.auto.tfvars` (hai tên Terraform tự nạp) vì
chúng là chỗ giá trị cá nhân hay nằm. Tệp cỡ của env cần commit nên mang tên khác và phải truyền bằng `-var-file=stg.tfvars` ở **mọi**
`plan`, `apply`, `destroy`. Quên thì Terraform dừng ngay ở "No value for required variable" (biến cỡ không có mặc định), không dựng gì sai.

| Biến | stg | prd (7b, hướng) |
| --- | --- | --- |
| `az_count`, `single_nat_gateway`, `flow_log_enabled` | `2`, `true`, `false` | `3`, `false`, `true` |
| `kubernetes_version` | `1.36` | như stg lúc dựng |
| `eks_endpoint_public_access`, `control_plane_log_types` | `true`, `[]` | chốt ở 7b, `["api", "audit"]` |
| `node_instance_types`, `node_capacity_type` | `m7g.large`, `m6g.large`, `t4g.large`; `SPOT` | đo ở 7b; `ON_DEMAND` |
| `node_min_size` / `desired` / `max` | `3` / `3` / `5` | đo ở 7b |
| `rds_instance_class`, `rds_multi_az` | `db.t4g.small`, `false` | đo ở 7b, `true` |
| `rds_backup_retention_period`, `rds_delete_automated_backups` | `1`, `true` | ≥ 7, `false` |
| `rds_deletion_protection`, `rds_skip_final_snapshot` | `false`, `true` | `true`, `false` |
| `media_force_destroy`, `media_price_class` | `true`, `PriceClass_200` | `false`, `PriceClass_200` |

Giá trị cá nhân (`stg.auto.tfvars` hay `TF_VAR_*`):

| Biến | Lấy ở đâu |
| --- | --- |
| `hosted_zone_id` | output `zone_id` của `aws/bootstrap`, dán tay (root này không đọc state của root khác: không `terraform_remote_state`) |
| `domain` | tên web của stg **trong** zone lab, ví dụ `stg.aws.<domain>`; API là `api.<tên này>`; plan dừng ở precondition của `cluster_values` nếu tên nằm ngoài zone |
| `acme_email` | email tài khoản Let's Encrypt của cert-manager (biến `sensitive`) |
| `eks_public_access_cidrs` | IP của máy chạy `kubectl`, dạng `/32` |

## Dùng root này

**Người học chạy mọi lệnh dưới đây** (AI chỉ chạy `make check`, `make lock`). Cần `aws/bootstrap` đã apply và `aws/backend.hcl` đã có.
Trình tự cả buổi (kiểm DNS, bootstrap Argo CD, đo, dọn trước destroy, quét) ở script buổi và runbook của `aws/scripts/`.

```sh
cd infra/aws/envs/stg
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
export TF_VAR_account_id=<12 số của Account vừa đọc>
cp example.auto.tfvars.example stg.auto.tfvars          # rồi sửa bốn giá trị
AWS_PROFILE=anhnv-sso terraform init -backend-config=../../backend.hcl
AWS_PROFILE=anhnv-sso terraform plan -var-file=stg.tfvars -out=stg.tfplan
AWS_PROFILE=anhnv-sso terraform apply stg.tfplan
```

Sau `apply`:

```sh
AWS_PROFILE=anhnv-sso $(AWS_PROFILE=anhnv-sso terraform output -raw kubeconfig_command)   # context svp-stg, như CONTEXT=svp-stg của make eks-*
AWS_PROFILE=anhnv-sso terraform output -json cluster_values > <tệp ngoài git>               # giá trị cluster của root svp-root
AWS_PROFILE=anhnv-sso terraform output -raw rds_master_user_secret_arn                      # script buổi đọc mật khẩu master từ đây
```

Kết thúc buổi: `AWS_PROFILE=anhnv-sso terraform destroy -var-file=stg.tfvars` (sau bước dọn trong cluster của script buổi), rồi lệnh quét
tài nguyên sót.

## Output

| Output | Nội dung |
| --- | --- |
| `cluster_values` | map hợp đồng `cluster.*` (ADR-0034 §7), `sensitive` vì có `acmeEmail`: `terraform output` in `<sensitive>`, `terraform output -json cluster_values` in đủ |
| `rds_master_user_secret_arn` | ARN secret Secrets Manager giữ mật khẩu master của RDS (ARN không phải bí mật) |
| `kubeconfig_command` | `aws eks update-kubeconfig --region … --name svp-stg --alias svp-stg` |

Khoá của `cluster_values`:

| Khoá | Nguồn |
| --- | --- |
| `name` | `module.eks.cluster_name` (`svp-stg`) |
| `region` | `var.region` (`ap-southeast-1`) |
| `vpcId`, `vpcCidr` | `module.network` |
| `serviceCidr` | `module.eks.cluster_service_cidr` |
| `dbCidrs` | `module.network.private_subnet_cidrs` (subnet group của RDS là các subnet private) |
| `domain`, `hostedZoneId`, `acmeEmail` | biến cá nhân |
| `rdsAddress` | `module.rds.address` |
| `uploadsBucket`, `mediaBucket`, `mediaDomain` | `module.media` |
| `s3Cidrs` | `data "aws_ip_ranges"` dịch vụ `s3` của region, sắp xếp: NetworkPolicy của VPC CNI lọc theo địa chỉ, nên pod gọi S3 được mở đúng các dải này cổng 443. Danh sách đọc lại ở mỗi plan; dải AWS thêm giữa buổi chỉ tới được sau lần apply sau |

Thêm khoá thì sửa cả bốn nơi của hợp đồng (output này, mẫu `platforms/eks/*.values.tpl` của `svp-gitops`, fixture
`deploy/ci/cluster-values.example.yaml` của repo code, bảng ở ADR-0034 §7).

## Quyền AWS của hai service

| ServiceAccount (`svp`) | Role | Policy (inline `s3`) |
| --- | --- | --- |
| `video-service` | `svp-stg-video-service` | `video_service_policy_json` của module `media` |
| `media-worker` | `svp-stg-media-worker` | `media_worker_policy_json` của module `media` |

Trust policy như role của controller trong module `eks`: `pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`, condition trên
session tag `eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account` đúng cặp ở bảng. ServiceAccount của chart `svp-service`
mang tên release, nên tên release phải giữ `video-service`, `media-worker`. Chỉ hai role này: service khác không gọi API AWS nào.

RDS nhận 5432 từ security group node (pod mang IP của ENI node với VPC CNI) và security group cluster do EKS tạo. Security group
cluster nằm trên ENI của control plane (EKS cũng gắn nó cho thứ chạy không có security group riêng: pod Fargate, node của nhóm không có
launch template); node của root này không mang nó vì launch template của module `eks` ghi security group node.

## Ngoại lệ trivy

`AWS-0040` (endpoint public của API bật) và `AWS-0041` (endpoint public nhận một dải công khai) bỏ qua ngay trên `module "eks"` ở
`main.tf`, lý do trong comment: endpoint chỉ trả lời dải của `eks_public_access_cidrs` (module từ chối dải ngắn hơn `/8`), endpoint
private luôn bật. `make check` không nạp `stg.tfvars` nên không thấy hai finding này; chạy trivy với `--tf-vars stg.tfvars` thì thấy và
hai dòng bỏ qua có hiệu lực.

## Chi phí

Theo bảng ADR-0034 §12 (Singapore): ~$0,40/giờ với node Spot, buổi 4 giờ khoảng $2–3; chi tiết từng module ở README của module.
