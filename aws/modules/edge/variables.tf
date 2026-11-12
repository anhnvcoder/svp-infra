variable "name" {
  description = "Fixed start of every name (svp-stg, svp-prd): ALB and VPC origin `<name>-edge`, target group `<name>-envoy`, distributions and response headers policies `<name>-web` and `<name>-api`."
  type        = string

  validation {
    # Load balancer and target group names hold at most 32 characters; "-envoy" takes 6 of them.
    condition     = can(regex("^[a-z][a-z0-9-]{0,24}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 26 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "domain" {
  description = "Name of the env's hosted zone (svp.example): the web answers at `<domain>`, the API at `api.<domain>`."
  type        = string

  validation {
    # ACM takes a domain name of at most 64 characters; api.<domain> is the longest name of the module.
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain)) && length(var.domain) <= 60
    error_message = "domain must be a lowercase DNS name of at most 60 characters without a trailing dot, e.g. svp.example."
  }
}

variable "hosted_zone_id" {
  description = "ID of the Route 53 public hosted zone of domain: the module writes the ACM validation records and the alias records of both names there."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone ID such as Z0123456789ABCDEFGHIJ, without the /hostedzone/ prefix."
  }
}

variable "vpc_id" {
  description = "VPC of the load balancer, its security group and the target group."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID such as vpc-0123456789abcdef0."
  }
}

variable "subnet_ids" {
  description = "Edge subnets of the VPC, one per availability zone (output edge_subnet_ids of the network module): the internal ALB and the network interfaces of the CloudFront VPC origin live there."
  type        = list(string)

  validation {
    # An Application Load Balancer needs subnets in at least two availability zones.
    condition     = length(var.subnet_ids) >= 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold at least two subnet IDs such as subnet-0123456789abcdef0, in two availability zones."
  }
}

variable "node_security_group_id" {
  description = "Security group of the EKS nodes and, with the VPC CNI, of their pods (output node_security_group_id of the eks module): the module lets the ALB reach Envoy on it."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.node_security_group_id))
    error_message = "node_security_group_id must be a security group ID such as sg-0123456789abcdef0."
  }
}

variable "web_acl_arns" {
  description = "ARNs of the AWS WAF web ACLs of scope CLOUDFRONT (us-east-1, output web_acl_arn of the waf module), keyed web and api: each guards the distribution of the same name."
  type        = map(string)

  validation {
    condition = toset(keys(var.web_acl_arns)) == toset(["web", "api"]) && alltrue([
      for a in values(var.web_acl_arns) : can(regex("^arn:aws[a-z-]*:wafv2:us-east-1:[0-9]{12}:global/webacl/[A-Za-z0-9_-]+/[0-9a-f-]+$", a))
    ])
    error_message = "web_acl_arns must have exactly the keys web and api, each the ARN of a WAF web ACL of scope CLOUDFRONT, arn:aws:wafv2:us-east-1:<account>:global/webacl/<name>/<id>."
  }
}

variable "log_delivery_destination_arn" {
  description = "ARN of the CloudWatch Logs delivery destination (us-east-1, in the Log Archive account) that receives the standard logs of both distributions, `arn:aws:logs:us-east-1:<account>:delivery-destination:svp-cloudfront-<env>`."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:logs:us-east-1:[0-9]{12}:delivery-destination:[A-Za-z0-9._-]+$", var.log_delivery_destination_arn))
    error_message = "log_delivery_destination_arn must be the ARN of a CloudWatch Logs delivery destination in us-east-1, arn:aws:logs:us-east-1:<account>:delivery-destination:<name>."
  }
}

# No default: each env states it. true keeps the ALB through a destroy that should not have reached it; a lab session
# turns it off before its teardown.
variable "alb_deletion_protection" {
  description = "Deletion protection of the ALB: while it is on, terraform destroy fails at the load balancer."
  type        = bool
}
