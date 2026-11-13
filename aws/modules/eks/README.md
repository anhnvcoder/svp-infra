# `aws/modules/eks`: cluster EKS của một env

Module nội bộ mỏng bọc [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.29.0)
**21.29.0** (ghim chính xác): control plane, nhóm node hệ thống (managed node group Graviton on-demand), addon EKS, security group, IAM của
cluster và node; submodule `karpenter` cùng version tạo IAM, hàng đợi interruption và rule EventBridge cho Karpenter; module nội bộ thêm role
IAM và association EKS Pod Identity cho hai controller nền tảng (Load Balancer Controller, EBS CSI driver) và năm workload nền tảng
(Collector, Prometheus agent, ACK, Kyverno, Argo Rollouts), cùng quyền pull-through cache của role node; không controller nào của cluster
ghi DNS. Mức stg và prd chỉ khác ở biến (bảng dưới), một bộ code. Thiết kế node, Karpenter và version ghim: [ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md).

Không có provider nào trong module (kể cả provider Kubernetes hay Helm: StorageClass `gp3` mặc định do chart `svp-cluster` render, controller
do Argo CD cài): root gọi nó (`aws/envs/<env>`) đặt provider, `default_tags` và ghim version provider (`~> 6.59`) trong lock file. Module không
cấp quyền nào cho pod của `svp` (role của video-service, media-worker ở root env).

Secret của Kubernetes: mặc định EKS mã hoá dữ liệu API (gồm Secret) bằng key do AWS sở hữu, không tốn phí. `secrets_kms_encryption = true`
(mức prd) cho module registry tạo KMS key riêng (chính sách key mặc định của module registry: account, danh tính chạy `apply` là quản trị,
role của cluster là người dùng; xoay key hằng năm), alias `<name>-eks-secrets` (cạnh alias `eks/<name>` của module registry), cửa sổ xoá
7 ngày, và mã hoá phong bì Secret bằng nó: đọc Secret cần thêm `kms:Decrypt` trên key đó. Ngoại lệ trivy AWS-0039 trong module có điều kiện
`create_kms_key=false`; root của env để key tắt đặt lại ngoại lệ ở lời gọi module (trivy không khớp điều kiện bool khi quét từ root, xem
`.trivyignore.yaml`). Endpoint công khai của API tắt được (`endpoint_public_access = false`, khi đó không cần `endpoint_public_access_cidrs`);
output `cluster_endpoint`, `cluster_certificate_authority_data` cho provider `helm`, `kubernetes` của root bootstrap.

```hcl
module "eks" {
  source = "../../modules/eks"

  name                         = "svp-stg"
  kubernetes_version           = "1.36"
  vpc_id                       = module.network.vpc_id
  private_subnet_ids           = module.network.private_subnet_ids
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs # *.auto.tfvars không commit
  system_node_max_size         = 4
  guardduty_data_endpoint_id   = module.network.guardduty_data_endpoint_id

  amp_workspace_arn         = "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"
  log_group_arn             = "arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel"
  observability_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
  ecr_kms_key_arn           = "arn:aws:kms:ap-southeast-1:000000000000:key/89abcdef-0123-4567-89ab-cdef01234567"
  release_repository_arns   = ["arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-backend/gateway"]
  ecr_cache_prefixes        = ["ghcr", "docker-hub", "quay", "k8s", "ecr-public"]
}
```

Sáu biến cuối là tài nguyên sống lâu của root `aws/accounts/<env>` (module `observability`, `registry`); root env đọc chúng bằng data
source theo tên suy từ `svp-<env>`, không ghi cứng ARN như ví dụ.

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
| [aws_iam_policy_document.otel_collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.prometheus_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| amp\_workspace\_arn | ARN of the Amazon Managed Service for Prometheus workspace of the env (output amp\_workspace\_arn of the observability module): the Collector and the Prometheus agent write to it, Argo Rollouts queries it, the ACK controller manages its rules and alert manager definition. | `string` | n/a | yes |
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

## Giá trị theo env

| Biến | stg | prd |
| --- | --- | --- |
| `name` | `svp-stg` | `svp-prd` |
| `kubernetes_version` | `1.36` | như stg lúc dựng |
| `vpc_id` | output `vpc_id` của `network` | như stg |
| `private_subnet_ids` | 2 subnet private | 3 subnet private |
| `endpoint_public_access` | `true` | `true` hay `false` (chốt khi dựng prd) |
| `endpoint_public_access_cidrs` | CIDR của người học (`/32`) | CIDR của người học hay `[]` |
| `control_plane_log_types` | `[]` (tắt) | `["api", "audit"]` |
| `control_plane_log_retention_days` | (không dùng) | chốt khi dựng prd |
| `system_node_instance_type` | mặc định | như stg |
| `system_node_max_size` | 2 × số AZ | 2 × số AZ |
| `amp_workspace_arn`, `log_group_arn`, `observability_kms_key_arn` | workspace AMP, log group `/svp/stg/otel`, khoá của `observability` stg | như stg, của prd |
| `ecr_kms_key_arn`, `release_repository_arns`, `ecr_cache_prefixes` | khoá, repo phát hành, tiền tố cache của `registry` stg | như stg, của prd |

Endpoint public mặc định tắt để module an toàn khi gọi thiếu biến; root của stg bật và đưa CIDR. **Vì sao private luôn bật:** giới hạn
CIDR public mà tắt private thì node trong subnet private gọi API qua IP của NAT, IP đó không nằm trong danh sách, node không join được
(tài liệu EKS khuyên bật private khi giới hạn CIDR). Pod tới API qua ENI của control plane trong VPC, cổng 443.

**Node:** nhóm node hệ thống `system` chạy on-demand ở mọi env, mỗi AZ một node (min = desired = số subnet private), không taint, không gì
tự scale nó; nó giữ những gì phải chạy trước khi Karpenter có node (addon, Argo CD, chính Karpenter). Node cho workload do Karpenter dựng
theo pod đang chờ (NodePool, EC2NodeClass của chart `svp-cluster`), không nằm trong state. Module EKS bỏ qua thay đổi `desired_size` sau khi
tạo, nên scale tay nhóm hệ thống bằng lệnh người học chạy, không bằng biến:
`AWS_PROFILE=anhnv-stg aws eks update-nodegroup-config --cluster-name svp-stg --nodegroup-name <tên node group> --scaling-config minSize=2,maxSize=4,desiredSize=3 --region ap-southeast-1`
(tên node group: `aws eks list-nodegroups --cluster-name svp-stg --region ap-southeast-1`, có tiền tố `system-`).

**Version ghim:** AMI của nhóm hệ thống (`local.ami_release_version` ở `nodes.tf`, `use_latest_ami_release_version = false`) và `addon_version`
của mọi addon (`addons.tf`) ghim, nên stg và prd chạy cùng bản. `kubernetes_version` chỉ nhận đúng minor của bản AMI ghim (validation):
nâng minor thì đổi cả ba trong cùng thay đổi, cùng alias AMI của EC2NodeClass ở chart `svp-cluster`, theo runbook `docs/runbooks/eks-upgrade.md`.
Renovate không cập nhật chúng: datasource của addon và AMI cần credential AWS.

Không output OIDC: không dùng IRSA (`enable_irsa = false`), Pod Identity không cần OIDC provider.

## Bên trong: module cộng đồng tạo gì với cấu hình này

Đọc từ code của `terraform-aws-eks` v21.29.0 (`main.tf`, `node_groups.tf`, `modules/eks-managed-node-group/`), vì `terraform plan` chỉ
người học chạy.

| Tài nguyên | Tên | Vì sao |
| --- | --- | --- |
| `aws_eks_cluster` | `<name>` | `authentication_mode = "API"` (chỉ access entry, không ConfigMap `aws-auth`), `bootstrap_self_managed_addons = false` (không cài vpc-cni, CoreDNS, kube-proxy tự quản: chúng là addon ở dưới), `upgrade_policy.support_type = STANDARD` (hết standard support thì EKS nâng minor thay vì sang extended support, phí control plane ×6), không `encryption_config` |
| IAM role của cluster | `<name>-cluster-<hậu tố>` | EKS (`eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`) quản ENI, security group của control plane; gắn `AmazonEKSClusterPolicy` |
| Access entry + policy association | `cluster_creator` | identity chạy `apply` (role SSO của người học, đọc bằng `aws_iam_session_context` lúc plan) nhận `AmazonEKSClusterAdminPolicy` phạm vi cluster; không ARN nào ghi trong git |
| Security group cluster | `<name>-cluster-<hậu tố>` | gắn vào ENI của control plane, nhận 443 từ security group node |
| Security group node | `<name>-node-<hậu tố>`, tag `kubernetes.io/cluster/<name>=owned`, `karpenter.sh/discovery=<name>` | gắn vào mọi node (và vì VPC CNI, vào mọi pod); rule ở mục Cổng dưới đây |
| Tag trên security group chính | `aws_ec2_tag` | chép tag của module (`Project=svp`) lên security group EKS tự tạo |
| `time_sleep` | | chờ 30 s sau khi control plane xong rồi mới tạo node group và addon thường |
| IAM role của node | `system-eks-node-group-<hậu tố>` | EC2 assume; gắn `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly` và `AmazonEKS_CNI_Policy` (VPC CNI dùng role của node: pod thường không tới được IMDS, xem IMDS dưới đây) |
| Launch template | `system-<hậu tố>` | AMI `AL2023_ARM_64_STANDARD` bản ghim, IMDSv2 bắt buộc, hop limit 1, ổ gốc gp3 30 GiB mã hoá; tag `Project=svp` lên instance, volume, ENI |
| `aws_eks_node_group` | `system-<hậu tố>` | `ON_DEMAND`, `release_version` ghim, loại instance và `max_size` theo biến; trải mọi subnet private |
| `aws_eks_addon` | 6 addon | mục Addon (`aws-guardduty-agent` do module nội bộ tạo, ngoài module cộng đồng) |
| Log group CloudWatch | `/aws/eks/<name>/cluster` | chỉ khi `control_plane_log_types` khác rỗng, retention theo biến |

Submodule `karpenter` (`modules/karpenter/main.tf`, `policy.tf`), tên nguyên văn (`*_use_name_prefix = false`) vì chart Karpenter và
EC2NodeClass suy tên từ tên cluster:

| Tài nguyên | Tên | Vì sao |
| --- | --- | --- |
| IAM role controller | `<name>-karpenter` | trust `pods.eks.amazonaws.com`, statement `PodIdentity` thay bằng statement của module nội bộ (`karpenter.tf`): chỉ cluster này, `kube-system` / `karpenter` như bốn role dưới; policy `<name>-karpenter-<hậu tố>` của submodule giữ nguyên: `RunInstances`, `CreateFleet`, `CreateLaunchTemplate`, tag, xoá chỉ trên tài nguyên mang `kubernetes.io/cluster/<name>=owned`; `iam:PassRole` role node chỉ cho EC2; tạo, xoá instance profile theo tag cluster; đọc, xoá message của hàng đợi; `eks:DescribeCluster`, đọc giá, SSM, Describe EC2 |
| Pod Identity association | `kube-system` / `karpenter` | do submodule tạo (`create_pod_identity_association` mặc định); không nằm trong `local.pod_identity` |
| IAM role node | `<name>-karpenter-node` | EC2 assume; `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`, `AmazonEKS_CNI_Policy`; EC2NodeClass đặt `spec.role` là tên này, Karpenter tự tạo instance profile |
| Access entry | role node, loại `EC2_LINUX` | node Karpenter dựng join được cluster |
| Hàng đợi SQS | `<name>-karpenter` | sự kiện interruption (Spot, rebalance, health, đổi trạng thái), giữ 5 phút, mã hoá SSE-SQS, policy chỉ cho EventBridge gửi và chặn không TLS |
| Rule EventBridge | `Karpenter<sự kiện>-<hậu tố>` (5 rule) | đẩy sự kiện vào hàng đợi |

Module cộng đồng **không** tạo: KMS key (`create_kms_key = false`: $1/tháng mỗi key và còn sống qua thời gian chờ xoá; EKS mã hoá dữ liệu
API, gồm Secret, bằng key do AWS sở hữu theo mặc định), OIDC provider (`enable_irsa = false`), Fargate profile, node group tự quản.

**Module nội bộ tạo thêm** (`iam.tf`, `pod-identity.tf`):

| Controller | Namespace / ServiceAccount | Role | Quyền |
| --- | --- | --- | --- |
| AWS Load Balancer Controller | `kube-system` / `aws-load-balancer-controller` | `<name>-aws-load-balancer-controller` | managed policy cùng tên, nội dung là `docs/install/iam_policy.json` của tag **v3.6.2** giữ nguyên ở `policies/aws-load-balancer-controller-v3.6.2.json`; chart `eks/aws-load-balancer-controller` phải ghim **3.6.2** (appVersion v3.6.2), nâng controller thì thay file bằng policy của tag mới trong cùng thay đổi |
| EBS CSI driver | `kube-system` / `ebs-csi-controller-sa` | `<name>-ebs-csi-driver` | managed `service-role/AmazonEBSCSIDriverPolicy`; association do chính addon tạo (`pod_identity_association`) |
| OpenTelemetry Collector | `svp-obs` / `otel-collector` | `<name>-otel-collector` | `aps:RemoteWrite` trên workspace; `logs:PutLogEvents` trên stream `otel-collector` của `log_group_arn`; `kms:Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey` trên `observability_kms_key_arn` với `kms:ViaService` = `logs.<region>.amazonaws.com`; `xray:PutTraceSegments` trên `*` |
| Prometheus agent (2 replica, một association) | `svp-obs` / `kps-prometheus` | `<name>-prometheus-agent` | `aps:RemoteWrite` trên workspace |
| ACK prometheusservice controller | `svp-obs` / `ack-prometheusservice-controller` | `<name>-ack-prometheusservice` | `aps:Create`, `Put`, `Describe`, `DeleteRuleGroupsNamespace`, `TagResource`, `UntagResource`, `ListTagsForResource` trên `rulegroupsnamespace/<ws>/*`; `aps:Create`, `Put`, `Describe`, `DeleteAlertManagerDefinition`, `ListRuleGroupsNamespaces` trên workspace |
| Kyverno admission controller | `kyverno` / `kyverno-admission-controller` | `<name>-kyverno-admission` | `ecr:GetAuthorizationToken` trên `*`; `ecr:BatchGetImage`, `GetDownloadUrlForLayer` trên `release_repository_arns`; không KMS |
| Argo Rollouts | `argo-rollouts` / `argo-rollouts` | `<name>-argo-rollouts` | `aps:QueryMetrics` trên workspace (phân tích canary chỉ chạy truy vấn tức thời) |

Năm role cuối mang policy inline cùng tên role (`local.pod_identity_roles` ở `iam.tf`), association ở `pod-identity.tf`. Không action
`*`; resource `*` chỉ cho `ecr:GetAuthorizationToken` và `xray:PutTraceSegments`, hai action không có resource type theo Service
Authorization Reference. Không role nào trong bảng có quyền KMS của ECR: ECR giải mã repo mã hoá bằng key của khách hàng qua grant của
chính nó.
Action, resource theo [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §9 và
[ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) §11.

**Pull-through cache trên role node:** policy inline `<name>-ecr-pull-through-cache` trên role của nhóm `system` và role node Karpenter:
`ecr:BatchImportUpstreamImage`, `ecr:CreateRepository` chỉ trên `repository/<tiền tố>/*` của từng tiền tố trong `ecr_cache_prefixes`
(lần kéo đầu một image chưa có trong cache: node nhập image từ upstream vào repo nó tạo), và `kms:Decrypt` trên `ecr_kms_key_arn` chỉ với
`kms:ViaService` = `ecr.<region>.amazonaws.com` (dùng khoá của registry chỉ qua ECR khi kéo image). Node không tạo hay ghi được repo phát
hành; kéo vẫn qua managed policy đọc ECR có sẵn của role node.

Trust policy của mọi role trong bảng: `pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`, kèm condition trên session tag mà Pod Identity
đặt (`aws:RequestTag/eks-cluster-name` = `name`, `…/kubernetes-namespace`, `…/kubernetes-service-account` đúng cặp ở bảng): association
của cluster khác hay ServiceAccount khác không dùng được role dù có ai tạo. Chart cài controller phải dùng đúng namespace và tên
ServiceAccount ở bảng (Pod Identity không cần annotation trên ServiceAccount).

## Addon

Mỗi addon ghim `addon_version` ở `addons.tf` (bản và nguồn: ADR-0056 §8).

| Addon | Trước node group | Cấu hình |
| --- | --- | --- |
| `vpc-cni` | có | `enableNetworkPolicy: "true"` (agent network policy trên mọi node: NetworkPolicy của chart có hiệu lực như k3d; cần VPC CNI ≥ 1.21), `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` |
| `eks-pod-identity-agent` | có | agent nghe `169.254.170.23:80` trên mỗi node; pod nào cần credential phải được NetworkPolicy mở đúng `169.254.170.23/32` TCP 80 |
| `kube-proxy` | có | mặc định |
| `coredns` | không (cần node để chạy) | mặc định |
| `aws-ebs-csi-driver` | không | Pod Identity như trên; `controller.extraVolumeTags: {Project: svp}`; không tạo StorageClass nào (EKS từ 1.30 không đánh dấu `gp2` mặc định: `gp3` mặc định do `svp-cluster` render) |
| `metrics-server` | không | addon community của EKS (AWS chỉ hỗ trợ cài, gỡ qua API): API metrics cho `kubectl top` và HPA CPU của gateway, feed-service; k3s có sẵn, EKS không |
| `aws-guardduty-agent` | không | agent Runtime Monitoring của GuardDuty, DaemonSet trên mọi node (cả node Karpenter); resource `aws_eks_addon.guardduty_agent` riêng ở `addons.tf`, không trong `local.addons`: tạo sau module cộng đồng (cần node) và sau endpoint `guardduty-data` (`depends_on` trên biến `guardduty_data_endpoint_id`, output của `network`) |

Agent GuardDuty do Terraform cài, không để GuardDuty tự quản: GuardDuty tự quản thì tự tạo endpoint `guardduty-data` và security group
ngoài state, chặn destroy VPC cuối buổi ([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md)
§5). Agent gửi sự kiện qua endpoint đó (private DNS, module `network`); add-on không cần role IAM hay Pod Identity. Đưa add-on vào
`local.addons` thì cách duy nhất để nó chờ endpoint là cho cả map phụ thuộc biến, nghĩa là mọi add-on (kể cả `vpc-cni` trước node group)
cùng chờ.

**Số pod mỗi node:** không prefix delegation, `m7g.large` giữ 29 pod (3 ENI × (IP mỗi ENI − 1) + 2). Bật prefix delegation mỗi ENI nhận các khối `/28` nên số tính ra vượt 400, managed node group chặn ở
**110 pod** cho instance dưới 30 vCPU (EC2NodeClass đặt cùng `kubelet.maxPods`). vpc-cni được tạo trước node group để node đầu tiên đã có
giá trị này. Mỗi node giữ thêm một `/28` trống
(`WARM_PREFIX_TARGET=1`); subnet private phải còn khối `/28` liền nhau (subnet `/19` của `network` dư nhiều).

**IMDS:** IMDSv2 bắt buộc, hop limit 1: container (cách instance một hop) không đọc được credential của node, nên role của node (gồm
`AmazonEKS_CNI_Policy`) chỉ tới tay process chạy trên mạng host (`aws-node`). Phần node của EBS CSI khi đó lấy metadata từ Kubernetes
thay vì IMDS (driver tự thử Kubernetes khi IMDS không trả lời); controller nào cần region hay VPC (LBC) nhận chúng qua values.

## Cổng: control plane → node

Với VPC CNI, pod mang IP phụ của ENI node, nên security group node lọc cả lưu lượng tới pod; NetworkPolicy (agent network policy của VPC CNI)
thu hẹp thêm theo từng pod. Rule của module (giữ `node_security_group_enable_recommended_rules = true`, ghi lại ở `security-groups.tf`).
Module luôn bật: 443 hai chiều giữa node và cluster, 10250, và TCP/UDP 53 giữa node. Phần còn lại, gồm TCP 1025–65535 giữa node và egress, là rule khuyến nghị, giữ bật:

| Hướng | Cổng | Ai cần |
| --- | --- | --- |
| node → cluster | TCP 443 | node, pod tới API server |
| cluster → node | TCP 443 | webhook nghe 443 |
| cluster → node | TCP 10250 | kubelet; webhook của cert-manager, Prometheus operator |
| cluster → node | **TCP 10251** | **metrics-server của addon EKS** (API server gọi nó cho API `metrics.k8s.io`) |
| cluster → node | TCP 4443 | metrics-server bản cũ |
| cluster → node | TCP 6443 | API metrics của KEDA |
| cluster → node | TCP 8443 | webhook của Karpenter |
| cluster → node | TCP 9443 | webhook của LBC, Kyverno, KEDA |
| node ↔ node | TCP/UDP 53, TCP 1025–65535 | CoreDNS, pod tới pod |
| node → mọi nơi | tất cả | kéo image qua NAT, gọi API AWS (finding trivy `AWS-0104` bỏ qua có lý do ở `cluster.tf`) |

Webhook hay aggregated API ở cổng khác sẽ quá hạn tới khi thêm rule ở `security-groups.tf`. Rule cho lưu lượng và health check từ ALB edge
tới Envoy do module `edge` thêm vào security group node; LBC không thêm rule nào (`TargetGroupBinding` của Envoy không có khối `networking`).

## Ngoại lệ trivy của module registry

Hai finding trong module registry là lựa chọn có chủ đích, ghi ở `cluster.tf` ngay trên lời gọi module:

- **`AWS-0039`:** không có key KMS do khách hàng quản lý cho Secret khi `secrets_kms_encryption = false`; khi đó EKS mã hoá dữ liệu API của
  Kubernetes, Secret gồm cả, bằng key do AWS sở hữu. Ngoại lệ chỉ đúng với giá trị đó (`create_kms_key=false`): bật key thì finding hết và
  không gì bị bỏ qua. Ở trivy 0.76 điều kiện này khớp khi trivy quét chính module, không khớp khi tới module từ một root (điều kiện trên
  thuộc tính bool hay số không bao giờ khớp ở đó, trên chuỗi thì có), nên root của env để key tắt lặp lại ngoại lệ, không điều kiện, ở lời
  gọi module. Phạm vi: chỉ stg; prd bật `secrets_kms_encryption = true`, mã hoá phong bì Secret bằng key KMS do khách hàng quản lý, nên đọc
  Secret cũng cần `kms:Decrypt` trên key đó.
- **`AWS-0104`:** security group node cho mọi egress. Node kéo image từ registry công khai qua NAT gateway và pod gọi API AWS; egress theo
  từng pod được NetworkPolicy của các chart thu hẹp. Phạm vi: mọi env.

## Tài nguyên ngoài state và tag để quét

Do thành phần trong cluster tạo khi chạy, `terraform destroy` không xoá; script `pre-destroy.sh` gỡ chúng khi controller còn chạy, `sweep.sh`
tìm phần sót theo tag:

| Tài nguyên | Ai tạo | Tag hay dấu nhận diện |
| --- | --- | --- |
| Volume EBS của PVC | EBS CSI (StorageClass `gp3`) | `Project=svp` (`extraVolumeTags`), `ebs.csi.aws.com/cluster=true`, `kubernetes.io/created-for/pvc/name`, `…/namespace`, `kubernetes.io/created-for/pv/name` |
| Snapshot EBS | EBS CSI, Velero | như volume |
| ENI của VPC CNI | `aws-node` trên mỗi node | `cluster.k8s.amazonaws.com/name=<name>`, `node.k8s.amazonaws.com/instance_id`; mô tả `aws-K8S-…`; tìm theo VPC id; tự gỡ khi node xoá, sót thì chặn xoá subnet |
| Instance, ổ gốc, ENI chính của node | Auto Scaling group của node group (trong state qua node group) | `Project=svp`, `eks:cluster-name=<name>`, `eks:nodegroup-name`, `kubernetes.io/cluster/<name>=owned` |
| Instance, ổ gốc, ENI chính, launch template của node Karpenter | Karpenter (NodePool, EC2NodeClass) | `karpenter.sh/nodepool`, `karpenter.sh/nodeclaim`, `kubernetes.io/cluster/<name>=owned`; `Project=svp` do EC2NodeClass đặt (không phải module này) |
| Instance profile của role `<name>-karpenter-node` | Karpenter (từ `spec.role` của EC2NodeClass) | `kubernetes.io/cluster/<name>=owned`, `karpenter.k8s.aws/ec2nodeclass`; còn gắn role thì `terraform destroy` không xoá được role node |
| Log group `/aws/eks/<name>/cluster` | EKS khi bật log control plane | module tạo trước (trong state) khi `control_plane_log_types` khác rỗng; sót nếu bật log ngoài Terraform: tìm theo tên |

**Destroy cần xoá NodePool trước:** node Karpenter dựng không nằm trong state, còn chạy thì giữ ENI trong subnet private và instance profile
trên role node, `terraform destroy` kẹt ở subnet và role. `pre-destroy.sh` xoá NodePool rồi EC2NodeClass khi controller còn chạy, chờ tới khi
hết NodeClaim và instance; giới hạn chờ ở ADR-0056 §9.

## Kiểm ở buổi AWS

`make check` chỉ kiểm tĩnh; các điểm sau chỉ chứng minh được khi người học `apply`:

- Bản ghim của mỗi addon có cho `kubernetes_version`:
  `aws eks describe-addon-versions --addon-name <addon> --kubernetes-version 1.36 --region ap-southeast-1` liệt kê đúng `addon_version`
  của `addons.tf` (không có thì `apply` đỏ ở `aws_eks_addon`); `kubectl top node` chạy, HPA của gateway và feed-service không
  `FailedGetResourceMetric`. Agent GuardDuty: lệnh trên với `--addon-name aws-guardduty-agent` liệt kê bản của `addons.tf`; add-on
  `ACTIVE`, DaemonSet trong namespace `amazon-guardduty` chạy trên mọi node, GuardDuty báo coverage EKS `HEALTHY`.
- Karpenter: pod `karpenter` lấy được credential của role `<name>-karpenter` (log không `AccessDenied`), đọc được hàng đợi `<name>-karpenter`;
  NodeClaim của pod Pending lên `Ready` trong subnet private.
- Access entry của role SSO: `kubectl get ns` bằng kubeconfig của người tạo chạy được ngay sau `apply`.
- Trust policy theo session tag: pod của LBC, EBS CSI lấy được credential (log không `AccessDenied` khi
  `AssumeRoleForPodIdentity`); PVC `gp3` Bound.
- Số pod tối đa: `kubectl get node -o jsonpath='{.items[*].status.allocatable.pods}'` in `110` mỗi node.
