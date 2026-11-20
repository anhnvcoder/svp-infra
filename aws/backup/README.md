# `aws/backup`: vault copy của backup stg, prd (account `svp-backup`)

**Account** `svp-backup`, qua `OrganizationAccountAccessRole` từ management · **region** `ap-southeast-1` · **profile** `anhnv-sso`
(chỉ đọc: `anhnv-backup-ro`) · **state** bucket của `aws/bootstrap`, key `aws/backup/terraform.tfstate`

Giải thích: [07. Backup](../../docs/handbook/07-backup.md).

## Dựng gì

Mọi tài nguyên mang tag `Stack=backup` và sống suốt lab; key có `prevent_destroy`, nên root này không bao giờ `terraform destroy` cả khối.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `aws_kms_key.copy`, alias `alias/svp-backup-copy` (`kms.tf`) | `svp-backup`, `ap-southeast-1` | Mã hoá lại mọi bản copy của hai vault; chỉ statement quản trị mặc định |
| `module.vaults` ([`backup-vault`](../modules/backup-vault/README.md)): vault `svp-stg-copy` | `svp-backup`, `ap-southeast-1` | Vault Lock governance min 1, max 7 ngày; chỉ account stg copy vào |
| `module.vaults`: vault `svp-prd-copy` | `svp-backup`, `ap-southeast-1` | Vault Lock governance min 7, max 35 ngày; chỉ account prd copy vào |

Plan không nằm ở đây: Backup policy `svp-backup-<env>` của [`aws/org`](../org/README.md) sinh plan `svp-<env>` trong account env, rule
`daily` copy sang vault `svp-<env>-copy` của root này bằng ARN có id thật của `svp-backup`. Output: `kms_key_arn`, `vault_arns`.

## Giá trị ngoài repo

Id của bốn account đặt trong mỗi lệnh từ biến của terminal, không vào file nào: `TF_VAR_account_id` từ `SVP_AWS_MGMT_ACCOUNT_ID`,
`TF_VAR_backup_account_id` từ `SVP_AWS_BACKUP_ACCOUNT_ID`, `TF_VAR_stg_account_id` từ `SVP_AWS_STG_ACCOUNT_ID`, `TF_VAR_prd_account_id`
từ `SVP_AWS_PRD_ACCOUNT_ID` ([`operations.md`](../../docs/reference/operations.md#biến-account-và-direnv)). Provider chỉ cho phép
`backup_account_id`; key kiểm `account_id` là management của tổ chức chứa `svp-backup`. `backup.auto.tfvars` (git bỏ qua) chỉ khi đổi
`region`, chép từ `backup.auto.tfvars.example`.

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account.

- Áp lần đầu (sau `aws/org` đã tạo `svp-backup` và bật cross-account backup, trước `aws/accounts/<env>` và trước copy job đầu tiên):
  [`backup-setup.md`, bước (5)](../../docs/runbooks/backup-setup.md#bước-5-awsbackup).
- Kiểm sau áp: [`backup-setup.md`, 7a–7d](../../docs/runbooks/backup-setup.md#7a7d-kiểm-bằng-script) (dòng `7d` của `verify.sh backup`).
- Đổi lock hay retention: sửa `local.copy_vaults` cùng `local.backup_retention_days` của module `org-policies` trong một PR (khoảng lock
  phải chứa retention copy), rồi plan, apply như bước (5).
- Trong buổi: không chạy root này; `restore-drill.sh` copy vào vault ở đây, `preflight.sh` đọc bản copy bằng `anhnv-backup-ro`.
- Gỡ có chủ đích (lab kết thúc): [`lab-teardown.md`, `aws/backup`](../../docs/runbooks/lab-teardown.md#awsbackup).

## Tham chiếu

- [07. Backup](../../docs/handbook/07-backup.md): vì sao account riêng, Vault Lock governance, key của vault; chi tiết triển khai ở mục
  Đọc sâu (ghi chú thiết kế mà `main.tf` trỏ tới).
- [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §3, §5, §6: account đích, vault, lock, key.
- [Phụ lục ADR-0067 §5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#5-vault-copy-alarm): JSON
  vault access policy và nguồn.
