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
  description = "IDs of the private subnets, one per zone, in the order of azs: nodes, pods, database."
  value       = module.vpc.private_subnets
}

output "private_subnet_cidrs" {
  description = "IPv4 ranges of the private subnets, in the order of azs; network policies that allow traffic to a database in these subnets use them."
  value       = module.vpc.private_subnets_cidr_blocks
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per zone, in the order of azs: NAT gateways and internet-facing load balancers."
  value       = module.vpc.public_subnets
}

output "nat_public_ips" {
  description = "Public IPv4 addresses of the NAT gateways: every connection from the nodes and pods to the internet leaves from one of them."
  value       = module.vpc.nat_public_ips
}
