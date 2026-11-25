# `aws/baseline`: baseline bảo mật của mọi account và CMK EBS

**Account** management, và mỗi account thành viên qua `OrganizationAccountAccessRole` (đọc thêm key của `svp-log-archive`) · **region**
`ap-southeast-1` và `us-east-1`; `us-east-2`, `us-west-2` (rule đăng nhập root); management thêm `sso_region` · **profile**
`anhnv-sso` · **state** bucket của `aws/bootstrap`, key `aws/baseline/terraform.tfstate`

Giải thích: [06. Baseline](../../docs/handbook/06-baseline.md).

Chạy root này tạo gì: mục [`aws/baseline`](../../docs/reference/inventory.md#awsbaseline) của
[inventory](../../docs/reference/inventory.md) (số tài nguyên theo phần, theo loại, kèm sơ đồ).

## Dựng gì

Mọi tài nguyên mang tag `Stack=security-baseline` (SCP `svp-protect-baseline` dựa vào tag này để giữ CMK EBS) và sống suốt lab.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `module.<account>` ([`security-baseline`](../modules/security-baseline/README.md)), một lời gọi mỗi khoá của `local.accounts` | mỗi account, hai region | S3 Block Public Access, EBS mã hoá mặc định, recorder Config theo cờ, rule `svp-security-*` |
| `module.paid_features` | — | Đọc `aws/paid-features.json`: `config_recording` `always` thành `true` cho module của account đó |
| `aws_kms_key.stg_ebs`, `.prd_ebs`, alias `alias/svp-ebs` | `svp-stg`, `svp-prd`, `ap-southeast-1` | CMK EBS cũ, giữ tới khi không volume, snapshot nào dùng; key mặc định của EBS mọi nơi là `aws/ebs` |
| `data.aws_kms_alias.log_archive` | `svp-log-archive` | ARN `key/<id>` của key Log Archive cho delivery channel của Config |

Khác biệt giữa account là dữ liệu của `local.accounts` trong [`main.tf`](main.tf): stg, prd tắt rule `admin-*`;
management có thêm rule tổ chức, phiên root, Identity Center (ở `sso_region`). Mọi account có rule đăng nhập root ở ba region
(`local.root_signin_regions`), nên `aws/org` phải áp SCP mở rule đó ở `us-east-2`, `us-west-2` trước. Đích của mọi rule là bus
`svp-security-events` của `svp-security`, recorder giao về bucket `svp-config-<log>-ap-southeast-1`; root suy cả hai từ id account,
không đọc state của `aws/security`, `aws/log-archive`. Output: `ebs_kms_key_arns`.

## Giá trị ngoài repo

`baseline.auto.tfvars` (git bỏ qua) từ `baseline.auto.tfvars.example`: `sso_region` bằng `sso_region` của `aws/org/org.auto.tfvars`.
Id của sáu account đặt bằng `TF_VAR_*` từ biến `SVP_AWS_*_ACCOUNT_ID` trong lệnh.

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account.

- Áp lần đầu (sau `aws/log-archive`, `aws/org` đủ, `aws/security`):
  [`org-security-setup.md`, bước (6)](../../docs/runbooks/org-security-setup.md#bước-6-awsbaseline).
- Thêm account vào tổ chức khi root đã áp (như `svp-backup`): cùng bước (6), bỏ 6b.
- Đổi cờ `config_recording`: [`paid-features.md`, `aws/baseline`](../../docs/runbooks/paid-features.md#awsbaseline), theo
  [thứ tự apply cờ](../../docs/runbooks/paid-features.md#thứ-tự-apply-cờ).
- Đổi baseline khi SCP chặn cả đường thường: [`break-glass.md`](../../docs/runbooks/break-glass.md#đổi-baseline-bị-scp-chặn).
- Trong buổi: không chạy root này.
- Gỡ có chủ đích (lab kết thúc): [`lab-teardown.md`, `aws/baseline`](../../docs/runbooks/lab-teardown.md#awsbaseline).

## Tham chiếu

- [06. Baseline](../../docs/handbook/06-baseline.md): vì sao chạy từ management, CMK EBS, Config theo cờ; chi tiết triển khai ở mục Đọc
  sâu (ghi chú thiết kế mà `main.tf`, `ebs-key.tf` trỏ tới).
- [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) §2, §9: root từ management,
  baseline, CMK EBS.
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §4, §10: Config, rule chuyển sự
  kiện; rule theo account và region ở phụ lục.
- [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md) §6, §10: cờ `config_recording`.
