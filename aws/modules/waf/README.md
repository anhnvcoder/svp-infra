# Module `waf`

Một web ACL AWS WAF scope `CLOUDFRONT` trước một distribution CloudFront: luật rate-based theo IP, ba nhóm luật managed, tuỳ chọn Bot
Control chỉ đếm và ATP cho đường đăng nhập, log mọi request tới bucket log WAF của Log Archive. Scope `CLOUDFRONT` chỉ có ở `us-east-1`:
root gọi module với provider của region đó, ba lần mỗi env (`aws/envs/<env>/waf.tf`). Lý do từng luật ở
[chương 12. Media và edge](../../../docs/handbook/12-media-edge.md); test: `make test DIRS=aws/modules/waf`.

## Ví dụ

ACL `api` của `aws/envs/stg/waf.tf` (root gọi bằng `for_each`), giá trị là placeholder:

```hcl
module "waf" {
  source = "../../modules/waf"

  providers = { aws = aws.us_east_1 }

  name           = "svp-stg-api"
  log_bucket_arn = "arn:aws:s3:::aws-waf-logs-svp-000000000000-us-east-1"

  common_rule_set_count_overrides = []
  bot_control                     = null
  atp = {
    login_path           = "/auth/login"
    payload_type         = "JSON"
    username_field       = "/email"
    password_field       = "/password"
    success_status_codes = [200]
    failure_status_codes = [401]
  }
}
```

## Tham chiếu

- [Chương 12. Media và edge](../../../docs/handbook/12-media-edge.md): ghi chú thiết kế mà `main.tf` trỏ tới.
- [ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) §7: cấu hình từng ACL;
  [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §7, §9: log WAF.

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
| [aws_wafv2_web_acl_logging_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_logging_configuration) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| atp | Account takeover prevention (AWSManagedRulesATPRuleSet) for the login endpoint, last rule of the web ACL, scoped down to requests whose URI path is exactly login\_path: payload\_type JSON or FORM\_ENCODED, username\_field and password\_field as JSON pointers (JSON) or form field names, and the response status codes of a successful and a failed login. null: no ATP. | <pre>object({<br/>    login_path           = string<br/>    payload_type         = string<br/>    username_field       = string<br/>    password_field       = string<br/>    success_status_codes = list(number)<br/>    failure_status_codes = list(number)<br/>  })</pre> | `null` | no |
| bot\_control | Bot Control (AWSManagedRulesBotControlRuleSet) at this inspection level, after the other rules: the whole group and each of its rules only count, so it labels bots in the WAF log and blocks nothing. null: no Bot Control. | <pre>object({<br/>    inspection_level = string<br/>  })</pre> | `null` | no |
| common\_rule\_set\_count\_overrides | Rules of AWSManagedRulesCommonRuleSet that only count instead of blocking, for a rule that blocks a legitimate flow of this distribution (e.g. SizeRestrictions\_BODY where bodies exceed 8 KB). Empty: every rule of the group keeps its own action. | `list(string)` | `[]` | no |
| log\_bucket\_arn | ARN of the S3 bucket that receives the web ACL's logs: the WAF log bucket of the Log Archive account, arn:aws:s3:::aws-waf-logs-svp-<log account>-us-east-1. | `string` | n/a | yes |
| name | Name of the web ACL and prefix of the CloudWatch metric names of its rules, e.g. svp-prd-media. | `string` | n/a | yes |
| rate\_limit | Requests one client IP address may send within 5 minutes before the web ACL blocks it, until its rate falls back under the limit. A viewer of HLS fetches a segment every few seconds, a few hundred requests in 5 minutes; the default leaves room for several viewers behind one address. | `number` | `2000` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| web\_acl\_arn | ARN of the web ACL, for the one CloudFront distribution it protects (web\_acl\_id of a distribution takes the ARN of a WAF web ACL). |
<!-- END_TF_DOCS -->
