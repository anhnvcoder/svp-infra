variable "target_id" {
  description = "The organizational unit (ou-...) every policy of this module is attached to. Service control policies never apply to the management account, so the workload accounts sit in this OU."
  type        = string

  validation {
    condition     = can(regex("^ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}$", var.target_id))
    error_message = "target_id must be the id of an organizational unit, e.g. ou-ab12-cd34ef56."
  }
}
