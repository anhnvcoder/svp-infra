# Module `security-baseline`

Baseline bảo mật của một account: S3 Block Public Access cấp account, EBS mã hoá mặc định, AWS Config ghi liên tục, và rule EventBridge chuyển sự
kiện bảo mật sang account Security Tooling. Root `aws/baseline` gọi module một lần mỗi account, chạy từ management qua
`OrganizationAccountAccessRole`. Thiết kế: [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md)
§9 và [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §4, §10; event pattern đủ ở phụ
lục ADR-0060.

Module dùng một provider `aws` ở region nhà (region của provider). Tài nguyên ở region khác đặt đối số `region` của AWS provider v6, không dùng
provider thứ hai: `us-east-1` là region phụ cố định, vì IAM và Organizations ghi sự kiện CloudTrail ở đó và SCP `svp-deny-other-regions` chỉ cho
hai region này.

## Tạo gì

- **S3 Block Public Access cấp account:** bốn cờ `true`. Cài đặt của cả account, không theo region.
- **EBS mã hoá mặc định:** bật ở region nhà và `us-east-1`. Key mặc định ở region nhà là `ebs_kms_key_arn` khi có (CMK EBS của `svp-stg`,
  `svp-prd`); `null` giữ key AWS managed `aws/ebs`. `us-east-1` luôn dùng `aws/ebs`. Key phải cùng region nhà (precondition), vì EC2 chỉ nhận key
  mặc định của chính region. Xoá `ebs_kms_key_arn` thì Terraform xoá tài nguyên key mặc định, EC2 trở về `aws/ebs`.
- **AWS Config**, mỗi region một bộ khi `config_recording` là `true` (mặc định):
  - Service-linked role `AWSServiceRoleForConfig`, có ở mọi giá trị của `config_recording`; recorder dùng ARN của role này, ghép từ partition và
    account để plan biết trước.
  - Recorder `default`: mọi loại tài nguyên hỗ trợ, `recording_frequency` `CONTINUOUS`. Loại toàn cục (IAM) chỉ ghi ở region nhà
    ([điều kiện Config của Security Hub](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-setup-prereqs.html)), không thì
    mọi region ghi cùng một thay đổi. Ghi liên tục thay vì hằng ngày vì tài nguyên của buổi chỉ sống vài giờ
    ([tần suất ghi](https://docs.aws.amazon.com/config/latest/developerguide/select-resources.html)).
  - Delivery channel `default` về `config_bucket_name` (bucket Config của Log Archive), mã hoá bằng `log_archive_key_arn`, snapshot 24 giờ. Config
    giao object bằng principal `config.amazonaws.com`, bucket policy của Log Archive cho phép
    ([quyền bucket](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-policy.html)).
  - Trạng thái recorder bật, sau khi delivery channel có (`depends_on`): recorder không chạy được khi region chưa có delivery channel.
- **`config_recording`** = `false`: account không có recorder, delivery channel, recorder status ở cả hai region. Service-linked role, S3 Block
  Public Access, EBS mã hoá và mọi rule chuyển sự kiện giữ nguyên. Root ánh xạ cờ `config_recording` của file cờ chi phí (`off` → `false`); cờ,
  giá trị theo account và cái giá ở [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md).
  Rule `svp-security-detection`, `svp-security-denied-detection` vẫn hợp lệ: chúng khớp lời gọi API Config do CloudTrail ghi, không cần recorder.
  Đổi `true` → `false` xoá recorder status, delivery channel, recorder của hai region; lịch sử đã giao vào bucket Config của Log Archive còn.
  Lần apply đó `svp-security-detection` báo `StopConfigurationRecorder`, `DeleteDeliveryChannel`, `DeleteConfigurationRecorder` thành công.
- **Rule chuyển sự kiện** trên bus mặc định, đích là bus `svp-security-events` của Security Tooling (`security_event_bus_arn`), qua role
  `svp-security-forwarder`: đích là bus của account khác thì EventBridge cần role
  ([gửi sự kiện giữa account](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html)). Role chỉ tin
  `events.amazonaws.com` với `aws:SourceAccount` là account, chỉ được `events:PutEvents` trên bus đó.

## Rule theo input

| Rule | Region | Có khi |
| --- | --- | --- |
| `svp-security-root-signin` | `root_signin_regions` | luôn |
| `svp-security-trail`, `svp-security-detection`, `svp-security-alert-rules` | nhà, `us-east-1` | luôn |
| `svp-security-denied-iam` | `us-east-1` | luôn |
| `svp-security-denied-detection`, `svp-security-denied-storage` | nhà, `us-east-1` | luôn |
| `svp-security-root-session`, `svp-security-org` | `root-session`: nhà, `us-east-1`; `org`: `us-east-1` | `organization_events` |
| `svp-security-admin-iam`, `svp-security-admin-kms-s3` | `admin-iam`: `us-east-1`; `admin-kms-s3`: nhà, `us-east-1` | `admin_events` |
| `svp-security-admin-sso` | `identity_center_region` | `identity_center_region` khác `null` |

- Nhóm `denied-*` có ở mọi account, kể cả stg, prd, không phụ thuộc `admin_events`: lệnh bị SCP `svp-protect-baseline`, `svp-deny-iam-users`
  từ chối luôn là sự kiện cần biết. `errorCode` khớp `prefix` `AccessDenied` (phủ cả `AccessDeniedException` của API JSON);
  `denied-storage` khớp thêm `Client.UnauthorizedOperation` của EC2, kể cả `--dry-run`.
- `svp-security-root-signin`: CloudTrail ghi đăng nhập console của root ở `us-east-1`, `us-east-2` hay `us-west-2`
  ([sự kiện đăng nhập](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-aws-console-sign-in-events.html)).
  Management truyền cả ba; account thành viên giữ mặc định `us-east-1`, vì SCP chặn chúng ở region khác.
- `svp-security-root-session` có `state` `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`: `AssumeRoot` có thể là sự kiện chỉ đọc, mà rule
  `ENABLED` chỉ nhận sự kiện ghi
  ([sự kiện quản lý của CloudTrail](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail-management.html)).
- `admin_events` chỉ bật ở account ít đổi IAM, KMS, S3 (management, `svp-log-archive`, `svp-security`): mỗi buổi stg, prd tạo và xoá hàng chục
  role, key, bucket.
- Pattern viết bằng `jsonencode`; mỗi pattern tối đa 2 048 ký tự ([EventBridge quotas](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-quota.html)),
  test kiểm cỡ.
- Tên rule và role bắt đầu `svp-security-` vì `svp-protect-baseline` chặn mọi principal trừ `OrganizationAccountAccessRole` sửa rule, role theo
  đúng tiền tố đó. Đổi tên thì đổi cả SCP.

## Áp lần đầu

- Mỗi account mỗi region chỉ có một recorder và một delivery channel. Module đặt tên cố định `default`; `PutConfigurationRecorder`,
  `PutDeliveryChannel` với tên đã có thì cập nhật chứ không báo lỗi. Gọi module lần hai cho cùng account vì vậy không tạo recorder thứ hai mà
  apply thành công, hai địa chỉ state cùng ghi đè một recorder: root gọi module đúng một lần mỗi account.
- Account đã có `AWSServiceRoleForConfig`, recorder hay delivery channel tạo tay thì root nhập chúng vào state bằng khối `import` trước apply,
  không thêm cờ "đã có" vào module. Địa chỉ: `module.<account>.aws_iam_service_linked_role.config`,
  `module.<account>.aws_config_configuration_recorder.this["<region>"]`, `module.<account>.aws_config_delivery_channel.this["<region>"]`.
- Khi bus của Security Tooling đã có rule gửi SNS, apply của module sinh email từ chính các rule của nó, ở mỗi account áp baseline:
  - apply đầu tiên: `svp-security-detection` báo `PutConfigurationRecorder`, `PutDeliveryChannel` thành công;
  - apply đầu tiên và mỗi lần đổi pattern hay đích: `svp-security-alert-rules` báo mỗi `PutRule`, `PutTargets` thành công trên rule
    `svp-security-*` chạy sau khi chính nó đã có hiệu lực, một email mỗi lời gọi.

Test (`make test DIRS=aws/modules/security-baseline`, provider giả): bốn cờ BPA, EBS mã hoá ở hai region, recorder `CONTINUOUS` với loại toàn cục
chỉ ở region nhà, delivery channel đúng bucket và key, tập rule của account thành viên, của management và của `admin_events`, region và đích của
từng rule, nội dung các pattern, role chuyển sự kiện; số tài nguyên Config mỗi region và các tài nguyên giữ ở cả hai giá trị của
`config_recording`; mỗi luật validation và precondition một plan.

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
