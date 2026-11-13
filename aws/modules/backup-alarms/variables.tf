variable "name" {
  description = "Name of the env (svp-stg, svp-prd): prefix of the alarm names <name>-backup-job-failed and <name>-backup-copy-failed."
  type        = string

  validation {
    # A letter first, letters, digits and single hyphens, no hyphen last, as the other resource names of an env.
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "alarm_topic_arn" {
  description = "ARN of the SNS topic both alarms notify, when they fire and when they clear (topic_arn of the alarms module of the env)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be the ARN of an SNS topic."
  }
}
