# Size and protection of stg: the services, configuration, encryption and logs of prd, with less redundancy, smaller
# sizes, short retention and no protection against deletion, disposable at the end of every session. Committed; it
# holds no personal value. Every plan, apply and destroy of this root passes it:
#   AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan -var-file=stg.tfvars

# network: two zones, one NAT gateway, flow logs kept 1 day. The S3 gateway endpoint lets through the same buckets as
# in prd: the env's buckets, the image layer bucket of Amazon ECR in the region (both added by the root and the module)
# and the bucket registry.k8s.io redirects clients inside AWS to in this region.
az_count                  = 2
single_nat_gateway        = true
flow_log_enabled          = true
flow_log_retention_days   = 1
s3_endpoint_restricted    = true
s3_endpoint_extra_buckets = ["prod-registry-k8s-io-ap-southeast-1"]

# eks: no public endpoint (the API through the SSM tunnel of ssm-bastion.tf, on a local port other than prd's), all
# five control plane logs kept 1 day, Secrets encrypted with a customer managed KMS key. The eks module sizes the
# On-Demand system node group (one node per zone); Karpenter makes the other nodes, sized and limited in svp-gitops.
kubernetes_version               = "1.36"
api_tunnel_port                  = 6444
control_plane_log_types          = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
control_plane_log_retention_days = 1
eks_secrets_kms_encryption       = true

# rds: smallest Graviton class, one zone, storage growing up to 40 GiB, one day of backups, deleted with the env and
# with nothing left behind; Performance Insights at the free retention, enhanced monitoring every 60 s, PostgreSQL logs
# exported, logs and OS metrics kept 1 day.
rds_instance_class                        = "db.t4g.small"
rds_max_allocated_storage                 = 40
rds_multi_az                              = false
rds_backup_retention_period               = 1
rds_delete_automated_backups              = true
rds_deletion_protection                   = false
rds_skip_final_snapshot                   = true
rds_performance_insights_enabled          = true
rds_performance_insights_retention_period = 7
rds_monitoring_interval                   = 60
rds_cloudwatch_logs_exports               = ["postgresql", "upgrade"]
rds_cloudwatch_logs_retention_days        = 1

# msk: one small broker per zone, every topic on both brokers, writes accepted with one of them down (stg does not
# promise to keep them through the loss of a zone); broker volumes growing up to 20 GiB, broker logs kept 1 day.
msk_broker_instance_type       = "kafka.t3.small"
msk_replication_factor         = 2
msk_min_insync_replicas        = 1
msk_broker_volume_max_size     = 20
msk_broker_logs_enabled        = true
msk_broker_logs_retention_days = 1

# valkey: one micro node, no replica and no failover; changes applied at once (the env never lives until its
# maintenance window), slow log kept 1 day.
valkey_node_type               = "cache.t4g.micro"
valkey_node_count              = 1
valkey_apply_immediately       = true
valkey_slow_log_retention_days = 1

# media: destroy empties and deletes both buckets; no earlier versions kept, S3 access logs in a log bucket of the env,
# the web ACL of waf.tf in front of CloudFront.
media_force_destroy          = true
media_versioning_enabled     = false
media_access_logging_enabled = true
