# The VPC origin: an internal ALB in the edge subnets that only CloudFront reaches, forwarding to the Envoy pods that
# the TargetGroupBinding of the cluster registers in the target group. No tag of the Load Balancer Controller
# (elbv2.k8s.aws/*): the controller registers targets in any target group, and pre-destroy.sh waits for the load
# balancers that carry its tag. Design notes: aws/modules/edge/README.md.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# No egress block: Terraform removes the allow-all rule AWS puts on a new group, leaving only the rules below.
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-edge-"
  description = "ALB ${var.name}-edge, HTTPS from CloudFront only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-edge"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from CloudFront origin-facing servers"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_envoy" {
  for_each = local.envoy_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "Envoy ${each.key} on the EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "envoy_from_alb" {
  for_each = local.envoy_ports

  security_group_id            = var.node_security_group_id
  description                  = "Envoy ${each.key} from ALB ${var.name}-edge"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "this" {
  name                       = "${var.name}-edge"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"
  enable_deletion_protection = var.alb_deletion_protection

  tags = {
    Name = "${var.name}-edge"
  }
}

# HTTPS to the pods with the certificate of the cluster's internal CA, which the ALB does not verify; the readiness
# probe of Envoy speaks plain HTTP only.
resource "aws_lb_target_group" "envoy" {
  name        = "${var.name}-envoy"
  target_type = "ip"
  protocol    = "HTTPS"
  port        = 443
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTP"
    port     = tostring(local.envoy_ports.health)
    path     = "/ready"
    matcher  = "200"
  }

  tags = {
    Name = "${var.name}-envoy"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = local.alb_tls_policy
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.envoy.arn
  }

  tags = {
    Name = "${var.name}-edge-https"
  }
}

resource "aws_cloudfront_vpc_origin" "this" {
  vpc_origin_endpoint_config {
    name                   = "${var.name}-edge"
    arn                    = aws_lb.this.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = {
    Name = "${var.name}-edge"
  }
}
