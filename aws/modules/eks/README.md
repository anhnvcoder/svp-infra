# `aws/modules/eks`: cluster EKS của một env

Module nội bộ mỏng bọc [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.29.0)
**21.29.0** (ghim chính xác): control plane, managed node group Graviton, addon EKS, security group, IAM của cluster và node; module
nội bộ thêm role IAM và association EKS Pod Identity cho bốn controller nền tảng. Mức stg và prd chỉ khác ở biến (bảng dưới), một bộ code.

Không có provider nào trong module (kể cả provider Kubernetes hay Helm: StorageClass `gp3` mặc định do chart `svp-cluster` render, controller
do Argo CD cài): root gọi nó (`aws/envs/<env>`) đặt provider, `default_tags` và ghim version provider (`~> 6.59`) trong lock file. Module không
cấp quyền nào cho pod của `svp` (role của video-service, media-worker ở root env).

```hcl
module "eks" {
  source = "../../modules/eks"

  name                         = "svp-stg"
  kubernetes_version           = "1.36"
  vpc_id                       = module.network.vpc_id
  private_subnet_ids           = module.network.private_subnet_ids
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs # *.auto.tfvars không commit
  hosted_zone_id               = var.hosted_zone_id          # output của aws/bootstrap
}
```

## Biến

| Biến | Kiểu | Mặc định | stg (7a) | prd (7b) | Ý nghĩa |
| --- | --- | --- | --- | --- | --- |
| `name` | string | (bắt buộc) | `svp-stg` | `svp-prd` | tên cluster, tiền tố tên role, policy, security group; 3–38 ký tự |
| `kubernetes_version` | string | (bắt buộc) | `1.36` | như stg lúc dựng | minor của control plane và node group |
| `vpc_id` | string | (bắt buộc) | output `vpc_id` của `network` | như stg | VPC của cluster |
| `private_subnet_ids` | list(string) | (bắt buộc) | 2 subnet private | 3 subnet private | ENI của control plane và node đặt vào mọi subnet này (node group trải mọi AZ của danh sách) |
| `endpoint_public_access` | bool | `false` | `true` | `true` hay `false` (chốt ở 7b) | mở endpoint public của API; endpoint private **luôn bật** |
| `endpoint_public_access_cidrs` | list(string) | `[]` | CIDR của người học (`/32`) | CIDR của người học hay `[]` | dải IPv4 được gọi endpoint public; bắt buộc khác rỗng khi `endpoint_public_access`, mọi dải phải dài từ `/8` trở lên (không bao giờ mở cả Internet); giá trị cá nhân, chỉ qua `*.auto.tfvars` không commit hay `TF_VAR_*` |
| `control_plane_log_types` | list(string) | `[]` | `[]` (tắt) | `["api", "audit"]` | log control plane gửi CloudWatch; rỗng thì không tạo log group |
| `control_plane_log_retention_days` | number | `1` | (không dùng) | chốt ở 7b | số ngày giữ log control plane |
| `node_instance_types` | list(string) | `["m7g.large", "m6g.large", "t4g.large"]` | mặc định | đo ở 7b | loại Graviton cùng cỡ (2 vCPU, 8 GiB); phải là arm64 |
| `node_capacity_type` | string | `SPOT` | `SPOT` | `ON_DEMAND` | |
| `node_min_size` / `node_desired_size` / `node_max_size` | number | `3` / `3` / `5` | `3` / `3` / `5` | đo ở 7b | cỡ node group; `desired` chỉ có tác dụng lúc tạo (dưới đây) |
| `hosted_zone_id` | string | (bắt buộc) | zone `aws.<domain>` của `aws/bootstrap` | như stg | zone duy nhất ExternalDNS và cert-manager được ghi |

Endpoint public mặc định tắt để module an toàn khi gọi thiếu biến; root của stg bật và đưa CIDR. **Vì sao private luôn bật:** giới hạn
CIDR public mà tắt private thì node trong subnet private gọi API qua IP của NAT, IP đó không nằm trong danh sách, node không join được
(tài liệu EKS khuyên bật private khi giới hạn CIDR). Pod tới API qua ENI của control plane trong VPC, cổng 443.

**Đổi số node trong buổi:** module EKS bỏ qua thay đổi `desired_size` sau khi tạo (để autoscaler, hay người vận hành, quyết), nên tăng
node cho k6 bằng lệnh người học chạy, không bằng biến:
`AWS_PROFILE=anhnv-sso aws eks update-nodegroup-config --cluster-name svp-stg --nodegroup-name <tên node group> --scaling-config minSize=3,maxSize=5,desiredSize=5 --region ap-southeast-1`
(tên node group: `aws eks list-nodegroups --cluster-name svp-stg`, có tiền tố `default-`).

## Output

| Output | Dùng cho |
| --- | --- |
| `cluster_name` | khoá `name` của `cluster_values`, `aws eks update-kubeconfig --name` |
| `cluster_endpoint` | URL API server |
| `cluster_service_cidr` | khoá `serviceCidr` của `cluster_values` (EKS tự chọn dải lúc tạo; Service `kubernetes` lấy địa chỉ `.1`) |
| `node_security_group_id` | nguồn được security group của RDS cho vào 5432 (pod mang IP của ENI node nên đi theo security group của node) |
| `cluster_security_group_id` | security group module gắn thêm vào ENI của control plane |
| `cluster_primary_security_group_id` | security group EKS tự tạo cho cluster, gắn vào ENI của control plane |

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
| ExternalDNS | `external-dns` / `external-dns` | `<name>-external-dns` | inline: `ChangeResourceRecordSets`, `ListResourceRecordSets`, `ListTagsForResources` chỉ trên `arn:aws:route53:::hostedzone/<hosted_zone_id>`; `ListHostedZones` trên `*` tách riêng (không có quyền theo resource) |
| cert-manager (DNS-01) | `cert-manager` / `cert-manager` | `<name>-cert-manager` | inline: `ChangeResourceRecordSets` chỉ trên zone lab, chỉ bản ghi `TXT` có tên `_acme-challenge.*` (condition `route53:ChangeResourceRecordSetsRecordTypes`, `…NormalizedRecordNames`); `ListResourceRecordSets` trên zone; `GetChange` trên `change/*`; `ListHostedZonesByName` trên `*` tách riêng. Issuer dùng credential ambient (ClusterIssuer) |
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

Với VPC CNI, pod mang IP phụ của ENI node, nên security group node lọc cả lưu lượng tới pod. Rule của module (giữ
`node_security_group_enable_recommended_rules = true`, ghi lại ở `security-groups.tf`):

| Hướng | Cổng | Ai cần |
| --- | --- | --- |
| node → cluster | TCP 443 | node, pod tới API server |
| cluster → node | TCP 443 | webhook nghe 443 |
| cluster → node | TCP 10250 | kubelet; webhook của cert-manager, Prometheus operator |
| cluster → node | **TCP 10251** | **metrics-server của addon EKS** (API server gọi nó cho API `metrics.k8s.io`) |
| cluster → node | TCP 4443 | metrics-server bản cũ |
| cluster → node | TCP 6443 | API metrics của KEDA |
| cluster → node | TCP 8443 | webhook của Karpenter (7b) |
| cluster → node | TCP 9443 | webhook của LBC, Kyverno, KEDA |
| node ↔ node | TCP/UDP 53, TCP 1025–65535 | CoreDNS, pod tới pod |
| node → mọi nơi | tất cả | kéo image qua NAT, gọi API AWS (finding trivy `AWS-0104` bỏ qua có lý do ở `cluster.tf`) |

Webhook hay aggregated API ở cổng khác sẽ quá hạn tới khi thêm rule ở `security-groups.tf`. Rule cho lưu lượng và health check của NLB do
LBC tự thêm vào security group node (security group duy nhất của node có tag `kubernetes.io/cluster/<name>`).

## Tài nguyên ngoài state và tag để quét

Do thành phần trong cluster tạo khi chạy, `terraform destroy` không xoá; script `pre-destroy.sh` gỡ chúng khi controller còn chạy, `sweep.sh`
tìm phần sót theo tag:

| Tài nguyên | Ai tạo | Tag hay dấu nhận diện |
| --- | --- | --- |
| NLB, listener, target group | LBC (Service `LoadBalancer` của Envoy) | `elbv2.k8s.aws/cluster=<name>`, `service.k8s.aws/stack=<namespace>/<service>`, `service.k8s.aws/resource` |
| Security group frontend, backend của NLB; rule LBC thêm vào security group node | LBC | `elbv2.k8s.aws/cluster=<name>`, `elbv2.k8s.aws/resource` (rule nằm trong security group node: đi cùng nó khi destroy, nhưng security group backend còn được tham chiếu thì không xoá được) |
| Volume EBS của PVC | EBS CSI (StorageClass `gp3`) | `Project=svp` (`extraVolumeTags`), `ebs.csi.aws.com/cluster=true`, `kubernetes.io/created-for/pvc/name`, `…/namespace`, `kubernetes.io/created-for/pv/name` |
| Snapshot EBS | EBS CSI, Velero (7b) | như volume |
| ENI của VPC CNI | `aws-node` trên mỗi node | `cluster.k8s.amazonaws.com/name=<name>`, `node.k8s.amazonaws.com/instance_id`; mô tả `aws-K8S-…`; tìm theo VPC id; tự gỡ khi node xoá, sót thì chặn xoá subnet |
| Instance, ổ gốc, ENI chính của node | Auto Scaling group của node group (trong state qua node group) | `Project=svp`, `eks:cluster-name=<name>`, `eks:nodegroup-name`, `kubernetes.io/cluster/<name>=owned` |
| Log group `/aws/eks/<name>/cluster` | EKS khi bật log control plane | module tạo trước (trong state) khi `control_plane_log_types` khác rỗng; sót nếu bật log ngoài Terraform: tìm theo tên |
| Bản ghi Route 53 (A, TXT owner của ExternalDNS; TXT `_acme-challenge` khi DNS-01 lỗi) | ExternalDNS, cert-manager | bản ghi của zone lab ngoài NS/SOA ở đỉnh zone |

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
