variable "name" {
  description = "Identifier of the DB instance (svp-stg, svp-prd), also the prefix of its security group, subnet group and parameter group."
  type        = string

  validation {
    # The rules of an RDS identifier: a letter first, letters, digits and single hyphens, no hyphen last. 40 characters
    # leave room for the suffixes Terraform adds to the name prefixes.
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "vpc_id" {
  description = "VPC of the instance and of its security group."
  type        = string
}

variable "subnet_ids" {
  description = "Database subnets of the DB subnet group (the tier of the VPC with no route to the internet), in at least two availability zones (RDS requires two even for a single-AZ instance, and a Multi-AZ standby goes in the other one)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must hold at least two subnets, in two availability zones."
  }
}

variable "allowed_security_groups" {
  description = "Security groups whose members may connect on 5432 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not."
  type        = map(string)

  validation {
    condition     = length(var.allowed_security_groups) > 0
    error_message = "allowed_security_groups must name at least one security group; an instance nobody can reach is a mistake."
  }
}

variable "engine_major_version" {
  description = "Major version of PostgreSQL. RDS picks the newest minor of it and upgrades minors in the maintenance window; a major upgrade is a change of its own."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 17."
  }
}

variable "instance_class" {
  description = "DB instance class: db.t4g.small (stg) or db.m7g.large (prd), the classes whose memory, vCPU count and default max_connections the alarm thresholds are written for."
  type        = string
  default     = "db.t4g.small"

  validation {
    condition     = contains(keys(local.class_alarm_thresholds), var.instance_class)
    error_message = "instance_class must be db.t4g.small or db.m7g.large; another class needs its alarm thresholds added to the module first."
  }
}

variable "allocated_storage" {
  description = "Size of the gp3 volume, in GiB (20 is the gp3 minimum of RDS PostgreSQL)."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be at least 20 GiB."
  }
}

variable "max_allocated_storage" {
  description = "Upper limit, in GiB, up to which storage autoscaling grows the volume when free space runs low. At least 26 % above allocated_storage, so RDS does not warn that the limit is too close."
  type        = number
  default     = 40

  validation {
    condition     = var.max_allocated_storage >= ceil(var.allocated_storage * 1.26)
    error_message = "max_allocated_storage must be at least 26 % above allocated_storage."
  }
}

variable "backup_copy_account_id" {
  description = "AWS account (12 digits) that receives the cross-account copies of the instance's backups. The key policy of the instance's KMS key lets this account decrypt the snapshots and create grants for AWS resources, which a copy across accounts needs."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.backup_copy_account_id))
    error_message = "backup_copy_account_id must be the 12 digits of an AWS account id."
  }
}

variable "alarm_topic_arn" {
  description = "ARN of the SNS topic every CloudWatch alarm of the instance notifies, when it fires and when it clears."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be the ARN of an SNS topic."
  }
}

variable "multi_az" {
  description = "Keep a synchronous standby in a second availability zone, which takes over on failure (twice the instance cost). Off for a lab env that lives a few hours, on for production."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days of automated backups and point-in-time recovery. At least 1: 0 turns backups off."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

# Defaults to the lab value, like the cost variables above: production sets false.
variable "delete_automated_backups" {
  description = "Delete the automated backups, and with them the point-in-time recovery window, together with the instance, so a destroyed lab instance leaves no billed backup behind. Production keeps them (false): after a deletion they stay restorable to any second of the retention period, where the final snapshot alone holds one moment."
  type        = bool
  default     = true
}

# No default for the next two: a forgotten value either loses the data of production or blocks the destroy of a lab
# session, so each env says what it wants.
variable "deletion_protection" {
  description = "Refuse to delete the instance until this is turned off by an apply. Off where the instance is destroyed at the end of every session, on for production."
  type        = bool
}

variable "skip_final_snapshot" {
  description = "Delete the instance without a last manual snapshot. A final snapshot outlives the instance, is billed as backup storage and must be deleted by hand; skip it only where the data is disposable."
  type        = bool
}

variable "performance_insights_enabled" {
  description = "Turn on Performance Insights (database load by wait event, SQL and host) within Database Insights in Standard mode. Off by default: the lab reads the cluster's Prometheus."
  type        = bool
  default     = false
}

variable "performance_insights_retention_period" {
  description = "Days of Performance Insights history when performance_insights_enabled is true: 7 (the free retention), a multiple of 31 up to 713 (months), or 731."
  type        = number
  default     = 7

  validation {
    condition     = var.performance_insights_retention_period == 7 || var.performance_insights_retention_period == 731 || (var.performance_insights_retention_period >= 31 && var.performance_insights_retention_period <= 713 && var.performance_insights_retention_period % 31 == 0)
    error_message = "performance_insights_retention_period must be 7, a multiple of 31 from 31 to 713, or 731."
  }
}

variable "monitoring_interval" {
  description = "Seconds between two enhanced monitoring samples of the operating system; 0 (the default) turns enhanced monitoring off and creates no IAM role. Any other value creates the role <name>-rds-monitoring and the log group RDSOSMetrics of the account and region, which RDS writes the OS metrics to: no other instance of that account and region may have enhanced monitoring on."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30 or 60."
  }
}

variable "cloudwatch_logs_exports" {
  description = "PostgreSQL logs RDS exports to CloudWatch Logs (postgresql, upgrade, iam-db-auth-error), each into a log group /aws/rds/instance/<name>/<type> this module creates. Empty (the default) exports nothing: ingestion is billed per GB."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.cloudwatch_logs_exports : contains(["postgresql", "upgrade", "iam-db-auth-error"], t)])
    error_message = "cloudwatch_logs_exports may only hold postgresql, upgrade and iam-db-auth-error."
  }
}

variable "cloudwatch_logs_retention_days" {
  description = "Days CloudWatch keeps the exported logs when cloudwatch_logs_exports is not empty, and the OS metrics of enhanced monitoring when monitoring_interval is not 0."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.cloudwatch_logs_retention_days)
    error_message = "cloudwatch_logs_retention_days must be one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180 or 365."
  }
}
