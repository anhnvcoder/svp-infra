# Module `backup-vault`

Các vault AWS Backup mã hoá bằng một KMS key customer managed mà root gọi giữ, mỗi vault có Vault Lock governance và vault access policy
cho copy chéo account khi cần. Root `aws/backup` gọi module cho hai vault copy `svp-stg-copy`, `svp-prd-copy` (có lock, nhận copy từ đúng
account env); root `aws/accounts/<env>` gọi cho vault env `svp-<env>` (không lock, không access policy). Vì sao key ở root, vì sao
governance: [07. Backup](../../../docs/handbook/07-backup.md); test: `make test DIRS=aws/modules/backup-vault`.

## Ví dụ

Lời gọi của `aws/backup/main.tf` (ở đó `vaults` là `local.copy_vaults`), giá trị là placeholder:

```hcl
module "vaults" {
  source = "../modules/backup-vault"

  kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  vaults = {
    svp-stg-copy = {
      lock                  = { min_retention_days = 1, max_retention_days = 7 }
      copy_from_account_ids = ["000000000000"]
    }
    svp-prd-copy = {
      lock                  = { min_retention_days = 7, max_retention_days = 35 }
      copy_from_account_ids = ["000000000000"]
    }
  }
}
```

Vault env chỉ cần tên: `vaults = { "svp-<env>" = {} }`.

## Tham chiếu

- [07. Backup](../../../docs/handbook/07-backup.md): Vault Lock, copy chéo account, key của vault; key ở root và vault chỉ xoá khi rỗng ở
  mục Đọc sâu (ghi chú thiết kế mà `main.tf` trỏ tới).
- [Phụ lục ADR-0067 §5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#5-vault-copy-alarm): vault
  access policy, lock, nguồn tài liệu AWS.

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
