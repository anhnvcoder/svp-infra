# Module `account-baseline`

Phần sống lâu hơn mọi buổi của một account env (`svp-stg`, `svp-prd`): bucket state và key `alias/svp-tfstate` của mọi root trong
account, hosted zone của env với `CAA` ở đỉnh, bản ghi uỷ quyền zone con, budget tháng; theo biến, DNSSEC với hai alarm `page` và query
log của zone. Root `aws/accounts/<env>` ([README](../../accounts/README.md)) gọi module; vì sao từng phần:
[08. Account env](../../../docs/handbook/08-accounts.md). Test: `make test DIRS=aws/modules/account-baseline`.

## Ví dụ

Lời gọi của `aws/accounts/prd/main.tf` (stg bỏ năm đối số sau `budget_emails`), giá trị là placeholder:

```hcl
module "baseline" {
  source = "../../modules/account-baseline"

  env                  = "prd"
  account_id           = "000000000000"
  region               = "ap-southeast-1"
  zone_name            = "aws.svp.example"
  budget_limit_usd     = 20
  budget_emails        = ["<email>"]
  delegated_subdomains = { "stg.aws.svp.example" = ["<ns-1>", "<ns-2>", "<ns-3>", "<ns-4>"] }
  dnssec_enabled       = true
  dnssec_signing       = true
  alarm_topic_arn      = "arn:aws:sns:us-east-1:000000000000:svp-prd-dns-alarms"
  query_log_enabled    = true
}
```

## Tắt ký DNSSEC

Zone ký mà DNS cha còn bản ghi `DS` trỏ tới KSK thì mọi thay đổi làm chữ ký sai (tắt ký, xoá KSK, mất key KMS) khiến resolver kiểm
DNSSEC trả `SERVFAIL` cho cả zone. Vì vậy module không bao giờ để Terraform xoá key KMS (`prevent_destroy`), và tắt ký chỉ qua
`dnssec_signing` (`SIGNING` hay `NOT_SIGNING`; KSK vẫn `ACTIVE`, key vẫn giữ, vì Route 53 từ chối tắt KSK duy nhất của zone còn
ký). Không bao giờ đặt `dnssec_enabled = false` khi key còn trong state: `prevent_destroy` làm plan lỗi.

- **Đường lui** (gỡ `DS` ở DNS cha, chờ hết TTL của nó, `apply -var dnssec_signing=false` ở `aws/accounts/prd`, rồi PR đổi mặc định
  của biến thành `false`): [`edge-setup.md`, Đường lui](../../../docs/runbooks/edge-setup.md#đường-lui).
- **Gỡ hẳn** (hiếm, sau đường lui: bỏ key khỏi state, PR `dnssec_enabled = false`, lên lịch xoá key bằng tay):
  [`edge-setup.md`, Gỡ hẳn](../../../docs/runbooks/edge-setup.md#gỡ-hẳn).

## Tham chiếu

- [08. Account env](../../../docs/handbook/08-accounts.md): state, zone, `CAA`, DNSSEC; key policy, TTL, vùng `us-east-1` ở mục Đọc sâu
  (ghi chú thiết kế mà `kms.tf`, `dnssec.tf` trỏ tới).
- [Phụ lục ADR-0061 §11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0061-edge-cloudfront-waf-acm.md#11-dns):
  DNS env, zone, DNSSEC, chuỗi tin cậy và nguồn tài liệu AWS.
- [`edge-setup.md`, Alarm DNSSEC](../../../docs/runbooks/edge-setup.md#alarm-dnssec): hai alarm `page` và runbook của chúng.

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
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_cloudwatch_log_group.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_cloudwatch_metric_alarm.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_kms_alias.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_hosted_zone_dnssec.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_hosted_zone_dnssec) | resource |
| [aws_route53_key_signing_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_key_signing_key) | resource |
| [aws_route53_query_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_query_log) | resource |
| [aws_route53_record.caa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.delegation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_zone.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_iam_policy_document.dnssec_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account of the baseline (12 digits): part of the state bucket name and of the key policy. The root passes its own account\_id, which never goes into a committed file. | `string` | n/a | yes |
| alarm\_topic\_arn | SNS topic in us-east-1 the DNSSEC alarms notify (topic\_arn of the alarms module called with region us-east-1). Required when dnssec\_enabled. | `string` | `null` | no |
| budget\_emails | Addresses that receive the budget alerts. Personal data of a public repository: the root reads them from an uncommitted *.auto.tfvars or TF\_VAR\_budget\_emails. | `list(string)` | n/a | yes |
| budget\_limit\_usd | Monthly cost budget of the account, in US dollars. Alerts go out at 50, 80 and 100 percent of actual cost and at 100 percent of forecast cost. | `number` | n/a | yes |
| delegated\_subdomains | Child zones of other accounts to delegate from this zone: zone name (ending in .<zone\_name>) to its four name servers, the name\_servers output of the child's baseline. Each entry becomes an NS record in this zone. | `map(list(string))` | `{}` | no |
| dnssec\_enabled | Sign the zone with DNSSEC: a KMS key in us-east-1 (kept with prevent\_destroy), a key signing key, zone signing and two page alarms to alarm\_topic\_arn. Turning it off once on: the steps of the module README, never this variable alone. | `bool` | `false` | no |
| dnssec\_signing | With dnssec\_enabled, whether the zone is signed (SIGNING) or not (NOT\_SIGNING); the key signing key and the KMS key stay either way. Set it to false only after the DS record at the parent is gone and its TTL has passed. | `bool` | `true` | no |
| env | Environment the account runs (stg, prd): names the budget svp-<env>-monthly and appears in the comment of the hosted zone. | `string` | n/a | yes |
| query\_log\_enabled | Log the public DNS queries of the zone to the CloudWatch Logs group /aws/route53/<zone\_name> in us-east-1, kept 90 days. | `bool` | `false` | no |
| region | Region of the state bucket and its KMS key, part of the bucket name; the root passes the region of its provider. | `string` | n/a | yes |
| zone\_name | Name of the environment's hosted zone, e.g. aws.svp.example or stg.aws.svp.example. The zone above it delegates it with NS records to the name\_servers output. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| backend\_hcl | Content of aws/backend-<env>.hcl, the partial backend configuration every root of this account reads with -backend-config: bucket, region, encryption with the KMS key of the state and the S3 lock file. It holds no key argument: each root sets the key of its own state. |
| name\_servers | The four name servers of the environment's zone, which the zone above it delegates with NS records: the zone of prd for stg (delegated\_subdomains of aws/accounts/prd), the NS records aws at the parent domain's DNS for prd. |
| state\_bucket | Bucket of the remote state of every root of this account. |
| state\_kms\_key\_arn | ARN of the KMS key alias/svp-tfstate that encrypts the state bucket, in the key form arn:aws:kms:<region>:<account>:key/<key-id> that IAM policies match. |
| zone\_id | Id of the hosted zone of the environment, zone\_name. |
<!-- END_TF_DOCS -->
