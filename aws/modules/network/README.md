# `aws/modules/network`: VPC của một env

Module nội bộ mỏng bọc [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.7.3)
**6.7.3** (ghim chính xác): VPC ba tầng trên `az_count` AZ (subnet public, private và database), Internet Gateway, route table, NAT
gateway và Elastic IP theo `single_nat_gateway`, S3 gateway endpoint trên mọi route table private, security group mặc định không rule nào, flow log tắt mặc
định. Mức stg và prd chỉ khác ở biến (bảng dưới), một bộ code.

Policy của S3 gateway endpoint: mặc định không có (endpoint cho qua mọi bucket IAM cho phép, và NetworkPolicy của pod, vốn khớp S3 theo địa
chỉ, không phân biệt được bucket này với bucket khác). `s3_endpoint_restricted = true` (mức prd) đặt
policy chỉ cho qua các bucket trong `s3_endpoint_buckets` (bucket `uploads`, `media` của env, root truyền từ output của module `media`) và
`s3:GetObject` trên bucket layer image của Amazon ECR trong region (`prod-<region>-starport-layer-bucket`; xem mục "Minimum Amazon S3 bucket
permissions for Amazon ECR" của [tài liệu VPC endpoint của ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)). Route của endpoint nhận mọi địa
chỉ S3 của region, nên từ subnet private mọi bucket khác của region bị từ chối: credential bị lộ không chép dữ liệu ra bucket của account
khác được; image nào kéo blob từ bucket S3 khác trong cùng region cũng bị chặn.

Không có provider nào trong module: root gọi nó (`aws/envs/<env>`) đặt provider, `default_tags` (`Project=svp`, `ManagedBy=terraform`,
`Stack=<env>`) và ghim version provider trong lock file. Module không cấp quyền IAM nào cho pod.

```hcl
module "network" {
  source = "../../modules/network"

  name               = "svp-stg"
  cluster_name       = "svp-stg"
  az_count           = 2
  single_nat_gateway = true
}
```

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| vpc | terraform-aws-modules/vpc/aws | 6.7.3 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az\_count | Number of availability zones, taken in order from the zones of the region that need no opt-in. Each zone gets one public, one private and one database subnet. EKS needs subnets in at least two zones. | `number` | `2` | no |
| cidr | IPv4 range of the VPC, a /16 to /20. Pods take their addresses from the private subnets (VPC CNI), so the range must not overlap any network the cluster talks to. | `string` | `"10.0.0.0/16"` | no |
| cluster\_name | Name of the EKS cluster that runs in this VPC. The subnets get the tag kubernetes.io/cluster/<name> = shared, which the AWS Load Balancer Controller reads to pick subnets; the private subnets also get karpenter.sh/discovery = <name>, which the EC2NodeClass of Karpenter reads. | `string` | n/a | yes |
| flow\_log\_enabled | Send VPC flow logs (accepted and rejected traffic) to a CloudWatch log group that this module creates, with the IAM role that writes it. Off by default: ingestion is billed per GB. | `bool` | `false` | no |
| flow\_log\_retention\_days | Days CloudWatch keeps the flow logs when flow\_log\_enabled is true. | `number` | `1` | no |
| name | Name of the VPC and prefix of the names of its subnets, route tables, NAT gateways and Elastic IPs, e.g. svp-stg. | `string` | n/a | yes |
| s3\_endpoint\_buckets | Names of the buckets of the env (uploads and media) reachable through the S3 gateway endpoint when s3\_endpoint\_restricted is true. | `list(string)` | `[]` | no |
| s3\_endpoint\_restricted | Put a policy on the S3 gateway endpoint that lets through only the buckets of s3\_endpoint\_buckets and the image layer bucket of Amazon ECR in the region; every other bucket of the region is then unreachable from the private subnets. Off by default: the endpoint lets through every bucket IAM allows. | `bool` | `false` | no |
| single\_nat\_gateway | true: one NAT gateway, in the first zone, for every private subnet (cheaper; losing that zone cuts the egress of the whole VPC). false: one NAT gateway per zone and one private route table per zone that sends its traffic to the NAT gateway of the same zone. | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| azs | Availability zones of the subnets, in the order of the subnet lists. |
| database\_subnet\_cidrs | IPv4 ranges of the database subnets, in the order of azs; network policies that allow traffic to a database use them. |
| database\_subnet\_ids | IDs of the database subnets, one per zone, in the order of azs: RDS, MSK and ElastiCache. Their route table holds only the local route. |
| nat\_public\_ips | Public IPv4 addresses of the NAT gateways: every connection from the nodes and pods to the internet leaves from one of them. |
| private\_subnet\_cidrs | IPv4 ranges of the private subnets, in the order of azs. |
| private\_subnet\_ids | IDs of the private subnets, one per zone, in the order of azs: nodes and pods. |
| public\_subnet\_ids | IDs of the public subnets, one per zone, in the order of azs: NAT gateways and internet-facing load balancers. |
| vpc\_cidr | IPv4 range of the VPC. |
| vpc\_id | ID of the VPC. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->

## Giá trị theo env

| Biến | stg | prd |
| --- | --- | --- |
| `name` | `svp-stg` | `svp-prd` |
| `cidr` | mặc định | mặc định (hay dải khác nếu prd nối hai VPC) |
| `az_count` | `2` | `3` |
| `single_nat_gateway` | `true` (một NAT ở AZ đầu) | `false` (một NAT mỗi AZ, route table private mỗi AZ trỏ NAT cùng AZ) |
| `cluster_name` | tên cluster EKS stg | tên cluster EKS prd |
| `flow_log_enabled` | `false` | `true` |
| `flow_log_retention_days` | (không dùng) | chốt khi dựng prd |

**Chia dải** (`cidr` chia 8 khối bằng nhau): khối 0–5 là subnet private, mỗi AZ một khối (`/19` với `/16`: 8 192 địa chỉ, vì VPC CNI cấp
IP pod từ subnet private, prefix delegation lấy từng `/28` cho mỗi node); khối 7 chia tiếp 32 phần, mỗi AZ một subnet public (`/24` với
`/16`: chỉ NAT gateway và NLB nằm đây); khối 6 chia tiếp 8 phần, mỗi AZ một subnet database (`/22` với `/16`) cho RDS, MSK và ElastiCache. Với mặc định và 2 AZ: private
`10.0.0.0/19`, `10.0.32.0/19`; database `10.0.192.0/22`, `10.0.196.0/22`; public `10.0.224.0/24`, `10.0.225.0/24`.

**Tầng database** ([ADR-0054](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0054-data-subnet-tier.md)): subnet
database có route table riêng chỉ với route `local` của VPC (`create_database_subnet_route_table = true`, không route NAT, không route
Internet Gateway), nên không đi ra Internet được dù qua NAT, và không gì từ Internet vào được. Mặc định của module `vpc` là gắn subnet
database vào route table private (có `0.0.0.0/0` tới NAT); module đặt rõ ba cờ trong local `database_routes`, vì id route table chỉ biết
sau apply nên test đọc local đó. Subnet database không có tag `kubernetes.io/*`: Load Balancer Controller không đặt load balancer ở đó.
Chỉ subnet private mang `karpenter.sh/discovery = <cluster_name>`: EC2NodeClass của Karpenter chọn subnet theo tag này, nên node do
Karpenter dựng chỉ nằm ở subnet private, không ở subnet public hay database.
Module không tạo DB subnet group (`create_database_subnet_group = false`): module `rds` đã tạo của nó. Root đặt RDS, MSK, ElastiCache vào
`database_subnet_ids` và dùng `database_subnet_cidrs` cho egress của NetworkPolicy tới database.

## Tài nguyên trong state

Đọc từ code module ở version ghim (không từ `plan`, chỉ người học chạy):

| Tài nguyên | Số lượng | Ghi chú |
| --- | --- | --- |
| `aws_vpc` | 1 | DNS support và DNS hostnames bật (EKS cần) |
| `aws_internet_gateway` | 1 | |
| `aws_subnet` public / private / database | `az_count` mỗi loại | public: không tự cấp IP công khai (`map_public_ip_on_launch = false`) |
| `aws_route_table` public | 1 | route `0.0.0.0/0` tới Internet Gateway |
| `aws_route_table` private | 1 (stg) hay `az_count` (prd) | route `0.0.0.0/0` tới NAT (cùng AZ ở prd); mỗi subnet private một association |
| `aws_route_table` database | 1 (stg) hay `az_count` (prd) | chỉ route `local`, không `0.0.0.0/0`; mỗi subnet database một association |
| `aws_eip`, `aws_nat_gateway` | 1 (stg) hay `az_count` (prd) | NAT nằm ở subnet public cùng AZ |
| `aws_vpc_endpoint` `s3` | 1 | loại Gateway, gắn mọi route table private: dữ liệu S3 không qua NAT (NAT tính tiền theo GB); miễn phí; không interface endpoint nào (tính tiền theo giờ và AZ) |
| `aws_default_security_group` | 1 | module nhận quản lý và xoá mọi rule: tài nguyên tạo mà quên gán security group không nhận, không gửi được gì |
| `aws_default_network_acl`, `aws_default_route_table` | 1 mỗi loại | module quản lý mặc định của VPC (NACL mặc định cho mọi traffic như AWS) |
| flow log: `aws_flow_log`, `aws_cloudwatch_log_group` `/aws/vpc-flow-log/<vpc-id>`, `aws_iam_role`, `aws_iam_policy`, attachment | 0 hay 1 mỗi loại | chỉ khi `flow_log_enabled`; role, policy tên `<name>-vpc-flow-log-<hậu tố>` |

Chi phí theo giờ (Singapore, ADR-0034 mục chi phí): mỗi NAT $0,059/giờ + $0,059/GB xử lý, mỗi IPv4 công khai (EIP của NAT) $0,005/giờ;
stg một NAT, prd ba NAT.

## Tài nguyên ngoài state và tag nhận diện

Các thành phần chạy trong cluster tạo tài nguyên trong VPC này mà Terraform không biết. Chúng còn thì `terraform destroy` không xoá được
subnet, security group hay VPC (ENI còn gắn), nên script trước destroy và script quét của buổi phải tìm chúng theo tag. Tag đọc từ mã
nguồn của từng thành phần (nhánh chính, tính đến 2026-10-31); buổi đầu kiểm lại trên tài nguyên thật.

| Tài nguyên | Ai tạo | Tag hay dấu hiệu nhận diện |
| --- | --- | --- |
| NLB, target group, listener | AWS Load Balancer Controller từ Service của Envoy | `elbv2.k8s.aws/cluster=<cluster_name>`, `service.k8s.aws/stack=<namespace>/<service>`, `service.k8s.aws/resource`; thêm tag mặc định nếu chart của controller đặt `defaultTags` (`Project=svp`) |
| Security group của LBC (frontend của NLB, backend dùng chung) | AWS Load Balancer Controller | `elbv2.k8s.aws/cluster=<cluster_name>`; SG backend thêm `elbv2.k8s.aws/resource=backend-sg` |
| ENI của NLB trong subnet public | AWS (theo NLB) | mô tả `ELB net/k8s-…`; tự mất khi NLB bị xoá |
| ENI phụ của node (IP pod) | VPC CNI | `cluster.k8s.amazonaws.com/name=<cluster_name>`, `node.k8s.amazonaws.com/instance_id`, `eks:eni:owner=amazon-vpc-cni`; mô tả `aws-K8S-<instance-id>`; ENI `available` còn sót sau khi node mất |
| ENI của control plane EKS trong subnet private | EKS | mô tả `Amazon EKS <cluster_name>`; EKS xoá khi xoá cluster |
| Volume EBS của PVC | EBS CSI driver | `ebs.csi.aws.com/cluster=true`, `CSIVolumeName`, `kubernetes.io/created-for/pvc/namespace`, `kubernetes.io/created-for/pvc/name`, `kubernetes.io/created-for/pv/name`; `Project=svp` khi addon đặt `extraVolumeTags` (module EKS) |
| Instance, ổ gốc, ENI chính của node do Karpenter dựng | Karpenter (NodePool, EC2NodeClass) | `karpenter.sh/nodepool`, `karpenter.sh/nodeclaim`, `kubernetes.io/cluster/<cluster_name>=owned`; `Project=svp` do EC2NodeClass đặt |
| Log group `/aws/eks/<cluster_name>/cluster` | EKS khi bật log control plane | tên log group (module EKS quản lý nếu tạo trước) |

Thứ tự xoá an toàn: xoá Service `LoadBalancer`, PVC và NodePool của Karpenter trong cluster khi controller còn chạy, chờ NLB, volume
và node mất, rồi mới `terraform destroy`; sau đó quét các tag trên trong region.
