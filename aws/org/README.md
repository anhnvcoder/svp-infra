# `aws/org`: tổ chức AWS (chạy ở management account)

Mọi thứ cấp tổ chức của lab, ở management account (account sandbox, profile `anhnv-sso`). Management account chỉ giữ phần quản trị và dùng
chung, không chạy workload. Cấu trúc account theo AWS Security Reference Architecture (SRA): log ở account `svp-log-archive`, dịch vụ phát
hiện do account `svp-security` quản, stg và prd chạy trong hai account thành viên riêng. Thiết kế và lý do:
[ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) (account, OU, policy, root tập
trung, permission set, liên hệ) và [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md)
(delegated admin, trail org).

## Tài nguyên

| Tài nguyên | File | Vì sao |
| --- | --- | --- |
| Tổ chức (`aws_organizations_organization`, có sẵn, import) | `organization.tf` | feature set `ALL`; policy type SCP, RCP, declarative EC2, tag policy; trusted access của mọi dịch vụ dưới đây (danh sách ở mục [Trusted access](#trusted-access)) |
| OU `Security`, `Workloads` (có sẵn), `Workloads/Prod`, `Workloads/NonProd` | `organization.tf` | `Security` giữ hai account bảo mật; prd có guardrail riêng ở OU `Prod` |
| Account `svp-stg` (OU `NonProd`), `svp-prd` (OU `Prod`) | `organization.tf` | mỗi env một account; địa chỉ `aws_organizations_account.member["stg"\|"prd"]`, đổi OU là MoveAccount tại chỗ |
| Account `svp-log-archive`, `svp-security` (OU `Security`) | `organization.tf` | Log Archive và Security Tooling của SRA; chỉ vào được từ management qua `OrganizationAccountAccessRole` |
| Policy của tổ chức (module [`org-policies`](../modules/org-policies/README.md)) | `organization.tf` | SCP, RCP, declarative EC2, tag policy gắn root; `svp-prod-guardrails` gắn OU `Prod` |
| Delegated admin `svp-security` | `delegated-admins.tf` | GuardDuty (`ap-southeast-1`, `us-east-1`), Security Hub CSPM (region nhà, cấu hình tập trung), Config (`config`, `config-multiaccountsetup`), IAM Access Analyzer; dịch vụ cấu hình ở [`aws/security`](../security/README.md) |
| Root tập trung (`aws_iam_organizations_features`) | `root-access.tf` | `RootCredentialsManagement`, `RootSessions`: account thành viên không giữ credential root; việc chỉ root làm đi qua `sts:AssumeRoot` từ management |
| Liên hệ `SECURITY` của năm account | `contacts.tf` | AWS báo sự cố bảo mật tới người phụ trách, không chỉ email root (CIS AWS Foundations v5.0.0, 1.2); giá trị ở biến `security_contact` |
| Permission set `SvpAdmin`, `SvpReadOnly`, `SvpLogReader` | `identity-center.tf` | xem mục [Permission set](#permission-set) |
| Trail org `svp-audit` | `audit-trail.tf` | management event đọc + ghi của mọi account, mọi region; data event S3 của bucket người dùng prd; log file validation; giao về bucket `svp-cloudtrail-<log>-ap-southeast-1` của `svp-log-archive`, mã hoá bằng key `alias/svp-log-archive` của account đó |
| Bucket `svp-cloudtrail-<mgmt>-<region>`, `svp-cloudtrail-access-<mgmt>-<region>`, KMS key `alias/svp-cloudtrail` | `audit-trail.tf` | nơi trail ghi trước khi có Log Archive; chỉ đọc, giữ tới khi Object Lock của version cuối hết hạn, rồi gỡ theo [Gỡ bucket trail cũ](#gỡ-bucket-trail-cũ) |

`<mgmt>`, `<log>`, `<prd>` là id của management, `svp-log-archive`, `svp-prd`; tên suy từ id lúc chạy, không account nào nằm trong file
commit. Mọi tài nguyên mang tag `Project=svp`, `ManagedBy=terraform`, `Stack=org` và sống giữa các buổi. Tổ chức, bốn account, KMS key và hai
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
| `config.amazonaws.com`, `config-multiaccountsetup.amazonaws.com` | aggregator và rule tổ chức của AWS Config |
| `access-analyzer.amazonaws.com` | analyzer `ORGANIZATION` |
| `account.amazonaws.com` | liên hệ `SECURITY` của account thành viên |
| `iam.amazonaws.com` | root tập trung |
| `ec2.amazonaws.com` | declarative policy EC2 `svp-ec2-baseline`: tài liệu EC2 đòi bật cùng policy type; console bật nó khi mở trang EC2 policy, nên thiếu ở đây thì apply kế tiếp tắt và plan không bao giờ sạch ([Getting started with EC2 policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies-ec2_getting-started.html), đọc 2026-11-12) |

### Permission set

| Permission set | Quyền | Phiên | Gán ở | Profile |
| --- | --- | --- | --- | --- |
| `SvpAdmin` | `AdministratorAccess` | 1 giờ | `svp-stg`, `svp-prd` | `anhnv-stg`, `anhnv-prd` |
| `SvpReadOnly` | `ViewOnlyAccess`, `SecurityAudit`, inline đọc log CloudWatch (`FilterLogEvents`, `GetLogEvents`, `StartQuery`, `StopQuery`, `GetQueryResults`) | 4 giờ | `svp-stg`, `svp-prd`, `svp-security` | `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro` |
| `SvpLogReader` | `ViewOnlyAccess`, inline `s3:ListBucket`, `s3:GetObject` trên bảy bucket của `aws/log-archive`, `kms:Decrypt` chỉ qua S3 của hai region và chỉ trên key có alias `alias/svp-log-archive` | 4 giờ | `svp-log-archive` | `anhnv-log-ro` |

- `SvpReadOnly` đọc cấu hình, trạng thái và finding của GuardDuty, Security Hub, Config, Access Analyzer; không đọc object S3, giá trị secret,
  dữ liệu bảng, không ghi gì (kể cả đổi trạng thái finding).
- Phiên `SvpAdmin` 1 giờ không cắt `apply` dài khi profile dùng khối `[sso-session …]`: SDK lấy lại credential role từ token SSO tới hết
  phiên cổng truy cập. Profile kiểu cũ (không `sso-session`) không tự làm mới.
- Permission set có sẵn của chính management không quản ở đây. Break-glass khi Identity Center hỏng: root của management (MFA phần cứng),
  quy trình ở runbook `docs/runbooks/break-glass.md`.

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

Organizations, policy, IAM Identity Center, delegated admin, root tập trung, liên hệ: miễn phí. Trail org: bản sao đầu tiên của management event
miễn phí, data event prd tính theo event. KMS key `alias/svp-cloudtrail` cũ tính tới khi gỡ. Phí của dịch vụ phát hiện mà delegated admin
bật ở mọi account, giá có nguồn và ước theo tháng: [ADR-0060 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục)
và [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#12-chi-phí-liên-tục).

Trail chỉ là bản sao miễn phí khi org không có trail management event nào khác. Kiểm trước apply:
`AWS_PROFILE=anhnv-sso aws cloudtrail describe-trails --region ap-southeast-1 --query 'trailList[].[Name,IsOrganizationTrail]' --output text`
không in dòng nào ngoài `svp-audit`.

## Apply

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Cần: `aws/bootstrap` đã apply (bucket state, file
`aws/backend.hcl`), Terraform 1.15, AWS CLI v2, `jq`, `aws sso login --profile anhnv-sso`. Mỗi lệnh `terraform` đọc biến của root (`import`,
`plan`, `apply`) đặt `TF_VAR_account_id` ngay trong lệnh từ `SVP_AWS_MGMT_ACCOUNT_ID`; mỗi lệnh AWS CLI ghi `--region`: `ap-southeast-1`
cho STS, S3, CloudTrail; `us-east-1` cho Organizations.

Root này áp hai lần trong thứ tự áp nền bảo mật org (runbook `docs/runbooks/org-security-setup.md`): bước
(2) chỉ tổ chức, OU, account (`-target`); bước (4) đủ, sau khi `aws/log-archive` (bước (3)) đã tạo bucket và key mà trail cần.

### Chuẩn bị

```sh
cd infra/aws/org
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của Account vừa đọc>
AWS_PROFILE=anhnv-sso terraform init -backend-config=../backend.hcl
```

`Account` phải là management account (account sandbox), `Arn` là role SSO của người học. Khác thì dừng.

Giá trị cá nhân ở `org.auto.tfvars` (git bỏ qua; lần đầu `cp org.auto.tfvars.example org.auto.tfvars`), đủ mọi biến của
`org.auto.tfvars.example`:

- `account_emails`: bốn khoá `stg`, `prd`, `log-archive`, `security`; mỗi account một email **chưa account AWS nào dùng**, kể cả account đã
  đóng hay đang `SUSPENDED` (AWS không cho dùng lại email của account đã đóng). Hai khoá `stg`, `prd` giữ đúng email đang có của hai account.
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

Tạo account mất vài phút mỗi account. Hai dòng cuối là hai id 12 số khác nhau; đặt chúng trong terminal của mọi bước sau (không ghi vào file
commit), như `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` (output `stg_account_id`, `prd_account_id`). Tiếp theo: bước (3), apply
[`aws/log-archive`](../log-archive/README.md).

### Bước (4): đủ root

Sau khi `aws/log-archive` đã apply (key `alias/svp-log-archive` và bucket `svp-cloudtrail-<log>-ap-southeast-1` có sẵn).

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=org.tfplan
```

Mong đợi `Plan: 38 to add, 2 to change, 3 to destroy`:

- thêm: delegated admin (2 GuardDuty, 1 Security Hub, 3 qua Organizations), `aws_iam_organizations_features.root_access`, 5 liên hệ
  `SECURITY`, permission set `SvpReadOnly`, `SvpLogReader` với policy và gán (11), policy mới của `module.org_policies` và đích của chúng (12);
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

Plan lần hai phải là `No changes.`; khác thì dán lại. Kiểm trail ghi được vào Log Archive:

```sh
AWS_PROFILE=anhnv-sso aws cloudtrail get-trail-status --name svp-audit --region ap-southeast-1 --query '[IsLogging,LatestDeliveryError,LatestDigestDeliveryError]'
```

Mong đợi `[true, null, null]`; một lỗi giao log hay digest (bucket policy, key policy của `aws/log-archive` từ chối) hiện ở hai ô sau: dán lại.

### Profile

Mỗi profile một lần (AI không sửa `~/.aws/config`); chọn SSO session đang dùng cho `anhnv-sso`, region mặc định `ap-southeast-1`, output
`json`:

| Profile | Account | Role |
| --- | --- | --- |
| `anhnv-stg`, `anhnv-prd` | `svp-stg`, `svp-prd` | `SvpAdmin` |
| `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro` | `svp-stg`, `svp-prd`, `svp-security` | `SvpReadOnly` |
| `anhnv-log-ro` | `svp-log-archive` | `SvpLogReader` |

```sh
aws configure sso --profile anhnv-security-ro
AWS_PROFILE=anhnv-security-ro aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
```

`Account` bằng id của account trong bảng, `Arn` dạng `assumed-role/AWSReservedSSO_<permission set>_…`. Lặp lại cho từng profile.

### Quota và xác minh CloudFront của account workload

Account mới có quota EC2 mặc định (5 cho mỗi mã dưới đây ở `ap-southeast-1`), chưa đủ cho buổi stg, prd. Đọc:

```sh
for p in anhnv-stg anhnv-prd; do
  for q in L-1216C47A L-34B43A08 L-0263D0A3; do
    printf '%s %s ' "$p" "$q"
    AWS_PROFILE=$p aws service-quotas get-service-quota --service-code ec2 --quota-code $q --region ap-southeast-1 --query Quota.Value --output text
  done
done
```

| Mã | Quota | stg cần | prd cần |
| --- | --- | --- | --- |
| `L-1216C47A` | vCPU on-demand (Standard) | ≥ 4 | ≥ 16 |
| `L-34B43A08` | vCPU Spot (Standard) | ≥ 10 | — |
| `L-0263D0A3` | Elastic IP | ≥ 1 | ≥ 3 |

Thiếu thì xin tăng (mỗi mã thiếu một lệnh; `PENDING` rồi `APPROVED`, account mới thường vài giờ tới 1–2 ngày):

```sh
AWS_PROFILE=<anhnv-stg|anhnv-prd> aws service-quotas request-service-quota-increase --service-code ec2 --quota-code <mã> \
  --desired-value <số> --region ap-southeast-1 --query 'RequestedQuota.[QuotaCode,DesiredValue,Status]' --output text
```

Mỗi yêu cầu tăng quota thành một case loại "Service limits" trong Support Center của account đó.

Account mới chưa dùng được CloudFront tới khi AWS xác minh. Trên console của từng account (AWS access portal, permission set `SvpAdmin`),
Support Center mở bằng ô chat với trợ lý AI: gõ yêu cầu, ví dụ `Please verify this new account so it can create Amazon CloudFront
distributions. It is a member account of organization <o-…> (management account <id>), used for a <staging|production> environment.`; trợ lý
không tự giải quyết được thì hiện form tạo case đã điền sẵn. Kiểm Case type "Account and billing", Service "Account Activation", Category
"Account Verification", Severity "General question", liên lạc qua Web, rồi Submit; dán số case. Buổi stg, prd chỉ bắt đầu khi quota đã duyệt
và case đã xong.

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

Chỉ khi lab kết thúc, sau khi mọi env và các root `aws/baseline`, `aws/security` đã gỡ theo README của chúng. `aws/log-archive` còn nguyên
ở bước 1 (bước này đọc alias `alias/svp-log-archive` qua provider `aws.log_archive`); muốn xoá log trước khi đóng account thì gỡ nó giữa bước 1
và bước 2 theo [mục gỡ của root đó](../log-archive/README.md#gỡ-có-chủ-đích). Các bước theo thứ tự; lệnh `terraform` chạy trong
`infra/aws/org` với `TF_VAR_account_id` như trên.

0. **Kiểm account của phiên gỡ** (trước lệnh ghi đầu tiên; lệnh `aws` không có `allowed_account_ids` như provider Terraform):

   ```sh
   AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
   ```

   `Account` phải bằng `$SVP_AWS_MGMT_ACCOUNT_ID` (management account), `Arn` là role SSO của người học. Khác thì dừng, không chạy bước nào dưới đây.

1. **Tắt trail, bỏ delegated admin, root tập trung, liên hệ, quyền SSO** (không tài nguyên nào trong số này có `prevent_destroy`; log đã ghi
   vẫn còn):

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_cloudtrail.audit \
     -target=aws_guardduty_organization_admin_account.security -target=aws_securityhub_organization_admin_account.security \
     -target=aws_organizations_delegated_administrator.security -target=aws_iam_organizations_features.root_access \
     -target=aws_account_alternate_contact.security \
     -target=aws_ssoadmin_account_assignment.learner -target=aws_ssoadmin_managed_policy_attachment.admin -target=aws_ssoadmin_permission_set.admin \
     -target=aws_ssoadmin_account_assignment.read_only -target=aws_ssoadmin_managed_policy_attachment.read_only \
     -target=aws_ssoadmin_permission_set_inline_policy.read_only -target=aws_ssoadmin_permission_set.read_only \
     -target=aws_ssoadmin_account_assignment.log_reader -target=aws_ssoadmin_managed_policy_attachment.log_reader \
     -target=aws_ssoadmin_permission_set_inline_policy.log_reader -target=aws_ssoadmin_permission_set.log_reader
   ```

2. **Đóng bốn account thành viên theo quy trình AWS, không bằng destroy** (`close_on_deletion = false`, `prevent_destroy`): destroy chỉ gỡ
   account khỏi tổ chức. Account đã đóng ở trạng thái đóng 90 ngày, vẫn thuộc tổ chức và OU, vẫn tính vào hạn mức số account; email của nó
   không dùng lại được; mỗi 30 ngày chỉ đóng được một phần số account thành viên, nên có thể phải chia làm nhiều đợt
   ([Organizations: close account](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_close.html), đọc 2026-11-05).
   Đóng `svp-log-archive` là bỏ log của org: chỉ làm khi không cần lịch sử audit nữa.

   ```sh
   for id in "$SVP_AWS_STG_ACCOUNT_ID" "$SVP_AWS_PRD_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID" "$SVP_AWS_LOG_ACCOUNT_ID"; do
     AWS_PROFILE=anhnv-sso aws organizations close-account --account-id "$id" --region us-east-1
   done
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_account.member aws_organizations_account.log_archive aws_organizations_account.security
   ```

3. **Gỡ bucket trail cũ** nếu còn: như mục [Gỡ bucket trail cũ](#gỡ-bucket-trail-cũ). Object Lock chưa hết hạn thì thêm
   `--bypass-governance-retention` vào `delete-objects` (cần `s3:BypassGovernanceRetention`, có ở `AdministratorAccess`), và thay PR bằng bản
   sửa local không commit: đổi `prevent_destroy = true` thành `false` ở `aws_s3_bucket.trail`, `aws_s3_bucket.access_logs`,
   `aws_kms_key.cloudtrail`, rồi:

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_s3_bucket.trail \
     -target=aws_s3_bucket.access_logs -target=aws_kms_alias.cloudtrail -target=aws_kms_key.cloudtrail
   ```

4. **Sau khi AWS gỡ hẳn bốn account đã đóng khỏi tổ chức** (hết 90 ngày;
   `AWS_PROFILE=anhnv-sso aws organizations list-accounts --region us-east-1 --query 'Accounts[].[Id,Name,Status]' --output text` không còn
   account `svp-*`): xoá policy và OU (OU còn account thì không xoá được).

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=module.org_policies \
     -target=aws_organizations_organizational_unit.prod -target=aws_organizations_organizational_unit.nonprod \
     -target=aws_organizations_organizational_unit.workloads -target=aws_organizations_organizational_unit.security
   ```

5. **Trả tổ chức về như trước root này** (tổ chức có trước, không xoá): bỏ khỏi state, tắt trusted access và policy type mà root này bật, xoá
   state của root.

   ```sh
   R="$(AWS_PROFILE=anhnv-sso terraform output -raw root_id)"
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_organization.this
   for p in access-analyzer account cloudtrail config-multiaccountsetup config ec2 guardduty iam malware-protection.guardduty securityhub; do
     AWS_PROFILE=anhnv-sso aws organizations disable-aws-service-access --service-principal "$p.amazonaws.com" --region us-east-1
   done
   for t in DECLARATIVE_POLICY_EC2 TAG_POLICY; do
     AWS_PROFILE=anhnv-sso aws organizations disable-policy-type --root-id "$R" --policy-type "$t" --region us-east-1
   done
   AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-tfstate-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1/aws/org/terraform.tfstate" --region ap-southeast-1
   rm -f org.auto.tfvars
   ```

   Hoàn tác sửa local của bước 3 (`git checkout -- audit-trail.tf`), xoá thư mục này bằng PR nếu không dùng nữa.
