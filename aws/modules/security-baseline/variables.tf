variable "config_bucket_name" {
  description = "Name of the AWS Config bucket of the Log Archive account (svp-config-<log archive account>-<region>), where the delivery channels of both regions write."
  type        = string

  validation {
    # The S3 naming rules, without dots: a dotted name breaks the TLS certificate of virtual-hosted requests.
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.config_bucket_name))
    error_message = "config_bucket_name must be an S3 bucket name of 3 to 63 lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
}

variable "log_archive_key_arn" {
  description = "ARN of the KMS key of the Log Archive account in the home region, in its key/<id> form: the delivery channels encrypt with it."
  type        = string

  validation {
    condition     = can(regex("^arn:aws(-[a-z]+)*:kms:[a-z]{2}(-[a-z]+)+-[0-9]:[0-9]{12}:key/[A-Za-z0-9-]+$", var.log_archive_key_arn))
    error_message = "log_archive_key_arn must be the ARN of a KMS key in its key/<id> form, e.g. arn:aws:kms:ap-southeast-1:000000000000:key/<id>; an alias ARN never gives a clean plan."
  }
}

variable "security_event_bus_arn" {
  description = "ARN of the event bus svp-security-events of the Security Tooling account, target of every svp-security-* rule of the account."
  type        = string

  validation {
    condition     = can(regex("^arn:aws(-[a-z]+)*:events:[a-z]{2}(-[a-z]+)+-[0-9]:[0-9]{12}:event-bus/[A-Za-z0-9._-]+$", var.security_event_bus_arn))
    error_message = "security_event_bus_arn must be the ARN of an event bus, e.g. arn:aws:events:ap-southeast-1:000000000000:event-bus/svp-security-events."
  }
}

variable "ebs_kms_key_arn" {
  description = "ARN of the KMS key (key/<id> form, home region) that encrypts new EBS volumes of the home region by default; null keeps the AWS managed key aws/ebs. The other region always uses aws/ebs."
  type        = string
  default     = null

  validation {
    condition     = var.ebs_kms_key_arn == null || can(regex("^arn:aws(-[a-z]+)*:kms:[a-z]{2}(-[a-z]+)+-[0-9]:[0-9]{12}:key/[A-Za-z0-9-]+$", var.ebs_kms_key_arn))
    error_message = "ebs_kms_key_arn must be null or the ARN of a KMS key in its key/<id> form."
  }
}

variable "root_signin_regions" {
  description = "Regions of the rule svp-security-root-signin. CloudTrail records a console sign-in of the root user in us-east-1, us-east-2 or us-west-2: the management account passes all three, member accounts keep us-east-1 (other regions are denied to them)."
  type        = list(string)
  default     = ["us-east-1"]

  validation {
    condition = contains(var.root_signin_regions, "us-east-1") && length(distinct(var.root_signin_regions)) == length(var.root_signin_regions) && alltrue([
      for r in var.root_signin_regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", r))
    ])
    error_message = "root_signin_regions must be distinct AWS region names and hold us-east-1."
  }
}

variable "organization_events" {
  description = "Forward the events only the management account records: changes to AWS Organizations and its policies (svp-security-org) and AssumeRoot sessions (svp-security-root-session)."
  type        = bool
  default     = false
}

variable "admin_events" {
  description = "Forward successful administrative changes to IAM, KMS keys and S3 buckets (svp-security-admin-iam, svp-security-admin-kms-s3). For accounts where such a change is rare; an env account creates dozens of roles, keys and buckets per session."
  type        = bool
  default     = false
}

variable "identity_center_region" {
  description = "Region of the IAM Identity Center instance, for the account that holds it: forwards successful permission set and account assignment changes (svp-security-admin-sso), recorded in that region only. null: no such rule."
  type        = string
  default     = null

  validation {
    condition     = var.identity_center_region == null || can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.identity_center_region))
    error_message = "identity_center_region must be null or an AWS region name, e.g. ap-southeast-1."
  }
}
