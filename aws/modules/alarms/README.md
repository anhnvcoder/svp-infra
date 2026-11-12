# Module `alarms`

SNS topic mà mọi CloudWatch alarm của một env gửi `alarm_actions` và `ok_actions` tới, mã hoá bằng KMS key của module, cùng subscription email.
Thiết kế: [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) §1. Module giống nhau ở mọi
env; alarm nằm ở module của từng dịch vụ (`rds`, `msk`, `elasticache`), nhận `topic_arn` qua biến `alarm_topic_arn`.

Root `aws/security` gọi module với `name = "svp-security"` và `publisher_services = ["events.amazonaws.com"]`: topic `svp-security-alarms`
nhận sự kiện bảo mật của org từ rule EventBridge
([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §10).

Biến `region` (mặc định `null`: region của provider) đặt region của mọi tài nguyên của module; `<region>` trong ARN của topic và của
`aws:SourceArn` theo nó. CloudWatch alarm chỉ gửi tới topic cùng region, nên alarm ở region khác region của provider cần topic riêng ở region đó:
root `aws/accounts/prd` gọi module với `name = "svp-prd-dns"`, `region = "us-east-1"` cho hai alarm DNSSEC của module
[`account-baseline`](../account-baseline/README.md) (metric DNSSEC của Route 53 chỉ ở `us-east-1`). Topic này sống cùng zone, tách khỏi topic
`svp-prd-alarms` của buổi.

Tạo:

- Một KMS key customer managed (symmetric, xoay vòng bật, deletion window 7 ngày, alias `alias/<name>-alarms`). CloudWatch và EventBridge không
  gửi được vào topic mã hoá bằng key AWS quản lý của SNS (`alias/aws/sns`), vì key policy của key đó không sửa được để cho principal dịch vụ dùng
  ([Encrypting SNS topics](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html#compatibility-with-aws-services)). Key policy gồm
  statement mặc định của account (IAM của account quyết định ai khác dùng key) và một statement cho mỗi principal của `publisher_services`: chỉ
  `kms:Decrypt`, `kms:GenerateDataKey*`; điều kiện nguồn trên key theo dịch vụ (bảng dưới).
- SNS topic `<name>-alarms`, `kms_master_key_id` là alias của key trên.
- Topic policy thay policy mặc định: chỉ principal của `publisher_services` được `sns:Publish`, mỗi principal một statement với điều kiện
  `aws:SourceAccount` là account và `aws:SourceArn` khớp tài nguyên của chính dịch vụ đó (bảng dưới); mọi principal bị từ chối `sns:Publish`
  khi `aws:SecureTransport` là `false`. Principal của account vẫn quản lý và gửi vào topic bằng IAM policy của mình.
- Subscription `email` tới `alarm_email`.

Điều kiện confused deputy theo dịch vụ:

| `publisher_services` | Gửi từ | `aws:SourceArn` (`ArnLike`) | Key policy | Nguồn |
| --- | --- | --- | --- | --- |
| `cloudwatch.amazonaws.com` (mặc định) | CloudWatch alarm | `arn:aws:cloudwatch:<region>:<account>:alarm:*` | `aws:SourceAccount`, `aws:SourceArn` như topic policy | [CloudWatch](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html#SNS_Confused_Deputy) |
| `events.amazonaws.com` | Rule EventBridge, trên bus mặc định hay bus riêng | `arn:aws:events:<region>:<account>:rule/*` | không điều kiện nguồn | [EventBridge](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html#eb-sns-permissions), [SNS](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html#compatibility-with-aws-services) |

SNS không hỗ trợ `aws:SourceAccount`, `aws:SourceArn`, `aws:SourceOrgID` trong key policy khi EventBridge gửi vào topic mã hoá: có chúng thì KMS
từ chối cấp data key và cảnh báo không tới. Với EventBridge, chỉ topic policy giới hạn rule của account và region nào gửi được vào topic.

Mặc định chỉ CloudWatch: topic của hai env giữ đúng statement id (`CloudWatchAlarmsUseKey`, `CloudWatchAlarmsPublish`) và mô tả key, nên plan
của root env không đổi.

## Xác nhận email

- Apply tạo subscription ở trạng thái `PendingConfirmation`: SNS gửi email "AWS Notification - Subscription Confirmation" tới `alarm_email`, và
  topic không gửi gì tới địa chỉ đó cho tới khi người nhận mở link xác nhận. Terraform không xác nhận được subscription email.
- Bước của buổi: sau apply, mở link trong email; `aws sns list-subscriptions-by-topic` hiện `SubscriptionArn` là ARN thật thay
  `PendingConfirmation`. Sau đó `aws cloudwatch set-alarm-state` một alarm tới `ALARM` kiểm cả đường CloudWatch → KMS → SNS → email.
- `alarm_email` là biến sensitive, đặt ở `*.auto.tfvars` của root (không commit); ví dụ và test dùng `ops@svp.example`.

## Xoá

- **KMS key:** vào `PendingDeletion` 7 ngày, không tính phí lúc chờ; alias xoá ngay.
- **Subscription chưa xác nhận:** SNS không cho huỷ subscription `PendingConfirmation`; destroy chỉ bỏ nó khỏi state, nó còn ở AWS tới khi SNS
  tự xoá subscription chưa xác nhận. Xoá topic trước đó vẫn chặn mọi thông báo tới địa chỉ.

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
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_sns_topic.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.topic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_email | Email address subscribed to the topic; SNS sends it a confirmation link and delivers nothing until the link is opened. | `string` | n/a | yes |
| name | Name of the env or stack (svp-stg, svp-prd, svp-security): prefix of the SNS topic <name>-alarms and of the KMS alias alias/<name>-alarms. | `string` | n/a | yes |
| publisher\_services | Service principals that publish to the topic and use its key, each limited to its own resources of this account and region: cloudwatch.amazonaws.com (alarms), events.amazonaws.com (EventBridge rules). | `list(string)` | <pre>[<br/>  "cloudwatch.amazonaws.com"<br/>]</pre> | no |
| region | Region of the topic, its key and the alarms that may notify it (CloudWatch alarm actions reach a topic of their own region only). Null: the region of the provider. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| topic\_arn | ARN of the SNS topic <name>-alarms: alarm\_actions and ok\_actions of every CloudWatch alarm of the env (alarm\_topic\_arn of the rds, msk and elasticache modules). |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
