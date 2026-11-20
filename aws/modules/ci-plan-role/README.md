# Module `ci-plan-role`

Role IAM `svp-ci-terraform-plan` của một account env (`svp-stg`, `svp-prd`) mà job `plan` của workflow `plan.yml` assume qua OIDC để
chạy `terraform plan` trên PR: `ReadOnlyAccess`, policy inline đọc state qua S3, policy inline Deny dữ liệu workload và mọi ghi lên bucket
state. Root [`aws/accounts/<env>`](../../accounts/README.md) gọi module, nên role sống giữa các buổi. Lý do, trust theo `sub` và luồng
đọc state ở [chương 14. CI](../../../docs/handbook/14-ci.md#role-plan-svp-ci-terraform-plan); bảng Deny ở
[`docs/reference/ci.md`](../../../docs/reference/ci.md#quyền-của-role-plan).

## Ví dụ

Lời gọi trong `aws/accounts/stg/main.tf`, giá trị placeholder:

```hcl
module "ci_plan_role" {
  source = "../../modules/ci-plan-role"

  env               = "stg"
  oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com" # module.registry
  subject           = "repo:<owner>@<owner-id>/svp-infra@<repo-id>:environment:terraform-plan"
  state_bucket      = "svp-tfstate-000000000000-ap-southeast-1"                                      # module.baseline
  state_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/<key-id>"                         # module.baseline
}
```

Key policy của khoá state cần statement `CiPlanReadsState` cho đúng role này (module
[`account-baseline`](../account-baseline/README.md)): thiếu nó thì role không giải mã được state. `tests/ci-plan-role.tftest.hcl` (mock
provider, chỉ `plan`) kiểm trust, phiên, hai policy inline và mỗi luật validation (`make test DIRS=aws/modules/ci-plan-role`).

## Tham chiếu

- [Chương 14. CI](../../../docs/handbook/14-ci.md): plan trên PR, bảo mật của CI, role plan.
- [`docs/reference/ci.md`](../../../docs/reference/ci.md#plan-trên-pr): root được plan, giá trị che, duyệt lượt chờ, quyền của role.
- [ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §4–§6: thiết kế,
  tập Deny, kiểm kê refresh.

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
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.deny](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.deny](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| env | Environment of the account (stg, prd): picks the two state keys the role may read and the media bucket svp-<env>-media-<account>-<region>. | `string` | n/a | yes |
| oidc\_provider\_arn | ARN of the IAM OIDC provider of GitHub Actions in this account (github\_oidc\_provider\_arn of the registry module): the only principal the trust accepts. | `string` | n/a | yes |
| state\_bucket | Bucket of the Terraform state of this account, svp-tfstate-<account>-<region> (state\_bucket of the account-baseline module): the role reads two of its keys and writes nothing in it. | `string` | n/a | yes |
| state\_kms\_key\_arn | ARN of the KMS key of the state, arn:aws:kms:<region>:<account>:key/<key-id> (state\_kms\_key\_arn of the account-baseline module). IAM matches a key by its key ARN only, never by an alias ARN. | `string` | n/a | yes |
| subject | The one sub claim the trust accepts, in the immutable form of a job that names an environment: repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<name>. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| role\_arn | ARN of the role svp-ci-terraform-plan, which the plan workflow of svp-infra assumes through OIDC. |
<!-- END_TF_DOCS -->
