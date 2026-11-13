variable "name" {
  description = "Name of the VPC and prefix of the names of its subnets, route tables, NAT gateways and Elastic IPs, e.g. svp-stg."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 24 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "cidr" {
  description = "IPv4 range of the VPC, a /16 to /20. Pods take their addresses from the private subnets (VPC CNI), so the range must not overlap any network the cluster talks to."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be an IPv4 range from /16 to /20, e.g. 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones, taken in order from the zones of the region that need no opt-in. Each zone gets one public, one private, one edge and one database subnet. EKS needs subnets in at least two zones."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6 && floor(var.az_count) == var.az_count
    error_message = "az_count must be a whole number from 2 to 6."
  }
}

variable "interface_endpoint_az_count" {
  description = "Number of zones, from the first, whose private subnet holds a network interface of each interface endpoint of the AWS APIs. Fewer zones cost less; a caller in another zone then crosses zones, and losing those zones cuts every AWS API call of the VPC."
  type        = number

  validation {
    condition     = floor(var.interface_endpoint_az_count) == var.interface_endpoint_az_count && var.interface_endpoint_az_count >= 1 && var.interface_endpoint_az_count <= var.az_count
    error_message = "interface_endpoint_az_count must be a whole number from 1 to az_count."
  }
}

variable "single_nat_gateway" {
  description = "true: one NAT gateway, in the first zone, for every private subnet (cheaper; losing that zone cuts the egress of the whole VPC). false: one NAT gateway per zone and one private route table per zone that sends its traffic to the NAT gateway of the same zone."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Name of the EKS cluster that runs in this VPC. The public and private subnets get the tag kubernetes.io/cluster/<name> = shared, which the AWS Load Balancer Controller reads to pick subnets; the private subnets also get karpenter.sh/discovery = <name>, which the EC2NodeClass of Karpenter reads."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be a valid EKS cluster name: 1 to 100 letters, digits, dashes or underscores, starting with a letter or digit."
  }
}

variable "flow_log_bucket_arn" {
  description = "ARN of the S3 bucket of the log archive account that receives the VPC flow logs (accepted and rejected traffic), e.g. arn:aws:s3:::svp-flowlogs-000000000000-ap-southeast-1. The bucket ARN alone, no prefix: the logs land under AWSLogs/aws-account-id=<account>/, which the bucket's retention rules match."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.flow_log_bucket_arn))
    error_message = "flow_log_bucket_arn must be the ARN of an S3 bucket with no prefix, e.g. arn:aws:s3:::svp-flowlogs-000000000000-ap-southeast-1."
  }
}

variable "s3_endpoint_restricted" {
  description = "Put a policy on the S3 gateway endpoint that lets through only the buckets of s3_endpoint_buckets and the image layer bucket of Amazon ECR in the region; every other bucket of the region is then unreachable from the private subnets. Off by default: the endpoint lets through every bucket IAM allows."
  type        = bool
  default     = false
}

variable "s3_endpoint_buckets" {
  description = "Names of the buckets of the env (uploads and media) reachable through the S3 gateway endpoint when s3_endpoint_restricted is true."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for b in var.s3_endpoint_buckets : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b))])
    error_message = "s3_endpoint_buckets must hold bucket names (3 to 63 lowercase letters, digits, dots and hyphens), not ARNs."
  }

  validation {
    condition     = !var.s3_endpoint_restricted || length(var.s3_endpoint_buckets) > 0
    error_message = "s3_endpoint_buckets must name at least one bucket while s3_endpoint_restricted is true."
  }
}
