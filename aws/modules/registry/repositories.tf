# Release repositories: CI copies each release here by digest, with its signature and attestations as referrers.
# No lifecycle policy: every image here is untagged, so any rule would select images that run or are rollback targets.

# AWS-0030: the registry scanning configuration below picks the scanned repositories, enhanced or basic, and replaces
# the deprecated per-repository setting; its filter leaves releases out on purpose (its comment says why).
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

# Only the cached third-party images are scanned: continuously by Inspector, or on push by free basic scanning where
# Inspector is off for the account. Releases are scanned by CI before the push and rescanned daily, and admission
# requires a fresh vuln attestation, so the release repositories stay out of the filter.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = var.enhanced_scanning ? "ENHANCED" : "BASIC"

  rule {
    scan_frequency = var.enhanced_scanning ? "CONTINUOUS_SCAN" : "SCAN_ON_PUSH"

    dynamic "repository_filter" {
      for_each = keys(local.cache_rules)

      content {
        filter      = "${repository_filter.value}/*"
        filter_type = "WILDCARD"
      }
    }
  }
}
