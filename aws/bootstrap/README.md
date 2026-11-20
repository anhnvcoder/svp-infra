# `aws/bootstrap`: bucket state của management và cảnh báo tiền của cả tổ chức

**Account** management · **region** `ap-southeast-1` (bucket, key), Budgets và Cost Explorer qua `us-east-1` · **profile** `anhnv-sso` ·
**state** bucket của chính root này, key `aws/bootstrap/terraform.tfstate` (lần áp đầu trên state local)

Giải thích: [01. Bootstrap](../../docs/handbook/01-bootstrap.md).

## Dựng gì

Mọi tài nguyên mang tag `Stack=bootstrap` (script quét sót của buổi bỏ qua tag này) và sống suốt lab.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `aws_s3_bucket.state` `svp-tfstate-<account>-<region>` và năm cấu hình của nó | management, `ap-southeast-1` | Versioning, SSE-KMS mặc định với S3 Bucket Key, chặn public, `BucketOwnerEnforced`, policy chỉ TLS; `prevent_destroy` |
| `aws_kms_key.state`, alias `alias/svp-tfstate` | management, `ap-southeast-1` | Mã hoá state; xoay mỗi năm, chờ xoá 30 ngày, key policy mặc định; `prevent_destroy` |
| `aws_budgets_budget.monthly` `svp-monthly` | management, toàn cục | Hoá đơn gộp; email ở ngưỡng của `local.budget_alerts`; hạn mức `budget_limit_usd` |
| `aws_ce_anomaly_monitor.services` `svp-services`, `aws_ce_anomaly_subscription.daily` `svp-daily` | management, toàn cục | Bất thường theo dịch vụ, email hằng ngày từ ngưỡng của `cost.tf` |
| `aws_ce_cost_allocation_tag.this` | management, toàn cục | `Project`, `Env`, `Stack` ở `Active` |

Giá trị cá nhân ở `bootstrap.auto.tfvars` (git bỏ qua, chép từ `bootstrap.auto.tfvars.example`): `budget_emails`, `budget_limit_usd`.
Account chỉ vào qua `TF_VAR_account_id` trong lệnh, sau khi kiểm account.

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account. Các bước đánh số là bước của
[`org-security-setup.md`, bước (1)](../../docs/runbooks/org-security-setup.md#bước-1-awsbootstrap):

1. Kiểm account: [1a](../../docs/runbooks/org-security-setup.md#1a-kiểm-account).
2. Giá trị cá nhân: [1b](../../docs/runbooks/org-security-setup.md#1b-giá-trị-cá-nhân).
3. Bucket state chưa có (lab dựng từ đầu), apply trên state local:
   [1c](../../docs/runbooks/org-security-setup.md#1c-apply-lần-đầu-trên-state-local), rồi chuyển state vào bucket:
   [1d](../../docs/runbooks/org-security-setup.md#1d-chuyển-state-vào-bucket).
4. Code đổi khi state đã ở bucket: [1e](../../docs/runbooks/org-security-setup.md#1e-áp-thay-đổi-khi-state-đã-ở-bucket).
5. Monitor, subscription Cost Anomaly Detection và tag phân bổ chi phí: kiểm trước mỗi `plan` ở
   [1c](../../docs/runbooks/org-security-setup.md#1c-apply-lần-đầu-trên-state-local),
   [1e](../../docs/runbooks/org-security-setup.md#1e-áp-thay-đổi-khi-state-đã-ở-bucket) (monitor AWS tự tạo thì nhận quản, tag chưa có
   trong dữ liệu billing thì chờ); sau khi áp, đọc lại ở
   [7f](../../docs/runbooks/org-security-setup.md#7f-chi-phí-sau-1-và-7-ngày).
6. `aws/backend.hcl` đổi: init lại mọi root ở [1f](../../docs/runbooks/org-security-setup.md#1f-init-lại-mọi-root).

Gỡ có chủ đích khi lab kết thúc: [mục dưới](#gỡ-có-chủ-đích).

## Root dùng bucket state

Bucket giữ state của mọi root chạy bằng profile của management, mỗi root một key `<thư mục root>/terraform.tfstate`. Root của env để state
ở bucket của account env (`aws/accounts/<env>`). Danh sách và `-backend-config` (cùng thứ tự `aws/scripts/tfvars.sh init` chạy):

| Root | `-backend-config` |
| --- | --- |
| `aws/bootstrap` | `../backend.hcl` |
| `aws/org` | `../backend.hcl` |
| `aws/log-archive` | `../backend.hcl` |
| `aws/security` | `../backend.hcl` |
| `aws/baseline` | `../backend.hcl` |
| `aws/backup` | `../backend.hcl` |
| `github` | `../aws/backend.hcl` |

`aws/backend.hcl` (git bỏ qua) là output `backend_hcl` của root này: bucket, region, `encrypt`, `kms_key_id` (ARN `key/<id>` của
`alias/svp-tfstate`), `use_lockfile`; không có `key`. `aws/scripts/tfvars.sh backend mgmt` ghi nó
([1c](../../docs/runbooks/org-security-setup.md#1c-apply-lần-đầu-trên-state-local)); thiếu file thì mọi root trên không `init` được.

## Gỡ có chủ đích

Bucket và key có `prevent_destroy`: mất bucket là mất state của mọi root ở bảng trên, mất key là không đọc được state. Chỉ gỡ khi lab kết
thúc, sau mọi root khác và sau khi state của `github` đã chuyển đi:
[`lab-teardown.md`, Xoá bootstrap](../../docs/runbooks/lab-teardown.md#xoá-bootstrap).

## Tham chiếu

- [01. Bootstrap](../../docs/handbook/01-bootstrap.md): vì sao, kịch bản env quên gỡ, chi phí, đọc sâu về mã hoá state.
- [`org-security-setup.md`, bước (1)](../../docs/runbooks/org-security-setup.md#bước-1-awsbootstrap): áp root này.
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §11: Cost Anomaly Detection, tag
  phân bổ.
- [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) §11: CMK của bucket state.
