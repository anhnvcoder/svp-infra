# `aws/security`: phát hiện và cảnh báo của cả tổ chức, chạy từ account `svp-security`

**Account** `svp-security` qua `OrganizationAccountAccessRole` (đọc thêm management, `svp-log-archive`) · **region** `ap-southeast-1`
và `us-east-1` · **profile** `anhnv-sso` · **state** bucket của `aws/bootstrap`, key `aws/security/terraform.tfstate`

Giải thích: [05. Bảo mật](../../docs/handbook/05-security.md).

## Dựng gì

Tên tài nguyên như code; "hai region" là `ap-southeast-1` và `us-east-1`. Cờ là `aws/paid-features.json`, đọc qua module
[`paid-features`](../modules/paid-features/README.md).

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `aws_guardduty_organization_configuration.this` | `svp-security`, hai region | `auto_enable_organization_members = "ALL"`: mọi account có sẵn, account mới, cả delegated admin |
| `aws_guardduty_organization_configuration_feature.this` | `svp-security`, hai region | Sáu protection plan `ALL`; ba additional configuration quản agent của Runtime Monitoring `NONE`, theo thứ tự API trả (provider so theo vị trí, lệch là thay thế) |
| `aws_guardduty_publishing_destination.this` | `svp-security`, hai region | Finding về bucket `svp-guardduty-<log>-ap-southeast-1` của Log Archive, mã hoá bằng key `alias/svp-log-archive` region nhà |
| `aws_guardduty_detector.management`, `aws_guardduty_member.management` | management, hai region | Đưa management vào tổ chức GuardDuty |
| `aws_securityhub_finding_aggregator.this` | `svp-security`, nhà | `SPECIFIED_REGIONS` gom `us-east-1`; region nhà thành home region của cấu hình tập trung |
| `aws_securityhub_organization_configuration.this` | `svp-security`, nhà | `CENTRAL`; `auto_enable = false`, `auto_enable_standards = "NONE"` vì configuration policy quyết định |
| Configuration policy `svp-security-standards`, association `root` | `svp-security`, nhà | Security Hub bật; FSBP v1.0.0, CIS v5.0.0; control mới tự bật; tắt `GuardDuty.7`, `.12`, `.13` |
| Configuration policy `svp-security-off`, association `off` | `svp-security`, nhà | Security Hub tắt ở từng account có cờ `security_hub` `off`; chỉ có khi ít nhất một account `off` |
| `aws_inspector2_organization_configuration.this` | `svp-security`, nhà | Account mới vào tổ chức tự bật quét ECR; EC2, Lambda, Lambda code, code repository tắt |
| `aws_inspector2_enabler.security` (khối `import`) | `svp-security`, nhà | `svp-security` chỉ quét ECR |
| `aws_inspector2_member_association.members`, `aws_inspector2_enabler.members` | `svp-security`, nhà | Quét ECR ở mỗi account thành viên `ACTIVE` khác `svp-security` có `inspector_ecr` khác `off` |
| Aggregator Config `svp-org`, role `svp-security-config-aggregator` | `svp-security`, nhà | Nguồn tổ chức, mọi region; managed policy `AWSConfigRoleForOrganizations` |
| Analyzer Access Analyzer `svp-org` | `svp-security`, hai region | Loại `ORGANIZATION`: truy cập từ ngoài tổ chức |
| Bus `svp-security-events` và policy | `svp-security`, nhà | Đích của rule `svp-security-*` ở mọi account; `events:PutEvents` chỉ cho principal có `aws:PrincipalOrgID` của tổ chức |
| Rule `svp-security-notify` (bus `svp-security-events`), `svp-security-findings` (bus mặc định) | `svp-security`, nhà | Gửi topic qua input transformer |
| Rule `svp-security-guardduty-findings`, role `svp-security-guardduty-forwarder` | `svp-security`, hai region | Finding GuardDuty mức ≥ 7 của account có `security_hub` `off`; chỉ có khi ít nhất một account `off` |
| Topic `svp-security-alarms`, key `alias/svp-security-alarms`, subscription email (module [`alarms`](../modules/alarms/README.md)) | `svp-security`, nhà | Publisher `events.amazonaws.com`; email `security_alert_email` của `security.auto.tfvars` |

Detector GuardDuty và Security Hub của chính `svp-security` không có tài nguyên ở đây: `aws/org` chỉ định delegated admin và bước đó tự
bật chúng; root đọc detector bằng data source. Recorder Config của từng account ở [`aws/baseline`](../baseline/README.md).

Hai cờ của root này, khi `off` ở một account:

| Cờ | Root làm gì |
| --- | --- |
| `inspector_ecr` | Bỏ account khỏi liên kết thành viên và enabler `members` của Inspector |
| `security_hub` | Gắn account vào policy `svp-security-off`; thêm account vào `detail.accountId` của rule `svp-security-guardduty-findings` |

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account.

- Áp lần đầu (sau `aws/log-archive` và `aws/org` đủ, trước `aws/baseline`):
  [`org-security-setup.md`, bước (5)](../../docs/runbooks/org-security-setup.md#bước-5-awssecurity).
- Đổi cờ `security_hub` hay `inspector_ecr`: runbook đổi cờ, mục thứ tự apply cờ
  <!-- link-chờ: docs/runbooks/paid-features.md -->.
- Tổ chức đã áp root này trước khi có Inspector: runbook dựng nền tảng, mục thêm Inspector
  <!-- link-chờ: docs/runbooks/platform-setup.md -->.
- Trong buổi: không chạy root này; finding của buổi đọc trên Security Hub của `svp-security` theo runbook buổi.
- Gỡ có chủ đích (lab kết thúc): runbook gỡ lab <!-- link-chờ: docs/runbooks/lab-teardown.md -->.

## Tham chiếu

- [05. Bảo mật](../../docs/handbook/05-security.md): vì sao delegated admin, luồng cảnh báo, trạng thái chờ (ghi chú thiết kế mà
  `main.tf`, `inspector.tf` trỏ tới).
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md): phát hiện, log, cảnh báo của
  tổ chức; event pattern và bảng giá ở phụ lục.
- [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §10: quét ECR bằng Inspector.
- [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md) §4, §5: cờ `security_hub`,
  `inspector_ecr`.
