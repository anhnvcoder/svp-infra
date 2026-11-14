variable "features" {
  description = "Cost flags per account, as decoded from aws/paid-features.json: account key (mgmt, log-archive, security, backup, stg, prd) to the flags (managed_grafana, inspector_ecr, security_hub, config_recording) whose value differs from always. An absent account or flag is always."
  # A map, not an object type: Terraform drops attributes an object type does not declare, so a misspelt flag would
  # silently read as always instead of failing the plan.
  type     = map(map(string))
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.features) : contains(local.accounts, k)])
    error_message = "Every key of features must be an account key: mgmt, log-archive, security, backup, stg or prd."
  }

  validation {
    condition     = alltrue(flatten([for v in values(var.features) : [for f in keys(v) : contains(keys(local.values), f)]]))
    error_message = "Every flag must be managed_grafana, inspector_ecr, security_hub or config_recording."
  }

  validation {
    condition = alltrue(flatten([for v in values(var.features) : [
      for f, x in v : try(contains(local.values[f], x), false) if contains(keys(local.values), f)
    ]]))
    error_message = "managed_grafana must be always or session; inspector_ecr, security_hub and config_recording must be always or off."
  }

  # Absent, not always, is what an account outside stg and prd must hold: these two flags have nothing to switch there.
  validation {
    condition     = alltrue([for k, v in var.features : contains(["stg", "prd"], k) || length(setintersection(keys(v), ["managed_grafana", "inspector_ecr"])) == 0])
    error_message = "managed_grafana and inspector_ecr may only be set for the env accounts stg and prd."
  }

  validation {
    condition     = alltrue([for v in values(var.features) : lookup(v, "security_hub", "always") == "off" || lookup(v, "config_recording", "always") != "off"])
    error_message = "security_hub always needs config_recording always: Security Hub controls are AWS Config rules."
  }

  # The security account is the delegated administrator that aggregates the findings of every other account.
  validation {
    condition     = try(var.features["security"]["security_hub"], "always") != "off"
    error_message = "security_hub cannot be off for the security account, the delegated administrator of Security Hub."
  }
}
