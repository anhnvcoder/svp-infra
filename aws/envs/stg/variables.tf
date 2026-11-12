################################################################################
# Account and region
################################################################################

variable "account_id" {
  description = "The AWS account of the env, the only one this root may change (12 digits). Set it with TF_VAR_account_id from the account variable of the env after checking the account with aws sts get-caller-identity; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of every resource of this env."
  type        = string
  default     = "ap-southeast-1"
}

################################################################################
# Personal values: an uncommitted *.auto.tfvars or TF_VAR_* (the repository is public)
################################################################################

variable "hosted_zone_id" {
  description = "ID of the Route 53 hosted zone of the env, in the env's account: output zone_id of aws/accounts/<env> (stg.aws.svp.example for stg, aws.svp.example for prd). ExternalDNS and cert-manager may change records of this zone only, and domain must be its name or a name inside it."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone id such as Z0123456789ABCDEFGHIJ."
  }
}

variable "domain" {
  description = "Host name of the web client of this env: the name of the zone of hosted_zone_id (e.g. stg.aws.svp.example for stg, aws.svp.example for prd) or a name inside it; the API is api.<domain>. Origin of the CORS rules of both buckets and of CloudFront."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase DNS name without a trailing dot, e.g. stg.aws.svp.example or aws.svp.example."
  }
}

variable "acme_email" {
  description = "Email of the Let's Encrypt account of cert-manager (expiry notices go there)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.acme_email))
    error_message = "acme_email must be an email address."
  }
}

variable "alarm_email" {
  description = "Email subscribed to the SNS topic of the CloudWatch alarms of RDS, MSK and ElastiCache; nothing is delivered until the confirmation link SNS sends is opened."
  type        = string
  sensitive   = true
}

################################################################################
# Size and protection of the env: committed in <env>.tfvars, the only place where stg and prd differ
################################################################################

variable "az_count" {
  description = "Number of availability zones of the VPC (and of the nodes, the database subnets and the Kafka brokers, one per zone)."
  type        = number
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the whole VPC (true) or one per zone (false)."
  type        = bool
}

variable "flow_log_enabled" {
  description = "Send VPC flow logs to CloudWatch."
  type        = bool
}

variable "flow_log_retention_days" {
  description = "Days CloudWatch keeps the flow logs when flow_log_enabled is true."
  type        = number
  default     = 1
}

variable "s3_endpoint_restricted" {
  description = "Let only the env's buckets, s3_endpoint_extra_buckets and the image layer bucket of Amazon ECR through the S3 gateway endpoint; every other bucket of the region is then unreachable from the private subnets."
  type        = bool
  default     = false
}

variable "s3_endpoint_extra_buckets" {
  description = "Names of buckets outside the env reachable through the S3 gateway endpoint when s3_endpoint_restricted is true, such as the bucket of the region that registry.k8s.io redirects image pulls to. The uploads and media buckets of the env are always added."
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the cluster, e.g. 1.36."
  type        = string
}

variable "api_tunnel_port" {
  description = "Port on 127.0.0.1 of the learner's machine where the SSM tunnel to the private endpoint of the Kubernetes API listens (api_tunnel_command, kubeconfig_command): one port per env, so that a command for one env never reaches the cluster of another."
  type        = number
}

variable "control_plane_log_types" {
  description = "Control plane logs sent to CloudWatch; empty sends none."
  type        = list(string)
}

variable "control_plane_log_retention_days" {
  description = "Days CloudWatch keeps the control plane logs when control_plane_log_types is not empty."
  type        = number
  default     = 1
}

variable "eks_secrets_kms_encryption" {
  description = "Envelope-encrypt Kubernetes Secrets with a customer managed KMS key the eks module creates; false leaves them encrypted with an AWS owned key."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "DB instance class of the shared PostgreSQL instance."
  type        = string
}

variable "rds_max_allocated_storage" {
  description = "Upper limit in GiB up to which storage autoscaling grows the DB instance's volume."
  type        = number
}

variable "rds_multi_az" {
  description = "Keep a synchronous standby of the DB instance in a second zone."
  type        = bool
}

variable "rds_backup_retention_period" {
  description = "Days of automated backups and point-in-time recovery (1 to 35)."
  type        = number
}

variable "rds_delete_automated_backups" {
  description = "Delete the automated backups together with the DB instance."
  type        = bool
}

variable "rds_deletion_protection" {
  description = "Refuse to delete the DB instance until an apply turns this off."
  type        = bool
}

variable "rds_skip_final_snapshot" {
  description = "Delete the DB instance without a final snapshot."
  type        = bool
}

variable "rds_performance_insights_enabled" {
  description = "Turn on Performance Insights within Database Insights in Standard mode."
  type        = bool
  default     = false
}

variable "rds_performance_insights_retention_period" {
  description = "Days of Performance Insights history when rds_performance_insights_enabled is true (7 is the free retention)."
  type        = number
  default     = 7
}

variable "rds_monitoring_interval" {
  description = "Seconds between two enhanced monitoring samples; 0 turns enhanced monitoring off."
  type        = number
  default     = 0
}

variable "rds_cloudwatch_logs_exports" {
  description = "PostgreSQL logs exported to CloudWatch Logs (postgresql, upgrade, iam-db-auth-error); empty exports none."
  type        = list(string)
  default     = []
}

variable "rds_cloudwatch_logs_retention_days" {
  description = "Days CloudWatch keeps the exported logs and the enhanced monitoring metrics of the DB instance."
  type        = number
  default     = 1
}

variable "msk_broker_instance_type" {
  description = "Instance type of the Kafka brokers (kafka.t3.small, kafka.m7g.large)."
  type        = string
}

variable "msk_replication_factor" {
  description = "Replication factor of every topic and of the internal topics of offsets and transactions, at most az_count."
  type        = number
}

variable "msk_min_insync_replicas" {
  description = "Replicas that must hold a write acknowledged with acks=all: below msk_replication_factor, so that losing one broker still accepts writes (1 when the factor is 1)."
  type        = number
}

variable "msk_broker_logs_enabled" {
  description = "Send the broker logs to the CloudWatch log group /aws/msk/svp-<env>."
  type        = bool
}

variable "msk_broker_logs_retention_days" {
  description = "Days CloudWatch keeps the broker logs when msk_broker_logs_enabled is true."
  type        = number
  default     = 1
}

variable "msk_broker_volume_max_size" {
  description = "Upper limit in GiB up to which storage autoscaling grows the volume of each broker."
  type        = number
}

variable "valkey_node_type" {
  description = "Node type of the Valkey nodes (cache.t4g.micro, cache.m7g.large)."
  type        = string
}

variable "valkey_node_count" {
  description = "Valkey nodes, the primary included: 1 has no replica; 2 or more run Multi-AZ with automatic failover."
  type        = number
}

variable "valkey_apply_immediately" {
  description = "Apply a change of the Valkey replication group at once (true) or in its maintenance window (false)."
  type        = bool
}

variable "valkey_slow_log_retention_days" {
  description = "Days CloudWatch keeps the slow log of Valkey."
  type        = number
}

variable "media_force_destroy" {
  description = "Let destroy delete both buckets with every object in them."
  type        = bool
}

variable "media_versioning_enabled" {
  description = "Keep earlier versions of overwritten and deleted objects in both buckets for 30 days."
  type        = bool
  default     = false
}

variable "media_access_logging_enabled" {
  description = "Write S3 server access logs of both buckets to a log bucket of the env."
  type        = bool
  default     = false
}

################################################################################
# Passwords Terraform makes (Kafka and Valkey users): raise to rotate
################################################################################

variable "msk_password_version" {
  description = "Version of the Kafka passwords: an apply with a new value writes new passwords to the SCRAM secrets and the entries kafka-admin, kafka-users. Raise it for the rest of the session (TF_VAR_msk_password_version or the uncommitted <env>.auto.tfvars): an apply at another value writes new ones again."
  type        = number
  default     = 1
}

variable "valkey_password_version" {
  description = "Version of the Valkey passwords: an apply with a new value writes new passwords to the ElastiCache users and the entry valkey-users. Raise it for the rest of the session (TF_VAR_valkey_password_version or the uncommitted <env>.auto.tfvars): an apply at another value writes new ones again."
  type        = number
  default     = 1
}
