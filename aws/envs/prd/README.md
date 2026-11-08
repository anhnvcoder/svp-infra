# `aws/envs/prd`: cấu hình gốc của env prd

Tầng platform của prd trên AWS (ADR-0034 §2, ADR-0048): cùng module, cùng đối số với root stg
([`aws/envs/stg`](../stg/README.md)), cỡ và mức bảo vệ production ở `prd.tfvars`; web ACL AWS WAF trước CloudFront (`waf.tf`, provider
alias `us_east_1` ở `providers.tf`) có ở cả hai root. Ngoài phần chung đó, root này thêm đúng hai thứ: bastion SSM tới endpoint private của
API (`ssm-bastion.tf`, output `api_tunnel_command`, `kubeconfig_command` qua tunnel) và `teardown.tfvars` để gỡ cuối buổi. Ứng dụng trong cluster không ở đây:
Argo CD triển khai từ `svp-gitops`, bootstrap bằng root `aws/gitops/prd`.

## Account, profile, state

| Mục | Giá trị |
| --- | --- |
| Account | `svp-prd`, account thành viên của org (OU `Workloads`), không phải management account |
| Profile SSO | `anhnv-prd` (permission set `SvpAdmin`), người học tự tạo bằng `aws configure sso` |
| Biến account | `SVP_AWS_PRD_ACCOUNT_ID`, export trong terminal của buổi; mọi lệnh đặt `TF_VAR_account_id` từ nó (`allowed_account_ids` của cả hai provider) |
| Backend | `../../backend-prd.hcl` (bucket `svp-tfstate-<account prd>-<region>`, KMS key `alias/svp-tfstate`, lock file S3), sinh từ output `backend_hcl` của `aws/accounts/prd`, dạng ở `backend.hcl.example` |
| Key của state | `aws/prd/terraform.tfstate`, truyền bằng `-backend-config` thứ hai lúc `init`; khối `backend "s3" {}` trong `versions.tf` trống |
| Zone | `aws.<domain>` của account prd (output `zone_id` của `aws/accounts/prd`), uỷ quyền từ DNS cha của `<domain>` (bốn bản ghi `NS` `aws`, ngoài Terraform) |

Root chạy được khi baseline `aws/accounts/prd` đã apply và uỷ quyền DNS đã xong ([`aws/accounts/README.md`](../../accounts/README.md)).

## Cái gì khác với stg

Các file `*.tf` chép từ root stg. Khác biệt được phép, ngoài các file đó là lỗi:

| Chỗ | Khác gì |
| --- | --- |
| `main.tf` | `env = "prd"` của `locals`; không ngoại lệ trivy nào trên `module "eks"` (ba ngoại lệ của stg đều chỉ-stg) |
| `ssm-bastion.tf` | chỉ prd: module `ssm-bastion`, output `api_tunnel_command` |
| `outputs.tf` | `kubeconfig_command` lấy từ module `ssm-bastion` (server `https://127.0.0.1:6443`, `tls-server-name` là host của endpoint) |
| `prd.tfvars`, `teardown.tfvars` | cỡ và bảo vệ của prd; bảo vệ nhấc khi gỡ |

| Tệp | Commit | Nội dung |
| --- | --- | --- |
| `prd.tfvars` | có | cỡ và mức bảo vệ của prd (bảng ở README của stg, cột prd); không giá trị cá nhân nào |
| `teardown.tfvars` | có | chỉ hai bảo vệ cần nhấc để xoá (mục "Gỡ") |
| `prd.auto.tfvars` | **không** (git bỏ qua) | giá trị cá nhân, chép từ `example.auto.tfvars.example` |
| `../../backend-prd.hcl` | **không** | phần chung của backend trong account prd |
| `TF_VAR_account_id` | biến môi trường, đặt ngay trong lệnh | account được phép đổi (`allowed_account_ids`) |

Giá trị của `prd.tfvars` ngoài bảng của stg:

| Biến | prd | Vì sao |
| --- | --- | --- |
| `flow_log_retention_days`, `control_plane_log_retention_days`, `rds_cloudwatch_logs_retention_days` | `30` | log của env production đọc lại được sau sự cố |
| `s3_endpoint_restricted`, `s3_endpoint_extra_buckets` | `true`, `["prod-registry-k8s-io-ap-southeast-1"]` | endpoint S3 chỉ cho qua bucket `uploads`, `media` của env, bucket layer ECR của region (module thêm) và bucket mà `registry.k8s.io` chuyển hướng client trong AWS tới; thiếu bucket đó thì image của registry này (ExternalDNS…) không kéo được từ subnet private |
| `eks_public_access_cidrs` | `[]` | endpoint công khai tắt |
| `eks_secrets_kms_encryption` | `true` | Secret của Kubernetes mã hoá bằng KMS key riêng |
| `node_instance_types` | `m7g.large`, `m6g.large` | Graviton cùng cỡ, on-demand |
| `rds_performance_insights_enabled`, `_retention_period` | `true`, `7` | Database Insights Standard, mức miễn phí |
| `rds_monitoring_interval`, `rds_cloudwatch_logs_exports` | `60`, `["postgresql", "upgrade"]` | enhanced monitoring, log PostgreSQL vào CloudWatch |
| `media_versioning_enabled`, `media_access_logging_enabled` | `true`, `true` | bản cũ giữ 30 ngày, access log S3 vào bucket log của env |

Root không có `validation` ép giá trị prd: test của từng module có một `run` với giá trị prd, `make trivy DIRS=aws/envs/prd` quét với
`prd.tfvars`.

Giá trị cá nhân (`prd.auto.tfvars` hay `TF_VAR_*`): `hosted_zone_id` (output `zone_id` của `aws/accounts/prd`), `domain` (tên zone prd `aws.<domain>`, web ở
apex, API ở `api.<tên này>`; plan dừng ở precondition của `cluster_values` nếu tên khác), `acme_email`. Không có IP của máy người học.

## Tới API: tunnel SSM

Endpoint công khai của API tắt. Máy người học tới endpoint private qua phiên port forwarding của Session Manager tới instance `t4g.nano`
không inbound, không khoá SSH trong subnet private (module [`ssm-bastion`](../../modules/ssm-bastion/README.md)); security group của API nhận
443 từ security group của bastion. Cần AWS CLI và Session Manager plugin.

```sh
# terminal 1: tunnel 127.0.0.1:6443 → endpoint private:443, chạy tới khi Ctrl-C
eval "$(AWS_PROFILE=anhnv-prd terraform output -raw api_tunnel_command)"
# terminal 2: context svp-prd, server https://127.0.0.1:6443, tls-server-name là host của endpoint
eval "$(AWS_PROFILE=anhnv-prd terraform output -raw kubeconfig_command)"
kubectl --context svp-prd get nodes
```

Root `aws/gitops/prd` tới API qua cùng tunnel (host `https://127.0.0.1:6443`, TLS server name tính từ `cluster_endpoint` của state root này).

## Dùng root này

**Người học chạy mọi lệnh dưới đây** (AI chỉ chạy `make check`, `make lock`). Trình tự cả buổi ở runbook buổi prd
(`docs/runbooks/session-prd.md`) và script buổi của `aws/scripts/`.

Kiểm account trước (cột `Account` phải bằng `$SVP_AWS_PRD_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`; khác thì dừng):

```sh
cd infra/aws/envs/prd
AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_PRD_ACCOUNT_ID"
```

Dựng:

```sh
cp example.auto.tfvars.example prd.auto.tfvars          # rồi sửa ba giá trị
AWS_PROFILE=anhnv-prd terraform init -reconfigure -backend-config=../../backend-prd.hcl -backend-config=key=aws/prd/terraform.tfstate
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -var-file=prd.tfvars -out=prd.tfplan
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply prd.tfplan
```

Sau `apply`: mở tunnel và kubeconfig (mục trên); `AWS_PROFILE=anhnv-prd terraform output -raw rds_master_user_secret_arn` cho script buổi.
Tiếp theo: ghi giá trị secret (`AWS_PROFILE=anhnv-prd make eks-secrets CONTEXT=svp-prd` ở repo code), rồi apply root `aws/gitops/prd` khi
tunnel đang mở.

## Gỡ

Destroy `aws/gitops/prd` trước (qua tunnel), rồi root này với `teardown.tfvars`: `apply` nhấc bảo vệ, rồi `destroy`, cùng hai file:

```sh
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply -var-file=prd.tfvars -var-file=teardown.tfvars
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform destroy -var-file=prd.tfvars -var-file=teardown.tfvars
```

`teardown.tfvars` chỉ đặt `rds_deletion_protection = false` (RDS từ chối xoá instance còn bảo vệ) và `media_force_destroy = true` (bucket có
versioning không bao giờ rỗng); không đổi cỡ, log hay mã hoá. `rds_skip_final_snapshot` vẫn `false`, backup tự động vẫn giữ: destroy vẫn tạo
final snapshot. Sau đó runbook đọc final snapshot và backup tự động được giữ, xoá chúng, rồi chạy lệnh quét tài nguyên sót.

## Output

Như root stg (`cluster_values`, `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`, `rds_master_user_secret_arn`), khác ở:

| Output | Nội dung |
| --- | --- |
| `api_tunnel_command` | `AWS_PROFILE=anhnv-prd aws ssm start-session --region ap-southeast-1 --target <bastion> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '…'` |
| `kubeconfig_command` | `aws eks update-kubeconfig … --alias svp-prd && kubectl config set-cluster <ARN cluster> --server=https://127.0.0.1:6443 --tls-server-name=<host endpoint>` |

## Ngoại lệ trivy

`make trivy DIRS=aws/envs/prd` quét root với `prd.tfvars`, không ngoại lệ chỉ-stg nào: root không có `#trivy:ignore` nào; ngoại lệ trong
module mang `Scope: every environment` hay có điều kiện khớp giá trị stg (không khớp giá trị prd). Đổi tạm `eks_endpoint_public_access`
về `true` thì quét đỏ ở `AWS-0040`.

## Chi phí

Trần một buổi và phí giữa các buổi ở phụ lục ADR-0048, ADR-0049 (NAT mỗi AZ, RDS Multi-AZ, node on-demand, bastion). CloudFront của media
và web ACL WAF nằm trong gói flat-rate Free: $0 ([ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md)).
