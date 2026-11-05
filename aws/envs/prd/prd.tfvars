# Size and protection of prd: the production level of every module, kept for the whole session and protected against
# deletion. Committed; it holds no personal value. Every plan and apply of this root passes it:
#   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -var-file=prd.tfvars
# and the teardown at the end of a session adds teardown.tfvars (README.md).

# network: three zones, one NAT gateway per zone, flow logs kept 30 days. The S3 gateway endpoint lets through only the
# env's buckets, the image layer bucket of Amazon ECR in the region (both added by the root and the module) and the
# bucket registry.k8s.io redirects clients inside AWS to in this region.
az_count                  = 3
single_nat_gateway        = false
flow_log_enabled          = true
flow_log_retention_days   = 30
s3_endpoint_restricted    = true
s3_endpoint_extra_buckets = ["prod-registry-k8s-io-ap-southeast-1"]

# eks: no public endpoint (the API through the SSM tunnel of ssm-bastion.tf, so no public range either), control plane
# logs kept 30 days, Secrets encrypted with a customer managed KMS key, three on-demand Graviton nodes of one size
# spread over the three zones.
kubernetes_version               = "1.36"
eks_endpoint_public_access       = false
eks_public_access_cidrs          = []
control_plane_log_types          = ["api", "audit", "authenticator"]
control_plane_log_retention_days = 30
eks_secrets_kms_encryption       = true
node_instance_types              = ["m7g.large", "m6g.large"]
node_capacity_type               = "ON_DEMAND"
node_min_size                    = 3
node_desired_size                = 3
node_max_size                    = 6

# rds: smallest Graviton class with Database Insights, a standby in a second zone, seven days of backups kept after a
# deletion, deletion protection and a final snapshot; Performance Insights at the free retention, enhanced monitoring
# every 60 s, PostgreSQL logs exported, logs and OS metrics kept 30 days.
rds_instance_class                        = "db.t4g.medium"
rds_multi_az                              = true
rds_backup_retention_period               = 7
rds_delete_automated_backups              = false
rds_deletion_protection                   = true
rds_skip_final_snapshot                   = false
rds_performance_insights_enabled          = true
rds_performance_insights_retention_period = 7
rds_monitoring_interval                   = 60
rds_cloudwatch_logs_exports               = ["postgresql", "upgrade"]
rds_cloudwatch_logs_retention_days        = 30

# media: destroy stops at a bucket that holds objects; earlier versions kept 30 days, S3 access logs in a log bucket of
# the env, the web ACL of waf.tf in front of CloudFront.
media_force_destroy          = false
media_price_class            = "PriceClass_200"
media_versioning_enabled     = true
media_access_logging_enabled = true
