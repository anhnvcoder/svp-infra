# Centralized root access: member accounts keep no root password, access key or MFA device; the few tasks only root
# can do run from the management account through sts:AssumeRoot, one task policy and at most 15 minutes at a time.
# The management account's own root user stays the break-glass path. Design notes: README.md.
resource "aws_iam_organizations_features" "root_access" {
  enabled_features = [
    "RootCredentialsManagement",
    "RootSessions",
  ]

  # Both features need the trusted access of iam.amazonaws.com.
  depends_on = [aws_organizations_organization.this]
}
