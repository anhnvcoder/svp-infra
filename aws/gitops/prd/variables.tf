################################################################################
# Account and region
################################################################################

variable "account_id" {
  description = "The AWS account of the env, the only one this root may read (12 digits). Set it with TF_VAR_account_id from the account variable of the env after checking the account with aws sts get-caller-identity; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the env, of its state bucket and of its cluster."
  type        = string
  default     = "ap-southeast-1"
}

################################################################################
# Committed in <env>.tfvars, the only place where stg and prd differ
################################################################################

variable "node_arch" {
  description = "Architecture of the nodes of the env's node group (label svp.io/node-arch of the cluster Secret): arm64 for Graviton."
  type        = string
}

variable "require_pinned_revision" {
  description = "Stop the plan when envs/<env>/charts.yaml of svp-gitops holds no gitopsRevision, instead of bootstrapping at main."
  type        = bool
}

variable "api_server_url" {
  description = "Local end of the tunnel to a private API endpoint (https://127.0.0.1:<port>); null reaches cluster_endpoint of the env root."
  type        = string
  default     = null
}

################################################################################
# Per session or personal: an uncommitted *.auto.tfvars or TF_VAR_* (the repository is public)
################################################################################

variable "svp_cluster_chart" {
  description = "Directory of chart svp-cluster of svp-backend, extracted at the revision of envs/<env>/charts.yaml and set with TF_VAR_svp_cluster_chart (README.md of aws/gitops): its templates/namespaces.yaml gives the namespaces made before Argo CD."
  type        = string
}

variable "telegram_chat_id" {
  description = "Telegram chat that also gets the root's failed syncs and Degraded health; empty sends the commit status only."
  type        = string
  default     = ""
}
