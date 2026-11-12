# `aws/envs/prd`: cấu hình gốc của env prd

Tầng platform của prd trên AWS (ADR-0034 §2, ADR-0048, ADR-0055…0058): cùng `*.tf`, cùng module, cùng đối số với root stg
([`aws/envs/stg`](../stg/README.md)), kể cả web ACL AWS WAF trước CloudFront (`waf.tf`), bastion SSM tới endpoint private của API
(`ssm-bastion.tf`) và module `alarms`; cỡ, dự phòng, retention và bảo vệ production ở `prd.tfvars`. Ngoài phần chung đó, root này thêm đúng
một file: `teardown.tfvars` để gỡ cuối buổi. Ứng dụng trong cluster không ở đây: Argo CD triển khai từ `svp-gitops`, bootstrap bằng root
`aws/gitops/prd`.

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

Các file `*.tf` chép từ root stg, giống hệt trừ dòng `env = "prd"` của `locals` (`main.tf`). Khác biệt được phép
([ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) §6, kiểm bằng `diff -r -x .terraform -x '*.auto.tfvars' aws/envs/stg aws/envs/prd`):
dòng `env` đó, `<env>.tfvars`, `teardown.tfvars`, `README.md`, `backend.hcl.example` (profile, tên bucket), `example.auto.tfvars.example`
(giá trị ví dụ theo env). Ngoài các chỗ đó là lỗi.

| Tệp | Commit | Nội dung |
| --- | --- | --- |
| `prd.tfvars` | có | cỡ, dự phòng, retention và mức bảo vệ của prd; không giá trị cá nhân nào |
| `teardown.tfvars` | có | chỉ hai bảo vệ cần nhấc để xoá (mục "Gỡ") |
| `prd.auto.tfvars` | **không** (git bỏ qua) | giá trị cá nhân, chép từ `example.auto.tfvars.example` |
| `../../backend-prd.hcl` | **không** | phần chung của backend trong account prd |
| `TF_VAR_account_id` | biến môi trường, đặt ngay trong lệnh | account được phép đổi (`allowed_account_ids`) |

Giá trị của `prd.tfvars`: mỗi nhóm biến một comment nói vì sao, cùng thứ tự dòng với `stg.tfvars`; khác biệt với stg, nhóm của nó và mất
gì ở stg: bảng của [`environments.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/explanation/environments.md) ở repo code. Những gì chỉ prd có: ba AZ, NAT mỗi AZ, RDS
`db.m7g` Multi-AZ, MSK RF 3 và min ISR 2 (mất một AZ không mất ghi đã `acks=all`, ADR-0053 §6), Valkey có replica ở AZ khác với failover tự
động, `apply_immediately = false` của Valkey (thay đổi chờ cửa sổ bảo trì), retention log 30 ngày, backup 7 ngày giữ lại sau khi xoá,
deletion protection, final snapshot, versioning của media.

Root không có `validation` ép giá trị prd: test của từng module có một `run` với giá trị prd, `make trivy DIRS=aws/envs/prd` quét với
`prd.tfvars`.

Giá trị cá nhân (`prd.auto.tfvars` hay `TF_VAR_*`): `hosted_zone_id` (output `zone_id` của `aws/accounts/prd`), `domain` (tên zone prd `aws.<domain>`, web ở
apex, API ở `api.<tên này>`; plan dừng ở precondition của `cluster_values` nếu tên khác), `acme_email`, `alarm_email` (hộp thư của topic
`svp-prd-alarms`, xác nhận link SNS gửi sau apply). Không có IP của máy người học.

## Tới API: tunnel SSM

Endpoint công khai của API tắt. Máy người học tới endpoint private qua phiên port forwarding của Session Manager tới instance `t4g.nano`
không inbound, không khoá SSH trong subnet private (module [`ssm-bastion`](../../modules/ssm-bastion/README.md)); security group của API nhận
443 từ security group của bastion. Cổng local là `api_tunnel_port` của `prd.tfvars` (`6443`; stg `6444`). Cần AWS CLI và Session Manager
plugin. Cùng cơ chế ở stg ([README của stg](../stg/README.md#tới-api-tunnel-ssm)).

```sh
# terminal 1: tunnel 127.0.0.1:6443 → endpoint private:443, chạy tới khi Ctrl-C
eval "$(AWS_PROFILE=anhnv-prd terraform output -raw api_tunnel_command)"
# terminal 2: context svp-prd, server https://127.0.0.1:6443, tls-server-name là host của endpoint
eval "$(AWS_PROFILE=anhnv-prd terraform output -raw kubeconfig_command)"
AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes
```

Root `aws/gitops/prd` tới API qua cùng tunnel (`api_server_url = "https://127.0.0.1:6443"` của `aws/gitops/prd/prd.tfvars`, TLS server name
tính từ `cluster_endpoint` của state root này).

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

Sau `apply`: xác nhận email của topic `svp-prd-alarms`, mở tunnel và kubeconfig (mục trên); `AWS_PROFILE=anhnv-prd terraform output -raw rds_master_user_secret_arn` cho script buổi.
Tiếp theo: ghi giá trị secret (`AWS_PROFILE=anhnv-prd make eks-secrets CONTEXT=svp-prd` ở repo code), rồi apply root `aws/gitops/prd` khi
tunnel đang mở.

## Gỡ

`aws/scripts/pre-destroy.sh prd` (qua tunnel; xoá cả NodePool, EC2NodeClass và chờ hết node của Karpenter), destroy `aws/gitops/prd`
(qua tunnel), rồi root này với `teardown.tfvars`: `apply` nhấc bảo vệ, rồi `destroy`, cùng hai file:

```sh
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply -var-file=prd.tfvars -var-file=teardown.tfvars
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform destroy -var-file=prd.tfvars -var-file=teardown.tfvars
```

`teardown.tfvars` chỉ đặt `rds_deletion_protection = false` (RDS từ chối xoá instance còn bảo vệ) và `media_force_destroy = true` (bucket có
versioning không bao giờ rỗng); không đổi cỡ, log hay mã hoá. MSK và ElastiCache không có bảo vệ xoá nào để nhấc: `destroy` gỡ chúng
cùng secret `AmazonMSK_*` (xoá ngay, không cửa sổ khôi phục) và để KMS key của root (RDS, MSK, alarm, Secrets của EKS) ở `PendingDeletion`. `rds_skip_final_snapshot`
vẫn `false`, backup tự động vẫn giữ: destroy vẫn tạo final snapshot. Sau đó runbook đọc final snapshot và backup tự động được giữ, xoá
chúng, rồi chạy lệnh quét tài nguyên sót.

## Output

Như root stg ([bảng output](../stg/README.md#output)), với profile `anhnv-prd`, tên `svp-prd` và cổng `6443` trong `api_tunnel_command`,
`kubeconfig_command`.

## Ngoại lệ trivy

`make trivy DIRS=aws/envs/prd` quét root với `prd.tfvars`, không ngoại lệ chỉ-stg nào: root không có `#trivy:ignore` nào; ngoại lệ trong
module mang `Scope: every environment` hay có điều kiện khớp giá trị stg (không khớp giá trị prd).

## Chi phí

Trần một buổi và phí giữa các buổi ở mục "Chi phí và giới hạn" của runbook [`session-prd.md`](../../../docs/runbooks/session-prd.md) (phụ
lục ADR-0048, ADR-0053 §16: NAT mỗi AZ, RDS Multi-AZ, node on-demand, bastion, ba broker MSK, hai node Valkey). CloudFront của media
và web ACL WAF nằm trong gói flat-rate Free: $0 ([ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md)).
