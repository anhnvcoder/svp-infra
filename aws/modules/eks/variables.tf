variable "name" {
  description = "Name of the EKS cluster, e.g. svp-stg, and prefix of the names of its IAM roles, policies, security groups and node group."
  type        = string

  validation {
    # 29 characters at most: the longest IAM role name built from it (<name>-aws-load-balancer-controller, a 29-character
    # suffix) stays within the 64 characters IAM allows, and the module's role name_prefix (<name>-cluster-) within 38.
    condition     = can(regex("^[a-z][a-z0-9-]{1,27}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 29 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and of the node group, e.g. 1.36. Pick a minor in standard support: the cluster is created with the STANDARD support policy."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.36."
  }

  validation {
    # The node group runs the pinned image release, which is built for one minor only.
    condition     = !can(regex("^1\\.[0-9]{2}$", var.kubernetes_version)) || startswith(local.ami_release_version, "${var.kubernetes_version}.")
    error_message = "kubernetes_version must be the minor of the pinned AMI release (local.ami_release_version of nodes.tf): bump both together."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of the cluster (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "private_subnet_ids" {
  description = "Private subnets of the VPC, one per availability zone (output private_subnet_ids of the network module). The control plane's network interfaces and the nodes go into every one of them, so pods spread over all these zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2 && alltrue([for s in var.private_subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "private_subnet_ids must hold at least two subnet ids (EKS needs subnets in two availability zones)."
  }
}

variable "endpoint_public_access" {
  description = "Open the public endpoint of the Kubernetes API, reachable only from endpoint_public_access_cidrs. The private endpoint is always on, so nodes and pods reach the API inside the VPC either way."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "IPv4 ranges allowed to call the public endpoint of the Kubernetes API, e.g. the address of the learner's machine as a /32. Personal data of a public repository: set it in an uncommitted *.auto.tfvars or TF_VAR_endpoint_public_access_cidrs."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(cidrnetmask(c))])
    error_message = "endpoint_public_access_cidrs must hold IPv4 ranges such as 192.0.2.10/32."
  }

  validation {
    # Rejecting every /0 keeps the API off the whole Internet whatever the address is written as.
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : !can(cidrnetmask(c)) || tonumber(split("/", c)[1]) >= 8])
    error_message = "endpoint_public_access_cidrs must not open the API to the whole Internet: each range needs a prefix of /8 or longer, usually a /32."
  }

  validation {
    condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
    error_message = "endpoint_public_access_cidrs must hold at least one range while endpoint_public_access is true."
  }
}

variable "secrets_kms_encryption" {
  description = "Envelope-encrypt Kubernetes Secrets with a customer managed KMS key the module creates (alias <name>-eks-secrets, rotated yearly, 7-day deletion window). Off by default: EKS encrypts them with an AWS owned key, and a key of our own costs a month's fee and outlives the cluster for the deletion window."
  type        = bool
  default     = false
}

variable "control_plane_log_types" {
  description = "Control plane logs sent to CloudWatch, e.g. [\"api\", \"audit\"]. Empty (the default) sends none and creates no log group: ingestion is billed per GB."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.control_plane_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "control_plane_log_types may only hold api, audit, authenticator, controllerManager and scheduler."
  }
}

variable "control_plane_log_retention_days" {
  description = "Days CloudWatch keeps the control plane logs when control_plane_log_types is not empty."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.control_plane_log_retention_days)
    error_message = "control_plane_log_retention_days must be one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180 or 365."
  }
}

variable "system_node_instance_type" {
  description = "Graviton (arm64) instance type of the system node group, On-Demand in every env. It holds what runs before Karpenter has a node of its own (add-ons, Argo CD, Karpenter), one replica of Karpenter per node."
  type        = string
  default     = "m7g.large"

  validation {
    # The node group runs the arm64 image of Amazon Linux 2023; Graviton types carry a g after the generation digit.
    condition     = can(regex("^[a-z]+[0-9]+g[a-z]*\\.[a-z0-9]+$", var.system_node_instance_type))
    error_message = "system_node_instance_type must be a Graviton (arm64) instance type such as m7g.large."
  }
}

variable "system_node_max_size" {
  description = "Largest number of nodes of the system node group, room to scale it by hand. It starts with one node per zone (the number of private_subnet_ids) and nothing scales it on its own."
  type        = number

  validation {
    condition     = var.system_node_max_size >= length(var.private_subnet_ids) && floor(var.system_node_max_size) == var.system_node_max_size
    error_message = "system_node_max_size must be a whole number of at least the number of private_subnet_ids."
  }
}

variable "hosted_zone_id" {
  description = "ID of the Route 53 hosted zone of the env, in the env's account (output zone_id of aws/accounts/<env>). ExternalDNS and cert-manager may change records of this zone only."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone id such as Z0123456789ABCDEFGHIJ."
  }
}

variable "guardduty_data_endpoint_id" {
  description = "ID of the interface endpoint guardduty-data of the VPC (output guardduty_data_endpoint_id of the network module). The GuardDuty agent add-on is created after it, so the agent's first reports have a way out."
  type        = string

  validation {
    condition     = can(regex("^vpce-[0-9a-f]+$", var.guardduty_data_endpoint_id))
    error_message = "guardduty_data_endpoint_id must be a VPC endpoint id such as vpce-0123456789abcdef0."
  }
}
