# `aws/modules/eks`: cluster EKS của một env

Module nội bộ mỏng bọc [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.29.0)
**21.29.0** (ghim chính xác): control plane, managed node group Graviton, addon EKS, security group, IAM của cluster và node; module
nội bộ thêm role IAM và association EKS Pod Identity cho bốn controller nền tảng. Mức stg và prd chỉ khác ở biến (bảng dưới), một bộ code.

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
  hosted_zone_id               = var.hosted_zone_id          # output zone_id của aws/accounts/stg
}
```

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

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.cert_manager](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_policy.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cert_manager](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cert_manager](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_policy_document.cert_manager](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| control\_plane\_log\_retention\_days | Days CloudWatch keeps the control plane logs when control\_plane\_log\_types is not empty. | `number` | `1` | no |
| control\_plane\_log\_types | Control plane logs sent to CloudWatch, e.g. ["api", "audit"]. Empty (the default) sends none and creates no log group: ingestion is billed per GB. | `list(string)` | `[]` | no |
| endpoint\_public\_access | Open the public endpoint of the Kubernetes API, reachable only from endpoint\_public\_access\_cidrs. The private endpoint is always on, so nodes and pods reach the API inside the VPC either way. | `bool` | `false` | no |
| endpoint\_public\_access\_cidrs | IPv4 ranges allowed to call the public endpoint of the Kubernetes API, e.g. the address of the learner's machine as a /32. Personal data of a public repository: set it in an uncommitted *.auto.tfvars or TF\_VAR\_endpoint\_public\_access\_cidrs. | `list(string)` | `[]` | no |
| hosted\_zone\_id | ID of the Route 53 hosted zone of the env, in the env's account (output zone\_id of aws/accounts/<env>). ExternalDNS and cert-manager may change records of this zone only. | `string` | n/a | yes |
| kubernetes\_version | Kubernetes minor version of the control plane and of the node group, e.g. 1.36. Pick a minor in standard support: the cluster is created with the STANDARD support policy. | `string` | n/a | yes |
| name | Name of the EKS cluster, e.g. svp-stg, and prefix of the names of its IAM roles, policies, security groups and node group. | `string` | n/a | yes |
| node\_capacity\_type | SPOT (cheaper, nodes can be reclaimed with two minutes of notice) or ON\_DEMAND. | `string` | `"SPOT"` | no |
| node\_desired\_size | Number of nodes when the node group is created. Terraform ignores later changes of it (the module leaves it to whoever scales the group), so a session scales with aws eks update-nodegroup-config. | `number` | `3` | no |
| node\_instance\_types | Graviton (arm64) instance types of the node group, all of the same size so the scheduler sees the same node whichever one runs. Several types give Spot more pools to draw from when one runs short. | `list(string)` | <pre>[<br/>  "m7g.large",<br/>  "m6g.large",<br/>  "t4g.large"<br/>]</pre> | no |
| node\_max\_size | Largest number of nodes of the node group. | `number` | `5` | no |
| node\_min\_size | Smallest number of nodes of the node group. | `number` | `3` | no |
| private\_subnet\_ids | Private subnets of the VPC, one per availability zone (output private\_subnet\_ids of the network module). The control plane's network interfaces and the nodes go into every one of them, so pods spread over all these zones. | `list(string)` | n/a | yes |
| secrets\_kms\_encryption | Envelope-encrypt Kubernetes Secrets with a customer managed KMS key the module creates (alias <name>-eks-secrets, rotated yearly, 7-day deletion window). Off by default: EKS encrypts them with an AWS owned key, and a key of our own costs a month's fee and outlives the cluster for the deletion window. | `bool` | `false` | no |
| vpc\_id | ID of the VPC of the cluster (output vpc\_id of the network module). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_certificate\_authority\_data | Certificate authority of the Kubernetes API server, base64-encoded PEM: cluster.certificate-authority-data of a kubeconfig, cluster\_ca\_certificate (after base64decode) of the helm and kubernetes providers. |
| cluster\_endpoint | URL of the Kubernetes API server. |
| cluster\_name | Name of the EKS cluster: clusterName of the AWS Load Balancer Controller, txtOwnerId of ExternalDNS, aws eks update-kubeconfig --name. |
| cluster\_primary\_security\_group\_id | Security group EKS creates for the cluster and attaches to the control plane's network interfaces. |
| cluster\_security\_group\_id | Security group the module adds to the control plane's network interfaces. |
| cluster\_service\_cidr | IPv4 range of Kubernetes Services, chosen by EKS when the cluster is created; the API server's Service takes its first address. |
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
| `node_instance_types` | mặc định | theo số đo khi dựng prd |
| `node_capacity_type` | `SPOT` | `ON_DEMAND` |
| `node_min_size` / `node_desired_size` / `node_max_size` | `3` / `3` / `5` | theo số đo khi dựng prd |
| `hosted_zone_id` | output `zone_id` của `aws/accounts/stg` (zone `stg.aws.<domain>`) | output `zone_id` của `aws/accounts/prd` (zone `aws.<domain>`) |

Endpoint public mặc định tắt để module an toàn khi gọi thiếu biến; root của stg bật và đưa CIDR. **Vì sao private luôn bật:** giới hạn
CIDR public mà tắt private thì node trong subnet private gọi API qua IP của NAT, IP đó không nằm trong danh sách, node không join được
(tài liệu EKS khuyên bật private khi giới hạn CIDR). Pod tới API qua ENI của control plane trong VPC, cổng 443.

**Đổi số node trong buổi:** module EKS bỏ qua thay đổi `desired_size` sau khi tạo (để autoscaler, hay người vận hành, quyết), nên tăng
node cho k6 bằng lệnh người học chạy, không bằng biến:
`AWS_PROFILE=anhnv-sso aws eks update-nodegroup-config --cluster-name svp-stg --nodegroup-name <tên node group> --scaling-config minSize=3,maxSize=5,desiredSize=5 --region ap-southeast-1`
(tên node group: `aws eks list-nodegroups --cluster-name svp-stg`, có tiền tố `default-`).

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
| Security group node | `<name>-node-<hậu tố>`, tag `kubernetes.io/cluster/<name>=owned` | gắn vào mọi node (và vì VPC CNI, vào mọi pod); rule ở mục Cổng dưới đây |
| Tag trên security group chính | `aws_ec2_tag` | chép tag của module (`Project=svp`) lên security group EKS tự tạo |
| `time_sleep` | | chờ 30 s sau khi control plane xong rồi mới tạo node group và addon thường |
| IAM role của node | `default-eks-node-group-<hậu tố>` | EC2 assume; gắn `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly` và `AmazonEKS_CNI_Policy` (VPC CNI dùng role của node: pod thường không tới được IMDS, xem IMDS dưới đây) |
| Launch template | `default-<hậu tố>` | AMI `AL2023_ARM_64_STANDARD` mới nhất của minor, IMDSv2 bắt buộc, hop limit 1, ổ gốc gp3 30 GiB mã hoá; tag `Project=svp` lên instance, volume, ENI |
| `aws_eks_node_group` | `default-<hậu tố>` | `capacity_type`, loại instance, cỡ theo biến; trải mọi subnet private |
| `aws_eks_addon` | 6 addon | mục Addon |
| Log group CloudWatch | `/aws/eks/<name>/cluster` | chỉ khi `control_plane_log_types` khác rỗng, retention theo biến |

Module cộng đồng **không** tạo: KMS key (`create_kms_key = false`: $1/tháng mỗi key và còn sống qua thời gian chờ xoá; EKS mã hoá dữ liệu
API, gồm Secret, bằng key do AWS sở hữu theo mặc định), OIDC provider (`enable_irsa = false`), Fargate profile, node group tự quản.

**Module nội bộ tạo thêm** (`iam.tf`, `pod-identity.tf`):

| Controller | Namespace / ServiceAccount | Role | Quyền |
| --- | --- | --- | --- |
| AWS Load Balancer Controller | `kube-system` / `aws-load-balancer-controller` | `<name>-aws-load-balancer-controller` | managed policy cùng tên, nội dung là `docs/install/iam_policy.json` của tag **v3.6.2** giữ nguyên ở `policies/aws-load-balancer-controller-v3.6.2.json`; chart `eks/aws-load-balancer-controller` phải ghim **3.6.2** (appVersion v3.6.2), nâng controller thì thay file bằng policy của tag mới trong cùng thay đổi |
| ExternalDNS | `external-dns` / `external-dns` | `<name>-external-dns` | inline: `ChangeResourceRecordSets` chỉ trên `arn:aws:route53:::hostedzone/<hosted_zone_id>`, chỉ bản ghi `A`, `AAAA`, `CNAME`, `TXT` (condition `route53:ChangeResourceRecordSetsRecordTypes`; `TXT` cho registry của ExternalDNS; không ghi được `NS` uỷ quyền zone con hay `SOA`); `ListResourceRecordSets`, `ListTagsForResources` trên zone; `ListHostedZones` trên `*` tách riêng (không có quyền theo resource) |
| cert-manager (DNS-01) | `cert-manager` / `cert-manager` | `<name>-cert-manager` | inline: `ChangeResourceRecordSets` chỉ trên zone của env, chỉ bản ghi `TXT` có tên `_acme-challenge.*` (condition `route53:ChangeResourceRecordSetsRecordTypes`, `…NormalizedRecordNames`); `ListResourceRecordSets` trên zone; `GetChange` trên `change/*`; `ListHostedZonesByName` trên `*` tách riêng. Issuer dùng credential ambient (ClusterIssuer) |
| EBS CSI driver | `kube-system` / `ebs-csi-controller-sa` | `<name>-ebs-csi-driver` | managed `service-role/AmazonEBSCSIDriverPolicy`; association do chính addon tạo (`pod_identity_association`) |

Trust policy của bốn role: `pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`, kèm condition trên session tag mà Pod Identity
đặt (`aws:RequestTag/eks-cluster-name` = `name`, `…/kubernetes-namespace`, `…/kubernetes-service-account` đúng cặp ở bảng): association
của cluster khác hay ServiceAccount khác không dùng được role dù có ai tạo. Chart cài controller phải dùng đúng namespace và tên
ServiceAccount ở bảng (Pod Identity không cần annotation trên ServiceAccount).

## Addon

Mọi addon lấy bản mới nhất của addon cho `kubernetes_version`, chọn lúc plan (plan in ra version).

| Addon | Trước node group | Cấu hình |
| --- | --- | --- |
| `vpc-cni` | có | `enableNetworkPolicy: "true"` (agent network policy trên mọi node: NetworkPolicy của chart có hiệu lực như k3d; cần VPC CNI ≥ 1.21), `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` |
| `eks-pod-identity-agent` | có | agent nghe `169.254.170.23:80` trên mỗi node; pod nào cần credential phải được NetworkPolicy mở đúng `169.254.170.23/32` TCP 80 |
| `kube-proxy` | có | mặc định |
| `coredns` | không (cần node để chạy) | mặc định |
| `aws-ebs-csi-driver` | không | Pod Identity như trên; `controller.extraVolumeTags: {Project: svp}`; không tạo StorageClass nào (EKS từ 1.30 không đánh dấu `gp2` mặc định: `gp3` mặc định do `svp-cluster` render) |
| `metrics-server` | không | addon community của EKS (AWS chỉ hỗ trợ cài, gỡ qua API): API metrics cho `kubectl top` và HPA CPU của gateway, feed-service; k3s có sẵn, EKS không |

**Số pod mỗi node:** không prefix delegation, `m7g.large`, `m6g.large` giữ 29 pod, `t4g.large` 35 (3 ENI × (IP mỗi ENI − 1) + 2), node group
nhiều loại lấy số nhỏ nhất: 29. Bật prefix delegation mỗi ENI nhận các khối `/28` nên số tính ra vượt 400, managed node group chặn ở
**110 pod** cho instance dưới 30 vCPU. vpc-cni được tạo trước node group để node đầu tiên đã có giá trị này. Mỗi node giữ thêm một `/28` trống
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

Webhook hay aggregated API ở cổng khác sẽ quá hạn tới khi thêm rule ở `security-groups.tf`. Rule cho lưu lượng và health check của NLB do
LBC tự thêm vào security group node (security group duy nhất của node có tag `kubernetes.io/cluster/<name>`; security group chính mà EKS
tạo cho cluster không gắn vào node).

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
| NLB, listener, target group | LBC (Service `LoadBalancer` của Envoy) | `elbv2.k8s.aws/cluster=<name>`, `service.k8s.aws/stack=<namespace>/<service>`, `service.k8s.aws/resource` |
| Security group frontend, backend của NLB; rule LBC thêm vào security group node | LBC | `elbv2.k8s.aws/cluster=<name>`, `elbv2.k8s.aws/resource` (rule nằm trong security group node: đi cùng nó khi destroy, nhưng security group backend còn được tham chiếu thì không xoá được) |
| Volume EBS của PVC | EBS CSI (StorageClass `gp3`) | `Project=svp` (`extraVolumeTags`), `ebs.csi.aws.com/cluster=true`, `kubernetes.io/created-for/pvc/name`, `…/namespace`, `kubernetes.io/created-for/pv/name` |
| Snapshot EBS | EBS CSI, Velero | như volume |
| ENI của VPC CNI | `aws-node` trên mỗi node | `cluster.k8s.amazonaws.com/name=<name>`, `node.k8s.amazonaws.com/instance_id`; mô tả `aws-K8S-…`; tìm theo VPC id; tự gỡ khi node xoá, sót thì chặn xoá subnet |
| Instance, ổ gốc, ENI chính của node | Auto Scaling group của node group (trong state qua node group) | `Project=svp`, `eks:cluster-name=<name>`, `eks:nodegroup-name`, `kubernetes.io/cluster/<name>=owned` |
| Log group `/aws/eks/<name>/cluster` | EKS khi bật log control plane | module tạo trước (trong state) khi `control_plane_log_types` khác rỗng; sót nếu bật log ngoài Terraform: tìm theo tên |
| Bản ghi Route 53 (A, TXT owner của ExternalDNS; TXT `_acme-challenge` khi DNS-01 lỗi) | ExternalDNS, cert-manager | bản ghi của zone của env ngoài NS/SOA ở đỉnh zone và bản ghi NS uỷ quyền zone con (do `aws/accounts/<env>` tạo) |

## Kiểm ở buổi AWS

`make check` chỉ kiểm tĩnh; các điểm sau chỉ chứng minh được khi người học `apply`:

- Addon `metrics-server` có cho 1.36: `aws eks describe-addon-versions --addon-name metrics-server --kubernetes-version 1.36 --region ap-southeast-1`
  có ít nhất một version (không có thì plan đỏ ở data source `aws_eks_addon_version`); `kubectl top node` chạy, HPA của gateway và
  feed-service không `FailedGetResourceMetric`.
- Access entry của role SSO: `kubectl get ns` bằng kubeconfig của người tạo chạy được ngay sau `apply`.
- Trust policy theo session tag: pod của LBC, ExternalDNS, cert-manager, EBS CSI lấy được credential (log không `AccessDenied` khi
  `AssumeRoleForPodIdentity`); PVC `gp3` Bound.
- DNS-01 với condition tên `_acme-challenge.*`: Certificate `Ready`, không `AccessDenied` trong log cert-manager.
- Số pod tối đa: `kubectl get node -o jsonpath='{.items[*].status.allocatable.pods}'` in `110` mỗi node.
