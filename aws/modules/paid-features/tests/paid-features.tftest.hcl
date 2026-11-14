# What the flag block resolves to: every account and flag always when nothing is set, each value of each flag in
# flags, off_accounts and session_accounts, the stg values of aws/paid-features.json (repeated here: make test mounts
# only the module); then one plan per validation rule with a value that only that rule rejects. No resource here, but
# make test still requires the AWS provider to be a mock.

mock_provider "aws" {}

variables {
  features = {}

  all_always = {
    config_recording = "always"
    inspector_ecr    = "always"
    managed_grafana  = "always"
    security_hub     = "always"
  }
}

run "nothing_set" {
  command = plan

  assert {
    condition     = keys(output.flags) == ["backup", "log-archive", "mgmt", "prd", "security", "stg"]
    error_message = "flags must hold every account key, sorted."
  }

  assert {
    condition     = alltrue([for a, v in output.flags : v == var.all_always])
    error_message = "Every flag of every account must be always when the block sets nothing."
  }

  assert {
    condition     = keys(output.off_accounts) == keys(var.all_always) && alltrue([for f, a in output.off_accounts : length(a) == 0])
    error_message = "off_accounts must hold every flag with an empty list when the block sets nothing."
  }

  assert {
    condition     = keys(output.session_accounts) == keys(var.all_always) && alltrue([for f, a in output.session_accounts : length(a) == 0])
    error_message = "session_accounts must hold every flag with an empty list when the block sets nothing."
  }
}

run "stg_values" {
  command = plan

  variables {
    features = { stg = { managed_grafana = "session", inspector_ecr = "off", security_hub = "off", config_recording = "off" } }
  }

  assert {
    condition     = output.flags["stg"] == { config_recording = "off", inspector_ecr = "off", managed_grafana = "session", security_hub = "off" }
    error_message = "stg must have managed_grafana session and inspector_ecr, security_hub, config_recording off."
  }

  assert {
    condition     = alltrue([for a, v in output.flags : v == var.all_always if a != "stg"])
    error_message = "prd and the four shared accounts must keep every flag always."
  }

  assert {
    condition     = alltrue([for f in ["config_recording", "inspector_ecr", "security_hub"] : output.off_accounts[f] == tolist(["stg"])]) && length(output.off_accounts["managed_grafana"]) == 0
    error_message = "off_accounts must list stg for inspector_ecr, security_hub and config_recording, and no account for managed_grafana."
  }

  assert {
    condition     = output.session_accounts["managed_grafana"] == tolist(["stg"]) && alltrue([for f, a in output.session_accounts : length(a) == 0 if f != "managed_grafana"])
    error_message = "session_accounts must list stg for managed_grafana only."
  }
}

run "managed_grafana_session" {
  command = plan

  variables {
    features = { prd = { managed_grafana = "session" }, stg = { managed_grafana = "session" } }
  }

  assert {
    condition     = output.flags["prd"].managed_grafana == "session" && output.flags["stg"].managed_grafana == "session"
    error_message = "managed_grafana session must reach flags."
  }

  assert {
    condition     = output.session_accounts["managed_grafana"] == tolist(["prd", "stg"]) && length(output.off_accounts["managed_grafana"]) == 0
    error_message = "session_accounts must list prd and stg, sorted, for managed_grafana, and off_accounts none."
  }
}

run "managed_grafana_always" {
  command = plan

  variables {
    features = { stg = { managed_grafana = "always" } }
  }

  assert {
    condition     = output.flags["stg"] == var.all_always && length(output.session_accounts["managed_grafana"]) == 0
    error_message = "managed_grafana always set explicitly must equal leaving it out."
  }
}

run "inspector_ecr_off" {
  command = plan

  variables {
    features = { stg = { inspector_ecr = "off" }, prd = { inspector_ecr = "always" } }
  }

  assert {
    condition     = output.flags["stg"].inspector_ecr == "off" && output.flags["prd"].inspector_ecr == "always"
    error_message = "inspector_ecr off and always must reach flags."
  }

  assert {
    condition     = output.off_accounts["inspector_ecr"] == tolist(["stg"]) && length(output.session_accounts["inspector_ecr"]) == 0
    error_message = "off_accounts must list stg alone for inspector_ecr."
  }

  # Inspector off with Security Hub on is valid: control ECR.1 turns into a finding.
  assert {
    condition     = output.flags["stg"].security_hub == "always"
    error_message = "inspector_ecr off must leave security_hub always."
  }
}

run "security_hub_off" {
  command = plan

  variables {
    features = {
      prd    = { security_hub = "off" }
      mgmt   = { security_hub = "off" }
      backup = { security_hub = "off", config_recording = "off" }
      stg    = { security_hub = "always" }
    }
  }

  assert {
    condition     = output.flags["backup"].security_hub == "off" && output.flags["prd"].config_recording == "always" && output.flags["stg"].security_hub == "always"
    error_message = "security_hub off and always must reach flags, and config_recording stay always where unset."
  }

  assert {
    condition     = output.off_accounts["security_hub"] == tolist(["backup", "mgmt", "prd"]) && output.off_accounts["config_recording"] == tolist(["backup"])
    error_message = "off_accounts must list the accounts of each flag, sorted."
  }
}

run "config_recording_off" {
  command = plan

  variables {
    features = { "log-archive" = { security_hub = "off", config_recording = "off" }, security = { config_recording = "always" } }
  }

  assert {
    condition     = output.flags["log-archive"].config_recording == "off" && output.flags["security"].config_recording == "always"
    error_message = "config_recording off and always must reach flags."
  }

  assert {
    condition     = output.off_accounts["config_recording"] == tolist(["log-archive"])
    error_message = "off_accounts must list log-archive alone for config_recording."
  }
}

run "account_unknown" {
  command = plan

  variables {
    features = { dev = { security_hub = "off", config_recording = "off" } }
  }

  expect_failures = [var.features]
}

run "managed_grafana_value_unknown" {
  command = plan

  variables {
    features = { stg = { managed_grafana = "off" } }
  }

  expect_failures = [var.features]
}

run "inspector_ecr_value_unknown" {
  command = plan

  variables {
    features = { stg = { inspector_ecr = "session" } }
  }

  expect_failures = [var.features]
}

run "security_hub_value_empty" {
  command = plan

  variables {
    features = { prd = { security_hub = "" } }
  }

  expect_failures = [var.features]
}

run "config_recording_value_unknown" {
  command = plan

  variables {
    features = { prd = { security_hub = "off", config_recording = "on" } }
  }

  expect_failures = [var.features]
}

run "managed_grafana_shared_account" {
  command = plan

  variables {
    features = { backup = { managed_grafana = "always" } }
  }

  expect_failures = [var.features]
}

run "inspector_ecr_shared_account" {
  command = plan

  variables {
    features = { backup = { inspector_ecr = "off" } }
  }

  expect_failures = [var.features]
}

run "config_off_security_hub_unset" {
  command = plan

  variables {
    features = { prd = { config_recording = "off" } }
  }

  expect_failures = [var.features]
}

run "config_off_security_hub_always" {
  command = plan

  variables {
    features = { mgmt = { security_hub = "always", config_recording = "off" } }
  }

  expect_failures = [var.features]
}

run "security_hub_off_security_account" {
  command = plan

  variables {
    features = { security = { security_hub = "off", config_recording = "off" } }
  }

  expect_failures = [var.features]
}

run "flag_unknown" {
  command = plan

  variables {
    features = { stg = { securityhub = "off" } }
  }

  expect_failures = [var.features]
}
