variable "name_prefix" {
  description = "Fixed start of every name (svp-stg, svp-prd): buckets are <name_prefix>-uploads-<suffix> and <name_prefix>-media-<suffix>, the suffix random, so no name is built from the account id and a bucket left from an earlier session never collides."
  type        = string

  validation {
    # Bucket names: lowercase letters, digits and hyphens, at most 63 characters with "-uploads-" and 8 hex digits.
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name_prefix)) && !strcontains(var.name_prefix, "--")
    error_message = "name_prefix must be 2 to 40 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "cors_allowed_origins" {
  description = "Origins of the web client (https://<domain>) that may post upload forms to the uploads bucket and read playlists, segments and thumbnails of media cross-origin."
  type        = list(string)

  validation {
    # Bare origins only, so a typo cannot widen the rule to every site (a *) or break it (a path).
    condition     = length(var.cors_allowed_origins) > 0 && alltrue([for o in var.cors_allowed_origins : can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]+)?$", o))])
    error_message = "cors_allowed_origins must hold at least one origin like https://svp.example, without path or wildcard."
  }
}

# No default: true deletes every object of both buckets on destroy, which is what a lab session wants and what
# production must never do.
variable "force_destroy" {
  description = "Let terraform destroy delete both buckets with every object in them. Without it destroy fails on a bucket that is not empty."
  type        = bool
}

variable "price_class" {
  description = "Edge locations of the CloudFront distribution. PriceClass_200 serves Asia, Singapore and Vietnam included, from nearby edges, and leaves out the dearest regions (South America, Australia)."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}
