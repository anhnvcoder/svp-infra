# Module `waf`

Web ACL AWS WAF scope `CLOUDFRONT` đặt trước distribution CloudFront của module `media`: chặn ở edge, trước khi request bị tính tiền ở
origin. AWS chỉ nhận web ACL scope `CLOUDFRONT` ở `us-east-1`, nên module chỉ dùng provider mặc định `aws` và root gọi nó với provider của
region đó (`providers = { aws = aws.us_east_1 }`), rồi truyền output `web_acl_arn` vào biến `web_acl_arn` của module `media`. Root stg không
gọi module này (ngoại lệ trivy AWS-0011 có điều kiện ở `media/cloudfront.tf`).

Request không luật nào chặn thì cho qua. Ba luật, theo thứ tự WAF xét:

| Ưu tiên | Luật | Làm gì |
| --- | --- | --- |
| 0 | `rate-limit-per-ip` | Chặn một địa chỉ IP gửi quá `rate_limit` request trong 5 phút (mặc định 2000), tới khi tốc độ xuống lại dưới ngưỡng; đứng đầu để một đợt flood bị cắt trước khi bị tính phí ở các nhóm luật managed |
| 1 | `AWSManagedRulesCommonRuleSet` | Nhóm luật nền của AWS (khai thác kiểu OWASP, request quá cỡ hay sai dạng), giữ action `block` của nhóm |
| 2 | `AWSManagedRulesKnownBadInputsRuleSet` | Mẫu request của lỗ hổng đã biết (vd lookup Log4j) |

Mỗi luật và web ACL gửi metric CloudWatch và giữ request mẫu (xem ở console). Web ACL tính phí theo tháng mỗi ACL, mỗi luật và theo số
request; chi phí của env nằm ở phụ lục ADR của môi trường prd.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_wafv2_web_acl.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Name of the web ACL and prefix of the CloudWatch metric names of its rules, e.g. svp-prd-media. | `string` | n/a | yes |
| rate\_limit | Requests one client IP address may send within 5 minutes before the web ACL blocks it, until its rate falls back under the limit. A viewer of HLS fetches a segment every few seconds, a few hundred requests in 5 minutes; the default leaves room for several viewers behind one address. | `number` | `2000` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| web\_acl\_arn | ARN of the web ACL: web\_acl\_arn of the media module (web\_acl\_id of a CloudFront distribution takes the ARN of a WAF web ACL). |
<!-- END_TF_DOCS -->
