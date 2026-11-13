variable "name" {
  description = "Name of the env or stack (svp-stg, svp-prd, svp-security): prefix of the SNS topic <name>-alarms and of the KMS alias alias/<name>-alarms."
  type        = string

  validation {
    # A letter first, letters, digits and single hyphens, no hyphen last: valid in an SNS topic name and a KMS alias.
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "alarm_email" {
  description = "Email address subscribed to the topic; SNS sends it a confirmation link and delivers nothing until the link is opened."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alarm_email))
    error_message = "alarm_email must be an email address."
  }
}

variable "publisher_services" {
  description = "Service principals that publish to the topic and use its key, each limited to its own resources of this account and region: cloudwatch.amazonaws.com (alarms), events.amazonaws.com (EventBridge rules), aps.amazonaws.com (Alertmanager of the Prometheus workspace aps_workspace_arn)."
  type        = list(string)
  default     = ["cloudwatch.amazonaws.com"]

  validation {
    condition     = length(var.publisher_services) > 0 && length(distinct(var.publisher_services)) == length(var.publisher_services) && alltrue([for p in var.publisher_services : contains(["cloudwatch.amazonaws.com", "events.amazonaws.com", "aps.amazonaws.com"], p)])
    error_message = "publisher_services must list, without repeats, at least one of cloudwatch.amazonaws.com, events.amazonaws.com and aps.amazonaws.com."
  }

  validation {
    condition     = contains(var.publisher_services, "aps.amazonaws.com") == (var.aps_workspace_arn != null)
    error_message = "aps_workspace_arn must be set exactly when publisher_services lists aps.amazonaws.com."
  }
}

variable "aps_workspace_arn" {
  description = "ARN of the Amazon Managed Service for Prometheus workspace whose Alertmanager publishes to the topic (aws:SourceArn of the aps.amazonaws.com statement). Null: Prometheus does not publish."
  type        = string
  default     = null

  validation {
    condition     = var.aps_workspace_arn == null || can(regex("^arn:aws:aps:[a-z]{2}(-[a-z]+)+-[0-9]+:[0-9]{12}:workspace/ws-[0-9a-f-]+$", var.aps_workspace_arn))
    error_message = "aps_workspace_arn must be a workspace ARN such as arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-..., or null."
  }
}

variable "region" {
  description = "Region of the topic, its key and the alarms that may notify it (CloudWatch alarm actions reach a topic of their own region only). Null: the region of the provider."
  type        = string
  default     = null

  validation {
    condition     = var.region == null || can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name, e.g. us-east-1, or null."
  }
}
