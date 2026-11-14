# AWS Config records every supported resource type continuously in both regions, unless config_recording is off.
# Design notes: aws/modules/security-baseline/README.md.

locals {
  # Built from its parts rather than read from the role, so the recorders are known at plan time.
  config_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  config_regions = var.config_recording ? local.regions : toset([])
}

# Kept when config_recording is off, so turning recording back on only adds the per-region resources.
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# AWS allows one recorder per region and account. Put with an existing name updates it, so a second module call for
# the same account would silently overwrite this one: call the module once per account.
resource "aws_config_configuration_recorder" "this" {
  for_each = local.config_regions

  region   = each.key
  name     = "default"
  role_arn = local.config_role_arn

  recording_group {
    all_supported = true
    # Global types (IAM) in one region only, or every region records the same changes.
    include_global_resource_types = each.key == local.home_region
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }

  depends_on = [aws_iam_service_linked_role.config]
}

resource "aws_config_delivery_channel" "this" {
  for_each = local.config_regions

  region         = each.key
  name           = "default"
  s3_bucket_name = var.config_bucket_name
  s3_kms_key_arn = var.log_archive_key_arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

# A recorder can only start once its region has a delivery channel.
resource "aws_config_configuration_recorder_status" "this" {
  for_each = local.config_regions

  region     = each.key
  name       = aws_config_configuration_recorder.this[each.key].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}
