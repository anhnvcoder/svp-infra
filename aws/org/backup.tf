# Only the management account can turn cross-account backup on, and the setting holds for every member account: the
# env accounts copy their recovery points into the vaults of svp-backup. The provider reads back every flag AWS returns,
# so the map lists all of them; multi-party approval and delegated administrator stay off. Design notes: README.md.
resource "aws_backup_global_settings" "this" {
  global_settings = {
    isCrossAccountBackupEnabled     = "true"
    isDelegatedAdministratorEnabled = "false"
    isMpaEnabled                    = "false"
  }

  depends_on = [aws_organizations_organization.this]
}

# The backup policies run their plans with the opt-in of the management account, not of the member account. The
# resource writes the whole map, so it lists every type AWS Backup supports in the region, each on as AWS sets it for
# an account that starts using AWS Backup; RDS and S3 are the two the policies select.
resource "aws_backup_region_settings" "this" {
  resource_type_opt_in_preference = {
    "Aurora"                 = true
    "CloudFormation"         = true
    "DSQL"                   = true
    "DocumentDB"             = true
    "DynamoDB"               = true
    "EBS"                    = true
    "EC2"                    = true
    "EFS"                    = true
    "EKS"                    = true
    "FSx"                    = true
    "Neptune"                = true
    "RDS"                    = true
    "Redshift"               = true
    "Redshift Serverless"    = true
    "S3"                     = true
    "SAP HANA on Amazon EC2" = true
    "Storage Gateway"        = true
    "VirtualMachine"         = true
  }
}
