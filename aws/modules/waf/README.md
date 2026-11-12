# Module `waf`

Web ACL AWS WAF scope `CLOUDFRONT` đặt trước một distribution CloudFront: chặn ở edge, trước khi request tới origin. AWS chỉ nhận web ACL
scope `CLOUDFRONT` ở `us-east-1`, nên module chỉ dùng provider mặc định `aws`, không có đối số `region`; root gọi nó với provider của region đó
(`providers = { aws = aws.us_east_1 }`) và truyền output `web_acl_arn` cho đúng một distribution. Mỗi env gọi module ba lần, một lần mỗi
distribution (`svp-<env>-web`, `svp-<env>-api`, `svp-<env>-media`), với cấu hình ở
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) §7; ba ACL giống hệt ở stg và prd.

## Luật

Request không luật nào chặn thì cho qua. WAF xét luật theo thứ tự ưu tiên; luật rẻ đứng trước để request đã bị chặn không bị tính phí ở luật
sau, luật tính phí theo request (Bot Control, ATP) đứng cuối:

| Ưu tiên | Luật (tên trong web ACL) | Có khi | Làm gì |
| --- | --- | --- | --- |
| 0 | `rate-limit-per-ip` | luôn | Chặn một địa chỉ IP gửi quá `rate_limit` request trong 5 phút, tới khi tốc độ xuống lại dưới ngưỡng |
| 1 | `aws-ip-reputation`: `AWSManagedRulesAmazonIpReputationList` | luôn | IP Amazon Threat Intelligence ghi là nguồn bot, dò quét hay DDoS; giữ action của nhóm |
| 2 | `aws-common`: `AWSManagedRulesCommonRuleSet` | luôn | Nhóm luật nền (khai thác kiểu OWASP, request quá cỡ hay sai dạng); giữ action của nhóm, trừ luật trong `common_rule_set_count_overrides` chỉ đếm |
| 3 | `aws-known-bad-inputs`: `AWSManagedRulesKnownBadInputsRuleSet` | luôn | Mẫu request của lỗ hổng đã biết (vd lookup Log4j); giữ action của nhóm |
| 4 | `aws-bot-control`: `AWSManagedRulesBotControlRuleSet` | `bot_control` khác `null` | Gắn nhãn bot, không chặn gì (dưới đây) |
| 4, hay 5 khi có Bot Control | `aws-atp`: `AWSManagedRulesATPRuleSet` | `atp` khác `null` | Chống chiếm tài khoản ở đường đăng nhập (dưới đây) |

Mặc định (hai biến tuỳ chọn `null`, không override) web ACL có đúng **4 luật**: media của stg chạy gói CloudFront flat-rate Free, gói này nhận
tối đa 5 luật (luật tự viết cộng AWS Managed Rules) và không có Bot Control, ATP. Mỗi managed rule group tính là một luật là **giả định**
(trang của AWS không nói), kiểm ở buổi đầu; test của module kiểm số luật mặc định.

Mỗi luật và web ACL gửi metric CloudWatch (tên `<name>-<hậu tố>`) và giữ request mẫu (xem ở console). Web ACL gắn distribution có gói Free nằm
trong gói ($0); web ACL còn lại sau khi gói huỷ, và mọi web ACL của distribution pay-as-you-go, tính theo tháng mỗi ACL, mỗi luật và theo số
request, nên script quét sót bắt nó. Gói còn hiệu lực thì AWS không cho gỡ hay thay web ACL: đổi `name` (thay web ACL) phải huỷ gói trước.

### Override `count` của CommonRuleSet

`common_rule_set_count_overrides` liệt kê luật của `AWSManagedRulesCommonRuleSet` chỉ đếm (`rule_action_override` với `count`), cho luật chặn
một luồng hợp lệ của distribution đó; luật khác của nhóm giữ action của nó. Giá trị từng ACL và lý do ở ADR-0061 §7. AWS lặng lẽ bỏ qua
override có tên luật sai, nên biến chỉ nhận tên luật có trong nhóm (theo trang "Baseline rule groups" của AWS WAF Developer Guide); AWS thêm
luật vào nhóm thì thêm tên vào validation.

### Bot Control

`bot_control = { inspection_level = "COMMON" }` thêm nhóm Bot Control ở mức `COMMON`, ở hai mức `count` để đo trước khi chặn:

- `override_action { count {} }` trên luật nhóm: không gì của nhóm chặn, kể cả luật AWS thêm ở version sau.
- `rule_action_override` `count` cho từng luật mức `COMMON` (danh sách ở `local.bot_control_common_rules`): mọi luật đều được xét, thay vì
  dừng ở luật block đầu tiên khớp, nên log WAF có đủ nhãn bot.

Biến chỉ nhận `COMMON` vì danh sách override chỉ gồm luật của mức này; `enable_machine_learning` đặt `false` (chỉ luật mức `TARGETED` dùng).
Bật chặn là quyết định mới, sau khi đã đọc nhãn bot trong log WAF.

### ATP

`atp` thêm nhóm Account Takeover Prevention cho một đường đăng nhập:

- `login_path`: đường đăng nhập, bắt đầu bằng `/`; luật có scope-down URI path `EXACTLY` đường đó (không biến đổi, không regex), nên chỉ
  request tới đúng đường đó bị xét và tính phí.
- `payload_type`: `JSON` hay `FORM_ENCODED`, hai kiểu ATP đọc được; `username_field`, `password_field` là JSON pointer (`/email`) với `JSON`,
  tên trường form với `FORM_ENCODED`.
- `success_status_codes`, `failure_status_codes`: response inspection theo status code của response đăng nhập, mỗi danh sách ít nhất một
  mã, không mã nào ở cả hai. Response inspection chỉ có ở web ACL của CloudFront.

Nhóm giữ action của nó (`override_action { none {} }`).

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
