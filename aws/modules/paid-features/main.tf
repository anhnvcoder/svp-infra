# The cost flags of every account of the organization, read from aws/paid-features.json by each root that switches a
# paid service: no provider, no resource. Design notes: aws/modules/paid-features/README.md.

locals {
  accounts = ["backup", "log-archive", "mgmt", "prd", "security", "stg"]

  # Every flag and the values it takes; always is the default of every flag.
  values = {
    config_recording = ["always", "off"]
    inspector_ecr    = ["always", "off"]
    managed_grafana  = ["always", "session"]
    security_hub     = ["always", "off"]
  }

  by_account = {
    for a in local.accounts : a => {
      for f in keys(local.values) : f => coalesce(try(var.features[a][f], null), "always")
    }
  }
}
