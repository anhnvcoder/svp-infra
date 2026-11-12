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
  # delegation is on). Block 6 splits eight ways for the database subnets, one per zone (RDS, MSK, ElastiCache). Block 7
  # holds the public subnets (NAT gateways only) at its start and the edge subnets (internal ALB) in its back half.
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.cidr, 3, i)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(cidrsubnet(var.cidr, 3, 6), 3, i)]
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(cidrsubnet(var.cidr, 3, 7), 5, i)]
  edge_subnets     = [for i in range(var.az_count) : cidrsubnet(cidrsubnet(var.cidr, 3, 7), 4, 8 + i)]

  # Subnet discovery of the AWS Load Balancer Controller: an internet-facing load balancer goes to the subnets
  # tagged role/elb, an internal one to those tagged role/internal-elb. No subnet carries role/elb, so the controller
  # can make no internet-facing one. "shared" lets other clusters use the subnets too and tells the controller they are
  # not its to delete.
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }

  # The data tier gets a route table of its own with only the local route: no path to the internet either way. With
  # own_route_table false the vpc module attaches the database subnets to the private route tables, whose 0.0.0.0/0
  # goes to the NAT gateway. Kept in a local because route table IDs are unknown at plan time, so tests read this.
  database_routes = {
    own_route_table        = true
    nat_gateway_route      = false
    internet_gateway_route = false
  }

  # Entries of the NACL of each tier. No entry allows TCP or UDP to port 22 or 3389 from anywhere, so the ranges open
  # to the internet skip both ports. TCP, UDP and ICMP are named one by one instead of protocol -1: nothing in the VPC
  # speaks another IP protocol. Kept in locals for the tests: the rules are made inside the registry module.
  # Design notes: aws/modules/network/README.md.
  nacl_from_vpc = [for i, p in ["tcp", "udp", "icmp"] :
    { rule_number = 100 + i, rule_action = "allow", protocol = p, from_port = 0, to_port = p == "icmp" ? 0 : 65535, icmp_type = p == "icmp" ? -1 : null, icmp_code = p == "icmp" ? -1 : null, cidr_block = var.cidr }
  ]
  nacl_outbound = [for i, p in ["tcp", "udp", "icmp"] :
    { rule_number = 100 + i, rule_action = "allow", protocol = p, from_port = 0, to_port = p == "icmp" ? 0 : 65535, icmp_type = p == "icmp" ? -1 : null, icmp_code = p == "icmp" ? -1 : null, cidr_block = "0.0.0.0/0" }
  ]
  nacl_return_traffic = flatten([for i, p in ["tcp", "udp"] : [
    { rule_number = 120 + 20 * i, rule_action = "allow", protocol = p, from_port = 1024, to_port = 3388, cidr_block = "0.0.0.0/0" },
    { rule_number = 130 + 20 * i, rule_action = "allow", protocol = p, from_port = 3390, to_port = 65535, cidr_block = "0.0.0.0/0" },
  ]])
  nacl_icmp = [
    { rule_number = 160, rule_action = "allow", protocol = "icmp", from_port = 0, to_port = 0, icmp_type = -1, icmp_code = -1, cidr_block = "0.0.0.0/0" },
  ]
  # No tier takes TCP 443 from the internet: the public tier holds only NAT gateways, and inbound NACL rules do not
  # evaluate the traffic of CloudFront to the internal ALB in the edge tier.
  nacl_inbound = {
    public   = concat(local.nacl_from_vpc, local.nacl_return_traffic, local.nacl_icmp)
    private  = concat(local.nacl_from_vpc, local.nacl_return_traffic, local.nacl_icmp)
    edge     = local.nacl_from_vpc
    database = local.nacl_from_vpc
  }

  # Every subnet has the NACL of its tier, so the default NACL guards nothing and keeps no allow entry.
  default_nacl = {
    ingress = []
    egress  = []
  }

  # The default fields in their order, then those an investigation needs: subnet, instance and zone, the packet
  # addresses behind a NAT gateway or load balancer, the AWS service on either end, direction and path.
  flow_log_fields = [
    "version", "account-id", "interface-id", "srcaddr", "dstaddr", "srcport", "dstport", "protocol", "packets", "bytes",
    "start", "end", "action", "log-status", "vpc-id", "subnet-id", "instance-id", "tcp-flags", "type", "pkt-srcaddr",
    "pkt-dstaddr", "az-id", "pkt-src-aws-service", "pkt-dst-aws-service", "flow-direction", "traffic-path",
  ]
  flow_log = {
    destination_type           = "s3"
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
    max_aggregation_interval   = 60
    traffic_type               = "ALL"
    log_format                 = join(" ", [for f in local.flow_log_fields : "$${${f}}"])
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets
  public_subnets   = local.public_subnets

  # The edge tier is the registry module's intra tier: one route table with only the local route, since the ALB answers
  # CloudFront and reaches the pods inside the VPC. No node or pod takes an address there (VPC CNI uses the node's
  # subnet), so every connection from this range to Envoy comes from the ALB.
  intra_subnets       = local.edge_subnets
  intra_subnet_suffix = "edge"

  create_database_subnet_route_table     = local.database_routes.own_route_table
  create_database_nat_gateway_route      = local.database_routes.nat_gateway_route
  create_database_internet_gateway_route = local.database_routes.internet_gateway_route
  # The rds module makes the subnet group of its instance; a second one here would go unused.
  create_database_subnet_group = false

  # Nothing in a public subnet gets a public address by itself: nodes run in the private subnets, and the NAT
  # gateways get their Elastic IPs explicitly.
  map_public_ip_on_launch = false

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # The default security group is attached to anything created without a security group. Taking it over with no
  # rule at all means such a resource can neither receive nor send traffic, instead of talking to everything in it.
  manage_default_security_group  = true
  default_security_group_name    = "${var.name}-default"
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = local.cluster_tag
  # karpenter.sh/discovery: the EC2NodeClass of Karpenter launches nodes into the subnets with this tag.
  private_subnet_tags = merge(local.cluster_tag, {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  })

  manage_default_network_acl  = true
  default_network_acl_ingress = local.default_nacl.ingress
  default_network_acl_egress  = local.default_nacl.egress

  public_dedicated_network_acl   = true
  public_inbound_acl_rules       = local.nacl_inbound.public
  public_outbound_acl_rules      = local.nacl_outbound
  private_dedicated_network_acl  = true
  private_inbound_acl_rules      = local.nacl_inbound.private
  private_outbound_acl_rules     = local.nacl_outbound
  intra_dedicated_network_acl    = true
  intra_inbound_acl_rules        = local.nacl_inbound.edge
  intra_outbound_acl_rules       = local.nacl_outbound
  database_dedicated_network_acl = true
  database_inbound_acl_rules     = local.nacl_inbound.database
  database_outbound_acl_rules    = local.nacl_outbound

  # Straight into the bucket of the log archive account: delivery to S3 needs no IAM role here, the bucket and key
  # policies of that account let the log delivery service write.
  enable_flow_log                     = true
  flow_log_destination_type           = local.flow_log.destination_type
  flow_log_destination_arn            = var.flow_log_bucket_arn
  flow_log_file_format                = local.flow_log.file_format
  flow_log_hive_compatible_partitions = local.flow_log.hive_compatible_partitions
  flow_log_per_hour_partition         = local.flow_log.per_hour_partition
  flow_log_max_aggregation_interval   = local.flow_log.max_aggregation_interval
  flow_log_traffic_type               = local.flow_log.traffic_type
  flow_log_log_format                 = local.flow_log.log_format
}

# Gateway endpoint for S3 on every private route table: object traffic of the pods (uploads, HLS output) skips the NAT
# gateway, which bills every GB it processes. Gateway endpoints are free; an interface endpoint costs per hour and per
# zone. Without a policy (s3_endpoint_restricted = false) the endpoint lets through any bucket of the region that IAM
# allows, and the pods' NetworkPolicies, which match S3 by address, cannot tell one bucket from another.

# With the policy, only the env's buckets and the bucket ECR serves image layers from in this region
# (https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html) are reachable, so a stolen credential
# cannot copy data to a bucket of another account from inside the VPC.
# Design notes: aws/modules/network/README.md.
locals {
  s3_endpoint_policy = var.s3_endpoint_restricted ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The env's own buckets: what may be done in them is IAM's to decide, the endpoint only names the buckets.
        Sid       = "EnvBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource = flatten([for b in var.s3_endpoint_buckets : [
          "arn:${data.aws_partition.current.partition}:s3:::${b}",
          "arn:${data.aws_partition.current.partition}:s3:::${b}/*",
        ]])
      },
      {
        Sid       = "EcrImageLayers"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:${data.aws_partition.current.partition}:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*"
      },
    ]
  }) : null
}

data "aws_partition" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  policy            = local.s3_endpoint_policy

  tags = {
    Name = "${var.name}-s3"
  }
}

# Interface endpoint the GuardDuty agent of the EKS nodes sends runtime events to. Made here rather than left to
# GuardDuty, whose own endpoint and security group would sit outside the state and keep the VPC from being destroyed.
# The policy follows the GuardDuty guide: any call, but only by principals of this account.
data "aws_caller_identity" "current" {}

resource "aws_security_group" "guardduty_data" {
  name        = "${var.name}-guardduty-data"
  description = "Interface endpoint guardduty-data: HTTPS from the VPC"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.name}-guardduty-data"
  }
}

resource "aws_vpc_security_group_ingress_rule" "guardduty_data_https" {
  security_group_id = aws_security_group.guardduty_data.id
  description       = "GuardDuty agent on the nodes"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.cidr
}

locals {
  guardduty_data_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
      },
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_vpc_endpoint" "guardduty_data" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.guardduty-data"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.guardduty_data.id]
  private_dns_enabled = true
  policy              = local.guardduty_data_endpoint_policy

  tags = {
    Name = "${var.name}-guardduty-data"
  }
}
