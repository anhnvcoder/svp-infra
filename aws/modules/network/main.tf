data "aws_region" "current" {}

# Zones that every account has; opt-in zones (Local Zones, Wavelength) are left out because EKS managed node groups
# and NAT gateways are not offered in all of them.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # The VPC range splits into eight equal blocks. Blocks 0 to 5 are the private subnets, one per zone: the largest
  # ones, because every pod takes a VPC address from them (VPC CNI, with /28 prefixes per node when prefix
  # delegation is on). Block 7 splits again into 32 small public subnets, one per zone: only the NAT gateways and
  # the network load balancers live there. Block 6 stays free for later use (database or intra subnets).
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.cidr, 3, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(cidrsubnet(var.cidr, 3, 7), 5, i)]

  # Subnet discovery of the AWS Load Balancer Controller: an internet-facing load balancer goes to the subnets
  # tagged role/elb, an internal one to those tagged role/internal-elb. "shared" lets other clusters use them too
  # and tells the controller the subnets are not its to delete.
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Nothing in a public subnet gets a public address by itself: nodes run in the private subnets, and the NAT
  # gateways and load balancers get their addresses explicitly.
  map_public_ip_on_launch = false

  enable_dns_support   = true
  enable_dns_hostnames = true

  # single_nat_gateway = true: one NAT gateway and one private route table. false: one NAT gateway, Elastic IP and
  # private route table per zone, each private subnet routed to the NAT gateway of its own zone.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # The default security group is attached to anything created without a security group. Taking it over with no
  # rule at all means such a resource can neither receive nor send traffic, instead of talking to everything in it.
  manage_default_security_group  = true
  default_security_group_name    = "${var.name}-default"
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags  = merge(local.cluster_tag, { "kubernetes.io/role/elb" = "1" })
  private_subnet_tags = merge(local.cluster_tag, { "kubernetes.io/role/internal-elb" = "1" })

  enable_flow_log                                 = var.flow_log_enabled
  create_flow_log_cloudwatch_log_group            = var.flow_log_enabled
  create_flow_log_cloudwatch_iam_role             = var.flow_log_enabled
  flow_log_traffic_type                           = "ALL"
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  # Named after the VPC so that a sweep can tell which env a leftover role belongs to (the module adds a suffix).
  vpc_flow_log_iam_role_name   = "${var.name}-vpc-flow-log"
  vpc_flow_log_iam_policy_name = "${var.name}-vpc-flow-log"
}

# Gateway endpoint for S3 on every private route table: object traffic of the pods (uploads, HLS output) stays on
# the AWS network instead of going through the NAT gateway, which bills every GB it processes. Gateway endpoints are
# free. No interface endpoint: each costs per hour and per zone.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.name}-s3"
  }
}
