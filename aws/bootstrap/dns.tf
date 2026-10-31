# Hosted zone of the lab subdomain, kept between sessions so its four name servers, delegated once by NS records at
# the DNS of the parent domain, never change. ExternalDNS and cert-manager write only into this zone.
resource "aws_route53_zone" "lab" {
  name    = var.zone_name
  comment = "svp lab subdomain, delegated from the DNS of the parent domain"
}
