# Lifts the protections of prd.tfvars that stop a destroy, and nothing else: sizes, logs and encryption stay as they
# are. The teardown at the end of a session applies, then destroys, with prd.tfvars and this file; the commands are in
# the "Gỡ" section of README.md.

# rds_skip_final_snapshot stays false, so the destroy still writes the final snapshot of the DB instance, and the
# automated backups are still kept: the session runbook reads, then deletes, both.

# RDS refuses to delete an instance with deletion protection on; the apply turns it off first.
rds_deletion_protection = false

# Versioning keeps every object, so the buckets are never empty; destroy deletes them with all their versions.
media_force_destroy = true

# The internal ALB of the edge refuses deletion while its protection is on; the apply turns it off first.
edge_alb_deletion_protection = false
