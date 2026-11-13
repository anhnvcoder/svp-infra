# Release repositories: CI copies each release here by digest, with its signature and attestations as referrers.
# No lifecycle policy: every image here is untagged, so any rule would select images that run or are rollback targets.

# AWS-0030: the registry scans with Inspector (enhanced), where a repository's own scan setting has no effect; its
# filter leaves releases out on purpose (the comment on the scanning configuration below says why).
# Scope: every environment.
#trivy:ignore:AWS-0030
resource "aws_ecr_repository" "release" {
  for_each = toset(local.release_repositories)

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

# Inspector scans the cached third-party images only. Releases are scanned by CI before the push and rescanned daily,
# and admission requires a fresh vuln attestation, so the release repositories stay out of the filter.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    dynamic "repository_filter" {
      for_each = keys(local.cache_rules)

      content {
        filter      = "${repository_filter.value}/*"
        filter_type = "WILDCARD"
      }
    }
  }
}
