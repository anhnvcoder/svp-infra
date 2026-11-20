# `aws/org`: tổ chức AWS, account, policy, Identity Center và trail tổ chức

**Account** management (đọc thêm `svp-log-archive` qua `OrganizationAccountAccessRole`) · **region** `us-east-1` (Organizations, IAM),
`ap-southeast-1` (trail, AWS Backup), `sso_region` (Identity Center) · **profile** `anhnv-sso` · **state** bucket của `aws/bootstrap`, key
`aws/org/terraform.tfstate`

Giải thích: [03. Tổ chức](../../docs/handbook/03-org.md).

## Dựng gì

`<mgmt>`, `<log>`, `<prd>` là id của management, `svp-log-archive`, `svp-prd`, tính lúc chạy. Mọi tài nguyên mang tag `Stack=org` và sống
suốt lab.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `aws_organizations_organization.this` (có sẵn, nhận quản bằng import) | management | Feature set `ALL`; trusted access và loại policy của tổ chức |
| OU `Security`, `Workloads`, `Workloads/Prod`, `Workloads/NonProd` | tổ chức | Nhóm account theo việc; OU `Prod` có guardrail riêng |
| `aws_organizations_account.member["stg"\|"prd"]`, `.log_archive`, `.security`, `.backup` | tổ chức | Năm account `svp-*`; đổi OU là `MoveAccount` tại chỗ; `prevent_destroy` |
| `module.org_policies` ([`org-policies`](../modules/org-policies/README.md)) | tổ chức | SCP, RCP, declarative EC2, tag policy, Backup policy và đích của chúng |
| Delegated admin `svp-security` (`delegated-admins.tf`) | tổ chức, GuardDuty hai region | GuardDuty, Security Hub CSPM, Inspector, Config, Access Analyzer |
| `aws_iam_service_linked_role.access_analyzer` | management | Analyzer tổ chức của `aws/security` cần nó ở management |
| `aws_iam_organizations_features.root_access` | tổ chức | `RootCredentialsManagement`, `RootSessions` |
| `aws_account_alternate_contact.security` | mọi account | Liên hệ `SECURITY` từ `security_contact` |
| Permission set `SvpAdmin`, `SvpReadOnly`, `SvpLogReader` và gán | management, `sso_region` | Quyền và account của từng permission set ở `identity-center.tf` |
| `aws_identitystore_group.platform` | management, `sso_region` | Nhóm `svp-platform-admins`, `svp-platform-viewers`, không thành viên trong code |
| `aws_backup_global_settings.this`, `aws_backup_region_settings.this` | management, `ap-southeast-1` | Cross-account backup bật; opt-in mọi loại tài nguyên |
| `aws_cloudtrail.audit` `svp-audit` | management, `ap-southeast-1` | Trail tổ chức, giao về `svp-cloudtrail-<log>-ap-southeast-1`, key `alias/svp-log-archive` |
| Bucket `svp-cloudtrail-<mgmt>-<region>`, `svp-cloudtrail-access-<mgmt>-<region>`, key `alias/svp-cloudtrail` | management, `ap-southeast-1` | Nơi trail ghi trước khi có Log Archive; chỉ đọc tới khi gỡ ([mục dưới](#gỡ-bucket-trail-cũ)) |

Output: id của tổ chức, root, bốn OU, năm account và hai nhóm nền tảng (`outputs.tf`). Id nhóm vào `<env>.auto.tfvars` của
`aws/accounts/<env>` qua `aws/scripts/tfvars.sh groups <env>`; repo public không giữ id.

## Giá trị ngoài repo

Điền `org.auto.tfvars` (git bỏ qua) từ `org.auto.tfvars.example` trước mọi `plan`: `aws/scripts/tfvars.sh example aws/org` chép file mẫu,
rồi sửa trong editor. Biến và ý nghĩa ở file mẫu; cách chọn giá trị ở
[`org-security-setup.md`, Điền giá trị lần đầu](../../docs/runbooks/org-security-setup.md#điền-giá-trị-lần-đầu).

- `account_emails`: mỗi account một email chưa account AWS nào dùng, kể cả account đã đóng; khoá `stg`, `prd` giữ đúng email đang có.
- `security_contact`: người nhận thông báo bảo mật của AWS.
- `sso_user_name`, `sso_region`: user của người học và region của instance Identity Center.

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account. Áp root này trước mọi root khác của tổ chức (trừ `aws/bootstrap`):

- Lần đầu, hai lượt: [`org-security-setup.md`, bước (2)](../../docs/runbooks/org-security-setup.md#bước-2-awsorg-chỉ-tổ-chức-ou-account)
  chỉ tổ chức, OU, account (`-target`); [bước (4)](../../docs/runbooks/org-security-setup.md#bước-4-awsorg-đủ) đủ, sau `aws/log-archive`.
- Code đổi (policy, permission set, trusted access): cùng lệnh `plan`, `apply` của bước (4).
- Ghi profile SSO sau khi có permission set:
  [bước (4), 4c](../../docs/runbooks/org-security-setup.md#4c-profile-của-account-thành-viên).
- Gán người vào nhóm nền tảng, quota và xác minh CloudFront của account workload (sàn quota ở `quota_table` của
  `aws/scripts/preflight.sh`): [runbook dựng nền tảng](../../docs/runbooks/platform-setup.md).
- Thêm `svp-backup` và Backup policy vào tổ chức dựng trước: [runbook backup](../../docs/runbooks/backup-setup.md).
- Trong buổi: không chạy root này.
- Đường vào khi Identity Center hỏng, tháo SCP tạm: [`break-glass.md`](../../docs/runbooks/break-glass.md).

## Gỡ có chủ đích

Root này không bao giờ `terraform destroy` cả khối: tổ chức, năm account, key và hai bucket cũ có `prevent_destroy`. Tổ chức không bao giờ
bị xoá, chỉ trả về như trước root này. Account không đóng bằng destroy (`close_on_deletion = false`): đóng theo quy trình của AWS, một
bước riêng, chờ 90 ngày và không đảo ngược. Thứ tự và lệnh:
[`lab-teardown.md`, `aws/org`](../../docs/runbooks/lab-teardown.md#awsorg).

## Gỡ bucket trail cũ

Bucket `svp-cloudtrail-<mgmt>-ap-southeast-1`, bucket access log của nó và key `alias/svp-cloudtrail` giữ log trước khi trail đổi đích
sang Log Archive. Gỡ khi Object Lock của version cuối hết hạn (365 ngày sau lần ghi cuối), không bỏ qua retention:
[`lab-teardown.md`, Gỡ bucket trail cũ](../../docs/runbooks/lab-teardown.md#gỡ-bucket-trail-cũ).

## Tham chiếu

- [03. Tổ chức](../../docs/handbook/03-org.md): vì sao từng policy, trusted access, delegated admin, trail; import, service-linked role,
  phiên SSO ở mục Đọc sâu (ghi chú thiết kế mà các file `.tf` trỏ tới).
- [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md): account, OU, policy, root tập
  trung, permission set, liên hệ.
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md): delegated admin, trail tổ chức.
- [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md): account backup, Backup policy, opt-in.
