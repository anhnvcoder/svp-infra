# Size and protection of prd: the production level of every module, kept for the whole session and protected against
# deletion. Committed; it holds no personal value. Every plan and apply of this root passes it, and the teardown at the
# end of a session adds teardown.tfvars; the commands are in README.md.

# network: three zones, one NAT gateway and one network interface of each interface endpoint of the AWS APIs per
# zone; flow logs go to the log archive account, which keeps them. The S3 gateway endpoint lets through only the env's
# buckets, the image layer bucket of Amazon ECR in the region (both added by the root and the module) and the bucket
# registry.k8s.io redirects clients inside AWS to in this region.
az_count                    = 3
single_nat_gateway          = false
interface_endpoint_az_count = 3
s3_endpoint_restricted      = true
s3_endpoint_extra_buckets   = ["prod-registry-k8s-io-ap-southeast-1"]

# eks: no public endpoint (the API through the SSM tunnel of ssm-bastion.tf on its own local port), all five control
# plane logs kept 30 days, Secrets encrypted with a customer managed KMS key. The eks module sizes the On-Demand system
# node group (one node per zone); Karpenter makes the other nodes, sized and limited in svp-gitops.
kubernetes_version               = "1.36"
api_tunnel_port                  = 6443
control_plane_log_types          = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
control_plane_log_retention_days = 30
eks_secrets_kms_encryption       = true

# rds: Graviton class for production, a standby in a second zone, storage growing up to 100 GiB, seven days of backups
# kept after a deletion, deletion protection and a final snapshot; Performance Insights at the free retention, enhanced
# monitoring every 60 s, PostgreSQL logs exported, logs and OS metrics kept 30 days.
rds_instance_class                        = "db.m7g.large"
rds_max_allocated_storage                 = 100
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

# msk: one Graviton broker per zone, every topic on three brokers with two in sync, so a write acknowledged with
# acks=all survives the loss of a zone and writes go on; broker volumes growing up to 100 GiB, broker logs kept 30 days.
msk_broker_instance_type       = "kafka.m7g.large"
msk_replication_factor         = 3
msk_min_insync_replicas        = 2
msk_broker_volume_max_size     = 100
msk_broker_logs_enabled        = true
msk_broker_logs_retention_days = 30

# valkey: a primary and a replica in another zone, Multi-AZ with automatic failover; changes wait for the maintenance
# window, slow log kept 30 days.
valkey_node_type               = "cache.m7g.large"
valkey_node_count              = 2
valkey_apply_immediately       = false
valkey_slow_log_retention_days = 30

# media: destroy stops at a bucket that holds objects; earlier versions kept 30 days, S3 access logs in a log bucket of
# the env, its web ACL of waf.tf in front of CloudFront; pay-as-you-go, with standard logs in the log archive account.
media_force_destroy          = false
media_versioning_enabled     = true
media_access_logging_enabled = true
media_flat_rate_free         = false

# edge: the internal ALB behind CloudFront refuses deletion until teardown.tfvars turns this off.
edge_alb_deletion_protection = true
