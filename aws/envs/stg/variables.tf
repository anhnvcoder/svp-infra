################################################################################
# Account and region
################################################################################

variable "account_id" {
  description = "The AWS account this root may change (12 digits). Set it with TF_VAR_account_id after reading the account from aws sts get-caller-identity; it never goes into a committed file."
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
  description = "ID of the Route 53 hosted zone of the lab, output zone_id of aws/bootstrap. ExternalDNS and cert-manager may change records of this zone only, and domain must lie inside it."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone id such as Z0123456789ABCDEFGHIJ."
  }
}

variable "domain" {
  description = "Host name of the web client of this env, inside the lab zone (e.g. stg.aws.svp.example); the API is api.<domain>. Origin of the CORS rules of both buckets and of CloudFront."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase DNS name without a trailing dot, e.g. stg.aws.svp.example."
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

variable "media_force_destroy" {
  description = "Let destroy delete both buckets with every object in them."
  type        = bool
}

variable "media_price_class" {
  description = "Edge locations of the CloudFront distribution of the media bucket."
  type        = string
}
