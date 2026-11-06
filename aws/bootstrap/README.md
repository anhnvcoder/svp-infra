# `aws/bootstrap`: tầng account (chạy một lần mỗi account)

Tạo những thứ sống lâu hơn mọi buổi AWS và không thuộc env nào:

| Tài nguyên | Vì sao | Chi phí |
| --- | --- | --- |
| Bucket state `svp-tfstate-<account>-<region>` | state của ba root quản management account và GitHub, mỗi root một key (`aws/bootstrap/terraform.tfstate`, `aws/org/terraform.tfstate`, `github/terraform.tfstate`); state của env ở bucket của account env (`aws/accounts/`); khoá bằng lock file native của backend S3 (`use_lockfile`, không DynamoDB); versioning, SSE-S3, chặn public, `BucketOwnerEnforced`, policy từ chối request không TLS, `prevent_destroy` | < $0,01/tháng (vài file state; ước lượng) |
| Budget tháng `svp-monthly` | chi phí của cả org (budget không lọc ở management account tính hoá đơn gộp: management và mọi account thành viên); email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo; mặc định $20 (`budget_limit_usd`) | miễn phí ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/), đọc 2026-10-31) |

Mọi tài nguyên mang tag `Project=svp`, `ManagedBy=terraform`, `Stack=bootstrap` (script quét sót của buổi bỏ qua `Stack=bootstrap`). Tên
bucket theo `<tên>-<account>-<region>` như bucket của AWS CDK, Control Tower: duy nhất toàn cầu không cần phần ngẫu nhiên. Account chỉ vào
qua `TF_VAR_account_id` lúc chạy (provider từ chối mọi account khác, `allowed_account_ids`), nên không file commit nào chứa account thật.

Management account không giữ hosted zone nào: zone DNS của lab nằm ở account env, do baseline của nó tạo, uỷ quyền theo
[mục 5 của `aws/accounts/README.md`](../accounts/README.md#5-uỷ-quyền-zone-của-env). Lý do:
[ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md).

**Profile management:** root này (cùng `aws/org`, `github/`) chạy ở management account bằng profile `anhnv-sso`, account đọc từ biến
`SVP_AWS_MGMT_ACCOUNT_ID` (export trong terminal của buổi, không file commit nào); mỗi lệnh `terraform` đặt
`TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID"` ngay trong lệnh. Root của account stg, prd ở [`aws/accounts/`](../accounts/README.md).

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Làm trước root `aws/org` và buổi AWS đầu. Cần: Terraform
1.15 trên máy (`terraform version`), AWS CLI v2, đã `aws sso login --profile anhnv-sso`.

## 1. Kiểm account

```sh
cd infra/aws/bootstrap
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
```

So `Account` với management account trên trang SSO, `Arn` là role SSO của người học. Khác thì dừng. Đúng thì đặt biến của management
account trong terminal của buổi (không ghi vào file commit nào):

```sh
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của Account vừa đọc>
```

## 2. Giá trị cá nhân

```sh
cp bootstrap.auto.tfvars.example bootstrap.auto.tfvars
```

Sửa `bootstrap.auto.tfvars` (git bỏ qua): `budget_emails` (email nhận cảnh báo; AWS Budgets gửi thẳng, không có thư xác nhận),
`budget_limit_usd` nếu muốn khác $20.

## 3. Apply lần đầu, state local

Bucket state chưa có, nên lần đầu chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=bootstrap.tfplan
```

Đọc plan: `Plan: 7 to add, 0 to change, 0 to destroy` (bucket cùng 5 cấu hình của nó, budget). Dán dòng đó lại
nếu muốn kiểm cùng. Rồi:

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply bootstrap.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw backend_hcl > ../backend.hcl
cat ../backend.hcl            # bucket = "svp-tfstate-<account>-ap-southeast-1", region = "ap-southeast-1"
```

`aws/backend.hcl` (git bỏ qua) là cấu hình backend mà `aws/bootstrap`, `aws/org` và `github/` đọc bằng `-backend-config`.

## 4. Chuyển state vào bucket

```sh
rm local_override.tf bootstrap.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init -migrate-state -backend-config=../backend.hcl    # trả lời yes khi được hỏi chép state
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan                                                    # mong đợi: No changes.
AWS_PROFILE=anhnv-sso aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/bootstrap/terraform.tfstate --query '{Size:ContentLength,SSE:ServerSideEncryption}'   # SSE: AES256
```

Ba lệnh đều đúng mong đợi thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`. Từ đây mọi lệnh của root này
đọc state trong bucket.

## State còn hosted zone (bản trước)

State dựng từ bản trước của root này còn zone lab `aws.<domain>` (`aws_route53_zone.lab`) và bản ghi `NS` uỷ quyền
(`aws_route53_record.delegation`). Code không còn chúng, nên `plan` xoá đúng `aws_route53_zone.lab` cùng mỗi
`aws_route53_record.delegation["<tên zone>"]` còn trong state: `Plan: 0 to add, 0 to change, 2 to destroy` khi chỉ còn
`aws_route53_record.delegation["stg.aws.<domain>"]`. Tên resource hay số khác thì dừng, không `apply`.

Chỉ `apply` plan đó ở bước 7 của
[Chuyển zone gốc từ management sang prd](../accounts/README.md#chuyển-zone-gốc-từ-management-sang-prd-một-lần), theo đúng thứ tự của mục
đó; trước bước 7 không `apply` root này vì lý do nào khác (đổi budget cũng vậy), vì mọi plan lúc đó đều xoá zone. Trước `plan`, xoá dòng
`zone_name` và khối `delegated_subdomains` khỏi `bootstrap.auto.tfvars`.

Zone còn bản ghi ngoài `NS`, `SOA` ở đỉnh và các `NS` uỷ quyền nói trên (bản ghi sót của ExternalDNS hay `_acme-challenge`) thì
`DeleteHostedZone` lỗi `HostedZoneNotEmpty`. Liệt kê bản ghi của zone (tìm zone theo tên, không còn output `zone_id`), bản ghi khác thì xoá
trước trong console Route 53 của management account:

```sh
zone=$(AWS_PROFILE=anhnv-sso aws route53 list-hosted-zones-by-name --region ap-southeast-1 --dns-name aws.<domain> --query "HostedZones[?Name=='aws.<domain>.'].Id" --output text)
AWS_PROFILE=anhnv-sso aws route53 list-resource-record-sets --region ap-southeast-1 --hosted-zone-id "$zone" --query 'ResourceRecordSets[].[Name,Type]' --output text
```

## Xoá bootstrap (khi lab kết thúc)

Chỉ khi không còn root nào dùng bucket (mọi env đã `destroy`, script quét sót sạch):

0. Root `aws/org` giữ state ở bucket này: gỡ org trước (README của nó). Root `github/` (cài đặt GitHub) giữ state ở bucket này và không bao giờ `destroy`: trước khi xoá bucket, chuyển state của nó sang
   backend khác (`terraform init -migrate-state` với backend mới, như bước chuyển state ở trên). Bỏ qua bước này thì state mới
   rỗng: `plan` đòi tạo mọi tài nguyên đã có trên GitHub, phải nhận quản lại theo mục "Nhận quản repo đã có" của `github/README.md`.

1. Đưa state về local (bucket sắp bị xoá): tạo lại `local_override.tf` như bước 3, rồi
   `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init -migrate-state` (trả lời yes).
2. Gỡ bảo vệ có chủ đích, chỉ trong bản sửa local này (không commit): trong `state.tf` đổi `prevent_destroy = true` thành `false` và thêm
   `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ). Rồi
   `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply` (chỉ đổi `force_destroy`), `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform destroy`.
3. `rm -f terraform.tfstate* ../backend.hcl bootstrap.auto.tfvars local_override.tf`, hoàn tác sửa của bước 2 (`git checkout -- state.tf`),
   xoá thư mục này bằng PR nếu không dùng nữa.
