output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "IPv4 range of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "Availability zones of the subnets, in the order of the subnet lists."
  value       = local.azs
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per zone, in the order of azs: nodes and pods."
  value       = module.vpc.private_subnets
}

output "private_subnet_cidrs" {
  description = "IPv4 ranges of the private subnets, in the order of azs."
  value       = module.vpc.private_subnets_cidr_blocks
}

output "database_subnet_ids" {
  description = "IDs of the database subnets, one per zone, in the order of azs: RDS, MSK and ElastiCache. Their route table holds only the local route."
  value       = module.vpc.database_subnets
}

output "database_subnet_cidrs" {
  description = "IPv4 ranges of the database subnets, in the order of azs; network policies that allow traffic to a database use them."
  value       = module.vpc.database_subnets_cidr_blocks
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per zone, in the order of azs: the NAT gateways and nothing else."
  value       = module.vpc.public_subnets
}

output "edge_subnet_ids" {
  description = "IDs of the edge subnets, one per zone, in the order of azs: the internal ALB that CloudFront reaches through a VPC origin. No node or pod takes an address there; their route table holds only the local route."
  value       = module.vpc.intra_subnets
}

output "edge_subnet_cidrs" {
  description = "IPv4 ranges of the edge subnets, in the order of azs: every connection from them to Envoy comes from the ALB, so the network policy of Envoy lets in these ranges."
  value       = module.vpc.intra_subnets_cidr_blocks
}

output "nat_public_ips" {
  description = "Public IPv4 addresses of the NAT gateways: every connection from the nodes and pods to the internet leaves from one of them."
  value       = module.vpc.nat_public_ips
}

output "guardduty_data_endpoint_id" {
  description = "ID of the interface endpoint guardduty-data the GuardDuty agent of the EKS nodes reports to; the eks module installs the agent only once it exists."
  value       = aws_vpc_endpoint.guardduty_data.id
}

output "interface_endpoint_ids" {
  description = "IDs of the interface endpoints of the AWS APIs, by service (sts, ecr.api, ...)."
  value       = { for s, e in aws_vpc_endpoint.interface : s => e.id }
}

output "endpoints_security_group_id" {
  description = "ID of the security group of the interface endpoints of the AWS APIs: TCP 443 from the VPC range only."
  value       = aws_security_group.endpoints.id
}
