# Rule và đường cảnh báo bảo mật

Trang này tra các rule EventBridge đưa sự kiện bảo mật và finding tới email: rule `svp-security-*` ở mọi account (module
[`security-baseline`](../../aws/modules/security-baseline/README.md), root `aws/baseline`), rule và topic của `svp-security` (root
[`aws/security`](../../aws/security/README.md)). Vì sao có đường này và kịch bản đi qua nó: [05. Bảo mật](../handbook/05-security.md).
Event pattern đủ ở [ADR-0060 phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md).

## Rule chuyển sự kiện

Rule `svp-security-*` ở mỗi account chọn sự kiện CloudTrail trên bus mặc định, rồi chuyển sang bus `svp-security-events` của
`svp-security` bằng role `svp-security-forwarder`: EventBridge cần role để đặt sự kiện vào bus của account khác. Bus chỉ nhận
`events:PutEvents` từ principal có `aws:PrincipalOrgID` của tổ chức. Rule `svp-security-notify` của bus đó khớp mọi sự kiện, vì rule nguồn
đã chọn.

| Rule (module `security-baseline`) | Bắt gì | Region | Có ở |
| --- | --- | --- | --- |
| `svp-security-root-signin` | Root đăng nhập console | `root_signin_regions` (management: `us-east-1`, `us-east-2`, `us-west-2`) | mọi account |
| `svp-security-trail` | Trail bị dừng, xoá, đổi, thành công hay bị từ chối | nhà, `us-east-1` | mọi account |
| `svp-security-detection` | GuardDuty, Security Hub, Config, Access Analyzer bị tắt hay đổi | nhà, `us-east-1` | mọi account |
| `svp-security-alert-rules` | Rule `svp-security-*` bị đổi, tắt, xoá | nhà, `us-east-1` | mọi account |
| `svp-security-denied-iam`, `-denied-detection`, `-denied-storage` | Lệnh bị SCP `svp-protect-baseline`, `svp-deny-iam-users` từ chối | `denied-iam`: `us-east-1`; còn lại: nhà, `us-east-1` | mọi account |
| `svp-security-root-session`, `svp-security-org` | Phiên `AssumeRoot`; đổi Organizations, policy, root tập trung | `root-session`: nhà, `us-east-1`; `org`: `us-east-1` | `organization_events` (management) |
| `svp-security-admin-iam`, `svp-security-admin-kms-s3` | Đổi IAM, KMS key, policy hay mã hoá của bucket thành công | `admin-iam`: `us-east-1`; `admin-kms-s3`: nhà, `us-east-1` | `admin_events` (account không chạy workload: `local.accounts` của `aws/baseline/main.tf`) |
| `svp-security-admin-sso` | Đổi permission set, gán account của Identity Center | region của Identity Center | account giữ Identity Center |

- Nhóm `denied-*` có ở mọi account, kể cả stg, prd: lệnh bị guardrail từ chối luôn là thứ cần biết. `errorCode` khớp tiền tố
  `AccessDenied` (phủ cả `AccessDeniedException` của API JSON); `denied-storage` khớp thêm `Client.UnauthorizedOperation` của EC2, kể cả
  `--dry-run`.
- `svp-security-root-signin`: CloudTrail ghi đăng nhập root ở `us-east-1`, `us-east-2` hay `us-west-2`
  ([sự kiện đăng nhập][signin-events]); account thành viên chỉ cần `us-east-1` vì SCP chặn region khác.
- `svp-security-root-session` nhận cả sự kiện chỉ đọc (`ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`): `AssumeRoot` có thể là sự kiện
  chỉ đọc, mà rule `ENABLED` chỉ nhận sự kiện ghi
  ([sự kiện quản lý của CloudTrail](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail-management.html)).
- `admin_events` chỉ bật ở account ít đổi IAM, KMS, S3: mỗi buổi stg, prd tạo và xoá hàng chục role, key, bucket.
- Ba rule `svp-security-admin-*` bỏ phiên Terraform `OrganizationAccountAccessRole/svp-terraform` của account (`anything-but`); sự kiện
  không có `userIdentity.arn` (lời gọi của dịch vụ AWS) vẫn khớp qua nhánh `exists: false` của `$or`
  ([toán tử của event pattern](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-pattern-operators.html)). Thay đổi của
  pipeline IaC đã được đọc ở plan; cảnh báo nhắm thay đổi đi ngoài nó. Mọi root qua role đặt `session_name = "svp-terraform"`.
- Bộ lọc tên phiên không mở thêm quyền: ai assume được `OrganizationAccountAccessRole` cũng đặt được tên đó, nhưng role này đã là principal
  duy nhất mà `svp-protect-baseline` cho sửa baseline. Management không có role đó: `aws/bootstrap`, `aws/org`, `github` và provider `mgmt`
  của `aws/baseline` chạy bằng phiên SSO của `anhnv-sso`, mà event không tách được Terraform khỏi người (`userAgent` do client tự đặt),
  nên apply ở management vẫn gửi email `admin-*`.
- Các rule khác không lọc phiên: dừng trail, đổi rule cảnh báo, tắt dịch vụ phát hiện, root, Organizations, lệnh bị guardrail từ chối là
  việc không ai được làm ngoài lúc apply đã đọc plan.
- Tên rule và role bắt đầu `svp-security-` vì SCP `svp-protect-baseline` chặn mọi principal trừ `OrganizationAccountAccessRole` sửa
  rule, role có tiền tố đó. Đổi tên thì đổi cả SCP. Mỗi pattern tối đa 2 048 ký tự
  ([EventBridge quotas](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-quota.html)); test của module kiểm cỡ.

## Rule của `svp-security`

| Rule | Bus, region | Khớp | Gửi |
| --- | --- | --- | --- |
| `svp-security-notify` | `svp-security-events`, nhà | mọi sự kiện trên bus | topic, dòng `svp-security: <detail-type> <eventName> …` |
| `svp-security-findings` | mặc định, nhà (region aggregator) | `Security Hub Findings - Imported` với `Severity.Label` `HIGH`, `CRITICAL`, `RecordState` `ACTIVE`, `Workflow.Status` `NEW`, `ProductName` `GuardDuty` hay `IAM Access Analyzer` | topic, dòng `svp-security finding <severity> <product>: …` |
| `svp-security-guardduty-findings` | mặc định, hai region; chỉ có khi ít nhất một account có `security_hub` `off` | `GuardDuty Finding` với `detail.accountId` là id các account `off`, `detail.severity` ≥ 7 | nhà: topic; `us-east-1`: bus `svp-security-events` qua role `svp-security-guardduty-forwarder` |

- GuardDuty gửi finding vào Security Hub CSPM của account sinh finding, rồi aggregator gom về `svp-security`. Account có `security_hub`
  `off` không có đường đó; delegated admin GuardDuty nhận sự kiện `GuardDuty Finding` của mọi member trên bus mặc định của mình ở từng
  region, nên `svp-security-guardduty-findings` giữ email cho chúng. Account `always` không khớp rule này, nên không có thư trùng.
- Analyzer tổ chức gửi finding vào Security Hub của account giữ nó, tức `svp-security` (module `paid-features` cấm `security_hub` `off`
  ở đây), dù tài nguyên ở account nào: `AwsAccountId` là `svp-security`, account tài nguyên ở `ProductFields.ResourceOwnerAccount`
  ([Security Hub: tích hợp dịch vụ AWS](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-internal-providers.html)).
  Thư của finding Access Analyzer vì vậy ghi account `svp-security`; account tài nguyên đọc trên Security Hub.
- EventBridge không nhắm topic ở region khác. Ở `us-east-1` rule chuyển sang bus `svp-security-events` bằng role riêng (tên
  `svp-security-forwarder` đã là role của `aws/baseline` trong account này), và `svp-security-notify` gửi nó với dòng chung
  `svp-security: GuardDuty Finding …`; finding đầy đủ đọc trên GuardDuty.
- Finding của control FSBP, CIS và finding Inspector không tới email: Security Hub gửi lại sự kiện mỗi lần đánh giá lại, email sẽ lặp.
- Input transformer viết một dòng: tên sự kiện hay tiêu đề finding, account, region, principal, `errorCode` và URL runbook
  [`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md).
- Topic `svp-security-alarms` cho `events.amazonaws.com` `sns:Publish` khi `aws:SourceAccount` là `svp-security` và `aws:SourceArn` khớp
  `arn:aws:events:ap-southeast-1:<sec>:rule/*`. Key của topic cho nó `kms:Decrypt`, `kms:GenerateDataKey*` không điều kiện nguồn: SNS không
  hỗ trợ điều kiện đó trong key policy khi EventBridge gửi vào topic mã hoá (module [`alarms`](../../aws/modules/alarms/README.md)).

[signin-events]: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-aws-console-sign-in-events.html
