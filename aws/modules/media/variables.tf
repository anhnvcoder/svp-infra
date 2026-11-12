variable "name_prefix" {
  description = "Fixed start of every name (svp-stg, svp-prd): buckets are <name_prefix>-uploads-<account_id>-<region> and <name_prefix>-media-<account_id>-<region>."
  type        = string

  validation {
    # Bucket names: lowercase letters, digits and hyphens, at most 63 characters with "-uploads-", the 12 digits of the
    # account, a hyphen and a region of up to 14 characters (ap-southeast-1).
    condition     = can(regex("^[a-z][a-z0-9-]{0,25}[a-z0-9]$", var.name_prefix)) && !strcontains(var.name_prefix, "--")
    error_message = "name_prefix must be 2 to 27 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "account_id" {
  description = "The AWS account of the buckets (12 digits), part of their names. The root passes its own account_id, which never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the buckets, part of their names; the root passes the region of its provider."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region)) && length(var.region) <= 14
    error_message = "region must be an AWS region name of at most 14 characters, e.g. ap-southeast-1."
  }
}

variable "cors_allowed_origins" {
  description = "Origins of the web client (https://<domain>) that the CORS rules of the two buckets allow: POST of upload forms to the uploads bucket, GET and HEAD on the media bucket. Off the flat-rate Free plan the distribution allows the same origins for GET and HEAD; on it, every origin."
  type        = list(string)

  validation {
    # Bare origins only, so a typo cannot widen the rule to every site (a *) or break it (a path).
    condition     = length(var.cors_allowed_origins) > 0 && alltrue([for o in var.cors_allowed_origins : can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]+)?$", o))])
    error_message = "cors_allowed_origins must hold at least one origin like https://svp.example, without path or wildcard."
  }
}

# No default: true deletes every object of both buckets on destroy, which is what a lab session wants and what
# production must never do.
variable "force_destroy" {
  description = "Let terraform destroy delete both buckets with every object in them. Without it destroy fails on a bucket that is not empty."
  type        = bool
}

variable "versioning_enabled" {
  description = "Keep earlier versions of overwritten and deleted objects in both buckets, each for 30 days after it was replaced (a lifecycle rule then deletes it). Off by default: objects are written once, and kept versions keep deleted bytes billed."
  type        = bool
  default     = false
}

variable "access_logging_enabled" {
  description = "Write S3 server access logs of both buckets to a third bucket, <name_prefix>-logs-<account_id>-<region>, which this module creates (private, TLS only, SSE-S3, logs deleted after 90 days). Off by default."
  type        = bool
  default     = false
}

variable "web_acl_arn" {
  description = "ARN of the AWS WAF web ACL of scope CLOUDFRONT (in us-east-1, output web_acl_arn of the waf module) in front of the distribution. With flat_rate_free the plan requires one and covers it, and AWS refuses to detach or replace it while the plan lasts."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:wafv2:us-east-1:[0-9]{12}:global/webacl/[A-Za-z0-9_-]+/[0-9a-f-]+$", var.web_acl_arn))
    error_message = "web_acl_arn must be the ARN of a WAF web ACL of scope CLOUDFRONT, arn:aws:wafv2:us-east-1:<account>:global/webacl/<name>/<id>."
  }
}

variable "domain" {
  description = "Name of the env's hosted zone (svp.example): the distribution answers at `media.<domain>`, with its own certificate."
  type        = string

  validation {
    # ACM takes a domain name of at most 64 characters, media.<domain> included.
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain)) && length(var.domain) <= 58
    error_message = "domain must be a lowercase DNS name of at most 58 characters without a trailing dot, e.g. svp.example."
  }
}

variable "hosted_zone_id" {
  description = "ID of the Route 53 public hosted zone of domain: the module writes the ACM validation record and the A and AAAA alias records of `media.<domain>` there."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone ID such as Z0123456789ABCDEFGHIJ, without the /hostedzone/ prefix."
  }
}

# No default: each env states its plan.
variable "flat_rate_free" {
  description = "Subscribe the distribution to the CloudFront flat-rate Free plan (managed Managed-SimpleCORS headers policy, no access log). false: pay-as-you-go, with the module's own CORS and security headers policy and standard logs to log_delivery_destination_arn."
  type        = bool
}

variable "log_delivery_destination_arn" {
  description = "ARN of the CloudWatch Logs delivery destination (us-east-1, in the Log Archive account) that receives the standard logs of the distribution, `arn:aws:logs:us-east-1:<account>:delivery-destination:svp-cloudfront-<env>`. Required when flat_rate_free is false; unused when it is true (the Free plan has no access log)."
  type        = string
  default     = null

  validation {
    condition     = var.flat_rate_free || var.log_delivery_destination_arn != null
    error_message = "log_delivery_destination_arn is required when flat_rate_free is false: a pay-as-you-go distribution writes standard logs."
  }

  validation {
    condition     = var.log_delivery_destination_arn == null || can(regex("^arn:aws[a-z-]*:logs:us-east-1:[0-9]{12}:delivery-destination:[A-Za-z0-9._-]+$", var.log_delivery_destination_arn))
    error_message = "log_delivery_destination_arn must be the ARN of a CloudWatch Logs delivery destination in us-east-1, arn:aws:logs:us-east-1:<account>:delivery-destination:<name>."
  }
}
