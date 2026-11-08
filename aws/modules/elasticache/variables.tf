variable "name" {
  description = "ID of the replication group (svp-stg, svp-prd), also the name of its subnet group and user group, the prefix of its security group, parameter group and user IDs (<name>-gateway). It appears in the public Certificate Transparency logs through the TLS certificate of the nodes."
  type        = string

  validation {
    # The rules of a replication group ID: a letter first, letters, digits and single hyphens, no hyphen last, at
    # most 40 characters.
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "vpc_id" {
  description = "VPC of the nodes and of their security group."
  type        = string
}

variable "subnet_ids" {
  description = "Database subnets of the cache subnet group (the tier of the VPC with no route to the internet), in at least two availability zones (a replica goes in another zone than the primary)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must hold at least two subnets, in two availability zones."
  }
}

variable "allowed_security_groups" {
  description = "Security groups whose members may connect on 6379 (the EKS node and cluster security groups), keyed by a fixed label such as node or cluster: the keys name the rules, so they are known at plan time even when the ids are not."
  type        = map(string)

  validation {
    condition     = length(var.allowed_security_groups) > 0
    error_message = "allowed_security_groups must name at least one security group; a cache nobody can reach is a mistake."
  }
}

variable "engine_version" {
  description = "Valkey version, <major>.<minor>, at least 9.1: the first version whose ACL limits a user to databases (db=). ElastiCache applies the patch releases itself."
  type        = string
  default     = "9.1"

  validation {
    condition = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version)) && (
      tonumber(split(".", var.engine_version)[0]) > 9 ||
      (tonumber(split(".", var.engine_version)[0]) == 9 && tonumber(split(".", var.engine_version)[1]) >= 1)
    )
    error_message = "engine_version must be a Valkey version <major>.<minor> of at least 9.1, such as 9.1."
  }
}

variable "node_type" {
  description = "Node type of every node (cache.t4g.micro for a lab env, cache.m7g.large for production)."
  type        = string
  default     = "cache.t4g.micro"

  validation {
    condition     = startswith(var.node_type, "cache.")
    error_message = "node_type must be an ElastiCache node type such as cache.t4g.micro."
  }
}

variable "node_count" {
  description = "Nodes of the replication group, the primary included (1 to 6). With 2 or more the group runs Multi-AZ with automatic failover to a replica; 1 has no replica and no failover."
  type        = number

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 6 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a whole number from 1 to 6 (one primary and up to five replicas)."
  }
}

variable "valkey_users_secret_id" {
  description = "ID or ARN of the Secrets Manager entry svp/<env>/valkey-users (made by the external-secrets module), into which the module writes the password of each user under SVP_VALKEY_<USER>_PASSWORD."
  type        = string
}

variable "password_version" {
  description = "Version of the Valkey passwords. Terraform writes new random passwords, to the ElastiCache users and to the External Secrets entry together, only when this number changes: raise it to rotate every password."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
