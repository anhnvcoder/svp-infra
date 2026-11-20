# Module `edge`

Đường vào công khai của web và API của một env: distribution CloudFront `<name>-web` (tên `<domain>`) và `<name>-api` (tên
`api.<domain>`) cùng đi qua một VPC origin tới ALB internal `<name>-edge` ở các subnet edge, rồi tới pod Envoy trong target group
`<name>-envoy`; cộng cert ACM, response headers policy, log chuẩn v2 và bản ghi DNS của hai tên. Root `aws/envs/<env>` gọi module với
web ACL của module `waf`; lý do, đường đi của request và thứ tự gỡ ở
[chương 12. Media và edge](../../../docs/handbook/12-media-edge.md); test: `make test DIRS=aws/modules/edge`.

## Ví dụ

Lời gọi trong `aws/envs/stg/main.tf`, giá trị là placeholder:

```hcl
module "edge" {
  source = "../../modules/edge"

  name                    = "svp-stg"
  domain                  = "svp.example"
  hosted_zone_id          = "Z<id>"
  vpc_id                  = "vpc-<id>"
  subnet_ids              = ["subnet-<a>", "subnet-<b>"]
  node_security_group_id  = "sg-<node>"
  alb_deletion_protection = false

  web_acl_arns = {
    web = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-web/<id>"
    api = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-api/<id>"
  }
  log_delivery_destination_arn = "arn:aws:logs:us-east-1:000000000000:delivery-destination:svp-cloudfront-stg"
}
```

## Tham chiếu

- [Chương 12. Media và edge](../../../docs/handbook/12-media-edge.md): ghi chú thiết kế mà `main.tf`, `alb.tf`, `cloudfront.tf` trỏ tới.
- [ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) §2–§6, §8 và phụ lục:
  distribution, VPC origin, TLS, header, log edge.
- [`edge.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/explanation/edge.md) của svp-backend: đường đi của một request.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.69 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.69 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate.viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_acm_certificate_validation.viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_cloudfront_distribution.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_response_headers_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_response_headers_policy) | resource |
| [aws_cloudfront_vpc_origin.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_vpc_origin) | resource |
| [aws_cloudwatch_log_delivery.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery) | resource |
| [aws_cloudwatch_log_delivery_source.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery_source) | resource |
| [aws_lb.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.envoy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_route53_record.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_security_group.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.alb_to_envoy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.alb_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.envoy_from_alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_cloudfront_cache_policy.caching_disabled](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_origin_request_policy.all_viewer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_origin_request_policy) | data source |
| [aws_ec2_managed_prefix_list.cloudfront](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_managed_prefix_list) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alb\_deletion\_protection | Deletion protection of the ALB: while it is on, terraform destroy fails at the load balancer. | `bool` | n/a | yes |
| domain | Name of the env's hosted zone (svp.example): the web answers at `<domain>`, the API at `api.<domain>`. | `string` | n/a | yes |
| hosted\_zone\_id | ID of the Route 53 public hosted zone of domain: the module writes the ACM validation records and the alias records of both names there. | `string` | n/a | yes |
| log\_delivery\_destination\_arn | ARN of the CloudWatch Logs delivery destination (us-east-1, in the Log Archive account) that receives the standard logs of both distributions, `arn:aws:logs:us-east-1:<account>:delivery-destination:svp-cloudfront-<env>`. | `string` | n/a | yes |
| name | Fixed start of every name (svp-stg, svp-prd): ALB and VPC origin `<name>-edge`, target group `<name>-envoy`, distributions and response headers policies `<name>-web` and `<name>-api`. | `string` | n/a | yes |
| node\_security\_group\_id | Security group of the EKS nodes and, with the VPC CNI, of their pods (output node\_security\_group\_id of the eks module): the module lets the ALB reach Envoy on it. | `string` | n/a | yes |
| subnet\_ids | Edge subnets of the VPC, one per availability zone (output edge\_subnet\_ids of the network module): the internal ALB and the network interfaces of the CloudFront VPC origin live there. | `list(string)` | n/a | yes |
| vpc\_id | VPC of the load balancer, its security group and the target group. | `string` | n/a | yes |
| web\_acl\_arns | ARNs of the AWS WAF web ACLs of scope CLOUDFRONT (us-east-1, output web\_acl\_arn of the waf module), keyed web and api: each guards the distribution of the same name. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb\_security\_group\_id | Security group of the internal ALB: the only source the module lets in on the Envoy ports of the node security group. |
| distribution\_domains | Domain names (`<id>.cloudfront.net`) of the distributions, keyed web and api; `<domain>` and `api.<domain>` are alias records to them. |
| target\_group\_arn | ARN of the target group `<name>-envoy`: edgeTargetGroupArn of the cluster values, where the TargetGroupBinding of Envoy registers its pods. |
<!-- END_TF_DOCS -->
