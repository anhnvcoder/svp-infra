# `aws/accounts`: baseline của account stg và prd (chạy một lần mỗi account)

Mỗi account thành viên của org (`svp-stg`, `svp-prd`) có một root ở đây, gọi module
[`account-baseline`](../modules/account-baseline/README.md): bucket state và KMS key của nó, zone `<env>.aws.<domain>`, budget tháng. Mọi
thứ sống giữa các buổi AWS, mang tag `Stack=baseline` (script quét sót của buổi giữ lại tag này).

| Root | Profile SSO | Biến account | State |
| --- | --- | --- | --- |
| `stg/` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` | key `aws/accounts/stg/terraform.tfstate` trong bucket của account stg |
| `prd/` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` | key `aws/accounts/prd/terraform.tfstate` trong bucket của account prd |

Hai root chỉ khác giá trị: `local.env` (`main.tf`) và `key` của backend (`versions.tf`). Trong bucket của mỗi account còn có state của root
`aws/envs/<env>` (key `aws/<env>/terraform.tfstate`) và `aws/gitops/<env>` (key `aws/gitops/<env>/terraform.tfstate`), cả hai đọc
`-backend-config=../../backend-<env>.hcl`.

## Phí giữ giữa các buổi

Mỗi account, trong khi baseline còn:

| Tài nguyên | Phí | Nguồn |
| --- | --- | --- |
| KMS key `alias/svp-tfstate` | $1/tháng (tính theo giờ); xoay vòng tự động cộng $1/tháng ở lần xoay thứ nhất và thứ hai (mỗi năm một lần), từ lần thứ ba không cộng thêm: $1, $2 rồi $3/tháng | [AWS KMS pricing](https://aws.amazon.com/kms/pricing/), đọc 2026-11-05 |
| Request KMS của state | trong 20 000 request/tháng miễn phí (vài lần `plan`, `apply` mỗi buổi, S3 Bucket Key bật) | như trên; lượng là ước lượng |
| Hosted zone `<env>.aws.<domain>` | $0,50/tháng (không chia theo ngày) | [Route 53 pricing](https://aws.amazon.com/route53/pricing/), đọc 2026-11-05 |
| Bucket state | < $0,01/tháng (vài file state, cả version cũ) | ước lượng |
| Budget `svp-<env>-monthly` | miễn phí (budget không có action) | [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/), đọc 2026-11-05 |

Tổng R mỗi account khoảng $1,51/tháng năm đầu ($3,02 cho hai account), tăng lên $2,51 rồi $3,51 sau mỗi lần xoay key. Key đang chờ xoá
(`PendingDeletion`) không tính phí.

## Dựng baseline

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Làm sau khi root `aws/org` đã tạo account và gán permission set
`SvpAdmin`, trước buổi AWS đầu của env đó. Ví dụ dưới là stg; với prd thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`,
`SVP_AWS_STG_ACCOUNT_ID` bằng `SVP_AWS_PRD_ACCOUNT_ID`.

Cần: Terraform 1.15, AWS CLI v2, `jq`, `dig`; profile `anhnv-stg` đã tạo bằng `aws configure sso` (permission set `SvpAdmin` của account
stg) và `aws sso login --profile anhnv-stg`; trong terminal của buổi (không file commit nào) đã `export SVP_AWS_STG_ACCOUNT_ID=<12 số>`.

### 1. Kiểm account và role

```sh
cd infra/aws/accounts/stg
AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_STG_ACCOUNT_ID"
```

`Account` phải bằng số vừa in, `Arn` phải chứa `assumed-role/AWSReservedSSO_SvpAdmin_`. Sai một trong hai thì dừng: key policy chỉ cho role
SSO của `SvpAdmin` mã hoá, giải mã, nên apply bằng role khác (vd `OrganizationAccountAccessRole`) tạo được key nhưng không ghi được state vào
bucket ở bước 4.

### 2. Giá trị cá nhân

```sh
cp stg.auto.tfvars.example stg.auto.tfvars
```

Sửa `stg.auto.tfvars` (git bỏ qua): `budget_emails`, `lab_zone_name = "aws.<domain>"` (zone lab của management, không dấu chấm cuối),
`budget_limit_usd` nếu muốn khác $20.

### 3. Apply lần đầu, state local

Bucket state chưa có, nên lần đầu chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan -out=stg.tfplan
```

Đọc plan: `Plan: 10 to add, 0 to change, 0 to destroy` (KMS key và alias, bucket cùng 5 cấu hình của nó, hosted zone, budget). Rồi:

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw backend_hcl > ../../backend-stg.hcl
cat ../../backend-stg.hcl     # bucket, region, encrypt, kms_key_id, use_lockfile của account stg
```

`aws/backend-stg.hcl` (git bỏ qua) là cấu hình backend mà mọi root của account stg đọc bằng `-backend-config`.

### 4. Chuyển state vào bucket

```sh
rm local_override.tf stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state -backend-config=../../backend-stg.hcl   # trả lời yes
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan                                                         # mong đợi: No changes.
AWS_PROFILE=anhnv-stg aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/accounts/stg/terraform.tfstate --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId}'   # SSE: aws:kms, Key: ARN của key state
```

Ba lệnh đều đúng mong đợi thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`.

### 5. Uỷ quyền zone của env

Zone `stg.aws.<domain>` chỉ trả lời được khi zone lab ở management account có bản ghi `NS` trỏ về nó: làm theo mục "Uỷ quyền zone con" của
[`aws/bootstrap/README.md`](../bootstrap/README.md#6-uỷ-quyền-zone-con-của-account-stg-prd), với bốn name server của:

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]'
```

Output `zone_id` là `hosted_zone_id` của root `aws/envs/stg`.

## Gỡ baseline (có chủ đích)

Chỉ khi bỏ hẳn env đó: bucket giữ state của mọi root của account, key giữ quyền đọc state. Trước hết mọi root của account đã `destroy`
(`aws/gitops/<env>`, `aws/envs/<env>`), quét sót của buổi sạch.

1. Bỏ uỷ quyền: xoá mục `stg.aws.<domain>` khỏi `delegated_subdomains` trong `aws/bootstrap/bootstrap.auto.tfvars`, rồi `plan`, `apply`
   của `aws/bootstrap` theo README của nó (mong đợi `1 to destroy`, đúng bản ghi `NS` đó).
2. Kiểm account của env trước lệnh đầu tiên bằng profile env (các bước dưới đây ghi vào account đó):
   `AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text`:
   `Account` phải bằng `$SVP_AWS_STG_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`. Khác thì dừng.
3. Kiểm zone chỉ còn `NS`, `SOA` ở đỉnh (bản ghi sót của ExternalDNS hay `_acme-challenge` chặn việc xoá zone; xoá chúng trước):
   `AWS_PROFILE=anhnv-stg aws route53 list-resource-record-sets --region ap-southeast-1 --hosted-zone-id "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw zone_id)" --query 'ResourceRecordSets[].[Name,Type]' --output text`
4. Đưa state về local (bucket và key sắp bị xoá): tạo lại `local_override.tf` như bước 3 của mục dựng, rồi
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state` (trả lời yes).
5. Gỡ bảo vệ, chỉ trong bản sửa local này (không commit): trong `aws/modules/account-baseline/state.tf` và `kms.tf` đổi
   `prevent_destroy = true` thành `false`, thêm `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ và state
   của các root khác). Rồi `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply` (chỉ đổi `force_destroy`),
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform destroy`. Key vào `PendingDeletion` 30 ngày (không tính
   phí), huỷ được trong thời gian đó (id key in ở output của `destroy`):
   `AWS_PROFILE=anhnv-stg aws kms cancel-key-deletion --key-id <id key> --region ap-southeast-1`.
6. `rm -f terraform.tfstate* ../../backend-stg.hcl stg.auto.tfvars local_override.tf`, hoàn tác sửa của bước 5
   (`git checkout -- ../../modules/account-baseline`).
