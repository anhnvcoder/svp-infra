# Module `eks`

Cluster EKS của một env, bọc `terraform-aws-modules/eks/aws` (version ghim ở `cluster.tf`): control plane chỉ endpoint private theo
mặc định, access entry, nhóm node `system` on-demand Graviton, add-on ghim version, KMS key cho Secret; submodule `karpenter`; role Pod
Identity của controller nền tảng, quyền pull-through cache của node. Root `aws/envs/<env>` gọi module; lý do ở chương
[10. EKS](../../../docs/handbook/10-eks.md); test: `make test DIRS=aws/modules/eks`.

## Ví dụ

Lời gọi của `aws/envs/stg/main.tf`, rút gọn, giá trị placeholder; sáu biến cuối là tài nguyên của `aws/accounts/<env>`:

```hcl
module "eks" {
  source = "../../modules/eks"

  name                       = "svp-stg"
  kubernetes_version         = "1.36"
  vpc_id                     = "vpc-<id>"
  private_subnet_ids         = ["subnet-<a>", "subnet-<b>"]
  secrets_kms_encryption     = true
  guardduty_data_endpoint_id = "vpce-<id>"
  system_node_max_size       = 4

  amp_workspace_arn         = "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-<id>"
  log_group_arn             = "arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel"
  observability_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  ecr_kms_key_arn           = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  release_repository_arns   = ["arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-backend/gateway"]
  ecr_cache_prefixes        = ["ghcr", "docker-hub", "quay", "k8s", "ecr-public"]
}
```

## Nâng version bằng tay

AMI của nhóm `system` (`local.ami_release_version` ở `nodes.tf`) và `addon_version` của mọi add-on (`addons.tf`) ghim, nên stg và prd
chạy cùng bản; `kubernetes_version` chỉ nhận đúng minor của AMI ghim. Renovate không nâng chúng (datasource cần credential AWS): nâng
minor thì đổi cả ba cùng alias AMI của EC2NodeClass ở `svp-gitops` trong một thay đổi, theo
[`eks-upgrade.md`](../../../docs/runbooks/eks-upgrade.md).

## Tham chiếu

- [10. EKS](../../../docs/handbook/10-eks.md): ghi chú thiết kế mà `cluster.tf`, `security-groups.tf` trỏ tới (endpoint, KMS, Pod
  Identity, cổng control plane tới node, tài nguyên ngoài state ở mục Đọc sâu).
- [ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md): node, Karpenter, add-on, version ghim.
- [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §9: quyền role controller.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.59 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.59 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| eks | terraform-aws-modules/eks/aws | 21.29.0 |
| karpenter | terraform-aws-modules/eks/aws//modules/karpenter | 21.29.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_addon.guardduty_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_pod_identity_association.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_policy.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.node_ecr_cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ack_prometheusservice](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.argo_rollouts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.karpenter_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.kyverno_admission](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.node_ecr_cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.opencost](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.otel_collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.prometheus_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| amp\_workspace\_arn | ARN of the Amazon Managed Service for Prometheus workspace of the env (output amp\_workspace\_arn of the observability module): the Collector and the Prometheus agent write to it, Argo Rollouts and OpenCost query it, the ACK controller manages its rules and alert manager definition. | `string` | n/a | yes |
| control\_plane\_log\_retention\_days | Days CloudWatch keeps the control plane logs when control\_plane\_log\_types is not empty. | `number` | `1` | no |
| control\_plane\_log\_types | Control plane logs sent to CloudWatch, e.g. ["api", "audit"]. Empty (the default) sends none and creates no log group: ingestion is billed per GB. | `list(string)` | `[]` | no |
| ecr\_cache\_prefixes | Repository prefixes of the pull through cache rules of the env's registry (output cache\_prefixes of the registry module). Nodes may import images and create repositories under <prefix>/* only. | `list(string)` | n/a | yes |
| ecr\_kms\_key\_arn | ARN of the KMS key alias/svp-<env>-ecr (output kms\_key\_arn of the registry module), which encrypts every repository of the env's registry. Nodes may decrypt with it only through ECR of the region when they pull an image. | `string` | n/a | yes |
| endpoint\_public\_access | Open the public endpoint of the Kubernetes API, reachable only from endpoint\_public\_access\_cidrs. The private endpoint is always on, so nodes and pods reach the API inside the VPC either way. | `bool` | `false` | no |
| endpoint\_public\_access\_cidrs | IPv4 ranges allowed to call the public endpoint of the Kubernetes API, e.g. the address of the learner's machine as a /32. Personal data of a public repository: set it in an uncommitted *.auto.tfvars or TF\_VAR\_endpoint\_public\_access\_cidrs. | `list(string)` | `[]` | no |
| guardduty\_data\_endpoint\_id | ID of the interface endpoint guardduty-data of the VPC (output guardduty\_data\_endpoint\_id of the network module). The GuardDuty agent add-on is created after it, so the agent's first reports have a way out. | `string` | n/a | yes |
| kubernetes\_version | Kubernetes minor version of the control plane and of the node group, e.g. 1.36. Pick a minor in standard support: the cluster is created with the STANDARD support policy. | `string` | n/a | yes |
| log\_group\_arn | ARN, without a trailing :*, of the log group /svp/<env>/otel of the observability module (output log\_group\_arn). The Collector writes to its stream otel-collector. | `string` | n/a | yes |
| name | Name of the EKS cluster, e.g. svp-stg, and prefix of the names of its IAM roles, policies, security groups and node group. | `string` | n/a | yes |
| observability\_kms\_key\_arn | ARN of the KMS key alias/svp-<env>-observability (output kms\_key\_arn of the observability module), which encrypts the log group the Collector writes to. | `string` | n/a | yes |
| private\_subnet\_ids | Private subnets of the VPC, one per availability zone (output private\_subnet\_ids of the network module). The control plane's network interfaces and the nodes go into every one of them, so pods spread over all these zones. | `list(string)` | n/a | yes |
| release\_repository\_arns | ARNs of the release repositories of the env's registry (values of output release\_repository\_arns of the registry module). The Kyverno admission controller reads images, signatures and attestations there. | `list(string)` | n/a | yes |
| secrets\_kms\_encryption | Envelope-encrypt Kubernetes Secrets with a customer managed KMS key the module creates (alias <name>-eks-secrets, rotated yearly, 7-day deletion window). Off by default: EKS encrypts them with an AWS owned key, and a key of our own costs a month's fee and outlives the cluster for the deletion window. | `bool` | `false` | no |
| system\_node\_instance\_type | Graviton (arm64) instance type of the system node group, On-Demand in every env. It holds what runs before Karpenter has a node of its own (add-ons, Argo CD, Karpenter), one replica of Karpenter per node. | `string` | `"m7g.large"` | no |
| system\_node\_max\_size | Largest number of nodes of the system node group, room to scale it by hand. It starts with one node per zone (the number of private\_subnet\_ids) and nothing scales it on its own. | `number` | n/a | yes |
| vpc\_id | ID of the VPC of the cluster (output vpc\_id of the network module). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_certificate\_authority\_data | Certificate authority of the Kubernetes API server, base64-encoded PEM: cluster.certificate-authority-data of a kubeconfig, cluster\_ca\_certificate (after base64decode) of the helm and kubernetes providers. |
| cluster\_endpoint | URL of the Kubernetes API server. |
| cluster\_name | Name of the EKS cluster: clusterName of the AWS Load Balancer Controller, aws eks update-kubeconfig --name. |
| cluster\_primary\_security\_group\_id | Security group EKS creates for the cluster and attaches to the control plane's network interfaces. |
| cluster\_security\_group\_id | Security group the module adds to the control plane's network interfaces. |
| cluster\_service\_cidr | IPv4 range of Kubernetes Services, chosen by EKS when the cluster is created; the API server's Service takes its first address. |
| karpenter\_node\_iam\_role\_name | IAM role of the nodes Karpenter launches: spec.role of the EC2NodeClass (Karpenter makes the instance profile from it). |
| karpenter\_queue\_name | SQS queue of the interruption events Karpenter handles (Spot interruption, rebalance, health, state change): settings.interruptionQueue of the Karpenter chart. |
| node\_security\_group\_id | Security group of every node and, with the VPC CNI, of every pod: the source a database security group lets in. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
