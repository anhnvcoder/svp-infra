# Module `external-secrets`

Nguồn Secret của cluster EKS một env trong AWS Secrets Manager và quyền đọc chúng của External Secrets Operator (ESO): vỏ entry
`svp/<env>/<entry>`, role IAM của controller ESO qua EKS Pod Identity và một role IAM cho SecretStore của mỗi namespace. Hai root env
(`aws/envs/stg`, `aws/envs/prd`) gọi module với cùng đối số `env`, `cluster_name`.

## Entry

- Module chỉ tạo vỏ entry (`aws_secretsmanager_secret`), không có `aws_secretsmanager_secret_version`. Giá trị của `kafka-admin`,
  `kafka-users` do module [`msk`](../msk/README.md), của `valkey-users` do module [`elasticache`](../elasticache/README.md) ghi trong cùng
  apply với mật khẩu chúng đặt cho user, qua đối số write-only (root truyền ARN entry từ output `secret_arns`); giá trị của entry khác do
  người học ghi bằng script `make eks-secrets` của repo code sau khi apply root env. Không giá trị nào nằm trong plan hay state.
- Mã hoá bằng key AWS quản lý của Secrets Manager: mọi người đọc đều là role của module này, key do khách hàng quản lý không vạch thêm ranh
  giới nào mà thêm key policy và phí hằng tháng.
- `recovery_window_in_days = 0`: `destroy` xoá entry ngay. Ngoại lệ của lab: env dựng lại mỗi buổi với cùng tên entry, entry còn chờ hết hạn
  khôi phục sẽ chặn lần apply sau; giá trị được ghi lại ở buổi sau.

## Ai đọc entry nào

- Map namespace → entry (`local.namespace_entries` ở `main.tf`) là các `remoteRef` key của ExternalSecret mà chart `svp-cluster` của repo
  code render với store `aws`, object store managed (`s3.mode: external`), Kafka và Valkey ngoài cluster
  (`externalSecrets.localKafkaValkey: false`) và Argo CD notifications bật. Khi đó chart không render entry của object store trong
  cluster (`s3-root`, `s3-users`, `pg-backup-s3`) hay của CA local (`local-ca`, `local-tls`), nên map không có chúng. Map chép từ render
  của `origin/main`, chart giải nén bằng `git archive` vào một thư mục trống:

  ```sh
  helm template svp-cluster deploy/helm/svp-cluster --namespace svp --show-only templates/external-secrets.yaml \
    --set externalSecrets.enabled=true --set externalSecrets.store=aws --set externalSecrets.prefix=svp/stg/ \
    --set s3.mode=external --set externalSecrets.argocdNotifications=true --set externalSecrets.localKafkaValkey=false \
    --set externalSecrets.aws.region=ap-southeast-1 --set externalSecrets.aws.roles.<namespace>=<arn>   # mỗi namespace
  ```

  Thêm Secret vào `files/external-secrets.yaml` của chart thì thêm entry vào map, nếu không ExternalSecret đó bị AWS từ chối.
- Role controller `svp-<env>-external-secrets`: chỉ EKS Pod Identity assume được (principal `pods.eks.amazonaws.com`), trust đòi session
  tag đúng cluster, namespace `external-secrets` và ServiceAccount `external-secrets` (controller của `base/external-secrets.yaml` trong
  `svp-gitops`); association Pod Identity gắn ServiceAccount đó với role. Role không đọc entry nào, chỉ được `sts:AssumeRole` +
  `sts:TagSession` lên năm role namespace (session tag của Pod Identity là transitive nên lần assume tiếp theo mang chúng theo và cần
  `sts:TagSession`).
- Role namespace `svp-<env>-external-secrets-<namespace>` (`svp`, `svp-data`, `svp-obs`, `keda`, `argocd`): chỉ tin role controller, chỉ được
  `secretsmanager:GetSecretValue` trên đúng các entry namespace đó đọc. ExternalSecret đọc một key của entry không gọi API nào khác
  (`DescribeSecret` chỉ khi `metadataPolicy: Fetch`, `ListSecrets`/`BatchGetSecretValue` chỉ với `dataFrom.find`, chart không dùng).
  Output `roles` (namespace → ARN) là khoá `externalSecretsRoles` của cluster values.
- Resource của policy là ARN entry viết theo tên, đuôi `-??????`: Secrets Manager gắn vào tên một dấu gạch và sáu ký tự ngẫu nhiên để thành
  ARN, `??????` khớp đúng sáu ký tự đó nên mẫu chỉ khớp một entry (không `*`). ARN role cũng dựng từ tên. Nhờ vậy policy biết lúc `plan` và
  test kiểm được nội dung; role namespace `depends_on` role controller vì IAM từ chối trust policy có principal chưa tồn tại.

## Test

`tests/policies.tftest.hcl` (mock provider, chỉ `plan`) chép lại map namespace → entry và kiểm: tên entry, `recovery_window_in_days`, mỗi
role namespace chỉ `GetSecretValue` đúng entry của mình (không `*`), trust của role namespace chỉ có role controller, trust của role
controller chỉ Pod Identity với ba session tag, association và quyền assume của controller; một run cho prd và một run mỗi luật validation.
Map được chép lại ở file test có chủ đích: đổi ai đọc entry nào thì phải đổi cả hai nơi.

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

## Outputs

| Name | Description |
| ---- | ----------- |
| roles | ARN of the IAM role of each namespace's SecretStore, by namespace: key externalSecretsRoles of the cluster values. |
| secret\_arns | ARN of each Secrets Manager entry, by entry name (the secret is svp/<env>/<entry>). |
<!-- END_TF_DOCS -->
