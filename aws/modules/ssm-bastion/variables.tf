variable "name" {
  description = "Name of the env's cluster (svp-prd): prefix of the names of the instance, its security group, IAM role and instance profile."
  type        = string

  validation {
    # The longest name built from it, the IAM role <name>-ssm-bastion, stays well within the 64 characters IAM allows.
    condition     = can(regex("^[a-z][a-z0-9-]{1,27}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 29 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "account_id" {
  description = "The AWS account of the env (12 digits), part of the ARN of the cluster in kubeconfig_command."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the env, written into the commands of the outputs."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as ap-southeast-1."
  }
}

variable "aws_profile" {
  description = "AWS profile of the env's account on the learner's machine (anhnv-prd), written into the commands of the outputs."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.aws_profile))
    error_message = "aws_profile must be a profile name of letters, digits, dots, dashes or underscores."
  }
}

variable "vpc_id" {
  description = "VPC of the cluster (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_id" {
  description = "Private subnet of the instance, one of output private_subnet_ids of the network module: it reaches Systems Manager through the NAT gateway of its zone and has no public address."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet id such as subnet-0abc..."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster (output cluster_name of the eks module): name and context of the kubeconfig entry."
  type        = string
}

variable "cluster_endpoint" {
  description = "URL of the Kubernetes API server (output cluster_endpoint of the eks module). With the public endpoint off, its host resolves inside the VPC to the private endpoint, which the instance forwards the tunnel to."
  type        = string

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+$", var.cluster_endpoint))
    error_message = "cluster_endpoint must be an https:// URL without path or port, as EKS gives it."
  }
}

variable "api_security_group_id" {
  description = "Security group on the network interfaces of the private endpoint of the Kubernetes API (output cluster_security_group_id of the eks module). The module adds to it a rule that lets the instance in on 443."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.api_security_group_id))
    error_message = "api_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "local_port" {
  description = "Port on 127.0.0.1 of the learner's machine where the tunnel listens; the server of the kubeconfig entry and api_server_url of the GitOps root of the env use the same port. 6443 stays clear of the local k3d cluster (6550 and 8443)."
  type        = number
  default     = 6443

  validation {
    condition     = var.local_port >= 1024 && var.local_port <= 65535 && floor(var.local_port) == var.local_port
    error_message = "local_port must be a whole number from 1024 to 65535."
  }
}
