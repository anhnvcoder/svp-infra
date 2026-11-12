# Module `waf`

Web ACL AWS WAF scope `CLOUDFRONT` đặt trước distribution CloudFront của module `media`: chặn ở edge, trước khi request bị tính tiền ở
origin. AWS chỉ nhận web ACL scope `CLOUDFRONT` ở `us-east-1`, nên module chỉ dùng provider mặc định `aws` và root gọi nó với provider của
region đó (`providers = { aws = aws.us_east_1 }`), rồi truyền output `web_acl_arn` vào biến `web_acl_arn` của module `media`. Cả hai root
`aws/envs/stg`, `aws/envs/prd` gọi module này (`waf.tf`, tên `svp-<env>-media`): gói CloudFront flat-rate Free của distribution media bắt
buộc có một web ACL ([ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md)).

Request không luật nào chặn thì cho qua. Ba luật, theo thứ tự WAF xét:

| Ưu tiên | Luật | Làm gì |
| --- | --- | --- |
| 0 | `rate-limit-per-ip` | Chặn một địa chỉ IP gửi quá `rate_limit` request trong 5 phút (mặc định 2000), tới khi tốc độ xuống lại dưới ngưỡng; đứng đầu để một đợt flood bị cắt trước khi bị tính phí ở các nhóm luật managed |
| 1 | `AWSManagedRulesCommonRuleSet` | Nhóm luật nền của AWS (khai thác kiểu OWASP, request quá cỡ hay sai dạng), giữ action `block` của nhóm |
| 2 | `AWSManagedRulesKnownBadInputsRuleSet` | Mẫu request của lỗ hổng đã biết (vd lookup Log4j) |

Gói Free nhận tối đa **5 luật** (luật tự viết cộng AWS Managed Rules), có rate limit theo IP và geo block; không có lọc theo header, regex,
CAPTCHA, challenge, Bot Control hay rule group tự tạo. Mỗi managed rule group tính là một luật là **giả định** (trang của AWS không nói),
kiểm ở phép kiểm (c) của buổi đầu. Thêm luật thì giữ trong giới hạn đó (test của module kiểm số luật).

Mỗi luật và web ACL gửi metric CloudWatch và giữ request mẫu (xem ở console). Web ACL, luật và request của web ACL gắn distribution có gói
nằm trong gói ($0); web ACL còn lại sau khi gói huỷ thì tính pay-as-you-go theo tháng mỗi ACL, mỗi luật và theo số request, nên script quét
sót bắt nó. Gói còn hiệu lực thì AWS không cho gỡ hay thay web ACL: đổi `name` (thay web ACL) phải huỷ gói trước.

## Log

`aws_wafv2_web_acl_logging_configuration` ghi **mọi request** (không logging filter) vào bucket `log_bucket_arn`: bucket log WAF
`aws-waf-logs-svp-<log>-us-east-1` của account `svp-log-archive`
([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §7, §9). WAF chỉ giao log tới
bucket tên bắt đầu `aws-waf-logs-`, nên biến kiểm ARN S3 với tiền tố đó. Header `authorization` và `cookie` bị che (`SingleHeader`): log
giữ IP, URI, header khác của người xem, không giữ credential hay cookie phiên.

- **Bucket ở account khác:** module chỉ nhận ARN. Bucket policy của root `aws/log-archive` cho `delivery.logs.amazonaws.com` ghi với điều
  kiện `aws:SourceOrgID` của org, và key `alias/svp-log-archive` ở `us-east-1` cho dịch vụ đó `kms:GenerateDataKey*`; account của web ACL
  không cần quyền đọc hay ghi policy của bucket. Bucket chưa có (Log Archive chưa áp) thì `apply` của root env lỗi ở tài nguyên này.
- **Gói flat-rate Free:** gói không chặn log WAF; phí giao log tới S3 nằm ngoài gói (vended log của CloudWatch, `us-east-1`), log gửi mỗi 5
  phút.
- **Gỡ:** destroy xoá cấu hình log trước web ACL (tham chiếu ARN của nó); object log đã giao ở lại bucket Log Archive theo retention của
  bucket đó.

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
| log\_bucket\_arn | ARN of the S3 bucket that receives the web ACL's logs: the WAF log bucket of the Log Archive account, arn:aws:s3:::aws-waf-logs-svp-<log account>-us-east-1. | `string` | n/a | yes |
| name | Name of the web ACL and prefix of the CloudWatch metric names of its rules, e.g. svp-prd-media. | `string` | n/a | yes |
| rate\_limit | Requests one client IP address may send within 5 minutes before the web ACL blocks it, until its rate falls back under the limit. A viewer of HLS fetches a segment every few seconds, a few hundred requests in 5 minutes; the default leaves room for several viewers behind one address. | `number` | `2000` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| web\_acl\_arn | ARN of the web ACL: web\_acl\_arn of the media module (web\_acl\_id of a CloudFront distribution takes the ARN of a WAF web ACL). |
<!-- END_TF_DOCS -->
