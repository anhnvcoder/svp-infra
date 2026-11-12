resource "aws_route53_record" "site" {
  for_each = { for p in setproduct(keys(local.sites), ["A", "AAAA"]) : "${p[0]}-${p[1]}" => { site = p[0], type = p[1] } }

  zone_id = var.hosted_zone_id
  name    = local.sites[each.value.site].alias
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.this[each.value.site].domain_name
    zone_id                = aws_cloudfront_distribution.this[each.value.site].hosted_zone_id
    evaluate_target_health = false
  }
}
