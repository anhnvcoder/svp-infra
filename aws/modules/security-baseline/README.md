# Module `security-baseline`

Baseline bảo mật của một account: S3 Block Public Access cấp account, EBS mã hoá mặc định ở hai region, AWS Config ghi liên tục theo
`config_recording`, và rule EventBridge `svp-security-*` chuyển sự kiện bảo mật sang bus `svp-security-events` của `svp-security` qua role
`svp-security-forwarder`. Root `aws/baseline` gọi module đúng một lần mỗi account, chạy từ management qua `OrganizationAccountAccessRole`
(management: phiên SSO). Phần baseline giải thích ở chương 06. Baseline <!-- link-chờ: docs/handbook/06-baseline.md -->, rule và đường
cảnh báo ở [05. Bảo mật](../../../docs/handbook/05-security.md#đường-của-sự-kiện); test: `make test DIRS=aws/modules/security-baseline`.

## Ví dụ

Lời gọi của account stg trong `aws/baseline/main.tf`, giá trị là placeholder:

```hcl
module "stg" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.stg }

  config_bucket_name     = "svp-config-000000000000-ap-southeast-1"
  log_archive_key_arn    = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  security_event_bus_arn = "arn:aws:events:ap-southeast-1:000000000000:event-bus/svp-security-events"
  ebs_kms_key_arn        = "arn:aws:kms:ap-southeast-1:000000000000:key/<id>"
  admin_events           = false
  organization_events    = false
  root_signin_regions    = ["us-east-1"]
  identity_center_region = null
  config_recording       = false
}
```

## Tham chiếu

- [05. Bảo mật](../../../docs/handbook/05-security.md): rule theo input, bộ lọc phiên Terraform của `svp-security-admin-*`, đường tới
  email (ghi chú thiết kế mà `events.tf` trỏ tới).
- Chương 06. Baseline <!-- link-chờ: docs/handbook/06-baseline.md -->: S3 Block Public Access, EBS mã hoá, recorder Config (ghi chú
  thiết kế mà `main.tf`, `config.tf` trỏ tới).
- [ADR-0060 phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md): event pattern
  đủ của mọi rule.

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
| [aws_cloudwatch_event_rule.forward](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.forward](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_config_configuration_recorder.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder) | resource |
| [aws_config_configuration_recorder_status.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder_status) | resource |
| [aws_config_delivery_channel.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_delivery_channel) | resource |
| [aws_ebs_default_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_default_kms_key) | resource |
| [aws_ebs_encryption_by_default.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_encryption_by_default) | resource |
| [aws_iam_role.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_service_linked_role.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_service_linked_role) | resource |
| [aws_s3_account_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_account_public_access_block) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.forwarder_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_events | Forward successful administrative changes to IAM, KMS keys and S3 buckets (svp-security-admin-iam, svp-security-admin-kms-s3). For accounts where such a change is rare; an env account creates dozens of roles, keys and buckets per session. | `bool` | `false` | no |
| config\_bucket\_name | Name of the AWS Config bucket of the Log Archive account (svp-config-<log archive account>-<region>), where the delivery channels of both regions write. | `string` | n/a | yes |
| config\_recording | Run AWS Config in both regions: recorder, delivery channel and recorder status. false leaves the account without them; the service-linked role, S3 Block Public Access, EBS encryption and every rule stay. | `bool` | `true` | no |
| ebs\_kms\_key\_arn | ARN of the KMS key (key/<id> form, home region) that encrypts new EBS volumes of the home region by default; null keeps the AWS managed key aws/ebs. The other region always uses aws/ebs. | `string` | `null` | no |
| identity\_center\_region | Region of the IAM Identity Center instance, for the account that holds it: forwards successful permission set and account assignment changes (svp-security-admin-sso), recorded in that region only. null: no such rule. | `string` | `null` | no |
| log\_archive\_key\_arn | ARN of the KMS key of the Log Archive account in the home region, in its key/<id> form: the delivery channels encrypt with it. | `string` | n/a | yes |
| organization\_events | Forward the events only the management account records: changes to AWS Organizations and its policies (svp-security-org) and AssumeRoot sessions (svp-security-root-session). | `bool` | `false` | no |
| root\_signin\_regions | Regions of the rule svp-security-root-signin. CloudTrail records a console sign-in of the root user in us-east-1, us-east-2 or us-west-2: the management account passes all three, member accounts keep us-east-1 (other regions are denied to them). | `list(string)` | <pre>[<br/>  "us-east-1"<br/>]</pre> | no |
| security\_event\_bus\_arn | ARN of the event bus svp-security-events of the Security Tooling account, target of every svp-security-* rule of the account. | `string` | n/a | yes |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
