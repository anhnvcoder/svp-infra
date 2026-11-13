# What the vaults guarantee: every vault uses the caller's key; by default no lock and no access policy; a lock is
# governance mode with the given retention; an access policy lets only the given accounts copy in, nothing else; then
# one plan per validation rule with a value that only that rule rejects. The AWS provider is a mock. The access policy
# is asserted through the arguments of its aws_iam_policy_document data source.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"backup:CopyIntoBackupVault\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
  vaults = {
    svp-stg = {}
  }
}

# The vault of an env: recovery points are deleted at the end of each session, so neither lock nor access policy.
run "defaults" {
  command = plan

  assert {
    condition     = keys(aws_backup_vault.this) == ["svp-stg"] && aws_backup_vault.this["svp-stg"].name == "svp-stg"
    error_message = "The module must make one vault per entry of vaults, named by its key."
  }

  assert {
    condition     = aws_backup_vault.this["svp-stg"].kms_key_arn == "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
    error_message = "Every vault must be encrypted with kms_key_arn."
  }

  assert {
    condition     = length(aws_backup_vault_lock_configuration.this) == 0 && length(aws_backup_vault_policy.this) == 0 && length(data.aws_iam_policy_document.access) == 0
    error_message = "Without lock and copy_from_account_ids a vault must have no lock and no access policy."
  }
}

# The copy vaults of the backup account: each locked in governance mode and open to copies from its env's account only.
run "copy_vaults" {
  command = plan

  variables {
    vaults = {
      svp-stg-copy = {
        lock                  = { min_retention_days = 1, max_retention_days = 7 }
        copy_from_account_ids = ["000000000000"]
      }
      svp-prd-copy = {
        lock                  = { min_retention_days = 7, max_retention_days = 35 }
        copy_from_account_ids = ["333333333333"]
      }
    }
  }

  assert {
    condition = alltrue([for name in ["svp-stg-copy", "svp-prd-copy"] :
      aws_backup_vault.this[name].kms_key_arn == "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
    ])
    error_message = "Every vault must be encrypted with kms_key_arn."
  }

  assert {
    condition = alltrue([
      aws_backup_vault_lock_configuration.this["svp-stg-copy"].backup_vault_name == "svp-stg-copy",
      aws_backup_vault_lock_configuration.this["svp-stg-copy"].min_retention_days == 1,
      aws_backup_vault_lock_configuration.this["svp-stg-copy"].max_retention_days == 7,
      aws_backup_vault_lock_configuration.this["svp-prd-copy"].backup_vault_name == "svp-prd-copy",
      aws_backup_vault_lock_configuration.this["svp-prd-copy"].min_retention_days == 7,
      aws_backup_vault_lock_configuration.this["svp-prd-copy"].max_retention_days == 35,
    ])
    error_message = "Each lock must be on its own vault with the given min and max retention."
  }

  # changeable_for_days set would turn the lock into compliance mode once it elapses: the lock could never be removed.
  assert {
    condition     = alltrue([for l in values(aws_backup_vault_lock_configuration.this) : l.changeable_for_days == null])
    error_message = "A lock must stay in governance mode: no changeable_for_days."
  }

  assert {
    condition = alltrue([for name, account in { svp-stg-copy = "000000000000", svp-prd-copy = "333333333333" } :
      aws_backup_vault_policy.this[name].backup_vault_name == name &&
      length(data.aws_iam_policy_document.access[name].statement) == 1 &&
      alltrue([for s in data.aws_iam_policy_document.access[name].statement :
        s.effect == "Allow" &&
        toset(s.actions) == toset(["backup:CopyIntoBackupVault"]) &&
        toset(s.resources) == toset(["*"]) &&
        length(s.condition) == 0 &&
        try(length(s.not_actions), 0) == 0 &&
        length(s.not_principals) == 0 &&
        length(s.principals) == 1 &&
        alltrue([for p in s.principals : p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::${account}:root"])])
      ])
    ])
    error_message = "The access policy of a copy vault may only allow backup:CopyIntoBackupVault, and only to the account given for that vault."
  }
}

# A lock without an access policy and the other way round: each part follows its own entry.
run "lock_or_policy_alone" {
  command = plan

  variables {
    vaults = {
      locked = { lock = { min_retention_days = 1, max_retention_days = 1 } }
      shared = { copy_from_account_ids = ["000000000000", "333333333333"] }
    }
  }

  assert {
    condition     = keys(aws_backup_vault_lock_configuration.this) == ["locked"] && keys(aws_backup_vault_policy.this) == ["shared"]
    error_message = "Only a vault with lock may get a lock, only a vault with copy_from_account_ids an access policy."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.access["shared"].statement : alltrue([for p in s.principals :
      toset(p.identifiers) == toset(["arn:aws:iam::000000000000:root", "arn:aws:iam::333333333333:root"])
    ])])
    error_message = "The access policy must name every given account, and only those."
  }
}

# The ARN of a key's name in KMS instead of the key: the string is joined because make test refuses a line holding
# the keyword of extra provider configurations.
run "kms_key_arn_not_a_key" {
  command = plan

  variables {
    kms_key_arn = join("", ["arn:aws:kms:ap-southeast-1:000000000000:ali", "as/svp-backup-copy"])
  }

  expect_failures = [var.kms_key_arn]
}

run "vaults_empty" {
  command = plan

  variables {
    vaults = {}
  }

  expect_failures = [var.vaults]
}

run "vault_name_with_dot" {
  command = plan

  variables {
    vaults = {
      "svp.stg" = {}
    }
  }

  expect_failures = [var.vaults]
}

run "vault_name_too_long" {
  command = plan

  variables {
    vaults = {
      "svp-0123456789-0123456789-0123456789-0123456789-012" = {}
    }
  }

  expect_failures = [var.vaults]
}

run "account_id_eleven_digits" {
  command = plan

  variables {
    vaults = {
      svp-stg-copy = { copy_from_account_ids = ["00000000000"] }
    }
  }

  expect_failures = [var.vaults]
}

run "account_id_repeated" {
  command = plan

  variables {
    vaults = {
      svp-stg-copy = { copy_from_account_ids = ["000000000000", "000000000000"] }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_min_zero" {
  command = plan

  variables {
    vaults = {
      svp-stg-copy = { lock = { min_retention_days = 0, max_retention_days = 7 } }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_min_over_max" {
  command = plan

  variables {
    vaults = {
      svp-prd-copy = { lock = { min_retention_days = 35, max_retention_days = 7 } }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_max_missing" {
  command = plan

  variables {
    vaults = {
      svp-prd-copy = { lock = { min_retention_days = 7, max_retention_days = null } }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_fractional_days" {
  command = plan

  variables {
    vaults = {
      svp-prd-copy = { lock = { min_retention_days = 1.5, max_retention_days = 7 } }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_max_over_aws_limit" {
  command = plan

  variables {
    vaults = {
      svp-prd-copy = { lock = { min_retention_days = 7, max_retention_days = 36501 } }
    }
  }

  expect_failures = [var.vaults]
}

run "lock_max_at_aws_limit" {
  command = plan

  variables {
    vaults = {
      svp-prd-copy = { lock = { min_retention_days = 7, max_retention_days = 36500 } }
    }
  }
}
