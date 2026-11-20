# Module `registry`

Registry ECR private của một account env (`svp-stg`, `svp-prd`): repo phát hành theo `local.release_repositories`, rule pull-through
cache theo `local.cache_rules` cùng vỏ secret và repository creation template, cấu hình quét image cache, key `alias/svp-<env>-ecr`, IAM
OIDC provider của GitHub Actions và mỗi mục của `ci_roles` một role chép bản phát hành. Root `aws/accounts/<env>`
([README](../../accounts/README.md)) gọi module nên registry sống qua `destroy` của buổi; luồng image và lý do:
[08. Account env](../../../docs/handbook/08-accounts.md#amazon-ecr-repo-phát-hành-quét). Test: `make test DIRS=aws/modules/registry`.

## Ví dụ

Lời gọi của `aws/accounts/stg/main.tf` (ở đó `ci_roles` là `local.ci_roles`, `enhanced_scanning` đọc cờ `inspector_ecr`), giá trị là
placeholder:

```hcl
module "registry" {
  source = "../../modules/registry"

  env = "stg"
  ci_roles = {
    svp-ci-ecr-release-backend = {
      subject      = "repo:<owner>@<owner-id>/svp-backend@<repo-id>:ref:refs/heads/main"
      repositories = ["svp-backend/*"]
      delete       = false
    }
  }
  enhanced_scanning = false
}
```

Thêm service ở `files/sources.json` của chart `svp-policy` thì thêm repo ở `local.release_repositories` (`main.tf`), nếu không bước chép
vào ECR bị từ chối. Giá trị secret cache (khoá `username`, `accessToken`) do người học ghi bằng `aws/scripts/cache-secrets.sh`.

## Tham chiếu

- [08. Account env](../../../docs/handbook/08-accounts.md): repo phát hành, quét, pull-through cache, role CI; key, template, ARN dựng
  từ tên ở mục Đọc sâu (ghi chú thiết kế mà `main.tf` và test trỏ tới).
- [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md): registry, cache, bảng **Role CI
  ECR** (§5), quét (§10); policy và nguồn ở phụ lục của nó.

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
| [aws_ecr_pull_through_cache_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_pull_through_cache_rule) | resource |
| [aws_ecr_registry_scanning_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_registry_scanning_configuration) | resource |
| [aws_ecr_repository.release](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_ecr_repository_creation_template.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_secretsmanager_secret.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ci_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ecr_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.template_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| ci\_roles | IAM roles GitHub Actions assumes through OIDC to copy releases into this registry, by role name. subject is the one sub claim the trust accepts (repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/<branch> or :environment:<name>); repositories are release repositories (svp-backend/gateway) or a whole group of them (svp-backend/*); delete adds ecr:BatchDeleteImage on them. | <pre>map(object({<br/>    subject      = string<br/>    repositories = list(string)<br/>    delete       = bool<br/>  }))</pre> | n/a | yes |
| enhanced\_scanning | Whether Amazon Inspector scans the cached repositories (ENHANCED, CONTINUOUS\_SCAN). false scans them with free ECR basic scanning (BASIC, SCAN\_ON\_PUSH), for an account whose Inspector ECR scanning is off; the filter is the same. | `bool` | `true` | no |
| env | Environment of the account (stg, prd): names the KMS key alias/svp-<env>-ecr and the role svp-<env>-ecr-template. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| cache\_prefixes | Repository prefixes of the pull through cache rules (ghcr, docker-hub, quay, k8s, ecr-public): nodes import and create repositories under <prefix>/*. |
| ci\_role\_arns | ARN of each role of ci\_roles, by role name. |
| github\_oidc\_provider\_arn | ARN of the IAM OIDC provider of GitHub Actions in the account: the principal of the trust of every role GitHub Actions assumes here. |
| kms\_key\_arn | ARN of the KMS key alias/svp-<env>-ecr that encrypts every repository of the registry. |
| registry\_host | Host of the private registry of the account, <account>.dkr.ecr.<region>.amazonaws.com: key ecrRegistry of the cluster values. |
| release\_repository\_arns | ARN of each release repository, by repository name (svp-backend/gateway, svp-frontend/web). |
<!-- END_TF_DOCS -->
