# `aws/org`: tổ chức AWS (chạy ở management account)

Mọi thứ cấp tổ chức của lab, ở management account (account sandbox, profile `anhnv-sso`). Management account chỉ giữ phần quản trị và dùng
chung, không chạy workload. Cấu trúc account theo AWS Security Reference Architecture (SRA): log ở account `svp-log-archive`, dịch vụ phát
hiện do account `svp-security` quản, bản copy backup ở account `svp-backup`, stg và prd chạy trong hai account thành viên riêng. Thiết kế
và lý do:
[ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) (account, OU, policy, root tập
trung, permission set, liên hệ), [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md)
(delegated admin, trail org), [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §10
(delegated admin của Inspector), [ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) và
[ADR-0065](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0065-argocd-eks-capability.md) (nhóm nền tảng),
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) (account backup, Backup policy, opt-in).

## Tài nguyên

| Tài nguyên | File | Vì sao |
| --- | --- | --- |
| Tổ chức (`aws_organizations_organization`, có sẵn, import) | `organization.tf` | feature set `ALL`; policy type SCP, RCP, declarative EC2, tag policy, Backup policy; trusted access của mọi dịch vụ dưới đây (danh sách ở mục [Trusted access](#trusted-access)) |
| OU `Security`, `Workloads` (có sẵn), `Workloads/Prod`, `Workloads/NonProd` | `organization.tf` | `Security` giữ hai account bảo mật và account backup; prd có guardrail riêng ở OU `Prod` |
| Account `svp-stg` (OU `NonProd`), `svp-prd` (OU `Prod`) | `organization.tf` | mỗi env một account; địa chỉ `aws_organizations_account.member["stg"\|"prd"]`, đổi OU là MoveAccount tại chỗ |
| Account `svp-log-archive`, `svp-security` (OU `Security`) | `organization.tf` | Log Archive và Security Tooling của SRA; chỉ vào được từ management qua `OrganizationAccountAccessRole` |
| Account `svp-backup` (OU `Security`) | `organization.tf` | bản copy của recovery point stg, prd, ngoài tầm admin của account env (Central Backup account của SRA); chỉ vào được từ management qua `OrganizationAccountAccessRole`, vault và key ở `aws/backup` |
| Policy của tổ chức (module [`org-policies`](../modules/org-policies/README.md)) | `organization.tf` | SCP, RCP, declarative EC2, tag policy gắn root; `svp-prod-guardrails`, Backup policy `svp-backup-prd` gắn OU `Prod`; `svp-backup-stg` gắn OU `NonProd` |
| Cross-account backup (`aws_backup_global_settings`) | `backup.tf` | `isCrossAccountBackupEnabled`: chỉ management bật được, có hiệu lực cho mọi account thành viên; account env copy recovery point sang vault của `svp-backup`. `isMpaEnabled`, `isDelegatedAdministratorEnabled` ghi rõ `false` |
| Opt-in loại tài nguyên của management (`aws_backup_region_settings`, `ap-southeast-1`) | `backup.tf` | plan của Backup policy chạy theo opt-in của management, không theo opt-in của account thành viên; xem mục [Backup](#backup) |
| Delegated admin `svp-security` | `delegated-admins.tf` | GuardDuty (`ap-southeast-1`, `us-east-1`), Security Hub CSPM (region nhà, cấu hình tập trung), Amazon Inspector (`ap-southeast-1`, nơi có registry ECR), Config (`config`, `config-multiaccountsetup`), IAM Access Analyzer; dịch vụ cấu hình ở [`aws/security`](../security/README.md) |
| Root tập trung (`aws_iam_organizations_features`) | `root-access.tf` | `RootCredentialsManagement`, `RootSessions`: account thành viên không giữ credential root; việc chỉ root làm đi qua `sts:AssumeRoot` từ management |
| Liên hệ `SECURITY` của sáu account | `contacts.tf` | AWS báo sự cố bảo mật tới người phụ trách, không chỉ email root (CIS AWS Foundations v5.0.0, 1.2); giá trị ở biến `security_contact` |
| Permission set `SvpAdmin`, `SvpReadOnly`, `SvpLogReader` | `identity-center.tf` | xem mục [Permission set](#permission-set) |
| Nhóm Identity Center `svp-platform-admins`, `svp-platform-viewers` | `identity-center.tf` | xem mục [Nhóm nền tảng](#nhóm-nền-tảng) |
| Trail org `svp-audit` | `audit-trail.tf` | management event đọc + ghi của mọi account, mọi region; data event S3 của bucket người dùng prd; log file validation; giao về bucket `svp-cloudtrail-<log>-ap-southeast-1` của `svp-log-archive`, mã hoá bằng key `alias/svp-log-archive` của account đó |
| Bucket `svp-cloudtrail-<mgmt>-<region>`, `svp-cloudtrail-access-<mgmt>-<region>`, KMS key `alias/svp-cloudtrail` | `audit-trail.tf` | nơi trail ghi trước khi có Log Archive; chỉ đọc, giữ tới khi Object Lock của version cuối hết hạn, rồi gỡ theo [Gỡ bucket trail cũ](#gỡ-bucket-trail-cũ) |

`<mgmt>`, `<log>`, `<prd>` là id của management, `svp-log-archive`, `svp-prd`; tên suy từ id lúc chạy, không account nào nằm trong file
commit. Mọi tài nguyên mang tag `Project=svp`, `ManagedBy=terraform`, `Stack=org` và sống giữa các buổi. Tổ chức, năm account, KMS key và hai
bucket cũ có `prevent_destroy`: root này không bao giờ `terraform destroy` cả khối, gỡ theo mục [Gỡ có chủ đích](#gỡ-có-chủ-đích).

### Trusted access

`aws_service_access_principals` là toàn bộ danh sách: principal không có ở đây bị apply kế tiếp tắt, kể cả principal mà dịch vụ tự bật khi
đăng ký delegated admin. Vì thế danh sách gồm cả `malware-protection.guardduty.amazonaws.com`: GuardDuty dùng nó cho service-linked role
quét malware EC2 ở account thành viên
([GuardDuty: malware scan nhiều account](https://docs.aws.amazon.com/guardduty/latest/ug/configure-malware-protection-guardduty-initiated-multi-account.html),
đọc 2026-11-12).

| Principal | Dùng cho |
| --- | --- |
| `sso.amazonaws.com` | IAM Identity Center (có trước root này) |
| `cloudtrail.amazonaws.com` | trail org |
| `guardduty.amazonaws.com`, `malware-protection.guardduty.amazonaws.com` | GuardDuty và Malware Protection for EC2 |
| `securityhub.amazonaws.com` | Security Hub CSPM |
| `inspector2.amazonaws.com` | Amazon Inspector quét image ECR của các account có cờ `inspector_ecr` khác `off` trong `aws/paid-features.json` |
| `config.amazonaws.com`, `config-multiaccountsetup.amazonaws.com` | aggregator và rule tổ chức của AWS Config |
| `access-analyzer.amazonaws.com` | analyzer `ORGANIZATION` |
| `account.amazonaws.com` | liên hệ `SECURITY` của account thành viên |
| `iam.amazonaws.com` | root tập trung |
| `backup.amazonaws.com` | Backup policy `svp-backup-prd`, `svp-backup-stg` (đòi trusted access cùng policy type `BACKUP_POLICY`) |
| `ec2.amazonaws.com` | declarative policy EC2 `svp-ec2-baseline`: tài liệu EC2 đòi bật cùng policy type; console bật nó khi mở trang EC2 policy, nên thiếu ở đây thì apply kế tiếp tắt và plan không bao giờ sạch ([Getting started with EC2 policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies-ec2_getting-started.html), đọc 2026-11-12) |

### Permission set

| Permission set | Quyền | Phiên | Gán ở | Profile |
| --- | --- | --- | --- | --- |
| `SvpAdmin` | `AdministratorAccess` | 1 giờ | `svp-stg`, `svp-prd` | `anhnv-stg`, `anhnv-prd` |
| `SvpReadOnly` | `ViewOnlyAccess`, `SecurityAudit`, inline đọc log CloudWatch (`FilterLogEvents`, `GetLogEvents`, `StartQuery`, `StopQuery`, `GetQueryResults`) | 4 giờ | `svp-stg`, `svp-prd`, `svp-security`, `svp-backup` | `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro`, `anhnv-backup-ro` |
| `SvpLogReader` | `ViewOnlyAccess`, inline `s3:ListBucket`, `s3:GetObject` trên bảy bucket của `aws/log-archive`, `kms:Decrypt` chỉ qua S3 của hai region và chỉ trên key có alias `alias/svp-log-archive` | 4 giờ | `svp-log-archive` | `anhnv-log-ro` |

- `SvpReadOnly` đọc cấu hình, trạng thái và finding của GuardDuty, Security Hub, Config, Access Analyzer; không đọc object S3, giá trị secret,
  dữ liệu bảng, không ghi gì (kể cả đổi trạng thái finding). Ở `svp-backup` nó đọc đủ vault, lock, vault access policy, recovery point, job,
  plan và cài đặt của AWS Backup mà không cần inline thêm (bảng action ở
  [phụ lục ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#3-account-organizations-opt-in) §3).
- Phiên `SvpAdmin` 1 giờ không cắt `apply` dài khi profile dùng khối `[sso-session …]`: SDK lấy lại credential role từ token SSO tới hết
  phiên cổng truy cập. Profile kiểu cũ (không `sso-session`) không tự làm mới.
- Permission set có sẵn của chính management không quản ở đây. Break-glass khi Identity Center hỏng: root của management (MFA phần cứng),
  quy trình ở runbook `docs/runbooks/break-glass.md`.

### Nhóm nền tảng

Hai nhóm của Identity Center mà công cụ nền tảng của stg, prd cấp quyền theo nhóm: `svp-platform-admins` (vai trò `ADMIN` của Amazon Managed
Grafana) và `svp-platform-viewers` (`VIEWER` của Grafana). ADR-0065 dùng lại hai nhóm này cho vai trò `ADMIN`, `VIEWER` của Argo CD chạy bằng EKS
Capability.

- Code chỉ tạo nhóm, không thành viên: ai thuộc nhóm là quyết định về người, không phải cấu hình, nên người học gán lúc
  chạy bằng script, không bằng Terraform hay console.
- Id nhóm là output `platform_admin_group_id`, `platform_viewer_group_id`. Chúng nằm trong biến cùng tên của `<env>.auto.tfvars` của
  `aws/accounts/<env>` (git bỏ qua): repo public không giữ id nhóm.

```sh
../scripts/platform-member.sh add admins <user-name>        # or viewers; remove undoes it
../scripts/platform-member.sh count admins
../scripts/tfvars.sh groups stg                             # and prd: the two ids into <env>.auto.tfvars
```

`<user-name>` là tên user ở góc phải trên của AWS access portal. `add` in `ok    <user-name> added to
svp-platform-admins`, hay `skip  … is already a member` khi đã thuộc nhóm (chạy lại an toàn); `FAIL  no user <user-name>
in Identity Center` là tên sai hoặc user chưa tạo ([Profile gốc](#profile-gốc-anhnv-sso), bước 3). `count` in `ok
svp-platform-admins has N member(s)`, chỉ số lượng, không id; mong ít nhất `1` ở nhóm admin. `tfvars.sh groups` ghi hai
biến, không in id: `ok    aws/accounts/stg/stg.auto.tfvars: platform_admin_group_id, platform_viewer_group_id from
aws/org written (N lines, mode 600)`.

### Backup

Phần cấp tổ chức của backup: account `svp-backup`, trusted access `backup.amazonaws.com`, policy type `BACKUP_POLICY`, cross-account backup và
opt-in của management. Backup policy (plan, lịch, retention, selection, copy) ở module [`org-policies`](../modules/org-policies/README.md); vault
copy và key của nó ở `aws/backup`; vault env, role `svp-<env>-backup` và opt-in của từng account env ở
`aws/accounts/<env>`.

- **Không delegated administrator cho AWS Backup:** management giữ Backup policy như SCP, RCP. `svp-backup` chỉ là đích copy.
- **Opt-in ghi cả map:** `aws_backup_region_settings` ghi đè mọi loại tài nguyên, nên `backup.tf` liệt kê đủ mọi loại AWS Backup hỗ trợ ở
  `ap-southeast-1`, khoá viết như `describe-region-settings` trả, tất cả `true` như AWS đặt cho account bắt đầu dùng AWS Backup. Danh sách và
  nguồn ở [phụ lục ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#3-account-organizations-opt-in)
  §3; AWS thêm loại theo thời gian, nên trước khi apply đối chiếu khoá với output `describe-region-settings` của management (mục
  [Thêm account backup và Backup policy](#thêm-account-backup-và-backup-policy-vào-tổ-chức-đã-áp)).
- **Thứ tự với các root khác:** Backup policy có hiệu lực ngay khi gắn, nhưng job chỉ chạy được khi account env đã có vault `svp-<env>` và role
  `svp-<env>-backup`, và copy chỉ tới được khi `svp-backup` đã có vault `svp-<env>-copy`. Thứ tự áp `aws/org`, `aws/baseline`, `aws/security`,
  `aws/backup`, `aws/accounts/<env>` ở runbook `docs/runbooks/backup-setup.md`.

## Trail org

Trail `svp-audit` vẫn ở management (owner của trail org); log của nó nằm ở account khác, nơi admin của account workload không xoá được
(admin của management vào được qua `OrganizationAccountAccessRole`). Bucket, Object Lock, retention, key và policy ở
[`aws/log-archive`](../log-archive/README.md).

- **Key theo ARN `key/<id>`**: data source `aws_kms_alias` đọc `alias/svp-log-archive` qua provider `aws.log_archive` (assume
  `OrganizationAccountAccessRole` của `svp-log-archive`, id lấy từ state, không biến mới). CloudTrail trả `KmsKeyId` dạng `key/<id>`; ARN
  alias ở đây làm plan không bao giờ sạch.
- **Advanced event selector**: `management` (management event đọc và ghi); `prd-uploads` (data event S3 đọc và ghi của
  `svp-prd-uploads-<prd>-ap-southeast-1`); `prd-media-writes` (chỉ ghi của `svp-prd-media-<prd>-ap-southeast-1`: lượt đọc là người xem qua
  CloudFront). Bucket stg không có data event: dữ liệu người dùng thật chỉ ở prd.
- **Tên trail không đổi**: policy bucket và key của `aws/log-archive` chỉ cho `aws:SourceArn` của `svp-audit`.
- CIS AWS Foundations Benchmark v5.0.0: trail đa region (3.1), log file validation (3.2), server access logging của bucket trail (3.4, ở
  `aws/log-archive`), mã hoá KMS (3.5), xoay khoá (3.6); data event S3 ghi và đọc (3.8, 3.9) chỉ cho bucket người dùng của prd.

## Phí giữ

Organizations, policy (kể cả Backup policy), IAM Identity Center, delegated admin, root tập trung, liên hệ, cài đặt AWS Backup: miễn phí.
Trail org: bản sao đầu tiên của management event miễn phí, data event prd tính theo event. KMS key `alias/svp-cloudtrail` cũ tính tới
khi gỡ. Phí của dịch vụ phát hiện mà delegated admin bật ở mọi account, giá có nguồn và ước theo tháng: [ADR-0060 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục)
và [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#12-chi-phí-liên-tục).
Bản copy, key của vault và baseline của `svp-backup`:
[ADR-0067 §13](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#13-chi-phí).

Trail chỉ là bản sao miễn phí khi org không có trail management event nào khác. Kiểm trước apply:
`AWS_PROFILE=anhnv-sso aws cloudtrail describe-trails --region ap-southeast-1 --query 'trailList[].[Name,IsOrganizationTrail]' --output text`
không in dòng nào ngoài `svp-audit`.

## Apply

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Cần: `aws/bootstrap` đã apply (bucket state, file
`aws/backend.hcl`), Terraform 1.15, AWS CLI v2, `jq`, profile `anhnv-sso` ([Profile gốc](#profile-gốc-anhnv-sso)) và
`aws sso login --profile anhnv-sso`. Mỗi lệnh `terraform` đọc biến của root (`import`,
`plan`, `apply`) đặt `TF_VAR_account_id` ngay trong lệnh từ `SVP_AWS_MGMT_ACCOUNT_ID`; mỗi lệnh AWS CLI ghi `--region`: `ap-southeast-1`
cho STS, S3, CloudTrail; `us-east-1` cho Organizations.

Root này áp hai lần trong thứ tự áp nền bảo mật org (runbook `docs/runbooks/org-security-setup.md`): bước
(2) chỉ tổ chức, OU, account (`-target`); bước (4) đủ, sau khi `aws/log-archive` (bước (3)) đã tạo bucket và key mà trail cần.

### Chuẩn bị

```sh
cd infra/aws/org
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của Account vừa đọc>
../scripts/tfvars.sh init
../scripts/tfvars.sh example aws/org
```

`Account` phải là management account (account sandbox), `Arn` là role SSO của người học. Khác thì dừng. `SVP_AWS_MGMT_ACCOUNT_ID` gõ tay vì
nó là giá trị mà `check_account` của mọi script đối chiếu với account thật của `anhnv-sso`: đọc từ chính profile đó thì phép đối chiếu vô
nghĩa. `tfvars.sh init` chạy `terraform init -reconfigure` ở mọi root của management ([`aws/bootstrap`, mục
5](../bootstrap/README.md#5-áp-thay-đổi-khi-state-đã-ở-bucket)); `tfvars.sh example aws/org` chép `org.auto.tfvars.example` thành
`org.auto.tfvars` (mode 600) khi file chưa có, không ghi đè, và liệt kê mỗi giá trị còn `<…>` một dòng `note`.

Giá trị cá nhân ở `org.auto.tfvars` (git bỏ qua; giữ tay, sửa trong editor), đủ mọi biến của `org.auto.tfvars.example`:

- `account_emails`: năm khoá `stg`, `prd`, `log-archive`, `security`, `backup`; mỗi account một email **chưa account AWS nào dùng**, kể cả
  account đã đóng hay đang `SUSPENDED` (AWS không cho dùng lại email của account đã đóng). Hai khoá `stg`, `prd` giữ đúng email đang có của hai account.
- `security_contact`: tên, chức danh, email, số điện thoại của người nhận thông báo bảo mật từ AWS.
- `sso_user_name` (tên user ở góc phải trên của AWS access portal), `sso_region` (dòng `sso_region` của profile `anhnv-sso` trong
  `~/.aws/config`, trong khối `[sso-session …]` nếu có).

Chỉ khi state chưa có tổ chức (root dựng lần đầu): import tổ chức có sẵn trước plan, không thì plan đòi **tạo** tổ chức mới và apply lỗi vì
account đã thuộc một tổ chức.

```sh
AWS_PROFILE=anhnv-sso aws organizations describe-organization --region us-east-1 --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform import aws_organizations_organization.this <o-… vừa đọc>
```

`MasterAccountId` phải bằng `SVP_AWS_MGMT_ACCOUNT_ID`, `FeatureSet` là `ALL`.

### Bước (2): tổ chức, OU, account

Tạo account là bước gần như không đảo ngược (đóng account chờ 90 ngày, email không dùng lại được): plan trước, đọc, rồi mới apply.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=org.tfplan \
  -target=aws_organizations_organization.this \
  -target=aws_organizations_organizational_unit.security \
  -target=aws_organizations_organizational_unit.workloads \
  -target=aws_organizations_organizational_unit.prod \
  -target=aws_organizations_organizational_unit.nonprod \
  -target=aws_organizations_account.member \
  -target=aws_organizations_account.log_archive \
  -target=aws_organizations_account.security
```

Mong đợi `Plan: 5 to add, 3 to change, 0 to destroy`:

- thêm: OU `Security`, `Prod`, `NonProd`; account `svp-log-archive`, `svp-security` (đọc `name`, `parent_id` là OU `Security`);
- đổi tại chỗ (`~`): tổ chức (chỉ **thêm** vào `aws_service_access_principals` và `enabled_policy_types`, không dòng `-` nào trong hai danh
  sách, `feature_set` không đổi); `member["stg"]`, `member["prd"]` (chỉ `parent_id`, sang `NonProd`, `Prod`).

Dừng (không apply, dán plan lại) nếu có `destroy`, `-/+` hay `must be replaced` ở tổ chức hay account nào, nếu `email` của `stg`, `prd` đổi,
hay nếu plan nhắc trail, data source hay provider `log_archive` (lệnh `-target` này không gồm chúng). Terraform in cảnh báo `Resource
targeting is in effect`: đúng như mong đợi.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply org.tfplan
rm org.tfplan
export SVP_AWS_LOG_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw log_archive_account_id)"
export SVP_AWS_SECURITY_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw security_account_id)"
printf '%s\n' "$SVP_AWS_LOG_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID"
```

Tạo account mất vài phút mỗi account. Hai dòng cuối là hai id 12 số khác nhau; đặt chúng trong terminal của mọi bước sau
(không ghi vào file commit), như `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID`. Lần dựng đầu dùng `terraform
output` ở đây vì `aws/scripts/accounts.sh` đòi đủ năm account thành viên, kể cả `svp-backup` mà tổ chức chỉ có sau bước (4): từ đó
trở đi một lệnh `eval "$(aws/scripts/accounts.sh)"` đặt cả năm biến. Tiếp theo: bước (3), apply
[`aws/log-archive`](../log-archive/README.md).

### Bước (4): đủ root

Sau khi `aws/log-archive` đã apply (key `alias/svp-log-archive` và bucket `svp-cloudtrail-<log>-ap-southeast-1` có sẵn).

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=org.tfplan
```

Mong đợi `Plan: 50 to add, 2 to change, 3 to destroy`:

- thêm: account `svp-backup` (`parent_id` là OU `Security`), delegated admin (2 GuardDuty, 1 Security Hub, 1 Inspector, 3 qua
  Organizations), `aws_iam_organizations_features.root_access`, 6 liên hệ `SECURITY`, permission set `SvpReadOnly`, `SvpLogReader` với
  policy và gán (12, trong đó gán `read_only["backup"]`), hai nhóm nền tảng, `aws_backup_global_settings.this`,
  `aws_backup_region_settings.this`, policy mới của `module.org_policies` và đích của chúng (16, trong đó `backup-prd`, `backup-stg`);
- đổi tại chỗ: `aws_ssoadmin_permission_set.admin` (chỉ `session_duration` `PT4H` → `PT1H`); `aws_cloudtrail.audit` (`s3_bucket_name` sang
  bucket của `svp-log-archive`, `kms_key_id` dạng `arn:aws:kms:ap-southeast-1:<log>:key/<id>`, `event_selector` thay bằng ba
  `advanced_event_selector`);
- thay (`-/+`, đếm trong cả add lẫn destroy): đúng ba `module.org_policies.aws_organizations_policy_attachment.this` của
  `deny-leave-organization`, `protect-cloudtrail`, `deny-other-regions` (`target_id` đổi từ OU `Workloads` sang root). Ba SCP này rời đích cũ
  vài giây trước khi gắn đích mới; policy của chúng không đổi.

Dừng (không apply, dán plan lại) nếu tổ chức, account, KMS key hay bucket cũ có `destroy` hay `-/+`, nếu có `destroy` ngoài ba đích trên,
hay nếu `kms_key_id` của trail là ARN alias.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply org.tfplan
rm org.tfplan
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan
```

Plan lần hai phải là `No changes.`; khác thì dán lại. Tổ chức giờ có đủ năm account thành viên: `eval "$(../scripts/accounts.sh)"`
đặt cả năm biến (lệnh của bước 3 mục
[Thêm account backup](#thêm-account-backup-và-backup-policy-vào-tổ-chức-đã-áp)). Kiểm trail ghi được vào Log Archive:

```sh
AWS_PROFILE=anhnv-sso aws cloudtrail get-trail-status --name svp-audit --region ap-southeast-1 --query '[IsLogging,LatestDeliveryError,LatestDigestDeliveryError]'
```

Mong đợi `[true, null, null]`; một lỗi giao log hay digest (bucket policy, key policy của `aws/log-archive` từ chối) hiện ở hai ô sau: dán lại.

### Thêm Inspector và nhóm nền tảng vào tổ chức đã áp

Khi bước (4) đã chạy trước khi root có Inspector và nhóm nền tảng, apply root này trước [`aws/security`](../security/README.md) (root đó cấu
hình Inspector từ `svp-security`, cần delegated admin có sẵn), cùng lệnh `plan`, `apply` của bước (4).

Mong đợi `Plan: 3 to add, 1 to change, 0 to destroy`:

- thêm: `aws_inspector2_delegated_admin_account.security`, `aws_identitystore_group.platform["admins"]`,
  `aws_identitystore_group.platform["viewers"]`;
- đổi tại chỗ (`~`): chỉ tổ chức, chỉ một dòng `+ "inspector2.amazonaws.com"` trong `aws_service_access_principals`, không dòng `-` nào.

Dừng (không apply, dán plan lại) nếu có `destroy`, `-/+` hay thay đổi nào khác. Sau apply, Inspector tự bật mọi loại quét ở `svp-security`;
`aws/security` thu về chỉ ECR. Plan lần hai phải là `No changes.`; rồi ghi id nhóm theo mục [Nhóm nền tảng](#nhóm-nền-tảng).

### Thêm account backup và Backup policy vào tổ chức đã áp

Khi tổ chức đã áp trước khi root có account `svp-backup` và Backup policy. Root này đi đầu trong thứ tự của runbook
`docs/runbooks/backup-setup.md`.

1. **Thêm khoá `backup` vào `org.auto.tfvars`** (git bỏ qua) trước mọi `plan`: một email **chưa account AWS nào dùng**, như mục
   [Chuẩn bị](#chuẩn-bị). Thiếu khoá thì `plan` dừng ở validation của `account_emails`.
2. **Đối chiếu opt-in:** đọc opt-in hiện tại của management.

   ```sh
   AWS_PROFILE=anhnv-sso aws backup describe-region-settings --region ap-southeast-1 --query 'ResourceTypeOptInPreference' --output json
   ```

   Mỗi khoá API trả phải có trong `resource_type_opt_in_preference` của `backup.tf`, và ngược lại. Lệch thì dừng, dán output lại: danh sách
   sửa bằng PR trước khi apply.
3. **Tạo account** (gần như không đảo ngược, như bước (2)): plan riêng account, đọc, rồi apply.

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=org.tfplan -target=aws_organizations_account.backup
   ```

   Mong đợi `Plan: 1 to add, 1 to change, 0 to destroy`: thêm `aws_organizations_account.backup` (`name` `svp-backup`, `parent_id` là OU
   `Security`); đổi tại chỗ tổ chức, chỉ hai dòng `+ "backup.amazonaws.com"` trong `aws_service_access_principals` và `+ "BACKUP_POLICY"` trong
   `enabled_policy_types`, không dòng `-` nào. Khác thì dừng, dán plan lại.

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply org.tfplan
   rm org.tfplan
   eval "$(../scripts/accounts.sh)"
   ```

   `accounts.sh` đọc tổ chức bằng `anhnv-sso` và đặt cả năm biến account của thành viên (không ghi vào file commit), mỗi
   biến một dòng `ok    SVP_AWS_<…>_ACCOUNT_ID: account svp-<tên>, ACTIVE` trên stderr; `SVP_AWS_BACKUP_ACCOUNT_ID` là
   id mới, khác bốn account đã có. Account `PENDING_CLOSURE` hay thiếu thì `FAIL  account svp-<tên> is <trạng thái>, not
   ACTIVE` và `eval` không đặt biến nào.
4. **Phần còn lại:** cùng lệnh `plan`, `apply` của bước (4).

   Mong đợi `Plan: 8 to add, 1 to change, 0 to destroy`:

   - thêm: `aws_account_alternate_contact.security["backup"]`, `aws_ssoadmin_account_assignment.read_only["backup"]`,
     `aws_backup_global_settings.this`, `aws_backup_region_settings.this`, `module.org_policies.aws_organizations_policy.this["backup-prd"]`,
     `["backup-stg"]` và hai `aws_organizations_policy_attachment` của chúng (đích OU `Prod`, `NonProd`);
   - đổi tại chỗ: `module.org_policies.aws_organizations_policy.this["tags"]` (thêm khoá `Backup`, giá trị `backup` của `Stack`).

   Dừng (không apply, dán plan lại) nếu có `destroy`, `-/+` hay thay đổi nào khác. Sau apply, plan lần hai phải là `No changes.`; một diff ở
   `global_settings` (AWS trả khoá ngoài ba khoá của `backup.tf`) thì dán lại. Kiểm cài đặt cross-account:

   ```sh
   AWS_PROFILE=anhnv-sso aws backup describe-global-settings --region ap-southeast-1 --query 'GlobalSettings' --output json
   ```

   Mong đợi đúng ba khoá: `isCrossAccountBackupEnabled` là `true`, `isDelegatedAdministratorEnabled` và `isMpaEnabled` là `false`.
   Tiếp theo: tạo profile `anhnv-backup-ro` (mục [Profile](#profile)), rồi các root còn lại theo runbook.

### Profile

Tám profile SSO của lab (bảng dưới) dùng chung một `sso_session`: một lần `aws sso login` cho tất cả. Chỉ `anhnv-sso` làm tay, một lần cho
mỗi lab; bảy profile còn lại do script ghi.

| Profile | Account | Role |
| --- | --- | --- |
| `anhnv-sso` | management | permission set do người học tạo (tên tuỳ ý, ví dụ quyền quản trị) |
| `anhnv-stg`, `anhnv-prd` | `svp-stg`, `svp-prd` | `SvpAdmin` |
| `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro`, `anhnv-backup-ro` | `svp-stg`, `svp-prd`, `svp-security`, `svp-backup` | `SvpReadOnly` |
| `anhnv-log-ro` | `svp-log-archive` | `SvpLogReader` |

#### Profile gốc `anhnv-sso`

Giữ tay vì đây là gốc của tin cậy: Identity Center, user và thiết bị MFA của người học chỉ tồn tại khi người học tự tạo
và xác nhận bằng chính mình (MFA không có API, và mọi script đều đối chiếu với profile này). Làm một lần, ở management
account:

1. **Bật IAM Identity Center**
   ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/get-set-up-for-idc.html), đọc 2026-11-15): đăng
   nhập management account, mở console IAM Identity Center, **Enable**, chọn *organization instance* (instance của
   account thành viên chỉ gán ứng dụng trong account đó, không gán permission set cho cả tổ chức). Region của instance
   chọn một lần: đổi region phải xoá instance rồi tạo lại, nên chọn region sẽ dùng lâu dài. Region đó là `sso_region` ở
   `org.auto.tfvars` và ở khối `[sso-session]` dưới.
2. **Bật MFA** ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/mfa-configure.html), đọc 2026-11-15):
   **Settings** → tab **Authentication** → **Multi-factor authentication** → **Configure**; giữ *Require them to
   register an MFA device at sign in*. Chấp nhận FIDO2 (khoá bảo mật, passkey) và ứng dụng xác thực TOTP. Tránh lựa chọn
   email one-time password: trang tài liệu nói nó không đạt MFA chuẩn.
3. **Tạo user của người học** ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/addusers.html), đọc
   2026-11-15): **Users** → **Add user**; tên user dài 1–100 ký tự và không đổi được sau này, đó là `sso_user_name` của
   `org.auto.tfvars`. Mặc định AWS gửi thư mời "Invitation to join AWS IAM Identity Center" hạn 7 ngày; hết hạn thì
   **Reset password** để gửi lại. Mở thư, đặt mật khẩu, đăng ký MFA ở lần đăng nhập đầu.
4. **Cấp quyền vào management account**: **AWS accounts** → chọn management account → **Assign users or groups** → user
   vừa tạo, gán một permission set có quyền quản trị (tạo ở **Permission sets** nếu chưa có). Code không quản permission
   set này (mục [Permission set](#permission-set)); từ `SvpAdmin` trở đi `aws/org` quản.
5. **Ghi profile** (một lần, có `sso-session`): `aws configure sso --profile anhnv-sso`, trả lời tên session (ví dụ
   `anhnv`), *SSO start URL* (trang access portal, dạng `https://d-0000000000.awsapps.com/start`), *SSO region* (bước
   1), scope mặc định `sso:account:access`; trình duyệt mở để xác nhận; chọn account management, role ở bước 4; *CLI
   default client Region* `ap-southeast-1`, output `json`
   ([nguồn](https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html), đọc 2026-11-15). Kết quả
   trong `~/.aws/config`: `[sso-session <tên>]` (`sso_start_url`, `sso_region`, `sso_registration_scopes`) và `[profile
   anhnv-sso]` (`sso_session`, `sso_account_id`, `sso_role_name`). Dùng kiểu cũ không có `sso_session` thì
   `sso-profiles.sh write` từ chối, vì kiểu đó không tự làm mới token.
6. **Đăng nhập và đối chiếu**: `AWS_PROFILE=anhnv-sso aws sso login --region us-east-1`, rồi `AWS_PROFILE=anhnv-sso aws
   sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text`; `Account` là
   `SVP_AWS_MGMT_ACCOUNT_ID`, `Arn` có `AWSReservedSSO_`.

Bẫy: phiên SSO hết hạn thì mọi lệnh báo `Token has expired` hay `The SSO session associated with this profile has expired`: chạy lại
`aws sso login --profile anhnv-sso`, không cần login từng profile cùng `sso_session`.

#### Bảy profile còn lại

Sau khi `aws/org` đã cấp permission set (bước (4)) và `eval "$(aws/scripts/accounts.sh)"` đã đặt các biến account (mục
[Bước (2)](#bước-2-tổ-chức-ou-account) và [Thêm account backup](#thêm-account-backup-và-backup-policy-vào-tổ-chức-đã-áp)):

```sh
../scripts/sso-profiles.sh write
../scripts/sso-profiles.sh check
```

`write` thêm hay thay khối `[profile …]` của từng profile trong bảng (lấy `sso_session` của `anhnv-sso`, account từ biến
của nó, role theo bảng trên, region `ap-southeast-1`, output `json`), không đổi dòng nào khác của `~/.aws/config` và
không gọi mạng. Mỗi profile một dòng `ok    profile <tên>: added|up to date …`; profile mà biến account chưa đặt thì
`skip  profile <tên>: SVP_AWS_<…>_ACCOUNT_ID is not exported` (đặt biến rồi chạy lại: chạy lại an toàn). `FAIL  no
[profile anhnv-sso] in …` hay `has no sso_session` là gốc chưa đúng: làm lại bước 5 ở trên. `check` đăng nhập từng
profile bằng `sts get-caller-identity` và so account với biến của dòng đó: `ok    account <12 số> of <tên>, arn:…` mỗi
profile (Arn dạng `assumed-role/AWSReservedSSO_<permission set>_…`); profile lỗi thì `FAIL  profile <tên> is account …`
hay lỗi của AWS CLI, `check` vẫn đọc profile sau rồi kết thúc `FAIL  N profile(s) failed, each named above`. Dán mọi
dòng `FAIL`. Danh sách profile, biến và permission set nằm ở `aws/scripts/profiles.sh`; bảng trên là phần thiết kế.
`--print` in các khối sẽ ghi, không ghi gì.

### Quota và xác minh CloudFront của account workload

Account mới có quota EC2 mặc định (5 cho mỗi mã ở `ap-southeast-1`), chưa đủ cho buổi stg, prd. Đọc (cần `SVP_AWS_STG_ACCOUNT_ID`,
`SVP_AWS_PRD_ACCOUNT_ID` từ `accounts.sh` và profile `anhnv-<env>`):

```sh
../scripts/preflight.sh quotas stg
../scripts/preflight.sh quotas prd
```

Mỗi quota một dòng: `ok    <mã> <tên>: <giá trị> (min|max <cần>)` khi đủ; `FAIL  <mã> <tên>: <giá trị>, needs min <cần>:
run preflight.sh quotas
<env> request` khi thiếu. Các mã quota và mức cần (EC2 vCPU on-demand và Spot, Elastic IP, chu kỳ luật AMP) nằm ở `quota_table` của
`aws/scripts/preflight.sh`, một nguồn cho mọi runbook; mức vCPU Spot, on-demand của prd còn cộng `limits.cpu` của NodePool đọc từ
`origin/main` của `svp-gitops`. Thiếu thì xin tăng (chỉ lệnh này ghi):

```sh
../scripts/preflight.sh quotas stg request
```

Mỗi quota thiếu gửi một yêu cầu và in `note  <mã> <tên>: <giá trị>, asked for <cần> (<id> <PENDING|CASE_OPENED>): wait for APPROVED`;
quota đã có yêu cầu mở thì `note  … a request is already open … not sent again`, nên chạy lại không gửi hai lần. Chờ `APPROVED` (account mới
thường vài giờ tới 1–2 ngày) rồi chạy lại bản không `request` cho tới khi mọi dòng `ok`. Mỗi yêu cầu tăng quota thành một case loại "Service
limits" trong Support Center của account đó. Lệnh `request` bị Service Quotas từ chối thì làm bằng case trên console (mục "Bước (8)" của
[`platform-setup.md`](../../docs/runbooks/platform-setup.md#bước-8-quota-chu-kỳ-luật-amp)).

Account mới chưa dùng được CloudFront tới khi AWS xác minh. Giữ tay vì xác minh là case ở Support Center, và AWS Support
API chỉ dùng được với gói Support trả phí (Business Support trở lên;
[nguồn](https://docs.aws.amazon.com/awssupport/latest/user/about-support-api.html), đọc 2026-11-15) mà lab không mua.
Trên console của từng account (AWS access portal, permission set `SvpAdmin`), Support Center mở bằng ô chat với trợ lý
AI: gõ yêu cầu, ví dụ `Please verify this new account so it can create Amazon CloudFront distributions. It is a member
account of organization <o-…> (management account <id>), used for a <staging|production> environment.`; trợ lý không tự
giải quyết được thì hiện form tạo case đã điền sẵn. Kiểm Case type "Account and billing", Service "Account Activation",
Category "Account Verification", Severity "General question", liên lạc qua Web, rồi Submit; dán số case. Buổi stg, prd
chỉ bắt đầu khi quota đã duyệt và case đã xong.

## OU ngoài Terraform

OU `Production`, `Development` dưới root chứa hai account demo đã đóng (`SUSPENDED`); root này không quản chúng. Khi AWS gỡ hẳn hai account
khỏi org (hết 90 ngày sau khi đóng), xoá hai OU rỗng:

```sh
AWS_PROFILE=anhnv-sso aws organizations list-organizational-units-for-parent --parent-id "$(AWS_PROFILE=anhnv-sso terraform output -raw root_id)" \
  --region us-east-1 --query 'OrganizationalUnits[].[Id,Name]' --output text
AWS_PROFILE=anhnv-sso aws organizations list-accounts-for-parent --parent-id <ou-… của Production> --region us-east-1 --query 'Accounts[].Id' --output text
AWS_PROFILE=anhnv-sso aws organizations delete-organizational-unit --organizational-unit-id <ou-… của Production> --region us-east-1
```

Lệnh thứ hai không in id nào thì mới xoá; lặp lại với `Development`.

## Gỡ bucket trail cũ

Bucket `svp-cloudtrail-<mgmt>-ap-southeast-1`, bucket access log của nó và key `alias/svp-cloudtrail` giữ log trước khi trail đổi đích. Gỡ khi
Object Lock của version cuối hết hạn (365 ngày sau lần ghi cuối, tức sau bước (4)), không cần bỏ qua retention. Kiểm hạn:

```sh
B="svp-cloudtrail-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1"
AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$B" --region ap-southeast-1 \
  --query 'max_by(Versions, &LastModified).[Key,VersionId]' --output text
AWS_PROFILE=anhnv-sso aws s3api get-object-retention --bucket "$B" --key <Key> --version-id <VersionId> --region ap-southeast-1
```

`RetainUntilDate` phải ở quá khứ; chưa tới thì chờ. Xoá mọi version và delete marker (lặp tới khi `versions.json` rỗng), rồi rỗng bucket
access log:

```sh
AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$B" --region ap-southeast-1 --output json \
  --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' > versions.json
jq -c '.Objects | _nwise(1000) | {Objects: ., Quiet: true}' versions.json | while read -r batch; do
  AWS_PROFILE=anhnv-sso aws s3api delete-objects --bucket "$B" --region ap-southeast-1 --delete "$batch"
done
rm versions.json
AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-cloudtrail-access-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1" --recursive --region ap-southeast-1
```

Rồi một PR bỏ khỏi `audit-trail.tf` key `aws_kms_key.cloudtrail`, alias, hai bucket cùng mọi tài nguyên và policy document của chúng, cùng
`local.trail_arn`, `log_retention_days`, `log_cold_after_days` khi không còn ai dùng. Plan sau PR chỉ có `destroy` của các tài nguyên đó; apply
đưa key vào trạng thái chờ xoá 30 ngày (huỷ được trong thời gian đó).

## Gỡ có chủ đích

Giữ tay hoàn toàn (không có script): đóng account chờ 90 ngày và không đảo ngược, `destroy` có `-target` theo thứ tự, và xoá dữ liệu không
khôi phục được; mỗi bước là quyết định của người học sau khi đọc lệnh.

Chỉ khi lab kết thúc, sau khi mọi env và các root `aws/backup`, `aws/baseline`, `aws/security` đã gỡ theo README của chúng. `aws/log-archive`
còn nguyên ở bước 1 (bước này đọc alias `alias/svp-log-archive` qua provider `aws.log_archive`); muốn xoá log trước khi đóng account thì gỡ nó giữa bước 1
và bước 2 theo [mục gỡ của root đó](../log-archive/README.md#gỡ-có-chủ-đích). Các bước theo thứ tự; lệnh `terraform` chạy trong
`infra/aws/org` với `TF_VAR_account_id` như trên.

0. **Kiểm account của phiên gỡ** (trước lệnh ghi đầu tiên; lệnh `aws` không có `allowed_account_ids` như provider Terraform):

   ```sh
   AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
   ```

   `Account` phải bằng `$SVP_AWS_MGMT_ACCOUNT_ID` (management account), `Arn` là role SSO của người học. Khác thì dừng, không chạy bước nào dưới đây.

1. **Tắt trail, bỏ delegated admin, root tập trung, liên hệ, quyền SSO, nhóm nền tảng** (không tài nguyên nào trong số này có
   `prevent_destroy`; log đã ghi vẫn còn):

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_cloudtrail.audit \
     -target=aws_guardduty_organization_admin_account.security -target=aws_securityhub_organization_admin_account.security \
     -target=aws_inspector2_delegated_admin_account.security \
     -target=aws_organizations_delegated_administrator.security -target=aws_iam_organizations_features.root_access \
     -target=aws_account_alternate_contact.security \
     -target=aws_ssoadmin_account_assignment.learner -target=aws_ssoadmin_managed_policy_attachment.admin -target=aws_ssoadmin_permission_set.admin \
     -target=aws_ssoadmin_account_assignment.read_only -target=aws_ssoadmin_managed_policy_attachment.read_only \
     -target=aws_ssoadmin_permission_set_inline_policy.read_only -target=aws_ssoadmin_permission_set.read_only \
     -target=aws_ssoadmin_account_assignment.log_reader -target=aws_ssoadmin_managed_policy_attachment.log_reader \
     -target=aws_ssoadmin_permission_set_inline_policy.log_reader -target=aws_ssoadmin_permission_set.log_reader \
     -target=aws_identitystore_group.platform
   ```

2. **Đóng năm account thành viên theo quy trình AWS, không bằng destroy** (`close_on_deletion = false`, `prevent_destroy`): destroy chỉ gỡ
   account khỏi tổ chức. Account đã đóng ở trạng thái đóng 90 ngày, vẫn thuộc tổ chức và OU, vẫn tính vào hạn mức số account; email của nó
   không dùng lại được; mỗi 30 ngày chỉ đóng được một phần số account thành viên, nên có thể phải chia làm nhiều đợt
   ([Organizations: close account](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_close.html), đọc 2026-11-05).
   Đóng `svp-log-archive` là bỏ log của org: chỉ làm khi không cần lịch sử audit nữa.

   ```sh
   for id in "$SVP_AWS_STG_ACCOUNT_ID" "$SVP_AWS_PRD_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID" "$SVP_AWS_LOG_ACCOUNT_ID" \
     "$SVP_AWS_BACKUP_ACCOUNT_ID"; do
     AWS_PROFILE=anhnv-sso aws organizations close-account --account-id "$id" --region us-east-1
   done
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_account.member aws_organizations_account.log_archive \
     aws_organizations_account.security aws_organizations_account.backup
   ```

3. **Gỡ bucket trail cũ** nếu còn: như mục [Gỡ bucket trail cũ](#gỡ-bucket-trail-cũ). Object Lock chưa hết hạn thì thêm
   `--bypass-governance-retention` vào `delete-objects` (cần `s3:BypassGovernanceRetention`, có ở `AdministratorAccess`), và thay PR bằng bản
   sửa local không commit: đổi `prevent_destroy = true` thành `false` ở `aws_s3_bucket.trail`, `aws_s3_bucket.access_logs`,
   `aws_kms_key.cloudtrail`, rồi:

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_s3_bucket.trail \
     -target=aws_s3_bucket.access_logs -target=aws_kms_alias.cloudtrail -target=aws_kms_key.cloudtrail
   ```

4. **Sau khi AWS gỡ hẳn năm account đã đóng khỏi tổ chức** (hết 90 ngày;
   `AWS_PROFILE=anhnv-sso aws organizations list-accounts --region us-east-1 --query 'Accounts[].[Id,Name,Status]' --output text` không còn
   account `svp-*`): xoá policy và OU (OU còn account thì không xoá được).

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=module.org_policies \
     -target=aws_organizations_organizational_unit.prod -target=aws_organizations_organizational_unit.nonprod \
     -target=aws_organizations_organizational_unit.workloads -target=aws_organizations_organizational_unit.security
   ```

5. **Trả tổ chức về như trước root này** (tổ chức có trước, không xoá): bỏ khỏi state, tắt cross-account backup, trusted access và policy
   type mà root này bật, xoá state của root. Opt-in của management giữ nguyên: mọi loại `true` là giá trị AWS đặt cho account dùng AWS Backup.

   ```sh
   R="$(AWS_PROFILE=anhnv-sso terraform output -raw root_id)"
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_organization.this aws_backup_global_settings.this aws_backup_region_settings.this
   AWS_PROFILE=anhnv-sso aws backup update-global-settings --global-settings isCrossAccountBackupEnabled=false --region ap-southeast-1
   for p in access-analyzer account backup cloudtrail config-multiaccountsetup config ec2 guardduty iam inspector2 malware-protection.guardduty \
     securityhub; do
     AWS_PROFILE=anhnv-sso aws organizations disable-aws-service-access --service-principal "$p.amazonaws.com" --region us-east-1
   done
   for t in BACKUP_POLICY DECLARATIVE_POLICY_EC2 TAG_POLICY; do
     AWS_PROFILE=anhnv-sso aws organizations disable-policy-type --root-id "$R" --policy-type "$t" --region us-east-1
   done
   AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-tfstate-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1/aws/org/terraform.tfstate" --region ap-southeast-1
   rm -f org.auto.tfvars
   ```

   Hoàn tác sửa local của bước 3 (`git checkout -- audit-trail.tf`), xoá thư mục này bằng PR nếu không dùng nữa.
