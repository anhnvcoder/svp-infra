variable "env" {
  description = "Environment of the entries and roles: entries are svp/<env>/<entry>, roles svp-<env>-external-secrets and svp-<env>-external-secrets-<namespace>."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster (output cluster_name of the eks module) whose External Secrets controller gets the role through EKS Pod Identity."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,27}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3 to 29 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "grafana_operator" {
  description = "Whether the env has a Grafana workspace (flag managed_grafana of aws/paid-features.json not off): the entry grafana-operator, the token of Grafana Operator, and its read by the SecretStore role of svp-obs exist only then."
  type        = bool
  nullable    = false
}
