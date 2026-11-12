# One viewer certificate per distribution, in us-east-1, and one certificate for the ALB in the home region holding
# both names. ACM gives a name the same validation record in every region of an account, so each name gets one record
# and all three certificates wait on it.

resource "aws_acm_certificate" "viewer" {
  for_each = local.sites

  region            = local.global_region
  domain_name       = each.value.alias
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"

  tags = {
    Name = "${var.name}-${each.key}"
  }

  # A distribution always holds a certificate: the new one is issued and attached before the old one goes.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "alb" {
  domain_name               = local.sites.web.alias
  subject_alternative_names = [local.sites.api.alias]
  validation_method         = "DNS"
  key_algorithm             = "EC_prime256v1"

  tags = {
    Name = "${var.name}-edge"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = local.sites

  zone_id = var.hosted_zone_id
  name    = one(aws_acm_certificate.viewer[each.key].domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.viewer[each.key].domain_validation_options).resource_record_type
  records = [one(aws_acm_certificate.viewer[each.key].domain_validation_options).resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "viewer" {
  for_each = local.sites

  region                  = local.global_region
  certificate_arn         = aws_acm_certificate.viewer[each.key].arn
  validation_record_fqdns = [aws_route53_record.validation[each.key].fqdn]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
