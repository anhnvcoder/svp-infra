variable "name" {
  description = "Name of the web ACL and prefix of the CloudWatch metric names of its rules, e.g. svp-prd-media."
  type        = string

  validation {
    # The rules of a WAF name; metric names (the name plus a suffix of at most 15 characters) have the same alphabet.
    condition     = can(regex("^[a-z][a-z0-9-]{1,100}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 102 lowercase letters, digits or hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "rate_limit" {
  description = "Requests one client IP address may send within 5 minutes before the web ACL blocks it, until its rate falls back under the limit. A viewer of HLS fetches a segment every few seconds, a few hundred requests in 5 minutes; the default leaves room for several viewers behind one address."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000 && floor(var.rate_limit) == var.rate_limit
    error_message = "rate_limit must be a whole number from 10 to 2000000000."
  }
}
