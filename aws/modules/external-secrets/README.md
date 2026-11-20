# Module `external-secrets`

Nguồn Secret của cluster EKS một env trong AWS Secrets Manager và quyền đọc chúng của External Secrets Operator: vỏ entry
`svp/<env>/<entry>` (không giá trị, xoá ngay khi `destroy`), role `svp-<env>-external-secrets` của controller qua EKS Pod Identity và
role `svp-<env>-external-secrets-<namespace>` chỉ `GetSecretValue` đúng các entry namespace đó dùng. Hai root `aws/envs/<env>` gọi
module; luồng secret và kịch bản ở chương [10. EKS](../../../docs/handbook/10-eks.md); test: `make test DIRS=aws/modules/external-secrets`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`:

```hcl
module "external_secrets" {
  source = "../../modules/external-secrets"

  env              = "stg"
  cluster_name     = "svp-stg"
  grafana_operator = false
}
```

`grafana_operator`: cờ `managed_grafana` của env khác `off` ([`paid-features`](../paid-features/README.md)). Map namespace → entry
(`local.namespace_entries`, chép lại có chủ đích ở `tests/policies.tftest.hcl`) lấy từ render của chart `svp-cluster` ở `origin/main`,
giải nén bằng `git archive` vào một thư mục trống:

```sh
helm template svp-cluster deploy/helm/svp-cluster --namespace svp --show-only templates/external-secrets.yaml \
  --set externalSecrets.enabled=true --set externalSecrets.store=aws --set externalSecrets.prefix=svp/stg/ \
  --set s3.mode=external --set externalSecrets.argocdNotifications=true --set externalSecrets.localKafkaValkey=false \
  --set externalSecrets.grafanaOperator=true --set externalSecrets.mediaSigning=true \
  --set externalSecrets.aws.region=ap-southeast-1 --set externalSecrets.aws.roles.<namespace>=<arn>   # mỗi namespace
```

## Tham chiếu

- [10. EKS](../../../docs/handbook/10-eks.md): ghi chú thiết kế mà `main.tf` trỏ tới (kịch bản, Luồng secret, Đọc sâu).
- [ADR-0026](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0026-secrets-gitops.md): secret trên đường GitOps.

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
| [aws_eks_pod_identity_association.controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.namespace](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.namespace](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_secretsmanager_secret.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.controller_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.namespace](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.namespace_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_name | Name of the EKS cluster (output cluster\_name of the eks module) whose External Secrets controller gets the role through EKS Pod Identity. | `string` | n/a | yes |
| env | Environment of the entries and roles: entries are svp/<env>/<entry>, roles svp-<env>-external-secrets and svp-<env>-external-secrets-<namespace>. | `string` | n/a | yes |
| grafana\_operator | Whether the env has a Grafana workspace (flag managed\_grafana of aws/paid-features.json not off): the entry grafana-operator, the token of Grafana Operator, and its read by the SecretStore role of svp-obs exist only then. | `bool` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| roles | ARN of the IAM role of each namespace's SecretStore, by namespace: key externalSecretsRoles of the cluster values. |
| secret\_arns | ARN of each Secrets Manager entry, by entry name (the secret is svp/<env>/<entry>). |
<!-- END_TF_DOCS -->
