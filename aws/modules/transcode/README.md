# Module `transcode`

Transcode video của một env bằng AWS Elemental MediaConvert: queue on-demand, role mà job chạy với, rule EventBridge đưa trạng thái cuối của job
vào hàng đợi SQS có dead-letter queue và alarm, cộng policy IAM (JSON) phần MediaConvert, `iam:PassRole`, SQS của bridge
(`media-worker mediaconvert`). Thiết kế: [ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md)
§1, §7, §9; bảng quyền, giá trị và nguồn ở
[phụ lục ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md) (mục "Giá trị → nguồn",
§7, §9, "Control FSBP"). Luồng của bridge (Probe, bản ghi job, quyết định kết quả) ở `docs/explanation/transcode.md` của repo code.

Root `aws/envs/<env>` gọi module với ARN hai bucket của module `media` và topic của module `alarms`. Mọi tài nguyên dùng region của provider, sống
trong buổi và bị gỡ cùng root env; lúc không buổi chúng không tồn tại, nên không tốn gì.

## Tên tài nguyên

| Tài nguyên | Tên |
| --- | --- |
| Queue MediaConvert (on-demand) | `svp-<env>` |
| Role MediaConvert | `svp-<env>-mediaconvert` |
| Rule EventBridge (bus mặc định) | `svp-<env>-mediaconvert-job-state` |
| SQS standard của trạng thái job | `svp-<env>-transcode-events` |
| Dead-letter queue | `svp-<env>-transcode-events-dlq` |
| Alarm CloudWatch | `svp-<env>-transcode-events-dlq` |

ARN của queue, role, rule và hai hàng đợi ghép từ partition, region, account và tên trong `locals` của `main.tf`, không đọc từ resource: policy và
event pattern biết lúc `plan`, test mock khẳng định được từng giá trị. `depends_on` giữ thứ tự tạo mà tham chiếu bỏ đi: DLQ trước hàng đợi nguồn (SQS
từ chối redrive tới queue chưa có), policy của hai hàng đợi trước đích của rule.

## Queue MediaConvert

On-demand (`pricing_plan = "ON_DEMAND"`): tính tiền theo phút output, không phí cố định; số job đồng thời theo hạn mức mặc định của queue
on-demand (phụ lục, dòng "Job đồng thời"). Tier Basic hay Professional là thuộc tính của job (bridge đặt trong settings), không của queue.

## Role MediaConvert

- **Trust:** `mediaconvert.amazonaws.com`, `sts:AssumeRole`, `StringEquals` `aws:SourceAccount` là account và `ArnLike` `aws:SourceArn` là ARN queue
  `svp-<env>`: cách tài liệu MediaConvert chống confused deputy, nên job của account hay queue khác không dùng được role.
- **Quyền:** đúng bảng "Role MediaConvert" của phụ lục §9: `s3:GetObject` trên `<uploads>/uploads/*` (đọc input), `s3:PutObject` trên
  `<media>/media/*` (ghi output), `kms:Decrypt` trên `uploads_kms_key_arn` (bucket `uploads` mã hoá SSE-KMS bằng key của module `media`,
  [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §8; `media` SSE-S3 nên ghi không cần quyền KMS).
  Policy inline tên `s3`.

## Policy của bridge

Output `bridge_policy_json` là các dòng MediaConvert, `iam:PassRole`, SQS của bảng "Quyền bridge" ở phụ lục §9; dòng S3 do module `media` giữ
(`media_worker_policy_json`). Root env gộp hai JSON vào role Pod Identity `svp-<env>-media-worker`.

| Statement | Action | Resource | Điều kiện |
| --- | --- | --- | --- |
| `CreateJobs` | `mediaconvert:CreateJob` | ARN queue `svp-<env>` | — |
| `ReadJobs` | `mediaconvert:GetJob` | `arn:aws:mediaconvert:<region>:<account>:jobs/*` (ID job chỉ có sau khi tạo) | — |
| `ProbeInputs` | `mediaconvert:Probe` | `*` (action không có resource type) | — |
| `PassMediaConvertRole` | `iam:PassRole` | ARN role `svp-<env>-mediaconvert` | `StringEquals` `iam:PassedToService` `mediaconvert.amazonaws.com` |
| `ConsumeJobStates` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` | ARN `svp-<env>-transcode-events` | — |

## Trạng thái job: EventBridge, SQS, DLQ

- **Rule** trên bus mặc định khớp `source` `aws.mediaconvert`, `detail-type` `MediaConvert Job State Change`, `detail.status` `COMPLETE` hoặc
  `ERROR`, `detail.queue` là ARN queue của env. `SUBMITTED`, `PROGRESSING` không quyết gì nên không vào hàng đợi.
- **Đích** là `svp-<env>-transcode-events`, dead-letter của đích là DLQ: không có nó, EventBridge bỏ event khi hết số lần thử mặc định (phụ lục §7).
- **Hàng đợi** standard, mã hoá SSE-SQS (không phí KMS). Redrive tới DLQ sau `maxReceiveCount` của `events.tf` (giá trị chọn ở phụ lục §7): message
  bridge không hành động được (không phải JSON, job không thuộc queue, `UserMetadata` hay destination sai) bị nhận lại tới mức đó rồi vào DLQ. DLQ
  giữ message lâu nhất SQS cho phép, để người vận hành chuyển về sau khi sửa nguyên nhân.
- **Policy** của cả hai hàng đợi: chỉ `events.amazonaws.com` được `sqs:SendMessage`, với `ArnEquals` `aws:SourceArn` là ARN của rule; statement
  `Deny` `sqs:*` khi `aws:SecureTransport` là `false`. Wildcard ở `Deny` chỉ mở rộng thứ bị cấm, không cấp quyền nào.
- **Alarm** `svp-<env>-transcode-events-dlq`: `ApproximateNumberOfMessagesVisible` của DLQ (tối đa mỗi phút) lớn hơn 0 trong một chu kỳ; tag
  `Severity` `page`, URL runbook `docs/runbooks/transcode-events-dlq.md` của repo code trong `alarm_description`, `alarm_actions` và `ok_actions` tới
  `alarm_topic_arn`. Message trong DLQ là một video đứng ở `PROCESSING`.

## Control FSBP

Bảng của phụ lục ADR-0066 (mục "Control FSBP"); Security Hub không có control nào cho MediaConvert.

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| SQS.1 | Queue SQS mã hoá at rest | có | Đạt | SSE-SQS ở cả hai queue |
| SQS.3 | Policy queue SQS không cho truy cập công khai | có | Đạt | Principal `events.amazonaws.com` với `aws:SourceArn` của rule |
| SQS.2 | Queue SQS có tag | không | Đạt | `default_tags` của root |
| EventBridge.3 | Custom event bus có resource policy | có | Không áp | Rule ở default bus |
| IAM.1 | Policy không cho `"*"` quản trị | có | Đạt | Action liệt kê từng cái |
| IAM.21 | Policy tự tạo không wildcard action theo dịch vụ | có | Đạt | Không `mediaconvert:*`, `sqs:*`, `s3:*` ở statement `Allow` |
| CloudWatch.15 | Alarm có action | không | Đạt | Alarm DLQ gửi topic của module `alarms` |

## Test

`tests/transcode.tftest.hcl` (provider mock, chỉ `plan`) so từng statement của trust, policy role và policy bridge với bảng của phụ lục, nên thêm hay bớt
một action, resource hay điều kiện làm test fail; kiểm event pattern, đích và dead-letter của rule, redrive và mã hoá của hai hàng đợi, policy hàng
đợi, alarm, tên ở prd, và mỗi biến một lần validation từ chối.

<!-- markdownlint-disable MD033 -->
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
| [aws_cloudwatch_event_rule.job_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.job_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_media_convert_queue.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/media_convert_queue) | resource |
| [aws_sqs_queue.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.events_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.mediaconvert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.mediaconvert_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.queue](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alarm\_topic\_arn | ARN of the SNS topic the alarm of the dead-letter queue notifies, when it fires and when it clears (output topic\_arn of the alarms module). | `string` | n/a | yes |
| env | Environment (stg, prd): every name of the module starts with svp-<env>. | `string` | n/a | yes |
| media\_bucket\_arn | ARN of the media bucket of the env (arn:aws:s3:::<name>): MediaConvert writes the output of a job under media/ with its role. | `string` | n/a | yes |
| uploads\_bucket\_arn | ARN of the uploads bucket of the env (arn:aws:s3:::<name>): MediaConvert reads the input of a job under uploads/ with its role. | `string` | n/a | yes |
| uploads\_kms\_key\_arn | ARN of the KMS key that encrypts the uploads bucket (output uploads\_kms\_key\_arn of the media module): MediaConvert decrypts the input of a job with its role. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| bridge\_policy\_json | IAM policy (JSON) of the bridge for MediaConvert, iam:PassRole and SQS; the env root joins it with media\_worker\_policy\_json of the media module in the Pod Identity role of media-worker. |
| events\_queue\_url | URL of the SQS queue svp-<env>-transcode-events of the job states: key transcodeEventsQueueUrl of the cluster values. |
| queue\_arn | ARN of the MediaConvert queue svp-<env>: key mediaconvertQueueArn of the cluster values. |
| role\_arn | ARN of the role svp-<env>-mediaconvert that jobs run with: key mediaconvertRoleArn of the cluster values. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
