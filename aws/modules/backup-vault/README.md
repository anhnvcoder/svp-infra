# Module `backup-vault`

Các vault AWS Backup mã hoá bằng một KMS key customer managed, mỗi vault có vault lock governance và vault access policy
tuỳ chọn. Thiết kế: [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §5, §6.
Root `aws/accounts/<env>` gọi module cho vault env `svp-<env>` (không lock, không access policy: recovery point bị xoá
mỗi cuối buổi); root `aws/backup` gọi module cho vault copy `svp-stg-copy`, `svp-prd-copy` (có lock, nhận copy từ đúng
account env tương ứng).

## Key đến từ root

Module nhận ARN key qua `kms_key_arn`, không tạo key. Key là tài nguyên của root vì Terraform không cho root đặt
`lifecycle` lên resource nằm trong module: root `aws/backup` giữ key của vault copy bằng `prevent_destroy`, root env thì
không. Key policy (statement chéo account cho account `svp-backup`) cũng do root viết. AWS Backup mã hoá recovery point
lưu hay copy vào vault bằng key của vault đó, nên bản copy dùng được cả khi key nguồn đã xoá.

## Tạo

Mỗi khoá của `vaults` là tên một vault (luật tên của API AWS Backup: 2 tới 50 chữ, số, `-`, `_`), với:

- `aws_backup_vault` mã hoá bằng `kms_key_arn`.
- `lock` khác `null`: `aws_backup_vault_lock_configuration` với `min_retention_days`, `max_retention_days`, không
  `changeable_for_days`: lock ở chế độ governance, người có quyền IAM `backup:DeleteBackupVaultLockConfiguration` gỡ
  được (gỡ lab); compliance không gỡ được sau grace time khi vault còn recovery point. Recovery point lưu vào vault phải
  có retention trong [`min_retention_days`, `max_retention_days`]. Validation: hai số nguyên, `1 ≤ min ≤ max ≤ 36500`
  (giới hạn của [`PutBackupVaultLockConfiguration`](https://docs.aws.amazon.com/aws-backup/latest/devguide/API_PutBackupVaultLockConfiguration.html)).
- `copy_from_account_ids` không rỗng: vault access policy một statement `Allow` `backup:CopyIntoBackupVault`,
  `Resource "*"`, principal `arn:aws:iam::<account>:root` của từng account đã cho, không điều kiện thêm. AWS Backup từ
  chối mọi action khác từ account khác bất kể vault policy, nên policy không cần statement `Deny`. Role nguồn cần thêm
  `backup:CopyIntoBackupVault` ở identity policy của nó.

Nguồn (đọc 2026-11-13): [Vault Lock](https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html), [vault
access policy](https://docs.aws.amazon.com/aws-backup/latest/devguide/create-a-vault-access-policy.html), [copy chéo
account](https://docs.aws.amazon.com/aws-backup/latest/devguide/create-cross-account-backup.html),
[CreateBackupVault](https://docs.aws.amazon.com/aws-backup/latest/devguide/API_CreateBackupVault.html).

## Xoá

AWS Backup chỉ xoá vault rỗng: destroy lỗi khi vault còn recovery point. Vault env được rút hết recovery point ở cuối
buổi trước destroy; vault copy sống giữa các buổi, giữ bản copy theo retention.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_backup_vault.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_backup_vault_lock_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault_lock_configuration) | resource |
| [aws_backup_vault_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault_policy) | resource |
| [aws_iam_policy_document.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| kms\_key\_arn | ARN of the customer managed KMS key that encrypts every vault of the module and the recovery points AWS Backup stores or copies into them. The key belongs to the calling root, which keeps its lifecycle and key policy. | `string` | n/a | yes |
| vaults | Vaults to make, by name. lock: governance-mode vault lock, retention in days every recovery point of the vault must keep (null: no lock). copy\_from\_account\_ids: 12-digit ids of the accounts allowed backup:CopyIntoBackupVault (empty: no vault access policy). | <pre>map(object({<br/>    lock = optional(object({<br/>      min_retention_days = number<br/>      max_retention_days = number<br/>    }))<br/>    copy_from_account_ids = optional(list(string), [])<br/>  }))</pre> | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| vault\_arns | ARN of each vault, by name: the target of a backup rule or of a copy action. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
