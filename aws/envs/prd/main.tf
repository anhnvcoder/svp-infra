locals {
  # Identity of this root, the only line of code in which the roots of stg and prd differ: sizes and
  # protections differ in <env>.tfvars, the backend key is given at init. Every name below starts with svp-<env>.
  env  = "prd"
  name = "svp-${local.env}"

  # Buckets of the log archive account that receive this env's flow logs and WAF logs, named as that account's root
  # names them: the account id comes from the terminal, so no file holds it.
  log_archive_buckets = {
    flow_logs = "svp-flowlogs-${var.log_archive_account_id}-${var.region}"
    waf       = "aws-waf-logs-svp-${var.log_archive_account_id}-us-east-1"
  }

  # Delivery destination of the log archive account for this env's CloudFront standard logs, named the same way.
  cloudfront_log_destination_arn = "arn:aws:logs:us-east-1:${var.log_archive_account_id}:delivery-destination:svp-cloudfront-${local.env}"
}

module "network" {
  source = "../../modules/network"

  name                = local.name
  cluster_name        = local.name
  az_count            = var.az_count
  single_nat_gateway  = var.single_nat_gateway
  flow_log_bucket_arn = "arn:aws:s3:::${local.log_archive_buckets.flow_logs}"

  interface_endpoint_az_count = var.interface_endpoint_az_count

  s3_endpoint_restricted = var.s3_endpoint_restricted
  s3_endpoint_buckets    = concat([module.media.uploads_bucket, module.media.media_bucket], var.s3_endpoint_extra_buckets)
}

module "eks" {
  source = "../../modules/eks"

  name                    = local.name
  kubernetes_version      = var.kubernetes_version
  vpc_id                  = module.network.vpc_id
  private_subnet_ids      = module.network.private_subnet_ids
  control_plane_log_types = var.control_plane_log_types
  secrets_kms_encryption  = var.eks_secrets_kms_encryption

  guardduty_data_endpoint_id = module.network.guardduty_data_endpoint_id

  # One system node per zone, room for as many again when scaled by hand; Karpenter makes the other nodes.
  system_node_max_size = 2 * var.az_count

  control_plane_log_retention_days = var.control_plane_log_retention_days

  # Pod Identity roles of the platform controllers and the pull through cache rights of the nodes, on the long-lived
  # resources of baseline.tf.
  amp_workspace_arn         = data.aws_prometheus_workspace.env.arn
  log_group_arn             = data.aws_cloudwatch_log_group.otel.arn
  observability_kms_key_arn = data.aws_kms_alias.observability.target_key_arn
  ecr_kms_key_arn           = data.aws_kms_alias.ecr.target_key_arn
  release_repository_arns   = [for r in data.aws_ecr_repository.release : r.arn]
  ecr_cache_prefixes        = keys(data.aws_ecr_pull_through_cache_rule.cache)
}

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.database_subnet_ids

  # Pods carry addresses of their node's network interfaces (VPC CNI), so they connect with the node security group.
  # The cluster security group EKS creates sits on the control plane's network interfaces, and EKS also gives it to
  # what it launches without a security group of its own (Fargate pods, nodes of a group with no launch template).
  # The nodes here do not carry it: the system node group's launch template names the node security group, and
  # Karpenter's EC2NodeClass selects that group by its discovery tag.
  allowed_security_groups = {
    node    = module.eks.node_security_group_id
    cluster = module.eks.cluster_primary_security_group_id
  }

  instance_class           = var.rds_instance_class
  max_allocated_storage    = var.rds_max_allocated_storage
  multi_az                 = var.rds_multi_az
  backup_retention_period  = var.rds_backup_retention_period
  delete_automated_backups = var.rds_delete_automated_backups
  deletion_protection      = var.rds_deletion_protection
  skip_final_snapshot      = var.rds_skip_final_snapshot

  performance_insights_enabled          = var.rds_performance_insights_enabled
  performance_insights_retention_period = var.rds_performance_insights_retention_period
  monitoring_interval                   = var.rds_monitoring_interval
  cloudwatch_logs_exports               = var.rds_cloudwatch_logs_exports
  cloudwatch_logs_retention_days        = var.rds_cloudwatch_logs_retention_days

  backup_copy_account_id = var.backup_account_id

  alarm_topic_arn = module.alarms.topic_arn
}

# Kafka of the env: one broker per zone, reached on 9096 (SASL/SCRAM over TLS) by the pods like RDS. The module writes
# the passwords of its users into the entries kafka-admin and kafka-users of External Secrets.
module "msk" {
  source = "../../modules/msk"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.database_subnet_ids

  allowed_security_groups = {
    node    = module.eks.node_security_group_id
    cluster = module.eks.cluster_primary_security_group_id
  }

  broker_count               = var.az_count
  broker_instance_type       = var.msk_broker_instance_type
  broker_volume_max_size     = var.msk_broker_volume_max_size
  replication_factor         = var.msk_replication_factor
  min_insync_replicas        = var.msk_min_insync_replicas
  broker_logs_enabled        = var.msk_broker_logs_enabled
  broker_logs_retention_days = var.msk_broker_logs_retention_days
  password_version           = var.msk_password_version

  kafka_admin_secret_id = module.external_secrets.secret_arns["kafka-admin"]
  kafka_users_secret_id = module.external_secrets.secret_arns["kafka-users"]

  alarm_topic_arn = module.alarms.topic_arn
}

# Valkey of the env, reached on 6379 over TLS by the same security groups; the module writes the passwords of its users
# into the entry valkey-users of External Secrets.
module "elasticache" {
  source = "../../modules/elasticache"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.database_subnet_ids

  allowed_security_groups = {
    node    = module.eks.node_security_group_id
    cluster = module.eks.cluster_primary_security_group_id
  }

  node_type               = var.valkey_node_type
  node_count              = var.valkey_node_count
  apply_immediately       = var.valkey_apply_immediately
  slow_log_retention_days = var.valkey_slow_log_retention_days
  password_version        = var.valkey_password_version

  valkey_users_secret_id = module.external_secrets.secret_arns["valkey-users"]
  alarm_topic_arn        = module.alarms.topic_arn
}

# SNS topic every CloudWatch alarm of RDS, MSK and ElastiCache and every alert of the rules on the Prometheus workspace
# notify: both are evaluated outside the cluster, so they still fire when the cluster is down.
module "alarms" {
  source = "../../modules/alarms"

  name        = local.name
  alarm_email = var.alarm_email

  publisher_services = ["cloudwatch.amazonaws.com", "aps.amazonaws.com"]
  aps_workspace_arn  = data.aws_prometheus_workspace.env.arn
}

module "media" {
  source = "../../modules/media"

  name_prefix          = local.name
  account_id           = var.account_id
  region               = var.region
  cors_allowed_origins = ["https://${var.domain}"]
  force_destroy        = var.media_force_destroy

  versioning_enabled     = var.media_versioning_enabled
  access_logging_enabled = var.media_access_logging_enabled

  domain                       = var.domain
  hosted_zone_id               = var.hosted_zone_id
  flat_rate_free               = var.media_flat_rate_free
  web_acl_arn                  = module.waf["media"].web_acl_arn
  log_delivery_destination_arn = local.cloudfront_log_destination_arn
}

# MediaConvert transcoding of the env: its jobs read uploads/ and write media/ of the buckets above, and their final
# states reach media-worker through an SQS queue whose dead-letter alarm pages on the alarms topic.
module "transcode" {
  source = "../../modules/transcode"

  env                 = local.env
  uploads_bucket_arn  = "arn:aws:s3:::${module.media.uploads_bucket}"
  uploads_kms_key_arn = module.media.uploads_kms_key_arn
  media_bucket_arn    = "arn:aws:s3:::${module.media.media_bucket}"
  alarm_topic_arn     = module.alarms.topic_arn
}

# The public way in to the web and the API: CloudFront, through a VPC origin, to an internal ALB in the edge subnets
# in front of Envoy. The ALB lets Envoy in on the node security group, where the pods take their addresses.
module "edge" {
  source = "../../modules/edge"

  name                    = local.name
  domain                  = var.domain
  hosted_zone_id          = var.hosted_zone_id
  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.edge_subnet_ids
  node_security_group_id  = module.eks.node_security_group_id
  alb_deletion_protection = var.edge_alb_deletion_protection

  web_acl_arns = {
    web = module.waf["web"].web_acl_arn
    api = module.waf["api"].web_acl_arn
  }
  log_delivery_destination_arn = local.cloudfront_log_destination_arn
}

# Secrets Manager entries of the env and the roles the SecretStores of the cluster read them with (External Secrets
# Operator). The modules msk and elasticache write the Kafka and Valkey passwords, write-only; the learner's script
# writes every other value after apply.
module "external_secrets" {
  source = "../../modules/external-secrets"

  env          = local.env
  cluster_name = module.eks.cluster_name
}

# Read to check that domain is the env's zone or lies inside it: the edge and media modules write their records and
# certificate validations in that zone, so a name outside it would get neither.
data "aws_route53_zone" "env" {
  zone_id = var.hosted_zone_id
}

# Address ranges of S3 in the region, as AWS publishes them. NetworkPolicies of the VPC CNI match addresses, not names,
# so the pods that call S3 are allowed exactly these ranges on 443. The list is read at every plan: a range AWS adds
# during a session is reachable only after the next apply.
data "aws_ip_ranges" "s3" {
  regions  = [var.region]
  services = ["s3"]
}
