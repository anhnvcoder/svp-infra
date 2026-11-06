# Lifts the protections of prd.tfvars that stop a destroy, and nothing else: sizes, logs and encryption stay as they
# are. The teardown at the end of a session applies, then destroys, with both files:
#   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply -var-file=prd.tfvars -var-file=teardown.tfvars
#   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform destroy -var-file=prd.tfvars -var-file=teardown.tfvars

# rds_skip_final_snapshot stays false, so the destroy still writes the final snapshot of the DB instance, and the
# automated backups are still kept: the session runbook reads, then deletes, both.

# RDS refuses to delete an instance with deletion protection on; the apply turns it off first.
rds_deletion_protection = false

# Versioning keeps every object, so the buckets are never empty; destroy deletes them with all their versions.
media_force_destroy = true
