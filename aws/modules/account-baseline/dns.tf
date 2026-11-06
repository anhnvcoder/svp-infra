# Hosted zone of the environment, kept between sessions so its four name servers, delegated once by NS records in the
# zone above it, never change. ExternalDNS and cert-manager of this environment write only into this zone.
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
