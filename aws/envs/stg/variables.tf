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

variable "eks_public_access_cidrs" {
  description = "IPv4 ranges allowed to call the public endpoint of the Kubernetes API, usually the learner's address as a /32. Ranges shorter than /8 are refused by the eks module."
  type        = list(string)
}

################################################################################
# Size and protection of the env: committed in <env>.tfvars, the only place where stg and prd differ
################################################################################

variable "az_count" {
  description = "Number of availability zones of the VPC (and of the nodes and the DB subnet group)."
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

variable "eks_endpoint_public_access" {
  description = "Open the public endpoint of the Kubernetes API to eks_public_access_cidrs; the private endpoint is always on."
  type        = bool
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

variable "node_instance_types" {
  description = "Graviton instance types of the node group, all of one size."
  type        = list(string)
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND."
  type        = string
}

variable "node_min_size" {
  description = "Smallest number of nodes."
  type        = number
}

variable "node_desired_size" {
  description = "Number of nodes when the node group is created (later changes are ignored by the eks module)."
  type        = number
}

variable "node_max_size" {
  description = "Largest number of nodes."
  type        = number
}

variable "rds_instance_class" {
  description = "DB instance class of the shared PostgreSQL instance."
  type        = string
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

variable "media_force_destroy" {
  description = "Let destroy delete both buckets with every object in them."
  type        = bool
}

variable "media_price_class" {
  description = "Edge locations of the CloudFront distribution of the media bucket."
  type        = string
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
