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
  name         = "svp-stg"
  cluster_name = "svp-stg"
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

run "flow_log_retention_days_not_offered" {
  command = plan

  variables {
    flow_log_retention_days = 2
  }

  expect_failures = [var.flow_log_retention_days]
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

# The defaults keep the network as it was: two zones, one NAT gateway, no flow log, an S3 endpoint without a policy.
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

  assert {
    condition     = module.vpc.vpc_flow_log_id == null
    error_message = "By default no flow log may be created."
  }
}

# Values of the prd root: three zones, one NAT gateway each, flow log, and the S3 endpoint limited to the env's
# buckets and the ECR layer bucket of the region.
run "prd_values" {
  command = plan

  variables {
    name                   = "svp-prd"
    cluster_name           = "svp-prd"
    az_count               = 3
    single_nat_gateway     = false
    flow_log_enabled       = true
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
