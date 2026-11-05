# Hosted zone of the environment, kept between sessions so its four name servers, delegated once by NS records in the
# lab zone of the management account (delegated_subdomains of aws/bootstrap), never change. ExternalDNS and
# cert-manager of this environment write only into this zone.
resource "aws_route53_zone" "env" {
  name    = "${var.env}.${var.lab_zone_name}"
  comment = "svp ${var.env} zone, delegated from the lab zone of the management account"
}
