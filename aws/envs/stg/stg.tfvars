# Size and protection of stg: cheap, disposable at the end of every session. Committed; it holds no personal value.
# Every plan, apply and destroy of this root passes it: AWS_PROFILE=anhnv-sso terraform plan -var-file=stg.tfvars.

# network: two zones, one NAT gateway, no flow log.
az_count           = 2
single_nat_gateway = true
flow_log_enabled   = false

# eks: public endpoint for the learner's machine only (ranges in an uncommitted *.auto.tfvars), no control plane log,
# three Graviton Spot nodes of one size.
kubernetes_version         = "1.36"
eks_endpoint_public_access = true
control_plane_log_types    = []
node_instance_types        = ["m7g.large", "m6g.large", "t4g.large"]
node_capacity_type         = "SPOT"
node_min_size              = 3
node_desired_size          = 3
node_max_size              = 5

# rds: smallest Graviton class, one zone, one day of backups, deleted with the env and with nothing left behind.
rds_instance_class           = "db.t4g.small"
rds_multi_az                 = false
rds_backup_retention_period  = 1
rds_delete_automated_backups = true
rds_deletion_protection      = false
rds_skip_final_snapshot      = true

# media: destroy empties and deletes both buckets.
media_force_destroy = true
media_price_class   = "PriceClass_200"
