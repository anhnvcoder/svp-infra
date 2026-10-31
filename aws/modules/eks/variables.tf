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

variable "node_instance_types" {
  description = "Graviton (arm64) instance types of the node group, all of the same size so the scheduler sees the same node whichever one runs. Several types give Spot more pools to draw from when one runs short."
  type        = list(string)
  default     = ["m7g.large", "m6g.large", "t4g.large"]

  validation {
    # The node group runs the arm64 image of Amazon Linux 2023; Graviton types carry a g after the generation digit.
    condition     = length(var.node_instance_types) > 0 && alltrue([for t in var.node_instance_types : can(regex("^[a-z]+[0-9]+g[a-z]*\\.[a-z0-9]+$", t))])
    error_message = "node_instance_types must hold at least one Graviton (arm64) instance type such as m7g.large."
  }
}

variable "node_capacity_type" {
  description = "SPOT (cheaper, nodes can be reclaimed with two minutes of notice) or ON_DEMAND."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "node_min_size" {
  description = "Smallest number of nodes of the node group."
  type        = number
  default     = 3

  validation {
    condition     = var.node_min_size >= 1 && floor(var.node_min_size) == var.node_min_size
    error_message = "node_min_size must be a whole number of at least 1."
  }
}

variable "node_desired_size" {
  description = "Number of nodes when the node group is created. Terraform ignores later changes of it (the module leaves it to whoever scales the group), so a session scales with aws eks update-nodegroup-config."
  type        = number
  default     = 3

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size && floor(var.node_desired_size) == var.node_desired_size
    error_message = "node_desired_size must be a whole number between node_min_size and node_max_size."
  }
}

variable "node_max_size" {
  description = "Largest number of nodes of the node group."
  type        = number
  default     = 5

  validation {
    condition     = var.node_max_size >= var.node_min_size && floor(var.node_max_size) == var.node_max_size
    error_message = "node_max_size must be a whole number of at least node_min_size."
  }
}

variable "hosted_zone_id" {
  description = "ID of the Route 53 hosted zone of the lab (output of aws/bootstrap). ExternalDNS and cert-manager may change records of this zone only."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone id such as Z0123456789ABCDEFGHIJ."
  }
}
