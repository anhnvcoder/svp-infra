# Hosted zone of the environment, kept between sessions so its four name servers, delegated once by NS records in the
# zone above it, never change. The records of a session (aliases of the distributions, ACM validation) come from the
# root aws/envs/<env>; nothing in the cluster writes to the zone.
resource "aws_route53_zone" "env" {
  name    = var.zone_name
  comment = "svp ${var.env} zone"
}

# Delegation of each child zone that lives in another account (the stg zone, in the zone of prd), as Route 53's
# "Creating a subdomain that uses Amazon Route 53 as the DNS service without migrating the parent domain" describes.
# TTL 172800, the value that guide gives for an NS record: the name servers of a kept zone do not change. With the map
# empty, no record exists.
resource "aws_route53_record" "delegation" {
  for_each = var.delegated_subdomains

  zone_id = aws_route53_zone.env.zone_id
  name    = each.key
  type    = "NS"
  ttl     = 172800
  records = each.value
}

locals {
  # The four CAs ACM issues from (ACM "CAA records": https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html).
  # issuewild needs them too, or ACM refuses a wildcard name.
  acm_cas = ["amazon.com", "amazontrust.com", "awstrust.com", "amazonaws.com"]
}

# Only Amazon's CAs may issue for the zone. At the apex only: a CA looks up CAA from a name towards its parents until it
# finds one (RFC 8659 section 3), so every name of the zone inherits it.
resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.env.zone_id
  name    = var.zone_name
  type    = "CAA"
  ttl     = 3600
  records = concat([for ca in local.acm_cas : "0 issue \"${ca}\""], [for ca in local.acm_cas : "0 issuewild \"${ca}\""])
}
