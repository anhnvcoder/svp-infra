variable "name" {
  description = "Name of the VPC and prefix of the names of its subnets, route tables, NAT gateways and Elastic IPs, e.g. svp-stg."
  type        = string

  validation {
    # 24 characters at most: with the flow log on, the vpc module names its IAM role with name_prefix
    # "<name>-vpc-flow-log-" (14 characters), and the provider caps a role name_prefix at 38.
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
  description = "Number of availability zones, taken in order from the zones of the region that need no opt-in. Each zone gets one public and one private subnet. EKS needs subnets in at least two zones."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6 && floor(var.az_count) == var.az_count
    error_message = "az_count must be a whole number from 2 to 6."
  }
}

variable "single_nat_gateway" {
  description = "true: one NAT gateway, in the first zone, for every private subnet (cheaper; losing that zone cuts the egress of the whole VPC). false: one NAT gateway per zone and one private route table per zone that sends its traffic to the NAT gateway of the same zone."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Name of the EKS cluster that runs in this VPC. The subnets get the tag kubernetes.io/cluster/<name> = shared, which the AWS Load Balancer Controller reads to pick subnets."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be a valid EKS cluster name: 1 to 100 letters, digits, dashes or underscores, starting with a letter or digit."
  }
}

variable "flow_log_enabled" {
  description = "Send VPC flow logs (accepted and rejected traffic) to a CloudWatch log group that this module creates, with the IAM role that writes it. Off by default: ingestion is billed per GB."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Days CloudWatch keeps the flow logs when flow_log_enabled is true."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a retention CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}
