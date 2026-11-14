variable "env" {
  description = "Environment of the account (stg, prd): names the workspaces `svp-<env>`, the log group `/svp/<env>/otel`, the KMS key `alias/svp-<env>-observability` and the role `svp-<env>-grafana`."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "amp_retention_days" {
  description = "Days the Prometheus workspace keeps metrics (1 to 1095, the range of Amazon Managed Service for Prometheus)."
  type        = number

  validation {
    condition     = var.amp_retention_days >= 1 && var.amp_retention_days <= 1095 && floor(var.amp_retention_days) == var.amp_retention_days
    error_message = "amp_retention_days must be a whole number of days from 1 to 1095."
  }
}

variable "log_retention_days" {
  description = "Days the log group `/svp/<env>/otel` keeps the application logs; one of the retention values CloudWatch Logs accepts."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "span_retention_days" {
  description = "Days the log group aws/spans, which X-Ray creates, keeps the spans; one of the retention values CloudWatch Logs accepts. Terraform cannot manage that group: the value goes into the command of the spans_retention_command output, run once per account."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.span_retention_days)
    error_message = "span_retention_days must be a retention CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "platform_admin_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-admins, given the ADMIN role of the Grafana workspace. Kept out of committed files: the root reads it from its uncommitted `<env>.auto.tfvars`."
  type        = string

  validation {
    condition     = can(regex("^([0-9a-f]{10}-)?[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$", var.platform_admin_group_id))
    error_message = "platform_admin_group_id must be an Identity Store group id: a UUID, optionally preceded by 10 hex digits and a dash."
  }
}

variable "platform_viewer_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-viewers, given the VIEWER role of the Grafana workspace. Kept out of committed files like platform_admin_group_id."
  type        = string

  validation {
    condition     = can(regex("^([0-9a-f]{10}-)?[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$", var.platform_viewer_group_id))
    error_message = "platform_viewer_group_id must be an Identity Store group id: a UUID, optionally preceded by 10 hex digits and a dash."
  }
}

variable "grafana_enabled" {
  description = "Whether the Amazon Managed Grafana workspace `svp-<env>` exists, with its role `svp-<env>-grafana`, group role associations, service account svp-grafana-operator and SSM parameter `/svp/<env>/grafana-workspace-id`. The Prometheus workspace, the key, the log groups and X-Ray stay at either value."
  type        = bool
  default     = true
}
