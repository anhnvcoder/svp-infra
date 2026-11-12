# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects; then what the defaults keep and the values of prd. The AWS provider is a mock: nothing reaches an
# account, and data sources return the values below (a mocked list is empty otherwise, and the module takes its zones
# from it; the provider still validates arguments, so policies must be JSON).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c", "ap-southeast-1d", "ap-southeast-1e", "ap-southeast-1f"]
    }
  }
}

variables {
  name                = "svp-stg"
  cluster_name        = "svp-stg"
  flow_log_bucket_arn = "arn:aws:s3:::svp-flowlogs-111111111111-ap-southeast-1"
}

run "valid" {
  command = plan
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp"
  }

  expect_failures = [var.name]
}

run "cidr_too_small" {
  command = plan

  variables {
    cidr = "10.0.0.0/24"
  }

  expect_failures = [var.cidr]
}

run "az_count_one" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "cluster_name_leading_dash" {
  command = plan

  variables {
    cluster_name = "-svp"
  }

  expect_failures = [var.cluster_name]
}

run "flow_log_bucket_arn_name_only" {
  command = plan

  variables {
    flow_log_bucket_arn = "svp-flowlogs-111111111111-ap-southeast-1"
  }

  expect_failures = [var.flow_log_bucket_arn]
}

run "flow_log_bucket_arn_with_prefix" {
  command = plan

  variables {
    flow_log_bucket_arn = "arn:aws:s3:::svp-flowlogs-111111111111-ap-southeast-1/vpc"
  }

  expect_failures = [var.flow_log_bucket_arn]
}

run "s3_endpoint_buckets_arn" {
  command = plan

  variables {
    s3_endpoint_buckets = ["arn:aws:s3:::svp-stg-media-000000000000-ap-southeast-1"]
  }

  expect_failures = [var.s3_endpoint_buckets]
}

run "s3_endpoint_restricted_without_buckets" {
  command = plan

  variables {
    s3_endpoint_restricted = true
  }

  expect_failures = [var.s3_endpoint_buckets]
}

# The defaults: two zones, one NAT gateway, an S3 endpoint without a policy.
run "defaults" {
  command = plan

  assert {
    condition     = length(local.azs) == 2 && length(module.vpc.natgw_ids) <= 1
    error_message = "By default the VPC must span two zones with one NAT gateway."
  }

  assert {
    condition     = local.s3_endpoint_policy == null
    error_message = "By default the S3 endpoint must carry no policy."
  }
}

# Every NACL of the VPC passes the NACL check of CIS AWS Foundations and Security Hub EC2.21 (Config rule
# nacl-no-unrestricted-ssh-rdp): no inbound allow from 0.0.0.0/0 or ::/0 for TCP, UDP or all protocols whose port range
# holds 22 or 3389 (protocol -1 holds every port). The rules are made inside the registry module, so the run reads the
# lists this module passes it (local.nacl_inbound, local.default_nacl).
run "nacl" {
  command = plan

  assert {
    condition = alltrue([for r in flatten(values(local.nacl_inbound)) :
      !(r.rule_action == "allow" &&
        anytrue([for c in [try(r.cidr_block, ""), try(r.ipv6_cidr_block, "")] : contains(["0.0.0.0/0", "::/0"], c)]) &&
        contains(["-1", "all", "6", "tcp", "17", "udp"], r.protocol) &&
      (contains(["-1", "all"], r.protocol) || anytrue([for p in [22, 3389] : r.from_port <= p && p <= r.to_port])))
    ])
    error_message = "No NACL may allow TCP or UDP to port 22 or 3389 from 0.0.0.0/0 or ::/0."
  }

  assert {
    condition     = length(local.default_nacl.ingress) == 0 && length(local.default_nacl.egress) == 0
    error_message = "The default NACL must keep no entry: every subnet has the NACL of its tier."
  }

  assert {
    condition = alltrue([for tier, rules in local.nacl_inbound : alltrue([for proto in ["tcp", "udp", "icmp"] :
      anytrue([for r in rules : r.rule_action == "allow" && r.protocol == proto && r.cidr_block == "10.0.0.0/16" &&
      (proto == "icmp" ? r.icmp_type == -1 && r.icmp_code == -1 : r.from_port == 0 && r.to_port == 65535)])
    ])])
    error_message = "The NACL of every tier must still allow TCP and UDP on every port and every ICMP type from the VPC range."
  }

  assert {
    condition = alltrue([for proto in ["tcp", "udp", "icmp"] :
      anytrue([for r in local.nacl_outbound : r.rule_action == "allow" && r.protocol == proto && r.cidr_block == "0.0.0.0/0" &&
      (proto == "icmp" ? r.icmp_type == -1 && r.icmp_code == -1 : r.from_port == 0 && r.to_port == 65535)])
    ])
    error_message = "Every NACL must let TCP, UDP and ICMP out to anywhere."
  }

  # Protocol -1 would also let through IP protocols nothing in the VPC uses (trivy AWS-0102).
  assert {
    condition     = !anytrue([for r in concat(flatten(values(local.nacl_inbound)), local.nacl_outbound) : contains(["-1", "all"], r.protocol)])
    error_message = "No NACL entry may use protocol -1: name TCP, UDP and ICMP."
  }

  assert {
    condition     = alltrue([for r in local.nacl_inbound.database : r.cidr_block == "10.0.0.0/16"])
    error_message = "The database NACL must let in nothing from outside the VPC."
  }

  # Return traffic from the internet reaches the NAT gateway and the nodes on every port from 1024 except 3389, for TCP
  # and UDP; the NLB listener takes TCP 443 in the public tier only.
  assert {
    condition = alltrue([for tier in ["public", "private"] : alltrue([for proto in ["tcp", "udp"] : alltrue([for p in [1024, 3388, 3390, 32768, 60999, 65535] :
      anytrue([for r in local.nacl_inbound[tier] : r.rule_action == "allow" && r.cidr_block == "0.0.0.0/0" && r.protocol == proto && r.from_port <= p && p <= r.to_port])
    ])])])
    error_message = "The public and private NACLs must let in TCP and UDP return traffic on 1024-3388 and 3390-65535."
  }

  assert {
    condition = (anytrue([for r in local.nacl_inbound.public : r.protocol == "tcp" && r.from_port == 443 && r.to_port == 443 && r.cidr_block == "0.0.0.0/0"]) &&
    !anytrue([for r in local.nacl_inbound.private : r.cidr_block == "0.0.0.0/0" && r.from_port <= 443 && 443 <= r.to_port && r.protocol != "icmp"]))
    error_message = "TCP 443 from the internet must reach the public subnets (NLB listener) and no other tier."
  }

  assert {
    condition     = alltrue([for tier, rules in local.nacl_inbound : length(distinct([for r in rules : r.rule_number])) == length(rules)])
    error_message = "Rule numbers must be unique within each NACL."
  }
}

# Flow logs go straight to the bucket of the log archive account: Parquet, Hive-style prefixes, hourly partitions,
# 60-second aggregation, every field an investigation reads; no CloudWatch log group or IAM role.
run "flow_log" {
  command = plan

  assert {
    condition     = module.vpc.vpc_flow_log_destination_type == "s3" && module.vpc.vpc_flow_log_destination_arn == "arn:aws:s3:::svp-flowlogs-111111111111-ap-southeast-1"
    error_message = "The flow log must be delivered to the S3 bucket given in flow_log_bucket_arn."
  }

  assert {
    condition     = module.vpc.vpc_flow_log_cloudwatch_iam_role_arn == ""
    error_message = "The flow log must need no IAM role or CloudWatch log group."
  }

  assert {
    condition = (local.flow_log.file_format == "parquet" && local.flow_log.hive_compatible_partitions &&
    local.flow_log.per_hour_partition && local.flow_log.max_aggregation_interval == 60 && local.flow_log.traffic_type == "ALL")
    error_message = "The flow log must hold all traffic in Parquet, with Hive-compatible hourly partitions and 60-second aggregation."
  }

  assert {
    condition     = startswith(local.flow_log.log_format, "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} ")
    error_message = "The flow log format must start with the default fields in their order."
  }

  assert {
    condition = alltrue([for f in ["vpc-id", "subnet-id", "instance-id", "tcp-flags", "type", "pkt-srcaddr", "pkt-dstaddr", "az-id", "pkt-src-aws-service", "pkt-dst-aws-service", "flow-direction", "traffic-path"] :
    contains(split(" ", local.flow_log.log_format), "$${${f}}")])
    error_message = "The flow log format must add the fields an investigation reads."
  }
}

# The interface endpoint of the GuardDuty agent: private DNS on, HTTPS from the VPC only, a policy that denies every
# principal of another account.
run "guardduty_data_endpoint" {
  command = plan

  assert {
    condition = (aws_vpc_endpoint.guardduty_data.service_name == "com.amazonaws.ap-southeast-1.guardduty-data" &&
      aws_vpc_endpoint.guardduty_data.vpc_endpoint_type == "Interface" &&
    aws_vpc_endpoint.guardduty_data.private_dns_enabled)
    error_message = "guardduty-data must be an interface endpoint with private DNS, so the agent resolves the service name to it."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.guardduty_data_https.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.guardduty_data_https.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.guardduty_data_https.to_port == 443 &&
    aws_vpc_security_group_ingress_rule.guardduty_data_https.cidr_ipv4 == "10.0.0.0/16")
    error_message = "The endpoint's security group must let in TCP 443 from the VPC range only."
  }

  assert {
    condition = (jsondecode(aws_vpc_endpoint.guardduty_data.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_vpc_endpoint.guardduty_data.policy).Statement[1].Effect == "Deny" &&
      jsondecode(aws_vpc_endpoint.guardduty_data.policy).Statement[1].Condition.StringNotEquals["aws:PrincipalAccount"] == "000000000000" &&
    length(jsondecode(aws_vpc_endpoint.guardduty_data.policy).Statement) == 2)
    error_message = "The endpoint policy must deny every principal outside the env's account."
  }
}

# Values of the prd root: three zones, one NAT gateway each, and the S3 endpoint limited to the env's buckets and the
# ECR layer bucket of the region.
run "prd_values" {
  command = plan

  variables {
    name                   = "svp-prd"
    cluster_name           = "svp-prd"
    az_count               = 3
    single_nat_gateway     = false
    s3_endpoint_restricted = true
    s3_endpoint_buckets    = ["svp-prd-uploads-222222222222-ap-southeast-1", "svp-prd-media-222222222222-ap-southeast-1"]
  }

  assert {
    condition     = length(local.azs) == 3 && length(module.vpc.natgw_ids) == 3
    error_message = "prd must span three zones, each with its own NAT gateway."
  }

  assert {
    condition     = length(module.vpc.private_route_table_ids) == 3
    error_message = "prd must route each private subnet through the NAT gateway of its own zone."
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.s3.policy).Statement[0].Resource == ["arn:aws:s3:::svp-prd-uploads-222222222222-ap-southeast-1", "arn:aws:s3:::svp-prd-uploads-222222222222-ap-southeast-1/*", "arn:aws:s3:::svp-prd-media-222222222222-ap-southeast-1", "arn:aws:s3:::svp-prd-media-222222222222-ap-southeast-1/*"]
    error_message = "The S3 endpoint of prd must let through the env's buckets and nothing else besides the ECR layer bucket."
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.s3.policy).Statement[1].Resource == "arn:aws:s3:::prod-ap-southeast-1-starport-layer-bucket/*" && jsondecode(aws_vpc_endpoint.s3.policy).Statement[1].Action == "s3:GetObject"
    error_message = "The S3 endpoint of prd must let nodes read the image layers of Amazon ECR in the region, read-only."
  }

  assert {
    condition     = length(jsondecode(aws_vpc_endpoint.s3.policy).Statement) == 2
    error_message = "The S3 endpoint policy of prd must hold exactly the two statements."
  }

  # Karpenter launches nodes only into the subnets with its discovery tag: every private subnet, nothing else.
  assert {
    condition     = length(module.vpc.private_subnet_objects) == 3 && alltrue([for s in module.vpc.private_subnet_objects : s.tags["karpenter.sh/discovery"] == "svp-prd"])
    error_message = "Every private subnet of prd must carry karpenter.sh/discovery = svp-prd."
  }

  assert {
    condition     = alltrue([for s in concat(module.vpc.public_subnet_objects, module.vpc.database_subnet_objects) : !contains(keys(s.tags), "karpenter.sh/discovery")])
    error_message = "Public and database subnets must not carry karpenter.sh/discovery: Karpenter would launch nodes there."
  }
}


# The data tier with the defaults (two zones, a /16): one database subnet per zone in block 6 of the range (the
# private subnets hold blocks 0 to 5, the public ones block 7), a route table of its own with no route out, and no
# subnet discovery tag of the Load Balancer Controller.
run "database_subnets" {
  command = plan

  assert {
    condition     = length(module.vpc.database_subnets) == 2
    error_message = "Each zone must get one database subnet."
  }

  assert {
    condition     = module.vpc.database_subnets_cidr_blocks == tolist(["10.0.192.0/22", "10.0.196.0/22"])
    error_message = "The database subnets must split block 6 (10.0.192.0/19) of the VPC range."
  }

  assert {
    condition     = module.vpc.private_subnets_cidr_blocks == tolist(["10.0.0.0/19", "10.0.32.0/19"]) && module.vpc.public_subnets_cidr_blocks == tolist(["10.0.224.0/24", "10.0.225.0/24"])
    error_message = "The database subnets must leave the private and public subnets where they were."
  }

  assert {
    condition     = local.database_routes.own_route_table && length(module.vpc.database_route_table_ids) >= 1
    error_message = "The database subnets must have a route table of their own, not the private one that routes to the NAT gateway."
  }

  assert {
    condition     = length(module.vpc.database_nat_gateway_route_ids) == 0 && module.vpc.database_internet_gateway_route_id == null && module.vpc.database_ipv6_egress_route_id == null
    error_message = "The database route table must hold no route to a NAT gateway or the internet gateway (no 0.0.0.0/0)."
  }

  assert {
    condition     = alltrue([for s in module.vpc.database_subnet_objects : length([for k in keys(s.tags) : k if startswith(k, "kubernetes.io/")]) == 0])
    error_message = "The database subnets must carry no tag the Load Balancer Controller reads to pick subnets."
  }

  assert {
    condition     = module.vpc.database_subnet_group == null
    error_message = "The network module must not make a DB subnet group: the rds module makes its own."
  }
}

# Three zones (prd) and the most zones on the smallest range: the database subnets still fill only block 6, between
# the last private subnet and the first public one.
run "database_subnets_prd" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = false
  }

  assert {
    condition     = module.vpc.database_subnets_cidr_blocks == tolist(["10.0.192.0/22", "10.0.196.0/22", "10.0.200.0/22"])
    error_message = "prd must get one database subnet per zone in block 6 of the VPC range."
  }

  assert {
    condition     = length(module.vpc.database_route_table_ids) == 3 && length(module.vpc.database_nat_gateway_route_ids) == 0 && module.vpc.database_internet_gateway_route_id == null
    error_message = "With one NAT gateway per zone the database route tables must still hold no route out."
  }
}

run "database_subnets_six_zones" {
  command = plan

  variables {
    cidr     = "10.0.0.0/20"
    az_count = 6
  }

  assert {
    condition     = module.vpc.database_subnets_cidr_blocks == tolist(["10.0.12.0/26", "10.0.12.64/26", "10.0.12.128/26", "10.0.12.192/26", "10.0.13.0/26", "10.0.13.64/26"])
    error_message = "Six zones on a /20 must get six database subnets inside block 6 (10.0.12.0/23)."
  }

  assert {
    condition     = module.vpc.private_subnets_cidr_blocks[5] == "10.0.10.0/23" && module.vpc.public_subnets_cidr_blocks[0] == "10.0.14.0/28"
    error_message = "The private subnets must end below block 6 and the public ones start above it."
  }
}
