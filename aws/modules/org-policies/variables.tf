variable "root_id" {
  description = "The root of the organization (r-...): every policy but the production guardrails is attached here, so it applies to every member account (and, for the declarative and tag policies, to the management account too)."
  type        = string

  validation {
    condition     = can(regex("^r-[0-9a-z]{4,32}$", var.root_id))
    error_message = "root_id must be the id of the organization root, e.g. r-ab12."
  }
}

variable "prod_ou_id" {
  description = "The organizational unit (ou-...) of the production accounts, which the production guardrails are attached to."
  type        = string

  validation {
    condition     = can(regex("^ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}$", var.prod_ou_id))
    error_message = "prod_ou_id must be the id of an organizational unit, e.g. ou-ab12-cd34ef56."
  }
}

variable "nonprod_ou_id" {
  description = "The organizational unit (ou-...) of the non-production accounts, which the backup policy of stg is attached to."
  type        = string

  validation {
    condition     = can(regex("^ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}$", var.nonprod_ou_id))
    error_message = "nonprod_ou_id must be the id of an organizational unit, e.g. ou-ab12-cd34ef56."
  }
}

variable "backup_account_id" {
  description = "The account svp-backup (12 digits), whose vaults svp-<env>-copy receive the copy of every recovery point of the backup policies."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.backup_account_id))
    error_message = "backup_account_id must be the 12 digits of an AWS account id."
  }
}

variable "organization_id" {
  description = "The id of the organization (o-...), the only one whose principals and services the resource control policy lets reach member account resources."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be the id of an organization, e.g. o-ab12cd34ef."
  }
}
