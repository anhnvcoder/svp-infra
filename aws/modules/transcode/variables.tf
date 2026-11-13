variable "env" {
  description = "Environment (stg, prd): every name of the module starts with svp-<env>."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "uploads_bucket_arn" {
  description = "ARN of the uploads bucket of the env (arn:aws:s3:::<name>): MediaConvert reads the input of a job under uploads/ with its role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.uploads_bucket_arn))
    error_message = "uploads_bucket_arn must be the ARN of an S3 bucket, arn:aws:s3:::<bucket>."
  }
}

variable "uploads_kms_key_arn" {
  description = "ARN of the KMS key that encrypts the uploads bucket (output uploads_kms_key_arn of the media module): MediaConvert decrypts the input of a job with its role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z]{2}(-[a-z]+)+-[0-9]+:[0-9]{12}:key/[0-9a-f-]+$", var.uploads_kms_key_arn))
    error_message = "uploads_kms_key_arn must be a key ARN (arn:aws:kms:<region>:<account>:key/<id>) with a 12-digit account, not an alias."
  }
}

variable "media_bucket_arn" {
  description = "ARN of the media bucket of the env (arn:aws:s3:::<name>): MediaConvert writes the output of a job under media/ with its role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.media_bucket_arn))
    error_message = "media_bucket_arn must be the ARN of an S3 bucket, arn:aws:s3:::<bucket>."
  }
}

variable "alarm_topic_arn" {
  description = "ARN of the SNS topic the alarm of the dead-letter queue notifies, when it fires and when it clears (output topic_arn of the alarms module)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be the ARN of an SNS topic."
  }
}
