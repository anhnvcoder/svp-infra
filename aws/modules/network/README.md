# `aws/modules/network`: VPC của một env

Module nội bộ mỏng bọc [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.7.3)
**6.7.3** (ghim chính xác): VPC, subnet public và private trên `az_count` AZ, Internet Gateway, route table, NAT gateway và Elastic IP
theo `single_nat_gateway`, S3 gateway endpoint trên mọi route table private, security group mặc định không rule nào, flow log tắt mặc
định. Mức stg và prd chỉ khác ở biến (bảng dưới), một bộ code.

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

## Biến

| Biến | Kiểu | Mặc định | stg (7a) | prd (7b) | Ý nghĩa |
| --- | --- | --- | --- | --- | --- |
| `name` | string | (bắt buộc) | `svp-stg` | `svp-prd` | tên VPC, tiền tố tên subnet, route table, NAT, EIP, security group mặc định, role flow log |
| `cidr` | string | `10.0.0.0/16` | mặc định | mặc định (hay dải khác nếu 7b nối hai VPC) | dải IPv4 của VPC, `/16`–`/20` |
| `az_count` | number | `2` | `2` | `3` | số AZ (2–6), lấy theo thứ tự trong các AZ không cần opt-in của region |
| `single_nat_gateway` | bool | `true` | `true` (một NAT ở AZ đầu) | `false` (một NAT mỗi AZ, route table private mỗi AZ trỏ NAT cùng AZ) | |
| `cluster_name` | string | (bắt buộc) | tên cluster EKS stg | tên cluster EKS prd | tag `kubernetes.io/cluster/<tên>=shared` trên mọi subnet |
| `flow_log_enabled` | bool | `false` | `false` | `true` | flow log `ALL` vào log group CloudWatch do module tạo, cùng role IAM ghi nó |
| `flow_log_retention_days` | number | `1` | (không dùng) | chốt ở 7b | số ngày giữ flow log, chỉ nhận giá trị CloudWatch cho phép |

**Chia dải** (`cidr` chia 8 khối bằng nhau): khối 0–5 là subnet private, mỗi AZ một khối (`/19` với `/16`: 8 192 địa chỉ, vì VPC CNI cấp
IP pod từ subnet private, prefix delegation lấy từng `/28` cho mỗi node); khối 7 chia tiếp 32 phần, mỗi AZ một subnet public (`/24` với
`/16`: chỉ NAT gateway và NLB nằm đây); khối 6 để trống cho subnet database hay intra sau này. Với mặc định và 2 AZ: private `10.0.0.0/19`,
`10.0.32.0/19`; public `10.0.224.0/24`, `10.0.225.0/24`.

## Output

| Output | Giá trị | Ai dùng |
| --- | --- | --- |
| `vpc_id` | ID của VPC | module EKS, RDS; khoá `cluster.vpcId` (LBC không đọc IMDS) |
| `vpc_cidr` | dải IPv4 của VPC | khoá `cluster.vpcCidr` (`TRUSTED_PROXY_CIDRS`, `nodeSubnet`, health check NLB) |
| `azs` | AZ theo thứ tự của các danh sách subnet | đọc kết quả, README của env |
| `private_subnet_ids` | subnet private, mỗi AZ một cái | node group EKS, subnet group RDS |
| `private_subnet_cidrs` | dải của subnet private | khoá `cluster.dbCidrs` khi RDS nằm ở subnet private |
| `public_subnet_ids` | subnet public, mỗi AZ một cái | (LBC tự tìm theo tag; output để đọc) |
| `nat_public_ips` | IP công khai của NAT | mọi kết nối ra Internet của node và pod đi từ đây (giới hạn tải ẩn danh của Docker Hub tính theo IP này) |

## Tài nguyên trong state

Đọc từ code module ở version ghim (không từ `plan`, chỉ người học chạy):

| Tài nguyên | Số lượng | Ghi chú |
| --- | --- | --- |
| `aws_vpc` | 1 | DNS support và DNS hostnames bật (EKS cần) |
| `aws_internet_gateway` | 1 | |
| `aws_subnet` public / private | `az_count` mỗi loại | public: không tự cấp IP công khai (`map_public_ip_on_launch = false`) |
| `aws_route_table` public | 1 | route `0.0.0.0/0` tới Internet Gateway |
| `aws_route_table` private | 1 (stg) hay `az_count` (prd) | route `0.0.0.0/0` tới NAT (cùng AZ ở prd); mỗi subnet private một association |
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
nguồn của từng thành phần (nhánh chính, 2026-10-31); buổi đầu kiểm lại trên tài nguyên thật.

| Tài nguyên | Ai tạo | Tag hay dấu hiệu nhận diện |
| --- | --- | --- |
| NLB, target group, listener | AWS Load Balancer Controller từ Service của Envoy | `elbv2.k8s.aws/cluster=<cluster_name>`, `service.k8s.aws/stack=<namespace>/<service>`, `service.k8s.aws/resource`; thêm tag mặc định nếu chart của controller đặt `defaultTags` (`Project=svp`) |
| Security group của LBC (frontend của NLB, backend dùng chung) | AWS Load Balancer Controller | `elbv2.k8s.aws/cluster=<cluster_name>`; SG backend thêm `elbv2.k8s.aws/resource=backend-sg` |
| ENI của NLB trong subnet public | AWS (theo NLB) | mô tả `ELB net/k8s-…`; tự mất khi NLB bị xoá |
| ENI phụ của node (IP pod) | VPC CNI | `cluster.k8s.amazonaws.com/name=<cluster_name>`, `node.k8s.amazonaws.com/instance_id`, `eks:eni:owner=amazon-vpc-cni`; mô tả `aws-K8S-<instance-id>`; ENI `available` còn sót sau khi node mất |
| ENI của control plane EKS trong subnet private | EKS | mô tả `Amazon EKS <cluster_name>`; EKS xoá khi xoá cluster |
| Volume EBS của PVC | EBS CSI driver | `ebs.csi.aws.com/cluster=true`, `CSIVolumeName`, `kubernetes.io/created-for/pvc/namespace`, `kubernetes.io/created-for/pvc/name`, `kubernetes.io/created-for/pv/name`; `Project=svp` khi addon đặt `extraVolumeTags` (module EKS) |
| Log group `/aws/eks/<cluster_name>/cluster` | EKS khi bật log control plane | tên log group (module EKS quản lý nếu tạo trước) |

Thứ tự xoá an toàn: xoá Service `LoadBalancer` và PVC trong cluster khi controller còn chạy, chờ NLB và volume mất, rồi mới
`terraform destroy`; sau đó quét các tag trên trong region.
