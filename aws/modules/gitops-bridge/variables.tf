################################################################################
# The cluster
################################################################################

variable "env" {
  description = "Environment the cluster runs: label svp.io/env of the cluster Secret, value env of the root Application, its directory under envs/ of svp-gitops."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "node_arch" {
  description = "Architecture of the nodes: label svp.io/node-arch of the cluster Secret, value nodeArch of the root Application."
  type        = string

  validation {
    condition     = contains(["arm64", "amd64"], var.node_arch)
    error_message = "node_arch must be arm64 or amd64."
  }
}

# Not an object type: conversion to one would drop a key the type does not name and refuse a missing one with a type
# error instead of this rule. The kind of each value is read from its JSON encoding, which tells a string from a
# number or a boolean, and a list from a map.
variable "cluster_values" {
  description = "Values of the cluster.* contract (output cluster_values of the env root): annotation svp.io/cluster-values of the cluster Secret, value cluster of the root Application. Exactly the keys of the contract, each of its kind; externalSecretsRoles names the role of the SecretStore of each of five namespaces."
  type        = any

  validation {
    condition = try(toset(keys(var.cluster_values)) == toset([
      "name", "region", "vpcId", "vpcCidr", "serviceCidr", "dbCidrs", "edgeCidrs", "edgeTargetGroupArn", "domain",
      "rdsAddress", "kafkaBrokers", "valkeyHost", "uploadsBucket", "mediaBucket", "mediaDomain", "s3Cidrs",
      "externalSecretsRoles", "ecrRegistry", "ampWorkspaceId", "ampEndpoint", "logGroup", "grafanaUrl", "alarmTopicArn",
    ]), false)
    error_message = "cluster_values must hold exactly the keys name, region, vpcId, vpcCidr, serviceCidr, dbCidrs, edgeCidrs, edgeTargetGroupArn, domain, rdsAddress, kafkaBrokers, valkeyHost, uploadsBucket, mediaBucket, mediaDomain, s3Cidrs, externalSecretsRoles, ecrRegistry, ampWorkspaceId, ampEndpoint, logGroup, grafanaUrl and alarmTopicArn."
  }

  validation {
    condition = try(alltrue(concat(
      [for k in [
        "name", "region", "vpcId", "vpcCidr", "serviceCidr", "edgeTargetGroupArn", "domain", "rdsAddress",
        "kafkaBrokers", "valkeyHost", "uploadsBucket", "mediaBucket", "mediaDomain", "ecrRegistry", "ampWorkspaceId",
        "ampEndpoint", "logGroup", "grafanaUrl", "alarmTopicArn",
      ] : startswith(jsonencode(var.cluster_values[k]), "\"")],
      [for k in ["dbCidrs", "edgeCidrs", "s3Cidrs"] :
        startswith(jsonencode(var.cluster_values[k]), "[") &&
        alltrue([for v in var.cluster_values[k] : startswith(jsonencode(v), "\"")])
      ],
      [
        startswith(jsonencode(var.cluster_values.externalSecretsRoles), "{") &&
        alltrue([for v in values(var.cluster_values.externalSecretsRoles) : startswith(jsonencode(v), "\"")])
      ],
    )), false)
    error_message = "cluster_values: dbCidrs, edgeCidrs and s3Cidrs must be lists of strings, externalSecretsRoles a map of strings, every other key a string."
  }

  validation {
    condition     = try(toset(keys(var.cluster_values.externalSecretsRoles)) == toset(["svp", "svp-data", "svp-obs", "keda", "argocd"]), false)
    error_message = "cluster_values.externalSecretsRoles must name the role of exactly the namespaces svp, svp-data, svp-obs, keda and argocd."
  }

  # A malformed value would otherwise show only in the cluster, as a failed pull, remote write or alert; refused here,
  # it stops the plan before anything is applied.
  validation {
    condition = try(alltrue([for k, re in {
      ecrRegistry    = "^[0-9]{12}\\.dkr\\.ecr\\.[a-z]{2}(-[a-z]+)+-[0-9]+\\.amazonaws\\.com$"
      ampWorkspaceId = "^ws-[0-9a-f-]+$"
      ampEndpoint    = "^https://aps-workspaces\\.[a-z]{2}(-[a-z]+)+-[0-9]+\\.amazonaws\\.com/workspaces/ws-[0-9a-f-]+/$"
      logGroup       = "^/svp/[a-z]+/otel$"
      grafanaUrl     = "^https://g-[0-9a-z]+\\.grafana-workspace\\.[a-z]{2}(-[a-z]+)+-[0-9]+\\.amazonaws\\.com$"
      alarmTopicArn  = "^arn:aws:sns:[a-z]{2}(-[a-z]+)+-[0-9]+:[0-9]{12}:svp-[a-z]+-alarms$"
    } : can(regex(re, var.cluster_values[k]))]), false)
    error_message = "cluster_values: ecrRegistry must be <account>.dkr.ecr.<region>.amazonaws.com, ampWorkspaceId ws-<id>, ampEndpoint https://aps-workspaces.<region>.amazonaws.com/workspaces/ws-<id>/, logGroup /svp/<env>/otel, grafanaUrl https://g-<id>.grafana-workspace.<region>.amazonaws.com without a trailing slash, alarmTopicArn arn:aws:sns:<region>:<account>:svp-<env>-alarms."
  }
}

variable "telegram_chat_id" {
  description = "Telegram chat that also gets the root's failed syncs and Degraded health (annotation svp.io/telegram-chat-id of the cluster Secret); empty sends the commit status only. Not in a committed file."
  type        = string
  default     = ""

  validation {
    condition     = var.telegram_chat_id == "" || can(regex("^-?[0-9]+$", var.telegram_chat_id))
    error_message = "telegram_chat_id must be empty or the integer id of a Telegram chat."
  }
}

################################################################################
# The Kubernetes API
################################################################################

variable "cluster_endpoint" {
  description = "URL of the Kubernetes API server (output cluster_endpoint of the env root). Its host is the TLS server name either way."
  type        = string

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+$", var.cluster_endpoint))
    error_message = "cluster_endpoint must be https://<host> without port or path, as EKS gives it."
  }
}

variable "api_server_url" {
  description = "Where the providers reach the API instead of cluster_endpoint: the local end of a tunnel, https on 127.0.0.1 at the port of the tunnel. null reaches cluster_endpoint itself."
  type        = string
  default     = null

  validation {
    condition     = var.api_server_url == null || can(regex("^https://127\\.0\\.0\\.1:[0-9]{1,5}$", var.api_server_url))
    error_message = "api_server_url must be null or https://127.0.0.1:<port>, the local end of the tunnel to the API."
  }
}

################################################################################
# svp-gitops: what the root reads, and at which commit
################################################################################

variable "main_commit" {
  description = "Commit of branch main of svp-gitops when the plan runs (GitHub REST API, media type application/vnd.github.sha)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", trimspace(var.main_commit)))
    error_message = "main_commit must be a full commit SHA (40 lowercase hex digits)."
  }
}

variable "env_charts" {
  description = "Content of the charts.yaml of the env under envs/ of svp-gitops at main_commit. Its optional key gitopsRevision is the bootstrap commit; without it the bootstrap commit is main_commit."
  type        = string

  validation {
    condition     = can(keys(yamldecode(var.env_charts))) && can(regex("^[0-9a-f]{40}$", lookup(yamldecode(var.env_charts), "gitopsRevision", "0000000000000000000000000000000000000000")))
    error_message = "env_charts must be a YAML map whose gitopsRevision, when present, is a full commit SHA (40 lowercase hex digits)."
  }

  validation {
    condition     = !var.require_pinned_revision || try(lookup(yamldecode(var.env_charts), "gitopsRevision", null) != null, false)
    error_message = "This environment requires a pinned revision: envs/<env>/charts.yaml of svp-gitops holds no gitopsRevision. Merge the promote pull request that sets it first."
  }
}

variable "require_pinned_revision" {
  description = "Refuse to plan when the charts.yaml of the env under envs/ holds no gitopsRevision, instead of taking main_commit."
  type        = bool
}

variable "argocd_bootstrap" {
  description = "Content of argocd/bootstrap.json of svp-gitops at the bootstrap commit: repository, chart, version and namespace of the release of Argo CD."
  type        = string
}

variable "argocd_values" {
  description = "Values files of the release of Argo CD at the bootstrap commit, in order: the file argocd_bootstrap names, then platforms/eks/argo-cd.yaml."
  type        = list(string)

  validation {
    condition     = length(var.argocd_values) > 0 && alltrue([for v in var.argocd_values : can(keys(yamldecode(v)))])
    error_message = "argocd_values must hold at least one values file, each a YAML map."
  }
}

variable "app_projects" {
  description = "Content of argocd/project.yaml of svp-gitops at the bootstrap commit: AppProject svp and the emptied AppProject default, applied as they are."
  type        = string
}

variable "svp_cluster_values_template" {
  description = "Content of platforms/eks/svp-cluster.values.tpl of svp-gitops at the bootstrap commit: the template chart argocd/apps renders on value cluster into the valuesObject of Application svp-cluster."
  type        = string
}

variable "namespace_manifests" {
  description = "Namespaces rendered from templates/namespaces.yaml of chart svp-cluster (helm template output, one or more documents each): namespace argocd, and the namespaces of the project and of the platform charts. Each must enforce, audit and warn Pod Security restricted."
  type        = list(string)
}
