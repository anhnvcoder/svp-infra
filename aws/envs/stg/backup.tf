# Alarms on failed backup and copy jobs of the env's account. The vault, the key and the role of AWS Backup outlive
# the session in aws/accounts/<env>; the alarms live with the env, whose resources are the ones backed up.
module "backup_alarms" {
  source = "../../modules/backup-alarms"

  name            = local.name
  alarm_topic_arn = module.alarms.topic_arn
}
