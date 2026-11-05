# Hosted zone of the lab subdomain, kept between sessions so its four name servers, delegated once by NS records at
# the DNS of the parent domain, never change.
resource "aws_route53_zone" "lab" {
  name    = var.zone_name
  comment = "svp lab subdomain, delegated from the DNS of the parent domain"
}

# Delegation of each environment's zone, which lives in the environment's own account (aws/accounts/<env>), as
# Route 53's "Creating a subdomain that uses Amazon Route 53 as the DNS service without migrating the parent domain"
# describes. TTL 172800, the value that guide gives for an NS record
# (https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-routing-traffic-for-subdomains.html): the name servers
# of a kept zone do not change. With the map empty, no record exists.
resource "aws_route53_record" "delegation" {
  for_each = var.delegated_subdomains

  zone_id = aws_route53_zone.lab.zone_id
  name    = each.key
  type    = "NS"
  ttl     = 172800
  records = each.value
}
