variable "name" {
  description = "Name of the MSK cluster (svp-stg, svp-prd), also the prefix of its security group, configuration, KMS alias, log group and SCRAM secrets (AmazonMSK_<name>-<user>)."
  type        = string

  validation {
    # A letter first, letters, digits and single hyphens, no hyphen last: valid in every name derived from it (an MSK
    # cluster or configuration name, a KMS alias, a secret name).
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "vpc_id" {
  description = "VPC of the brokers and of their security group."
  type        = string
}

variable "subnet_ids" {
  description = "Database subnets of the brokers (the tier of the VPC with no route to the internet), one per availability zone (MSK takes two or three, and spreads the brokers evenly over them)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2 || length(var.subnet_ids) == 3
    error_message = "subnet_ids must hold two or three subnets, in as many availability zones."
  }
}

variable "allowed_security_groups" {
  description = "Security groups whose members may connect on 9096, the SASL/SCRAM port (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not."
  type        = map(string)

  validation {
    condition     = length(var.allowed_security_groups) > 0
    error_message = "allowed_security_groups must name at least one security group; a cluster nobody can reach is a mistake."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version of the cluster, in the form <major>.<minor>.x.kraft: KRaft metadata mode, and MSK applies the patch releases of that line itself."
  type        = string
  default     = "4.1.x.kraft"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.x\\.kraft$", var.kafka_version))
    error_message = "kafka_version must be a KRaft version line such as 4.1.x.kraft."
  }
}

variable "broker_instance_type" {
  description = "Instance type of every broker (kafka.t3.small for a lab env, kafka.m7g.large for production)."
  type        = string
  default     = "kafka.t3.small"

  validation {
    condition     = startswith(var.broker_instance_type, "kafka.")
    error_message = "broker_instance_type must be an MSK broker type such as kafka.t3.small."
  }
}

variable "broker_count" {
  description = "Number of brokers: a multiple of the number of subnets, since MSK puts the same number of brokers in each zone (one per zone in this lab)."
  type        = number

  validation {
    condition     = var.broker_count >= length(var.subnet_ids) && var.broker_count % length(var.subnet_ids) == 0
    error_message = "broker_count must be a positive multiple of the number of subnets."
  }
}

variable "broker_volume_size" {
  description = "Size of the EBS volume of each broker, in GiB (1 to 16384)."
  type        = number
  default     = 10

  validation {
    condition     = var.broker_volume_size >= 1 && var.broker_volume_size <= 16384
    error_message = "broker_volume_size must be between 1 and 16384 GiB."
  }
}

variable "replication_factor" {
  description = "Replication factor of every topic (default.replication.factor; topics are created without one) and of the internal topics of consumer offsets and transactions."
  type        = number

  validation {
    condition     = var.replication_factor >= 1 && var.replication_factor <= var.broker_count
    error_message = "replication_factor must be between 1 and broker_count."
  }
}

variable "min_insync_replicas" {
  description = "Replicas that must hold a write acknowledged with acks=all (min.insync.replicas, and transaction.state.log.min.isr): below the replication factor, so that losing one broker still accepts writes; 1 when the replication factor is 1."
  type        = number

  validation {
    condition     = var.min_insync_replicas >= 1 && (var.replication_factor == 1 ? var.min_insync_replicas == 1 : var.min_insync_replicas < var.replication_factor)
    error_message = "min_insync_replicas must be at least 1 and below replication_factor (exactly 1 when replication_factor is 1)."
  }
}

variable "broker_logs_enabled" {
  description = "Send the broker logs to the CloudWatch log group /aws/msk/<name>, which this module creates. Off by default: ingestion is billed per GB."
  type        = bool
  default     = false
}

variable "broker_logs_retention_days" {
  description = "Days CloudWatch keeps the broker logs when broker_logs_enabled is true."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.broker_logs_retention_days)
    error_message = "broker_logs_retention_days must be one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180 or 365."
  }
}

variable "password_version" {
  description = "Version of the Kafka passwords. Terraform writes new random passwords, to the SCRAM secrets and to the two External Secrets entries together, only when this number changes: raise it to rotate every password."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}

variable "kafka_admin_secret_id" {
  description = "ARN of the External Secrets entry svp/<env>/kafka-admin (output secret_arns of the external-secrets module); this module writes its value, key SVP_KAFKA_ADMIN_PASSWORD."
  type        = string
}

variable "kafka_users_secret_id" {
  description = "ARN of the External Secrets entry svp/<env>/kafka-users (output secret_arns of the external-secrets module); this module writes its value, one key SVP_KAFKA_<USER>_PASSWORD per user other than svp-admin."
  type        = string
}
