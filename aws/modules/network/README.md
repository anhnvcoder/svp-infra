# Module `network`

VPC của một env, bọc module registry `terraform-aws-modules/vpc/aws` (version ghim chính xác ở `main.tf`): bốn tầng subnet public,
private, edge, database trên `az_count` AZ, NAT gateway theo `single_nat_gateway`, S3 gateway endpoint với policy theo
`s3_endpoint_restricted`, interface endpoint tới API AWS và `guardduty-data`, một NACL mỗi tầng, flow log thẳng vào bucket của account
Log Archive. Root `aws/envs/<env>` gọi module; lý do, chia dải và thứ còn qua NAT ở chương
[09. Env và mạng](../../../docs/handbook/09-envs-network.md); test: `make test DIRS=aws/modules/network`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder:

```hcl
module "network" {
  source = "../../modules/network"

  name                        = "svp-stg"
  cluster_name                = "svp-stg"
  az_count                    = 2
  single_nat_gateway          = true
  flow_log_bucket_arn         = "arn:aws:s3:::svp-flowlogs-000000000000-ap-southeast-1"
  interface_endpoint_az_count = 1
  s3_endpoint_restricted      = true
  s3_endpoint_buckets         = ["svp-stg-uploads-000000000000-ap-southeast-1", "svp-stg-media-000000000000-ap-southeast-1", "prod-registry-k8s-io-ap-southeast-1"]
}
```

## Tham chiếu

- [09. Env và mạng](../../../docs/handbook/09-envs-network.md): ghi chú thiết kế mà `main.tf` trỏ tới (chia dải, NACL, policy của S3
  gateway endpoint, endpoint interface ở mục Đọc sâu và mục VPC endpoint).
- [ADR-0064](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0064-interface-endpoints.md): endpoint interface; ai gọi
  từng dịch vụ và thứ còn qua NAT ở phụ lục §1, §6.
- [ADR-0054](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0054-data-subnet-tier.md): tầng database.

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
| [aws_security_group.endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.guardduty_data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_endpoint.guardduty_data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_ingress_rule.endpoints_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.guardduty_data_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_vpc_endpoint_service.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| az\_count | Number of availability zones, taken in order from the zones of the region that need no opt-in. Each zone gets one public, one private, one edge and one database subnet. EKS needs subnets in at least two zones. | `number` | `2` | no |
| cidr | IPv4 range of the VPC, a /16 to /20. Pods take their addresses from the private subnets (VPC CNI), so the range must not overlap any network the cluster talks to. | `string` | `"10.0.0.0/16"` | no |
| cluster\_name | Name of the EKS cluster that runs in this VPC. The public and private subnets get the tag kubernetes.io/cluster/<name> = shared, which the AWS Load Balancer Controller reads to pick subnets; the private subnets also get karpenter.sh/discovery = <name>, which the EC2NodeClass of Karpenter reads. | `string` | n/a | yes |
| flow\_log\_bucket\_arn | ARN of the S3 bucket of the log archive account that receives the VPC flow logs (accepted and rejected traffic), e.g. arn:aws:s3:::svp-flowlogs-000000000000-ap-southeast-1. The bucket ARN alone, no prefix: the logs land under AWSLogs/aws-account-id=<account>/, which the bucket's retention rules match. | `string` | n/a | yes |
| interface\_endpoint\_az\_count | Number of zones, from the first, whose private subnet holds a network interface of each interface endpoint of the AWS APIs. Fewer zones cost less; a caller in another zone then crosses zones, and losing those zones cuts every AWS API call of the VPC. | `number` | n/a | yes |
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
| edge\_subnet\_cidrs | IPv4 ranges of the edge subnets, in the order of azs: every connection from them to Envoy comes from the ALB, so the network policy of Envoy lets in these ranges. |
| edge\_subnet\_ids | IDs of the edge subnets, one per zone, in the order of azs: the internal ALB that CloudFront reaches through a VPC origin. No node or pod takes an address there; their route table holds only the local route. |
| endpoints\_security\_group\_id | ID of the security group of the interface endpoints of the AWS APIs: TCP 443 from the VPC range only. |
| guardduty\_data\_endpoint\_id | ID of the interface endpoint guardduty-data the GuardDuty agent of the EKS nodes reports to; the eks module installs the agent only once it exists. |
| interface\_endpoint\_ids | IDs of the interface endpoints of the AWS APIs, by service (sts, ecr.api, ...). |
| nat\_public\_ips | Public IPv4 addresses of the NAT gateways: every connection from the nodes and pods to the internet leaves from one of them. |
| private\_subnet\_cidrs | IPv4 ranges of the private subnets, in the order of azs. |
| private\_subnet\_ids | IDs of the private subnets, one per zone, in the order of azs: nodes and pods. |
| public\_subnet\_ids | IDs of the public subnets, one per zone, in the order of azs: the NAT gateways and nothing else. |
| vpc\_cidr | IPv4 range of the VPC. |
| vpc\_id | ID of the VPC. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
