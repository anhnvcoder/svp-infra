# `aws/bootstrap`: tầng account (chạy một lần mỗi account)

Tạo những thứ sống lâu hơn mọi buổi AWS và không thuộc env nào:

| Tài nguyên | Vì sao | Chi phí |
| --- | --- | --- |
| Bucket state `svp-tfstate-<account>-<region>` | state của mọi root chạy bằng profile management (danh sách ở [mục 5](#5-áp-thay-đổi-khi-state-đã-ở-bucket)), mỗi root một key `<thư mục root>/terraform.tfstate`; state của env ở bucket của account env (`aws/accounts/`); khoá bằng lock file native của backend S3 (`use_lockfile`, không DynamoDB); versioning, SSE-KMS bằng key `alias/svp-tfstate` với S3 Bucket Key, chặn public, `BucketOwnerEnforced`, policy từ chối request không TLS, `prevent_destroy` | < $0,01/tháng (vài file state; ước lượng) |
| KMS key `alias/svp-tfstate` | mã hoá state trong bucket; xoay tự động mỗi năm, chờ xoá 30 ngày, `prevent_destroy`; key policy mặc định của AWS (IAM của management account quyết ai dùng key, như ai đọc bucket: permission set của management không quản ở repo này) | $1/tháng mỗi key, hai lần xoay đầu mỗi lần thêm $1/tháng; request nằm trong 20 000 miễn phí mỗi tháng nhờ Bucket Key ([AWS KMS pricing](https://aws.amazon.com/kms/pricing/), đọc 2026-11-12) |
| Budget tháng `svp-monthly` | chi phí của cả org (budget không lọc ở management account tính hoá đơn gộp: management và mọi account thành viên); email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo; mặc định $20 (`budget_limit_usd`) | miễn phí ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/), đọc 2026-10-31) |
| Cost Anomaly Detection: monitor `svp-services` (`DIMENSIONAL`, theo dịch vụ), subscription `svp-daily` | bất thường chi phí của mọi dịch vụ trên hoá đơn gộp; email tóm tắt hằng ngày tới `budget_emails` khi tác động của bất thường từ ngưỡng của `cost.tf` trở lên; ngưỡng và lý do ở [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §11 | miễn phí ([Cost Anomaly Detection FAQ](https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/faqs/)) |
| Tag phân bổ chi phí `Project`, `Env`, `Stack` | kích hoạt (`Active`) để Cost Explorer, Budgets lọc và nhóm chi phí theo dự án, env, stack; điều kiện ở [mục Tag phân bổ chi phí](#tag-phân-bổ-chi-phí) | miễn phí ([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §12) |

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
AWS_PROFILE=anhnv-sso aws ce get-anomaly-monitors --region us-east-1 \
  --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,Dimension:MonitorDimension,Arn:MonitorArn}' --output table
```

AWS cho mỗi account một monitor `DIMENSIONAL`/`SERVICE` và tự tạo `Default-Services-Monitor` khi Cost Explorer bật, nên account mới có
thể đã có nó: tạo thêm thì `apply` lỗi `Limit exceeded on dimensional spend monitor creation`. Lệnh trên in một monitor như vậy thì nhận
quản nó trước `plan` như [mục 5](#5-áp-thay-đổi-khi-state-đã-ở-bucket) (`terraform import aws_ce_anomaly_monitor.services <Arn>`); plan khi
đó có `13 to add` và monitor đổi tên tại chỗ (`~`), không thêm.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=bootstrap.tfplan
```

Đọc plan: `Plan: 14 to add, 0 to change, 0 to destroy` (bucket cùng 5 cấu hình của nó, key và alias, budget, monitor và
subscription, 3 tag phân bổ). Dán dòng đó lại nếu muốn kiểm cùng. Account mới chưa có tag trong dữ liệu billing thì `apply` báo lỗi ở
`aws_ce_cost_allocation_tag` và vẫn tạo mọi tài nguyên khác: xem [mục Tag phân bổ chi phí](#tag-phân-bổ-chi-phí). Rồi:

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply bootstrap.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw backend_hcl > ../backend.hcl
cat ../backend.hcl            # bucket, region, encrypt, kms_key_id (ARN key/<id> của alias/svp-tfstate), use_lockfile
```

`aws/backend.hcl` (git bỏ qua) là cấu hình backend mà mọi root ở [mục 5](#5-áp-thay-đổi-khi-state-đã-ở-bucket) đọc bằng
`-backend-config`.

## 4. Chuyển state vào bucket

```sh
rm local_override.tf bootstrap.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init -migrate-state -backend-config=../backend.hcl    # trả lời yes khi được hỏi chép state
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan                                                    # mong đợi: No changes.
AWS_PROFILE=anhnv-sso aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/bootstrap/terraform.tfstate --query '{Size:ContentLength,SSE:ServerSideEncryption,Key:SSEKMSKeyId}'   # SSE: aws:kms
```

`plan` còn đòi tạo tag phân bổ chưa kích hoạt được thì vẫn coi là đúng mong đợi. `Key` là ARN `kms_key_id` của `aws/backend.hcl`.
Ba lệnh đều đúng mong đợi thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`. Từ đây mọi lệnh của root này
đọc state trong bucket.

## 5. Áp thay đổi khi state đã ở bucket

Root này đã chạy (state ở bucket) và code đổi thì áp như sau. Bước 1 và 2 ở trên vẫn cần (account, `bootstrap.auto.tfvars`).
Kiểm hai điều kiện của Cost Explorer trước (ở `us-east-1`, dịch vụ toàn cục):

```sh
cd infra/aws/bootstrap
AWS_PROFILE=anhnv-sso aws ce get-anomaly-monitors --region us-east-1 \
  --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,Dimension:MonitorDimension,Arn:MonitorArn}' --output table
AWS_PROFILE=anhnv-sso aws ce list-cost-allocation-tags --region us-east-1 --tag-keys Project Env Stack \
  --query 'CostAllocationTags[].{Key:TagKey,Status:Status}' --output table
```

Lệnh đầu không có monitor nào khác `svp-services`; có monitor `DIMENSIONAL`/`SERVICE` do AWS tự tạo thì nhận quản nó trước khi `plan`:
`AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform import aws_ce_anomaly_monitor.services <Arn>`, rồi đọc plan:
đổi tên tại chỗ (`~`) là đúng, đòi thay (`-/+`) thì dừng và dán plan. Lệnh sau liệt kê đủ ba key (`Active` hay `Inactive`); thiếu key nào
thì đọc [mục Tag phân bổ chi phí](#tag-phân-bổ-chi-phí).

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=bootstrap.tfplan
```

Đọc plan và dán lại dòng `Plan:`. Lần đầu bucket chuyển sang KMS: `7 to add, 1 to change, 0 to destroy` (thêm key, alias, monitor,
subscription, 3 tag; đổi tại chỗ cấu hình mã hoá của bucket). Không có dòng `destroy` nào. Rồi:

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply bootstrap.tfplan && rm bootstrap.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw backend_hcl > ../backend.hcl
cat ../backend.hcl            # có thêm kms_key_id khi bucket vừa chuyển sang KMS
```

`aws/backend.hcl` đổi (lần đầu có `kms_key_id`) thì mọi root đọc nó phải nhận lại cấu hình backend. `-reconfigure` ghi cấu hình mới
mà không chép state (bucket, key không đổi). Root chưa từng `init` cũng chạy được lệnh của nó (lần `init` đầu). Từ
`infra/aws/bootstrap`:

```sh
AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../backend.hcl
cd ../org              && AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../backend.hcl
cd ../log-archive      && AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../backend.hcl
cd ../security         && AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../backend.hcl
cd ../baseline         && AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../backend.hcl
cd ../../github        && AWS_PROFILE=anhnv-sso terraform init -reconfigure -backend-config=../aws/backend.hcl
cd ../aws/bootstrap    && AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan    # mong đợi: No changes.
```

Backend S3 có `encrypt = true` mà không `kms_key_id` tự đặt SSE-S3 cho mỗi lần ghi, ghi đè mã hoá mặc định của bucket; nên root nào
chưa `init -reconfigure` vẫn ghi state SSE-S3, kể cả `apply` trên của chính root này. Object state đã có giữ SSE-S3 tới lần ghi kế của
root đó sau `-reconfigure` (lần `apply` tiếp theo); bản cũ do versioning giữ lại vẫn SSE-S3 (bucket không có lifecycle xoá bản cũ). Kiểm
một object bằng lệnh `head-object` của bước 4 với `--key` của root đó: `SSE` là `aws:kms` sau lần ghi kế, `AES256` trước đó.

## Tag phân bổ chi phí

AWS chỉ kích hoạt được một tag key đã có trong dữ liệu billing: key xuất hiện trong vòng 24 giờ sau khi một tài nguyên có tag đó phát sinh
chi phí. `Project`, `Stack` có sau lần apply đầu của root này (bucket mang tag); `Env` chỉ có sau buổi stg hay prd đầu tiên. Thiếu key
thì `apply` lỗi ở đúng `aws_ce_cost_allocation_tag` của key đó, các tài nguyên khác vẫn được tạo, và thứ tự áp không đổi: chờ key hiện ra
trong `list-cost-allocation-tags` (lệnh ở mục 5), rồi `plan`, `apply` lại.

## Xoá bootstrap (khi lab kết thúc)

Chỉ khi không còn root nào dùng bucket (mọi env đã `destroy`, script quét sót sạch):

0. Root `aws/org` giữ state ở bucket này: gỡ org trước (README của nó). Root `github/` (cài đặt GitHub) giữ state ở bucket này và không bao giờ `destroy`: trước khi xoá bucket, chuyển state của nó sang
   backend khác (`terraform init -migrate-state` với backend mới, như bước chuyển state ở trên). Bỏ qua bước này thì state mới
   rỗng: `plan` đòi tạo mọi tài nguyên đã có trên GitHub, phải nhận quản lại theo mục "Nhận quản repo đã có" của `github/README.md`.

1. Đưa state về local (bucket sắp bị xoá): tạo lại `local_override.tf` như bước 3, rồi
   `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init -migrate-state` (trả lời yes).
2. Gỡ bảo vệ có chủ đích, chỉ trong bản sửa local này (không commit): trong `state.tf` đổi cả hai `prevent_destroy = true` (bucket và
   `aws_kms_key.state`) thành `false` và thêm `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ). Key
   bị lên lịch xoá sau 30 ngày; trong thời gian đó `aws kms cancel-key-deletion` còn cứu được nó. Rồi
   `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply` (chỉ đổi `force_destroy`), `AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform destroy`.
3. `rm -f terraform.tfstate* ../backend.hcl bootstrap.auto.tfvars local_override.tf`, hoàn tác sửa của bước 2 (`git checkout -- state.tf`),
   xoá thư mục này bằng PR nếu không dùng nữa.
