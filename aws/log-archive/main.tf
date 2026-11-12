# The log archive of the organization: one bucket per kind of log in an account of its own, so administrators of the
# workload and security accounts cannot read, change or delete the logs; management still can, through the role this
# root applies with. Lives between sessions. Design notes: README.md.

data "aws_partition" "current" {}

# A member account may describe its organization; the id scopes every service principal below to it.
data "aws_organizations_organization" "this" {}

locals {
  partition = data.aws_partition.current.partition
  org_id    = data.aws_organizations_organization.this.id

  # Web ACLs of CloudFront live in us-east-1 and deliver their logs from there; SSE-KMS needs a key of the bucket's
  # region, hence one key per region under the same alias.
  key_regions = {
    home = var.region
    waf  = "us-east-1"
  }

  # Known before the trail points here, so the key and bucket policies name it without a dependency on aws/org.
  trail_arn = "arn:${local.partition}:cloudtrail:${var.region}:${var.account_id}:trail/svp-audit"
  # Detector ids exist only once aws/security has applied, after this root.
  guardduty_detector_arns = [
    for r in values(local.key_regions) : "arn:${local.partition}:guardduty:${r}:${var.security_account_id}:detector/*"
  ]

  # One year of audit history (PCI DSS v4 10.5.1: at least 12 months); after three months Glacier Instant Retrieval
  # still reads in milliseconds and its 90-day minimum storage is met.
  audit_retention_days  = 365
  audit_cold_after_days = 90
  # Network logs: a quarter of investigation for prd; stg lives a few hours a session.
  network_retention_days     = 90
  stg_network_retention_days = 7

  # key: entry of local.key_regions for SSE-KMS, null for SSE-S3. stg_prefix: where the stg account's logs land.
  buckets = {
    cloudtrail = {
      name            = "svp-cloudtrail-${var.log_archive_account_id}-${var.region}"
      region          = var.region
      key             = "home"
      object_lock     = true
      retention_days  = local.audit_retention_days
      cold_after_days = local.audit_cold_after_days
      stg_prefix      = null
    }
    cloudtrail_access = {
      name            = "svp-cloudtrail-access-${var.log_archive_account_id}-${var.region}"
      region          = var.region
      key             = null
      object_lock     = false
      retention_days  = local.audit_retention_days
      cold_after_days = null
      stg_prefix      = null
    }
    config = {
      name            = "svp-config-${var.log_archive_account_id}-${var.region}"
      region          = var.region
      key             = "home"
      object_lock     = false
      retention_days  = local.audit_retention_days
      cold_after_days = local.audit_cold_after_days
      stg_prefix      = null
    }
    flowlogs = {
      name            = "svp-flowlogs-${var.log_archive_account_id}-${var.region}"
      region          = var.region
      key             = "home"
      object_lock     = false
      retention_days  = local.network_retention_days
      cold_after_days = null
      stg_prefix      = "AWSLogs/aws-account-id=${var.stg_account_id}/"
    }
    guardduty = {
      name            = "svp-guardduty-${var.log_archive_account_id}-${var.region}"
      region          = var.region
      key             = "home"
      object_lock     = false
      retention_days  = local.audit_retention_days
      cold_after_days = local.audit_cold_after_days
      stg_prefix      = null
    }
    waf = {
      name            = "aws-waf-logs-svp-${var.log_archive_account_id}-${local.key_regions.waf}"
      region          = local.key_regions.waf
      key             = "waf"
      object_lock     = false
      retention_days  = local.network_retention_days
      cold_after_days = null
      stg_prefix      = "AWSLogs/${var.stg_account_id}/"
    }
  }

  bucket_arns = { for k, b in local.buckets : k => "arn:${local.partition}:s3:::${b.name}" }
}
