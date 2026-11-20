# Module `org-policies`

Mọi policy của AWS Organizations của lab: SCP, RCP, declarative policy EC2, tag policy và Backup policy, mỗi policy gắn đúng một đích
(root của tổ chức, OU `Prod` hay OU `NonProd`). Root [`aws/org`](../../org/README.md) gọi module một lần; loại policy phải bật ở tổ chức
trước (`enabled_policy_types` của root), module không bật. Vì sao từng policy, chúng chặn gì và trừ ai:
[03. Tổ chức](../../../docs/handbook/03-org.md). Test: `make test DIRS=aws/modules/org-policies` (provider giả).

## Ví dụ

```hcl
module "org_policies" {
  source = "../modules/org-policies"

  root_id           = "r-0000"
  prod_ou_id        = "ou-0000-00000001"
  nonprod_ou_id     = "ou-0000-00000002"
  organization_id   = "o-0000000000"
  backup_account_id = "000000000000"
}
```

Danh sách policy, nội dung, đích và retention của Backup policy ở `local.policies`, `local.backup_retention_days` của `main.tf`. Đổi đích
của một policy là thay `aws_organizations_policy_attachment` (khoá `for_each` giữ nguyên), không tạo lại policy.

## Tham chiếu

- [03. Tổ chức](../../../docs/handbook/03-org.md): SCP, RCP, declarative, tag policy, Backup policy; giới hạn và ngoại lệ ở mục Đọc sâu
  (ghi chú thiết kế mà `main.tf` trỏ tới).
- [Phụ lục ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0059-org-structure-guardrails.md): statement
  đủ của mọi policy, bảng đối chiếu RCP.
- [Phụ lục ADR-0067 §4](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#4-backup-policy): Backup
  policy.

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
| [aws_organizations_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy) | resource |
| [aws_organizations_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| backup\_account\_id | The account svp-backup (12 digits), whose vaults svp-<env>-copy receive the copy of every recovery point of the backup policies. | `string` | n/a | yes |
| nonprod\_ou\_id | The organizational unit (ou-...) of the non-production accounts, which the backup policy of stg is attached to. | `string` | n/a | yes |
| organization\_id | The id of the organization (o-...), the only one whose principals and services the resource control policy lets reach member account resources. | `string` | n/a | yes |
| prod\_ou\_id | The organizational unit (ou-...) of the production accounts, which the production guardrails are attached to. | `string` | n/a | yes |
| root\_id | The root of the organization (r-...): every policy but the production guardrails is attached here, so it applies to every member account (and, for the declarative and tag policies, to the management account too). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| policy\_ids | Id of each policy of the organization, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions, protect-baseline, deny-iam-users, prod-guardrails, data-perimeter, ec2-baseline, tags, backup-prd, backup-stg). |
<!-- END_TF_DOCS -->
