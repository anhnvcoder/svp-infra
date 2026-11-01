# `aws/bootstrap`: tầng account (chạy một lần mỗi account)

Tạo những thứ sống lâu hơn mọi buổi AWS và không thuộc env nào:

| Tài nguyên | Vì sao | Chi phí |
| --- | --- | --- |
| Bucket state `svp-tfstate-<account>-<region>` | state của mọi root, mỗi root một key (`aws/bootstrap/terraform.tfstate`, `aws/stg/terraform.tfstate`, …), khoá bằng lock file native của backend S3 (`use_lockfile`, không DynamoDB); versioning, SSE-S3, chặn public, `BucketOwnerEnforced`, policy từ chối request không TLS, `prevent_destroy` | < $0,01/tháng (vài file state; ước lượng) |
| Budget tháng `svp-monthly` | email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo; mặc định $20 (`budget_limit_usd`) | miễn phí ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/), đọc 2026-10-31) |
| Hosted zone `aws.<domain>` | giữ giữa các buổi để bốn name server, uỷ quyền một lần, không đổi; ExternalDNS và cert-manager chỉ ghi zone này | $0,50/tháng ([Route 53 pricing](https://aws.amazon.com/route53/pricing/), đọc 2026-10-31) |

Mọi tài nguyên mang tag `Project=svp`, `ManagedBy=terraform`, `Stack=bootstrap` (script quét sót của buổi bỏ qua `Stack=bootstrap`). Tên
bucket theo `<tên>-<account>-<region>` như bucket của AWS CDK, Control Tower: duy nhất toàn cầu không cần phần ngẫu nhiên. Account chỉ vào
qua `TF_VAR_account_id` lúc chạy (provider từ chối mọi account khác, `allowed_account_ids`), nên không file commit nào chứa account thật.

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Làm vài ngày trước buổi AWS đầu, để uỷ quyền NS kịp lan
truyền. Cần: Terraform 1.15 trên máy (`terraform version`), AWS CLI v2, `jq`, `dig`, đã `aws sso login --profile anhnv-sso`.

## 1. Kiểm account

```sh
cd infra/aws/bootstrap
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
```

So `Account` với account sandbox trên trang SSO, `Arn` là role SSO của người học. Khác thì dừng. Đúng thì đặt biến cho mọi lệnh sau
(trong cùng terminal; không ghi vào file nào):

```sh
export TF_VAR_account_id=<12 số của Account vừa đọc>
```

## 2. Giá trị cá nhân

```sh
cp bootstrap.auto.tfvars.example bootstrap.auto.tfvars
```

Sửa `bootstrap.auto.tfvars` (git bỏ qua): `budget_emails` (email nhận cảnh báo; AWS Budgets gửi thẳng, không có thư xác nhận),
`zone_name = "aws.<domain>"` (subdomain của lab, không dấu chấm cuối), `budget_limit_usd` nếu muốn khác $20.

## 3. Apply lần đầu, state local

Bucket state chưa có, nên lần đầu chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-sso terraform init
AWS_PROFILE=anhnv-sso terraform plan -out=bootstrap.tfplan
```

Đọc plan: `Plan: 8 to add, 0 to change, 0 to destroy` (bucket cùng 5 cấu hình của nó, budget, hosted zone). Dán dòng đó lại
nếu muốn kiểm cùng. Rồi:

```sh
AWS_PROFILE=anhnv-sso terraform apply bootstrap.tfplan
AWS_PROFILE=anhnv-sso terraform output -raw backend_hcl > ../backend.hcl
cat ../backend.hcl            # bucket = "svp-tfstate-<account>-ap-southeast-1", region = "ap-southeast-1"
```

`aws/backend.hcl` (git bỏ qua) là cấu hình backend chung mà mọi root đọc bằng `-backend-config`.

## 4. Chuyển state vào bucket

```sh
rm local_override.tf bootstrap.tfplan
AWS_PROFILE=anhnv-sso terraform init -migrate-state -backend-config=../backend.hcl    # trả lời yes khi được hỏi chép state
AWS_PROFILE=anhnv-sso terraform plan                                                    # mong đợi: No changes.
AWS_PROFILE=anhnv-sso aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-sso terraform output -raw state_bucket)" \
  --key aws/bootstrap/terraform.tfstate --query '{Size:ContentLength,SSE:ServerSideEncryption}'   # SSE: AES256
```

Ba lệnh đều đúng mong đợi thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`. Từ đây mọi lệnh của root này
đọc state trong bucket.

## 5. Uỷ quyền `aws.<domain>` sang Route 53

```sh
AWS_PROFILE=anhnv-sso terraform output -json name_servers | jq -r '.[]'
```

Trong Cloudflare (DNS đang phục vụ domain): **DNS** → **Records** của `<domain>` → **Add record** bốn lần, mỗi lần **Type** `NS`,
**Name** `aws`, **Nameserver** một trong bốn tên vừa in (không dấu chấm cuối), **TTL** Auto. Không đổi gì khác của domain (không đổi name
server của domain, không xoá bản ghi nào).

Kiểm lan truyền (lặp lại tới khi qua; thường vài phút, có thể tới 48 giờ do cache):

```sh
diff <(dig NS aws.<domain> +short @1.1.1.1 | sed 's/\.$//' | sort) \
     <(AWS_PROFILE=anhnv-sso terraform output -json name_servers | jq -r '.[]' | sort) && echo "delegation OK"
dig NS aws.<domain> +short          # resolver của máy: cũng đúng bốn name server đó
```

Mỗi buổi AWS bắt đầu bằng phép kiểm này (script buổi); sai thì không `apply`.

## Xoá bootstrap (khi lab kết thúc)

Chỉ khi không còn root nào dùng bucket và zone (mọi env đã `destroy`, script quét sót sạch):

0. Root `github/` (cài đặt GitHub) giữ state ở bucket này và không bao giờ `destroy`: trước khi xoá bucket, chuyển state của nó sang
   backend khác (`terraform init -migrate-state` với backend mới, như bước chuyển state ở trên). Bỏ qua bước này thì state mới
   rỗng: `plan` đòi tạo mọi tài nguyên đã có trên GitHub, phải nhận quản lại theo mục "Nhận quản repo đã có" của `github/README.md`.

1. Xoá bốn bản ghi `NS` `aws` trong Cloudflare.
2. Kiểm zone chỉ còn `NS`, `SOA` ở đỉnh (bản ghi sót của ExternalDNS hay `_acme-challenge` chặn việc xoá zone; xoá chúng trước):
   `AWS_PROFILE=anhnv-sso aws route53 list-resource-record-sets --hosted-zone-id "$(AWS_PROFILE=anhnv-sso terraform output -raw zone_id)" --query 'ResourceRecordSets[].[Name,Type]' --output text`
3. Đưa state về local (bucket sắp bị xoá): tạo lại `local_override.tf` như bước 3, rồi
   `AWS_PROFILE=anhnv-sso terraform init -migrate-state` (trả lời yes).
4. Gỡ bảo vệ có chủ đích, chỉ trong bản sửa local này (không commit): trong `state.tf` đổi `prevent_destroy = true` thành `false` và thêm
   `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ). Rồi
   `AWS_PROFILE=anhnv-sso terraform apply` (chỉ đổi `force_destroy`), `AWS_PROFILE=anhnv-sso terraform destroy`.
5. `rm -f terraform.tfstate* ../backend.hcl bootstrap.auto.tfvars local_override.tf`, hoàn tác sửa của bước 4 (`git checkout -- state.tf`),
   xoá thư mục này bằng PR nếu không dùng nữa.
