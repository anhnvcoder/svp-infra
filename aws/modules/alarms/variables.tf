variable "name" {
  description = "Name of the env (svp-stg, svp-prd): prefix of the SNS topic <name>-alarms and of the KMS alias alias/<name>-alarms."
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
