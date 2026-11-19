# Runbook: áp nền bảo mật cấp org lần đầu

Áp lần đầu nền bảo mật của tổ chức AWS theo AWS Security Reference Architecture: hai account mới `svp-log-archive`, `svp-security`, OU
`Security`, `Workloads/Prod`, `Workloads/NonProd`, policy của tổ chức, root tập trung, permission set chỉ đọc, dịch vụ phát hiện (cả Amazon
Inspector quét ECR của account thành viên), baseline của mọi account của tổ chức (bảng "Áp gì ở account nào" của
[README `aws/baseline`](../../aws/baseline/README.md#áp-gì-ở-account-nào)); rồi kiểm dịch vụ bật, guardrail chặn đúng và cảnh báo tới email.
Security Hub CSPM, AWS Config recorder và Inspector ECR của từng account theo cờ của
[`aws/paid-features.json`](../../aws/paid-features.json) ([ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md));
mong đợi dưới đây tính theo file của repo: mọi account trừ `svp-security` (delegated admin) tắt Security Hub và Config,
stg và prd tắt thêm Inspector ECR
([ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §1). Đổi
cờ sau khi đã áp: [`paid-features.md`](paid-features.md).
Thiết kế: [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) (account, OU, policy, root
tập trung, permission set, baseline), [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md)
(phát hiện, log, cảnh báo, chi phí) và [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md)
§10 (Inspector). Tổ chức đã áp trước khi có Inspector: thêm nó theo [`platform-setup.md`](platform-setup.md#thứ-tự-áp-lần-đầu), bước (1), (2).
Bước (4) tạo luôn account `svp-backup` và Backup policy của tổ chức; phần còn lại của backup (root `aws/backup`, vault, restore) làm sau
runbook này, theo [`backup-setup.md`](backup-setup.md#thứ-tự-áp-lần-đầu).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output dán lại. Lệnh `plan`, `apply` và
mong đợi của từng plan nằm ở README của root; runbook này giữ thứ tự, điểm dừng và phần kiểm sau áp. Mọi lệnh chạy từ gốc repo này (`infra/`)
trừ chỗ ghi `cd`. Bước nào đỏ thì dừng ở đó, dán output, không đi tiếp.

## Thứ tự áp lần đầu

```mermaid
flowchart TD
  B1["(1) aws/bootstrap: key state, Cost Anomaly Detection, tag phân bổ; init -reconfigure mọi root"] --> B2
  B2["(2) aws/org -target: OU, hai account mới, chuyển OU của stg, prd"] -->|đặt SVP_AWS_LOG_ACCOUNT_ID, SVP_AWS_SECURITY_ACCOUNT_ID| B3
  B3["(3) aws/log-archive: bucket log, hai key alias/svp-log-archive"] --> B4
  B4["(4) aws/org đủ: account svp-backup, policy, root tập trung, permission set, trail"] -->|tạo bốn profile chỉ đọc| B5
  B5["(5) aws/security: dịch vụ phát hiện, Inspector ECR theo cờ, bus, SNS; xác nhận email"] --> B6
  B6["(6) aws/baseline: BPA, EBS mặc định, Config recorder theo cờ, rule svp-security-*, CMK EBS"] --> B7
  B7["(7) kiểm sau áp: dịch vụ, root tập trung, trail, phép thử guardrail, cảnh báo thử, chi phí"]
```

- **(1)** `aws/bootstrap`; [README mục 5](../../aws/bootstrap/README.md#5-áp-thay-đổi-khi-state-đã-ở-bucket). Dán lại:
  dòng `Plan:`, `Apply complete!`, `No changes.` của plan cuối.
- **(2)** `aws/org` (`-target`): OU, hai account `svp-log-archive` và `svp-security`, chuyển OU của stg, prd;
  [README, Bước (2)](../../aws/org/README.md#bước-2-tổ-chức-ou-account). Dán lại: **plan đủ** (điểm dừng),
  `Apply complete!`, hai id đã che bớt.
- **(3)** `aws/log-archive`; [README, Apply lần đầu](../../aws/log-archive/README.md#apply-lần-đầu). Dán lại: dòng
  `Plan:`, `Apply complete!`, số bucket và key của output.
- **(4)** `aws/org` (đủ): account `svp-backup`, trusted access, delegated admin (cả Inspector), service-linked role
  Access Analyzer ở management (analyzer tổ chức của bước (5) cần nó), policy (cả Backup policy), root tập trung,
  permission set, nhóm nền tảng, liên hệ, trail đổi đích;
  [README, Bước (4)](../../aws/org/README.md#bước-4-đủ-root). Dán lại: **plan đủ** (điểm dừng), `Apply complete!`,
  `No changes.`, `get-trail-status`.
- **(5)** `aws/security`: GuardDuty, Security Hub CSPM, Config aggregator, Access Analyzer, Inspector ECR theo cờ,
  bus, SNS; xác nhận email; [README, Apply](../../aws/security/README.md#apply-bước-5-của-thứ-tự-áp-lần-đầu). Dán lại:
  dòng `Plan:`, `Apply complete!`, output mục "Kiểm nhanh".
- **(6)** `aws/baseline`; [README, Apply lần đầu](../../aws/baseline/README.md#apply-lần-đầu). Dán lại: output mục "Kiểm
  cái đã có", dòng `Plan:`, `Apply complete!`.
- **(7)** —; [Bước (7)](#bước-7-kiểm-sau-áp). Dán lại: output từng mục.

## Trước khi bắt đầu

1. **Code trên `main`**: `git switch main && git pull --ff-only` trong bản clone này. Các root `aws/log-archive`, `aws/security`,
   `aws/baseline` và thay đổi của `aws/org`, `aws/bootstrap` đã merge.
2. **Giá trị ngoài repo** (không commit, mỗi file tạo từ `.example` cùng thư mục):
   - `aws/org/org.auto.tfvars`: `account_emails` với hai khoá mới `log-archive`, `security`, mỗi khoá một email chưa account AWS nào dùng, kể
     cả account đã đóng hay `SUSPENDED`; `security_contact`; `sso_user_name`, `sso_region` (README `aws/org`, mục Chuẩn bị).
   - `aws/security/security.auto.tfvars`: `security_alert_email`, hộp thư nhận mọi cảnh báo bảo mật.
   - `aws/baseline/baseline.auto.tfvars`: `sso_region` bằng giá trị của `org.auto.tfvars`.
3. **Chi phí liên tục**: từ bước (5) dịch vụ phát hiện tính tiền mỗi tháng ở mọi account của tổ chức, kể cả khi không có buổi; bước (1),
   (3), (6) thêm KMS key. Đọc bảng ở [ADR-0060 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục)
   và [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#12-chi-phí-liên-tục).
   Inspector tính theo digest image được quét ở registry của account env (không có registry thì $0):
   [ADR-0062 §11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md#11-chi-phí-registry).
   Account có cờ `off` không trả phần đó:
   [bảng tháng không buổi của
   ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#bảng-tháng-không-buổi);
   tháng không buổi với file của repo ở
   [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8.
   Budget tổng của org phải đủ cho khoản đó cộng các buổi: lệnh đọc ở cuối mục [Mở terminal](#mở-terminal) (cần biến và phiên SSO của mục đó).
4. **Phụ thuộc buổi**: từ khi code này ở `main`, root `aws/envs/stg`, `aws/envs/prd` ghi flow log và log WAF vào bucket của `svp-log-archive`
   và cần `SVP_AWS_LOG_ACCOUNT_ID`. Buổi stg, prd chỉ chạy được sau khi bước (1)–(3) đã áp.

## Mở terminal

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1
printf 'mgmt …%s stg …%s prd …%s\n' "${SVP_AWS_MGMT_ACCOUNT_ID: -4}" "${SVP_AWS_STG_ACCOUNT_ID: -4}" \
  "${SVP_AWS_PRD_ACCOUNT_ID: -4}"   # từ .envrc (direnv)
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"                                      # check-account.sh ghi mốc ở đây
aws/scripts/check-account.sh mgmt
```

Tìm `ok    account <12 số> of mgmt, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_…`. Profile `anhnv-sso` và phiên
SSO chưa có thì làm [Profile gốc](../../aws/org/README.md#profile-gốc-anhnv-sso) trước. Biến account đã nạp qua direnv từ
`.envrc` ở thư mục chứa các clone ([README](../../README.md#plan-và-apply)); chưa có file thì tạo theo README,
với ba biến trên đọc trên trang SSO (`SVP_AWS_MGMT_ACCOUNT_ID` luôn gõ tay: `check-account.sh` đối chiếu nó với account thật). Lần dựng
đầu chỉ có ba biến đó, vì `aws/scripts/accounts.sh` đòi đủ năm account thành viên mà `svp-backup` chỉ có sau bước (4). Từ bước (2) thêm
hai biến `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID` vào `.envrc`. Mở lại terminal giữa chừng: direnv nạp lại biến, chạy lại
`check-account.sh mgmt`; khi `svp-backup` đã có, `eval "$(aws/scripts/accounts.sh)"` đặt các biến thành viên còn lại, thêm chúng vào
file. Mọi lệnh ghi của bước (1)–(6) chạy bằng `anhnv-sso` (root `aws/log-archive`, `aws/security`,
`aws/baseline` vào account đích qua `OrganizationAccountAccessRole`); trước mỗi bước,
chạy lại `check-account.sh mgmt`.

Budget tổng của org (điều 3 của mục Trước khi bắt đầu):

```sh
AWS_PROFILE=anhnv-sso aws budgets describe-budget --account-id "$SVP_AWS_MGMT_ACCOUNT_ID" --budget-name svp-monthly --region us-east-1 \
  --query 'Budget.BudgetLimit' --output text
```

Hạn mức thấp hơn ước của ADR cộng chi phí buổi trong tháng: đổi `budget_limit_usd` của `aws/bootstrap/bootstrap.auto.tfvars` trước bước (1).

## Cái đã có trước khi áp

Lần đọc hiện trạng trước thiết kế (ADR-0059, mục Bối cảnh) không thấy dịch vụ bảo mật nào bật tay. Tổ chức, OU `Workloads`, `svp-stg`, `svp-prd`
đã ở state `aws/org`; policy type SCP, RCP đã bật và `aws/org` giữ chúng trong danh sách. OU `Production`, `Development` (hai account demo đã
đóng) ở ngoài Terraform ([README `aws/org`, OU ngoài Terraform](../../aws/org/README.md#ou-ngoài-terraform)). Ba chỗ có thể đổi từ lần đọc đó tới
lúc áp, mỗi chỗ có lệnh đọc và lệnh nhập vào state ở README của root:

| Có thể đã có | Đọc ở bước | Hướng dẫn nhập vào state |
| --- | --- | --- |
| Tổ chức chưa ở state (root dựng lại từ đầu) | (2) | [README `aws/org`, Chuẩn bị](../../aws/org/README.md#chuẩn-bị) |
| Monitor Cost Anomaly Detection do AWS tự tạo | (1) | [README `aws/bootstrap`, mục 5](../../aws/bootstrap/README.md#5-áp-thay-đổi-khi-state-đã-ở-bucket) |
| `AWSServiceRoleForConfig`, recorder Config | (6) | [README `aws/baseline`, Kiểm cái đã có](../../aws/baseline/README.md#2-kiểm-cái-đã-có) |

## Bước (1): `aws/bootstrap`

```sh
aws/scripts/check-account.sh mgmt
cd aws/bootstrap
```

Theo [README mục 5](../../aws/bootstrap/README.md#5-áp-thay-đổi-khi-state-đã-ở-bucket): kiểm monitor và tag, plan, apply, sinh lại
`aws/backend.hcl` bằng `aws/scripts/tfvars.sh backend mgmt` (lần đầu có `kms_key_id`), `aws/scripts/tfvars.sh init` chạy `terraform init
-reconfigure` ở mọi root dùng nó, kể cả các root mới. Tag `Env` chưa có trong dữ
liệu billing thì `apply` lỗi ở đúng tag đó; thứ tự áp không đổi (README, mục Tag phân bổ chi phí). `cd ../..` về `infra/` khi xong.

## Bước (2): `aws/org`, chỉ tổ chức, OU, account

**Điểm dừng.** Tạo account gần như không đảo ngược được: đóng account chờ 90 ngày, email không dùng lại được.

```sh
aws/scripts/check-account.sh mgmt
cd aws/org
```

Theo [README, Bước (2)](../../aws/org/README.md#bước-2-tổ-chức-ou-account): plan có `-target`, **dán plan đủ và chờ đọc cùng** trước khi
apply; rồi apply file plan, đặt `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID` từ output. Lỗi email đã dùng: đổi email trong
`org.auto.tfvars`, không sửa code. Dán hai id đã che bớt (4 số cuối). `cd ../..` khi xong.

## Bước (3): `aws/log-archive`

```sh
aws/scripts/check-account.sh mgmt
cd aws/log-archive
```

Theo [README, Apply lần đầu](../../aws/log-archive/README.md#apply-lần-đầu). Từ đây buổi stg, prd chạy được (mục Phụ thuộc buổi ở trên).
`cd ../..` khi xong.

## Bước (4): `aws/org` đủ

**Điểm dừng.** Plan này gắn SCP, RCP, declarative policy, tag policy lên root của tổ chức và đổi đích trail: đọc cùng trước khi apply.

```sh
aws/scripts/check-account.sh mgmt
cd aws/org
```

Theo [README, Bước (4)](../../aws/org/README.md#bước-4-đủ-root): plan, đọc, apply, plan lần hai `No changes.`, `get-trail-status`. Delegated
admin và cấu hình tổ chức của dịch vụ có thể mất vài phút mới nhận: lỗi kiểu đó thì chờ rồi chạy lại đúng bước này. `cd ../..` khi xong.

**Bốn profile chỉ đọc**, ngay sau bước này (bước (5), (6), (7) dùng chúng): `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro` (`SvpReadOnly`),
`anhnv-log-ro` (`SvpLogReader`), theo [README `aws/org`, Profile](../../aws/org/README.md#bảy-profile-còn-lại):

```sh
aws/scripts/sso-profiles.sh write
aws/scripts/sso-profiles.sh check
```

`write` ghi các profile mà biến account đã đặt (`skip  profile <tên>: SVP_AWS_<…>_ACCOUNT_ID is not exported` cho
profile còn lại: đặt biến rồi chạy lại). Dán các dòng `ok    account <12 số> of <tên>, arn:…` của `check`, che account:
`Arn` là `AWSReservedSSO_SvpReadOnly_…` ở ba profile đầu, `AWSReservedSSO_SvpLogReader_…` ở `anhnv-log-ro`.

## Bước (5): `aws/security`

**Điểm dừng chi phí.** Từ apply này GuardDuty tính tiền mỗi tháng ở mọi account, Security Hub CSPM và Config ở account
có cờ `always` (với file của repo chỉ `svp-security`; mục Trước khi bắt đầu, điều 3). Áp khi đã chọn thời điểm.

```sh
aws/scripts/check-account.sh mgmt
cd aws/security
```

Theo [README, Apply](../../aws/security/README.md#apply-bước-5-của-thứ-tự-áp-lần-đầu): giá trị cá nhân, plan, apply,
**xác nhận email SNS** (thư "AWS Notification - Subscription Confirmation" tới `security_alert_email`; `verify.sh
subscriptions mgmt` kiểm), kiểm nhanh. Root đọc cờ `security_hub`, `inspector_ecr`: account `off` gắn policy
`svp-security-off`, không có liên kết Inspector, và có rule `svp-security-guardduty-findings` giữ email finding
GuardDuty của nó (mục Cờ chi phí của [README `aws/security`](../../aws/security/README.md#cờ-chi-phí)). `cd ../..` khi
xong.

## Bước (6): `aws/baseline`

```sh
aws/scripts/check-account.sh mgmt
cd aws/baseline
```

Theo [README, Apply lần đầu](../../aws/baseline/README.md#apply-lần-đầu): kiểm cái đã có, plan, apply. Apply có thể sinh vài email
`svp-security-detection` (recorder, delivery channel mới); thiếu email ở account hay region nào cũng chưa phải lỗi: rule có thể được tạo sau
recorder trong cùng apply. Account có cờ `config_recording` `off` không có recorder, delivery channel ở hai region (mục Cờ chi phí của
[README `aws/baseline`](../../aws/baseline/README.md#cờ-chi-phí)). Lần đầu, (5) đi trước (6) với cờ của file; đổi cờ sau đó theo thứ tự của
[`paid-features.md`](paid-features.md#thứ-tự-apply-cờ). Đường cảnh báo kiểm ở [7e](#7e-cảnh-báo-thử). `cd ../..` khi xong.

## Bước (7): kiểm sau áp

Chạy sau bước (6) ít nhất 30 phút (GuardDuty, Security Hub nhận account có sẵn có thể tới 24 giờ: mục nào chưa đủ thì đọc lại hôm sau). Lệnh
chỉ đọc trừ phép thử guardrail. Dán output từng mục; che 8 số đầu của account ID.

### 7a. Dịch vụ bật

Một lệnh đọc 7a, 7c và phần chỉ đọc của 7b (`iam list-organizations-features`), mỗi kiểm một dòng `ok`, `FAIL` hay `note`; một `FAIL`
không dừng kiểm sau, cuối cùng `FAIL  N check(s) failed, each named above` và exit 1:

```sh
aws/scripts/verify.sh org
```

Cần các profile `anhnv-sso`, `anhnv-security-ro`, `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-log-ro`, bốn biến account thành viên của
[Mở terminal](#mở-terminal) và `aws/org` đã `init` trong bản clone này (`aws/scripts/tfvars.sh init`). Trước mỗi nhóm kiểm lệnh đối chiếu
account của profile và in `ok    profile <tên> is the account of <tên>`; dòng `FAIL` đó nghĩa là bỏ cả nhóm của profile ấy. Mong đợi:

- **7a** `svp-security administers GuardDuty, Security Hub, Config, Access Analyzer and Inspector`: sáu principal của
  delegated administrator.
- **7a** `policies of the root and of OU Prod as expected`: root `FullAWSAccess` với năm SCP `svp-*`
  ([`org-policies`](../../aws/modules/org-policies/README.md)), `RCPFullAWSAccess` với `svp-data-perimeter`,
  `svp-ec2-baseline`, `svp-tags`; OU `Prod` `svp-prod-guardrails`.
- **7a** `GuardDuty in <region>`, `Access Analyzer svp-org ACTIVE`, `Security Hub is CENTRAL ENABLED`, `every source of
  the Config aggregator`, `Inspector scans only ECR`: các dịch vụ của [`aws/security`, Kiểm
  nhanh](../../aws/security/README.md#6-kiểm-nhanh).
- **7a** `every ACTIVE account but svp-security is a Security Hub member as its cost flag says`: account có
  `security_hub` `off` không phải member.
- **7a** `<profile> <region>: Security Hub standards and Config recorder as expected`: hai chuẩn `READY`, recorder
  `CONTINUOUS` và `True SUCCESS` ở hai region của management, `svp-security`, stg, prd; account có cờ `off` thì `note`
  thay `ok`.
- **7a** `rule svp-security-admin-sso ENABLED in the region of Identity Center`: rule phải ở đúng `sso_region` của
  `org.auto.tfvars`, không thì im lặng.
- **7b** `RootCredentialsManagement and RootSessions are on`: root tập trung.
- **7c** `trail svp-audit is logging with no delivery error`: `[true,null,null]`.
- **7c** `the Log Archive bucket holds logs of every ACTIVE account, management included`: log mới của mọi account, đọc
  được bằng `SvpLogReader`; sau bước (4) ít nhất một giờ.

Account mới nhận có thể tới 24 giờ mới hiện (`FAIL  7a: … Member status …`, `PENDING` ở association): đọc lại hôm sau,
vẫn `FAIL` thì dán dòng đó. Lỗi quyền ở một profile chỉ đọc: dán lệnh và lỗi, đó cũng là kết quả kiểm của permission
set. Dòng `note` dán lại và đọc bằng mắt: `7a: control <id> FAILED in <n> finding(s)` là control FAILED ban đầu, đầu vào
của việc sửa sau, không phải lỗi của bước này; `7c: last write to the old management trail bucket: <giờ>` là lần ghi
cuối vào bucket trail cũ, không mới hơn lúc apply bước (4) cộng vài phút giao log; `7a: Security score` chỉ trang
Summary của Security Hub trên console của `svp-security` (profile `anhnv-security-ro`), không có API đọc điểm: dán điểm
đó cùng danh sách control.

### 7b. Root tập trung

Phần chỉ đọc (`RootCredentialsManagement RootSessions`) nằm ở `verify.sh org` trên. Kiểm credential root của từng account giữ tay: mỗi
`sts assume-root` mở một phiên root, ghi lại một email `svp-security-root-session` (mục 7e), và credential của phiên là bí mật, nên
người học chạy từng account và đọc kết quả, `verify.sh` chỉ nhắc bằng một dòng `note`. Lệnh dùng `sts assume-root` với task policy
`IAMAuditRootUserCredentials`:

```sh
for id in "$SVP_AWS_LOG_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID" "$SVP_AWS_STG_ACCOUNT_ID" "$SVP_AWS_PRD_ACCOUNT_ID"; do
  (
    creds=$(AWS_PROFILE=anhnv-sso aws sts assume-root --target-principal "$id" --region ap-southeast-1 \
      --task-policy-arn arn=arn:aws:iam::aws:policy/root-task/IAMAuditRootUserCredentials \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || exit 1
    read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_PROFILE
    printf '%s password: ' "${id: -4}"; aws iam get-login-profile --region us-east-1 2>&1 | grep -q NoSuchEntity && echo none || echo PRESENT
    printf '%s access keys: ' "${id: -4}"; aws iam list-access-keys --region us-east-1 --query 'length(AccessKeyMetadata)' --output text
    printf '%s mfa: ' "${id: -4}"; aws iam list-mfa-devices --region us-east-1 --query 'length(MFADevices)' --output text
  )
done
```

Mong mỗi account `none`, `0`, `0`. Credential của phiên root chỉ nằm trong subshell, không in ra. `PRESENT` hay số khác `0`: dọn theo
[`break-glass.md`](break-glass.md#dọn-sau-khi-dùng).

### 7c. Trail

`verify.sh org` ở trên đọc trạng thái trail `svp-audit` và bucket Log Archive; `get-trail-status` tay ở
[README `aws/org`, Bước (4)](../../aws/org/README.md#bước-4-đủ-root) chỉ cần khi `verify.sh org` báo `FAIL  7c: trail svp-audit …`.

### 7d. Phép thử guardrail

Giữ tay vì mỗi probe là lệnh ghi (hay thử ghi) lên account, có bước hoàn tác, và lệnh không bị từ chối nghĩa là
guardrail hỏng: người học đọc từng kết quả và chạy bước hoàn tác viết sẵn, không để script tiếp tục. Mỗi probe là một
lệnh mà guardrail phải từ chối, chọn sao cho không đổi gì nếu guardrail hỏng (`--dry-run`, giá trị đang có, user tạm có
lệnh xoá viết sẵn). Chạy bằng `SvpAdmin`: `anhnv-stg`, probe Spot bằng `anhnv-prd`. Lệnh bị từ chối phải nói `explicit
deny in a service control policy`. Lỗi EC2 chỉ có `Encoded authorization failure message` thì giải mã, mong
`"explicitDeny":true`:

```sh
AWS_PROFILE=anhnv-stg aws sts decode-authorization-message --encoded-message <chuỗi> --region ap-southeast-1 --query DecodedMessage --output text |
  jq -c '{allowed, explicitDeny}'
```

**Lệnh không bị từ chối: dừng, chạy lệnh hoàn tác viết sẵn ngay dưới nó, dán output.** Đó là lỗi của guardrail, sửa bằng PR, không thử tiếp.

| Probe | Policy chặn | Từ chối mong đợi | Email (rule) |
| --- | --- | --- | --- |
| `iam create-user` | `svp-deny-iam-users` | `AccessDenied` | `svp-security-denied-iam` |
| `s3control put-public-access-block` | `svp-protect-baseline` | `AccessDenied` | `svp-security-denied-storage` |
| `ec2 disable-ebs-encryption-by-default --dry-run` | `svp-protect-baseline` | `UnauthorizedOperation` | `svp-security-denied-storage` |
| `kms disable-key-rotation` (CMK EBS) | `svp-protect-baseline` | `AccessDeniedException` | `svp-security-denied-storage` |
| `events disable-rule` (`svp-security-trail`) | `svp-protect-baseline` | `AccessDeniedException` | `svp-security-alert-rules` |
| `ec2 run-instances --dry-run` Spot ở prd | `svp-prod-guardrails` | `UnauthorizedOperation` | không bắt buộc |
| `ec2 get-*` (đọc) | `svp-ec2-baseline` | không từ chối; giá trị do declarative policy đặt | không |

```sh
aws/scripts/check-account.sh stg
```

IAM user (hoàn tác chỉ khi lệnh tạo thành công):

```sh
U="svp-scp-probe-$(date -u +%y%m%d)"
AWS_PROFILE=anhnv-stg aws iam create-user --user-name "$U" --region us-east-1
AWS_PROFILE=anhnv-stg aws iam delete-user --user-name "$U" --region us-east-1        # hoàn tác
```

S3 Block Public Access cấp account, đúng bốn cờ `true` đang có (không cần hoàn tác):

```sh
AWS_PROFILE=anhnv-stg aws s3control put-public-access-block --account-id "$SVP_AWS_STG_ACCOUNT_ID" --region ap-southeast-1 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
AWS_PROFILE=anhnv-stg aws s3control get-public-access-block --account-id "$SVP_AWS_STG_ACCOUNT_ID" --region ap-southeast-1 --output text
```

EBS mã hoá mặc định (`DryRunOperation` là guardrail hỏng; `--dry-run` không đổi gì):

```sh
AWS_PROFILE=anhnv-stg aws ec2 disable-ebs-encryption-by-default --dry-run --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws ec2 get-ebs-encryption-by-default --region ap-southeast-1 --output text
AWS_PROFILE=anhnv-stg aws ec2 get-ebs-default-kms-key-id --region ap-southeast-1 --output text
```

Mong sau lệnh bị từ chối: `True`; key mặc định là ARN của key `alias/svp-ebs` của stg (lệnh dưới in ARN đó).

CMK EBS (API không nhận alias: lấy ARN trước; không thử `disable-key`, `schedule-key-deletion`: guardrail hỏng thì volume mới hỏng):

```sh
K="$(AWS_PROFILE=anhnv-stg aws kms describe-key --key-id alias/svp-ebs --region ap-southeast-1 --query KeyMetadata.Arn --output text)"
AWS_PROFILE=anhnv-stg aws kms disable-key-rotation --key-id "$K" --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws kms enable-key-rotation --key-id "$K" --region ap-southeast-1                       # hoàn tác
AWS_PROFILE=anhnv-stg aws kms get-key-rotation-status --key-id "$K" --region ap-southeast-1 --query KeyRotationEnabled --output text
```

Mong `True` ở dòng cuối.

Rule cảnh báo (probe của dịch vụ API JSON, mã `AccessDeniedException`):

```sh
AWS_PROFILE=anhnv-stg aws events disable-rule --name svp-security-trail --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws events enable-rule --name svp-security-trail --region ap-southeast-1                # hoàn tác
AWS_PROFILE=anhnv-stg aws events describe-rule --name svp-security-trail --region ap-southeast-1 --query State --output text
```

Mong `ENABLED` ở dòng cuối.

Spot ở prd (`--dry-run`: không instance nào được tạo dù guardrail hỏng; `DryRunOperation` là guardrail hỏng):

```sh
aws/scripts/check-account.sh prd
AMI="$(AWS_PROFILE=anhnv-prd aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --region ap-southeast-1 --query Parameter.Value --output text)"
AWS_PROFILE=anhnv-prd aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type t4g.nano --region ap-southeast-1 \
  --instance-market-options MarketType=spot --metadata-options HttpTokens=required
```

Lỗi khác hai mã trên (ví dụ account không có VPC mặc định): dán lại, không kết luận.

Declarative policy EC2 (chỉ đọc, ở stg):

```sh
for c in get-instance-metadata-defaults get-serial-console-access-status get-snapshot-block-public-access-state \
  get-image-block-public-access-state; do
  AWS_PROFILE=anhnv-stg aws ec2 "$c" --region ap-southeast-1 --output json
done
```

Mong `HttpTokens` `required`, `HttpPutResponseHopLimit` `1`, `InstanceMetadataTags` `disabled`; serial console `false`; snapshot
`block-all-sharing`; AMI `block-new-sharing`; mỗi kết quả có `ManagedBy` `declarative-policy`. Giá trị đủ ở
[ADR-0059 §5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md#5-declarative-policy-ec2).

### 7e. Cảnh báo thử

Giữ tay vì lệnh tạo finding mẫu ghi vào GuardDuty của `svp-stg` và kéo theo email cảnh báo mà người học phải đọc ở hộp thư. Finding mẫu
GuardDuty mức HIGH ở `svp-stg`: finding đi về delegated admin ở `svp-security`, rồi tới email: qua aggregator Security Hub và
rule `svp-security-findings` khi cờ `security_hub` của stg là `always`, qua rule `svp-security-guardduty-findings` khi `off`.

```sh
D="$(AWS_PROFILE=anhnv-stg aws guardduty list-detectors --region ap-southeast-1 --query 'DetectorIds[0]' --output text)"
AWS_PROFILE=anhnv-stg aws guardduty create-sample-findings --detector-id "$D" --region ap-southeast-1 \
  --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS'
```

Trong 30 phút sau phép thử guardrail và lệnh trên, hộp thư `security_alert_email` phải có (thư SNS của topic `svp-security-alarms`, mỗi thư một
dòng có tên sự kiện hay tiêu đề finding, account, region và URL runbook
[`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md)):

- năm thư của năm probe chặn ở mục 7d, theo cột Email của bảng; probe Spot, declarative không bắt buộc;
- bốn thư `AssumeRoot` của mục 7b (rule `svp-security-root-session` của management);
- một thư finding `[SAMPLE] …` mức HIGH của account stg (rule `svp-security-findings`, hay `svp-security-guardduty-findings` khi
  `security_hub` của stg là `off`).

Finding của Inspector vào Security Hub như GuardDuty nhưng không tới email (rule `svp-security-findings` chỉ lọc GuardDuty, Access Analyzer):
đọc chúng ở phép kiểm (a) của mục [Phép kiểm nền tảng managed](session-stg.md#phép-kiểm-nền-tảng-managed) của runbook buổi (account có
`inspector_ecr` `always`).

Dán danh sách tiêu đề và giờ nhận, cùng nguyên văn một thư (che account). Thiếu thư nào: đọc lại subscription (README `aws/security`, mục
5), rồi dán lệnh của probe đó và giờ chạy; rule nguồn, account, region theo phụ lục
[ADR-0060 §10](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#10-đường-cảnh-báo).
Finding mẫu ở lại tới khi GuardDuty tự xoá (90 ngày); đổi trạng thái nó theo runbook `security-alert.md`.

### 7f. Chi phí sau 1 và 7 ngày

Cost Explorer có dữ liệu sau ~24 giờ. Sau 1 ngày và sau 7 ngày kể từ bước (5), theo dịch vụ, cả org (ngày áp bước (5) dạng `yyyy-mm-dd`):

```sh
aws/scripts/verify.sh cost mgmt <ngày áp bước 5>
```

Mỗi dòng dữ liệu là `note  <ngày>  <dịch vụ>  <số> USD` cho sáu dịch vụ của mục này (GuardDuty, Security Hub, Config,
KMS, S3, CloudTrail), cuối `ok    N row(s) from <ngày> to <hôm nay>, <tổng> USD`; chưa có dữ liệu thì `note  no cost
data from … yet (Cost Explorer lags about 24 hours)`. So với [ADR-0060
§12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục).
Trong 30 ngày dùng thử GuardDuty và Security Hub ghi $0: đọc chi phí ước sau dùng thử ở trang "Usage" của GuardDuty và
Security Hub trên console của `svp-security` (giữ tay: không có API đọc ước tính đó), dán cả hai; lệnh nhắc bằng hai
dòng `note` cuối. Monitor, subscription Cost Anomaly Detection và trạng thái tag phân bổ: hai lệnh đọc ở [README
`aws/bootstrap`, mục 5](../../aws/bootstrap/README.md#5-áp-thay-đổi-khi-state-đã-ở-bucket), mong monitor `svp-services`
và ba tag `Active` (`Env` chỉ sau buổi stg hay prd đầu tiên).

#### Bật Cost Explorer lần đầu

`verify.sh cost` (và mọi lệnh `ce`) lỗi `FAIL  ce get-cost-and-usage (first use: turn Cost Explorer on once in the
console …)` khi account chưa bật Cost Explorer. Giữ tay vì chỉ bật được trên console, không có API
([nguồn](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-enable.html), đọc 2026-11-15). Làm một lần, ở
management account:

1. Đăng nhập management account bằng quyền đủ (root hay người dùng IAM được phép), không bằng profile chỉ đọc.
2. Console **Billing and Cost Management** → **Cost Explorer** → **Launch Cost Explorer**. Bật ở management account thì
   mọi account thành viên dùng được; thành viên không tự bật khi management chưa bật
   ([nguồn](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-access.html), đọc 2026-11-15).
3. Chờ: dữ liệu của tháng hiện tại hiện sau khoảng 24 giờ, phần còn lại thêm vài ngày. Trong lúc đó `verify.sh cost` in
   `note  no cost data …` hay lỗi như trên là bình thường.

Bẫy: bật Cost Explorer cũng tự cấu hình Cost Anomaly Detection (tắt được) và AWS tạo monitor `Default-Services-Monitor`;
monitor này làm `apply` của `aws/bootstrap` lỗi `Limit exceeded on dimensional spend monitor creation` cho tới khi nhận
quản nó: mục "Cái đã có trước khi áp" ở trên. Kiểm: chạy lại `verify.sh cost mgmt` sau 24 giờ, mong `ok    N row(s) …`.

## Khi một bước đỏ

- Lỗi ở `plan`: không có gì đổi trên account; đọc lỗi, sửa nguyên nhân (biến terminal, file `.auto.tfvars`, phiên SSO), chạy lại đúng bước.
- Lỗi giữa `apply`: phần đã tạo nằm trong state; `plan` lại cùng root chỉ còn phần chưa tạo. Dán lỗi và plan mới trước khi apply lại.
- Plan có `destroy` hay `-/+` ở tổ chức, account, bucket hay key có sẵn: dừng, không apply, dán plan.
- Mất đường vào (Identity Center hỏng, phiên SSO không đăng nhập được): [`break-glass.md`](break-glass.md).
