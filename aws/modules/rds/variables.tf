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
  description = "Private subnets of the DB subnet group, in at least two availability zones (RDS requires two even for a single-AZ instance, and a Multi-AZ standby goes in the other one)."
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
  default     = "15"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 15."
  }
}

variable "instance_class" {
  description = "DB instance class."
  type        = string
  default     = "db.t4g.small"
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
