# Runbook: áp nền bảo mật cấp org lần đầu

[Mục lục](README.md) · [github-setup, bước 1–6](github-setup.md) →

> **Tóm tắt**
>
> - **Làm gì:** áp lần đầu nền bảo mật của tổ chức theo AWS Security Reference Architecture: ba account `svp-log-archive`,
>   `svp-security`, `svp-backup`, OU `Security`, `Workloads/Prod`, `Workloads/NonProd`, policy của tổ chức, root tập trung, permission set
>   chỉ đọc, dịch vụ phát hiện (cả Amazon Inspector quét ECR), baseline của mọi account; rồi kiểm dịch vụ bật, guardrail chặn đúng và cảnh
>   báo tới email.
> - **Khi nào và bao lâu:** một lần khi dựng tổ chức, trước mọi buổi: root `aws/envs/<env>` ghi flow log, log WAF vào bucket của
>   `svp-log-archive` và cần `SVP_AWS_LOG_ACCOUNT_ID`, nên buổi stg, prd chỉ chạy được sau bước (1)–(3). Bước (7) chạy sau bước (6) ít
>   nhất 30 phút, có mục đọc lại hôm sau (GuardDuty, Security Hub nhận account có sẵn tới 24 giờ).
> - **Phí trong lúc chạy:** từ bước (5) dịch vụ phát hiện tính tiền mỗi tháng kể cả khi không buổi; bước (1), (3), (6) thêm KMS key. Tháng
>   không buổi của cả tổ chức với cờ của repo ~31,1 USD ở tháng đầu, ~39,4 USD ở tháng thứ sáu
>   ([ADR-0078 §8](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md#8-chi-phí)).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output dán lại. Mọi lệnh chạy từ gốc
repo này (`infra/`) trừ chỗ ghi `cd`. Bước nào đỏ thì dừng ở đó, dán output, không đi tiếp. Mong đợi dưới đây tính theo cờ của
[`aws/paid-features.json`](../../aws/paid-features.json): mọi account trừ `svp-security` (delegated admin) tắt Security Hub và Config,
stg và prd tắt thêm Inspector ECR
([ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §1); đổi cờ sau khi đã áp:
[`paid-features.md`](paid-features.md). Bước (4) tạo luôn `svp-backup` và Backup policy; phần còn lại của backup làm sau runbook này,
theo [backup-setup, Thứ tự áp lần đầu](backup-setup.md#thứ-tự-áp-lần-đầu). Tổ chức đã áp trước khi có
Inspector: [platform-setup, bước (1), (2)](platform-setup.md#thứ-tự-áp-lần-đầu). Vì sao từng phần:
chương 03 tới 06 của [handbook](../handbook/README.md).

## Điều kiện trước

- [ ] **Công cụ**: Terraform 1.15 (`terraform version`), AWS CLI v2, `jq`, direnv.
- [ ] **Profile gốc** `anhnv-sso` có khối `[sso-session …]` và đăng nhập được: mục [Profile gốc](#profile-gốc-anhnv-sso), làm một lần.
- [ ] **Code trên `main`**: `git switch main && git pull --ff-only` trong bản clone này; các root `aws/log-archive`, `aws/security`,
  `aws/baseline` và thay đổi của `aws/org`, `aws/bootstrap` đã merge.
- [ ] **Giá trị ngoài repo** (không commit, mỗi file tạo từ `.example` cùng thư mục):
  - `aws/org/org.auto.tfvars`: `account_emails` với hai khoá mới `log-archive`, `security`, mỗi khoá một email chưa account AWS nào dùng, kể
    cả account đã đóng hay `SUSPENDED`; `security_contact`; `sso_user_name`, `sso_region` ([2a](#2a-chuẩn-bị)).
    Chép file mẫu bằng `aws/scripts/tfvars.sh example aws/org`, rồi điền bằng editor (mục [Điền giá trị lần đầu](#điền-giá-trị-lần-đầu)).
  - `aws/bootstrap/bootstrap.auto.tfvars`: `budget_emails`, `budget_limit_usd` ([1b](#1b-giá-trị-cá-nhân)).
  - `aws/security/security.auto.tfvars`: `security_alert_email`, hộp thư nhận mọi cảnh báo bảo mật (tạo ở bước (5)).
  - `aws/baseline/baseline.auto.tfvars`: `sso_region` bằng giá trị của `org.auto.tfvars`.
- [ ] **Budget đủ** cho phí giữ của tổ chức cộng các buổi trong tháng: lệnh đọc ở cuối mục [Mở terminal](#mở-terminal). Bảng giá:
  [ADR-0060 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục) và
  [phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#12-chi-phí-liên-tục);
  Inspector tính theo digest image được quét ở registry của account env
  ([ADR-0062 §11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md#11-chi-phí-registry));
  account có cờ `off` không trả phần đó ([bảng tháng không buổi của
  ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#bảng-tháng-không-buổi)).

### Điền giá trị lần đầu

- `security_contact`: một người thật, vì AWS gửi thông báo bảo mật và gọi theo số này. Số điện thoại dạng quốc tế `+84…` (không số 0 đầu,
  không khoảng trắng), email là hộp thư người đó đọc hằng ngày.
- Email root của mỗi account mới: alias Gmail `<gmail>+svp-<tên>@gmail.com` dùng được (thư vào hộp thư gốc), miễn là chưa từng dùng cho
  account AWS nào, kể cả account đã đóng. Mỗi account một alias riêng, vì email root không đổi và không dùng lại được.
- Quy ước alias cho hộp thư nhận cảnh báo, để lọc theo nguồn: `+svp-security-alerts` cho `security_alert_email` (cảnh báo bảo mật của
  org), `+svp-<env>-alarms` cho `alarm_email` của env (alarm của env và alarm DNSSEC của prd, ví dụ `+svp-prd-alarms`).
- Domain của env (`aws/scripts/tfvars.sh env <env>` hỏi `domain`): tên hosted zone của env đó, không phải domain gốc: prd là zone gốc
  `aws.<domain>`, stg là `stg.` cộng zone gốc (`stg.aws.<domain>`).

### Profile gốc `anhnv-sso`

Giữ tay vì đây là gốc của tin cậy (MFA không có API, mọi script đối chiếu với profile này). Một lần mỗi lab, ở management; các
profile còn lại do script ghi ở [4c](#4c-profile-của-account-thành-viên).

1. **Bật IAM Identity Center** ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/get-set-up-for-idc.html)): console IAM
   Identity Center của management, **Enable**, chọn *organization instance*. Region của instance chọn một lần (đổi là xoá instance): đó
   là `sso_region` của `org.auto.tfvars` và của khối `[sso-session]`.
2. **Bật MFA** ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/mfa-configure.html)): **Settings** → **Authentication**
   → **Multi-factor authentication** → **Configure**; giữ *Require them to register an MFA device at sign in*; nhận FIDO2 và TOTP, tránh
   email one-time password (tài liệu nói nó không đạt MFA chuẩn).
3. **Tạo user của người học** ([nguồn](https://docs.aws.amazon.com/singlesignon/latest/userguide/addusers.html)): **Users** → **Add
   user**; tên không đổi được về sau, là `sso_user_name`. Thư mời hạn 7 ngày (hết hạn thì **Reset password**): đặt mật khẩu, đăng ký
   MFA ở lần đăng nhập đầu.
4. **Cấp quyền vào management**: **AWS accounts** → management account → **Assign users or groups** → user vừa tạo, với một permission
   set quyền quản trị (tạo ở **Permission sets** nếu chưa có). Code không quản permission set này; từ `SvpAdmin` trở đi `aws/org` quản.
5. **Ghi profile** có `sso-session` ([nguồn](https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html)):
   `aws --no-cli-pager configure sso --profile anhnv-sso`.
   - **Script hỏi:** *SSO session name* → ví dụ `anhnv`; *SSO start URL* → `https://d-0000000000.awsapps.com/start` của access portal;
     *SSO region* → region của bước 1; *SSO registration scopes* → mặc định; trình duyệt xác nhận; chọn management và role của bước 4;
     *CLI default client Region* → `ap-southeast-1`; *CLI default output format* → `json`.
   - **Mong đợi:** `~/.aws/config` có `[sso-session <tên>]` và `[profile anhnv-sso]` với `sso_session`. Kiểu cũ không `sso_session`
     không tự làm mới token, nên `sso-profiles.sh write` từ chối.
6. **Đăng nhập và đối chiếu**: `AWS_PROFILE=anhnv-sso aws --no-cli-pager sso login --region us-east-1`, rồi
   `AWS_PROFILE=anhnv-sso aws --no-cli-pager sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text`:
   `Account` là `SVP_AWS_MGMT_ACCOUNT_ID`, `Arn` có `AWSReservedSSO_`.

- **Bẫy:** phiên SSO hết hạn thì mọi lệnh báo `Token has expired` hay `The SSO session associated with this profile has expired`: chạy lại
  `aws --no-cli-pager sso login --profile anhnv-sso`, không cần login từng profile cùng `sso_session`.

## Mở terminal

Đăng nhập SSO của management, kiểm biến account và account của profile; chạy lại khối này mỗi khi mở terminal mới.

```sh
cd infra
AWS_PROFILE=anhnv-sso aws --no-cli-pager sso login --region us-east-1
printf 'mgmt …%s stg …%s prd …%s\n' "${SVP_AWS_MGMT_ACCOUNT_ID: -4}" "${SVP_AWS_STG_ACCOUNT_ID: -4}" \
  "${SVP_AWS_PRD_ACCOUNT_ID: -4}"   # từ .envrc (direnv)
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"  # check-account.sh ghi mốc ở đây
aws/scripts/check-account.sh mgmt
```

- **Mong đợi:** `ok    account <12 số> of mgmt, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_…`.
- **Việc tay:** profile `anhnv-sso` và phiên SSO chưa có thì làm [Profile gốc](#profile-gốc-anhnv-sso)
  trước. Biến account nạp qua direnv từ `.envrc` ở thư mục chứa các clone
  ([`operations.md`](../reference/operations.md#biến-account-và-direnv)); chưa có file thì tạo theo trang đó, với ba biến trên đọc trên
  trang SSO (`SVP_AWS_MGMT_ACCOUNT_ID` luôn gõ tay: `check-account.sh` đối chiếu nó với account thật). Từ bước (2) thêm
  `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID` vào `.envrc`; khi `svp-backup` đã có, `eval "$(aws/scripts/accounts.sh)"` đặt
  các biến thành viên còn lại, thêm chúng vào file.
- **Bẫy:** lần dựng đầu chỉ có ba biến trên, vì `aws/scripts/accounts.sh` đòi đủ năm account thành viên mà `svp-backup` chỉ có sau bước
  (4). Mọi lệnh ghi của bước (1)–(6) chạy bằng `anhnv-sso` (root `aws/log-archive`, `aws/security`, `aws/baseline` vào account đích qua
  `OrganizationAccountAccessRole`); trước mỗi bước, chạy lại `check-account.sh mgmt`.

Budget tổng của org:

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager budgets describe-budget --account-id "$SVP_AWS_MGMT_ACCOUNT_ID" --budget-name svp-monthly --region us-east-1 \
  --query 'Budget.BudgetLimit' --output text
```

- **Mong đợi:** hạn mức ít nhất bằng phí giữ của tổ chức (dòng **Phí** của Tóm tắt) cộng các buổi dự kiến trong tháng.
- **Việc tay:** thấp hơn thì đổi `budget_limit_usd` của `aws/bootstrap/bootstrap.auto.tfvars` trước bước (1).
- **Bẫy:** hạn mức thấp làm email cảnh báo 80 %, 100 % tới liên tục dù không có gì sai, và người học quen bỏ qua cảnh báo thật.

## Thứ tự áp lần đầu

| Bước | Root | Dựng gì | Dán lại |
| --- | --- | --- | --- |
| [(1)](#bước-1-awsbootstrap) | `aws/bootstrap` | Key state, Cost Anomaly Detection, tag phân bổ; `init -reconfigure` mọi root | `Plan:`, `Apply complete!`, `No changes.` của plan cuối |
| [(2)](#bước-2-awsorg-chỉ-tổ-chức-ou-account) | `aws/org` (`-target`) | OU, `svp-log-archive`, `svp-security`, chuyển OU của stg, prd | Plan đủ, `Apply complete!`, hai id đã che bớt |
| [(3)](#bước-3-awslog-archive) | `aws/log-archive` | Bucket log, hai key `alias/svp-log-archive` | `Plan:`, `Apply complete!`, output bucket và key |
| [(4)](#bước-4-awsorg-đủ) | `aws/org` (đủ) | `svp-backup`, trusted access, delegated admin (cả Inspector), service-linked role Access Analyzer, policy (cả Backup policy), root tập trung, permission set, nhóm nền tảng, liên hệ, trail đổi đích; profile | Plan đủ, `Apply complete!`, `No changes.`, `get-trail-status`, dòng `check` của 4c |
| [(5)](#bước-5-awssecurity) | `aws/security` | Dịch vụ phát hiện, Inspector ECR theo cờ, bus, SNS; xác nhận email | `Plan:`, `Apply complete!`, output của 5f |
| [(6)](#bước-6-awsbaseline) | `aws/baseline` | Block Public Access, EBS mặc định, recorder Config theo cờ, rule `svp-security-*`, CMK EBS | Output của 6b, `Plan:`, `Apply complete!` |
| [(7)](#bước-7-kiểm-sau-áp) | — | Kiểm sau áp: dịch vụ, root tập trung, trail, guardrail, cảnh báo thử, chi phí | Output từng mục |

## Bước (1): `aws/bootstrap`

Bucket state, key, budget, monitor chi phí, tag phân bổ ([01. Bootstrap](../handbook/01-bootstrap.md)). Bucket chưa có: 1a–1d rồi 1f;
đã có: 1a, 1b, 1e, 1f.

```sh
aws/scripts/check-account.sh mgmt
cd aws/bootstrap
```

### 1a. Kiểm account

`check-account.sh mgmt` đối chiếu profile với `SVP_AWS_MGMT_ACCOUNT_ID`. Lần đầu chưa có biến: đọc `Account` ở bước 6 của [Profile
gốc](#profile-gốc-anhnv-sso), so với trang SSO, gõ vào `.envrc` ([biến account](../reference/operations.md#biến-account-và-direnv)).

### 1b. Giá trị cá nhân

```sh
../scripts/tfvars.sh example aws/bootstrap
```

- **Mong đợi:** chép file mẫu thành `bootstrap.auto.tfvars` (mode 600) khi chưa có, không ghi đè; mỗi giá trị còn `<…>` một dòng
  `note  aws/bootstrap/bootstrap.auto.tfvars:<dòng> <biến> still holds a placeholder <...>`, hết thì `ok    … no placeholder <...> left`.
- **Việc tay:** sửa `budget_emails` (Budgets gửi thẳng, không thư xác nhận) và `budget_limit_usd` (**Budget đủ** ở
  [Điều kiện trước](#điều-kiện-trước)).

### 1c. Apply lần đầu trên state local

Bucket chưa có, nên chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform init
AWS_PROFILE=anhnv-sso aws --no-cli-pager ce get-anomaly-monitors --region us-east-1 \
  --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,Dimension:MonitorDimension,Arn:MonitorArn}' --output table
```

- **Bẫy:** account chỉ có một monitor `DIMENSIONAL`/`SERVICE`, mà AWS tự tạo `Default-Services-Monitor` khi Cost Explorer bật (không
  nhận quản thì `apply` lỗi `Limit exceeded on dimensional spend monitor creation`). Lệnh in một monitor như vậy thì trước `plan` chạy:

  ```sh
  AWS_PROFILE=anhnv-sso \
  TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
    terraform import -input=false aws_ce_anomaly_monitor.services <Arn>
  ```

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false -out=bootstrap.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color bootstrap.tfplan > "$SVP_SESSION_DIR/bootstrap-plan.txt"
```

- **Mong đợi:** `Plan: <n> to add, 0 to change, 0 to destroy` với `<n>` bằng tổng `to add` của mục
  [`aws/bootstrap`](../reference/inventory.md#awsbootstrap) ở inventory (account trống chạy lần đầu); đã nhận quản monitor thì trừ
  `aws_ce_anomaly_monitor` khỏi `<n>` và monitor đổi tại chỗ (`~`).

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false bootstrap.tfplan && rm bootstrap.tfplan
../scripts/tfvars.sh backend mgmt
```

- **Mong đợi:** `Apply complete!`; rồi `ok    account … of mgmt, …` và
  `ok    aws/backend.hcl: output backend_hcl of aws/bootstrap written (N lines, mode 600)` (ghi qua file tạm rồi `mv`).
- **Bẫy:** account mới chưa có tag trong dữ liệu billing thì `apply` lỗi ở `aws_ce_cost_allocation_tag` mà vẫn tạo mọi tài nguyên khác:
  tiếp tục, tag áp lại ở 1e khi key hiện ra. Output không có dòng `bucket` thì `tfvars.sh` in `FAIL` và không ghi gì.

### 1d. Chuyển state vào bucket

```sh
rm local_override.tf
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform init -migrate-state -backend-config=../backend.hcl
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false   # expect: No changes.
AWS_PROFILE=anhnv-sso aws --no-cli-pager s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/bootstrap/terraform.tfstate --query '{Size:ContentLength,SSE:ServerSideEncryption,Key:SSEKMSKeyId}'
```

- **Script hỏi:** `init -migrate-state` hỏi có chép state local lên backend mới không: `yes`.
- **Mong đợi:** `No changes.` (còn đòi tạo tag phân bổ chưa kích hoạt được cũng đúng); `SSE` `aws:kms`, `Key` là `kms_key_id` của
  `aws/backend.hcl`. Cả ba đúng thì `rm -f terraform.tfstate terraform.tfstate.backup`, rồi sang 1f.

### 1e. Áp thay đổi khi state đã ở bucket

Kiểm hai điều kiện của Cost Explorer (dịch vụ toàn cục, gọi ở `us-east-1`):

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager ce get-anomaly-monitors --region us-east-1 \
  --query 'AnomalyMonitors[].{Name:MonitorName,Type:MonitorType,Dimension:MonitorDimension,Arn:MonitorArn}' --output table
AWS_PROFILE=anhnv-sso aws --no-cli-pager ce list-cost-allocation-tags --region us-east-1 --tag-keys Project Env Stack \
  --query 'CostAllocationTags[].{Key:TagKey,Status:Status}' --output table
```

- **Mong đợi:** không monitor nào khác `svp-services`; đủ ba key `Project`, `Env`, `Stack` (`Active` hay `Inactive`).
- **Bẫy:** có monitor `DIMENSIONAL`/`SERVICE` do AWS tự tạo thì nhận quản như 1c rồi đọc plan: đổi tên tại chỗ (`~`) là đúng, `-/+` thì
  dừng và dán plan. Thiếu key nào: AWS chỉ kích hoạt key đã có trong dữ liệu billing, tức 24 giờ sau khi tài nguyên mang tag phát sinh
  chi phí (`Env` chỉ sau buổi env đầu): chờ key hiện ra rồi `plan`, `apply` lại; thứ tự áp không đổi.

Rồi `plan`, `show`, `apply`, `tfvars.sh backend mgmt` bằng các lệnh của [1c](#1c-apply-lần-đầu-trên-state-local) (apply xoá
`bootstrap.tfplan`).

- **Mong đợi:** không `destroy`; lần đầu bucket chuyển sang KMS thì thêm các phần của mục
  [`aws/bootstrap`](../reference/inventory.md#awsbootstrap) ở inventory mà account chưa có, kèm một đổi tại chỗ (`~`) mã hoá bucket.
  `tfvars.sh` in `… written` khi file đổi (thì sang 1f), `… already as written, file unchanged` khi không.

### 1f. Init lại mọi root

`aws/backend.hcl` mới hay vừa đổi: mọi root đọc nó nhận lại cấu hình bằng `-reconfigure` (không chép state; root chưa `init` cũng chạy).

```sh
../scripts/tfvars.sh init
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false   # expect: No changes.
```

- **Mong đợi:** mỗi root của [`aws/bootstrap`, Root dùng bucket state](../../aws/bootstrap/README.md#root-dùng-bucket-state) một dòng
  `ok    terraform init -reconfigure of <root> with <backend-config>`, theo thứ tự của bảng đó; `plan` là `No changes.`.
- **Bẫy:** `FAIL  terraform init -reconfigure of <root>`: các root trước đã xong; sửa nguyên nhân rồi chạy lại cả lệnh (chạy lại an toàn).
  `FAIL  no aws/backend.hcl`: chạy `tfvars.sh backend mgmt` trước. Object của root chưa `-reconfigure` giữ SSE-S3
  ([01. Bootstrap](../handbook/01-bootstrap.md#đọc-sâu)); kiểm bằng `head-object` của 1d với `--key` của root đó.

`cd ../..` về `infra/` khi xong.

## Bước (2): `aws/org`, chỉ tổ chức, OU, account

Lượt đầu của `aws/org` ([03. Tổ chức](../handbook/03-org.md)); phần còn lại cần bucket và key của `aws/log-archive`, nên đợi bước (4).

**Điểm dừng.** Tạo account gần như không đảo ngược được: đóng account chờ 90 ngày, email không dùng lại được.

```sh
aws/scripts/check-account.sh mgmt
cd aws/org
```

### 2a. Chuẩn bị

```sh
../scripts/tfvars.sh init
../scripts/tfvars.sh example aws/org
```

- **Mong đợi:** `init` như [1f](#1f-init-lại-mọi-root) (chạy lại an toàn); `example` chép `org.auto.tfvars` (mode 600) khi chưa có,
  không ghi đè, một dòng `note` mỗi giá trị còn `<…>`.
- **Việc tay:** điền đủ mọi biến của file mẫu ([Điền giá trị lần đầu](#điền-giá-trị-lần-đầu)); khoá `stg`, `prd` của `account_emails`
  giữ đúng email đang có; `sso_user_name` là tên ở góc phải trên của access portal, `sso_region` lấy từ khối `[sso-session …]`.

Chỉ khi state chưa có tổ chức (root dựng lại từ đầu): nhận quản tổ chức có sẵn, không thì plan đòi tạo tổ chức mới và apply lỗi. Mong
`MasterAccountId` bằng `SVP_AWS_MGMT_ACCOUNT_ID`, `FeatureSet` là `ALL`.

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager organizations describe-organization --region us-east-1 --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform import -input=false aws_organizations_organization.this <o-… vừa đọc>
```

### 2b. Plan có `-target`

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false -out=org.tfplan \
    -target=aws_organizations_organization.this \
    -target=aws_organizations_organizational_unit.security \
    -target=aws_organizations_organizational_unit.workloads \
    -target=aws_organizations_organizational_unit.prod \
    -target=aws_organizations_organizational_unit.nonprod \
    -target=aws_organizations_account.member \
    -target=aws_organizations_account.log_archive \
    -target=aws_organizations_account.security
AWS_PROFILE=anhnv-sso terraform show -no-color org.tfplan > "$SVP_SESSION_DIR/org-plan.txt"
```

- **Mong đợi:** `Plan: 5 to add, 3 to change, 0 to destroy`. Thêm: OU `Security`, `Prod`, `NonProd`; account `svp-log-archive`,
  `svp-security` (`parent_id` là OU `Security`). Đổi tại chỗ (`~`): tổ chức, chỉ **thêm** vào `aws_service_access_principals` và
  `enabled_policy_types`, không dòng `-` nào, `feature_set` không đổi; `member["stg"]`, `member["prd"]`, chỉ `parent_id`. Cảnh báo
  `Resource targeting is in effect` là đúng.
- **Bẫy:** dừng (không apply) nếu có `destroy`, `-/+` hay `must be replaced` ở tổ chức hay account, nếu `email` của `stg`, `prd` đổi, hay
  nếu plan nhắc trail, data source hay provider `log_archive` (lệnh `-target` này không gồm chúng).

### 2c. Apply và id của hai account

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false org.tfplan && rm org.tfplan
export SVP_AWS_LOG_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw log_archive_account_id)"
export SVP_AWS_SECURITY_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw security_account_id)"
printf '%s\n' "$SVP_AWS_LOG_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID"
```

- **Mong đợi:** `Apply complete!` sau vài phút mỗi account; hai dòng cuối là hai id 12 số khác nhau.
- **Việc tay:** thêm hai biến vào `.envrc`, `direnv allow` (lần đầu dùng `terraform output`: xem **Bẫy** của [Mở terminal](#mở-terminal)).
- **Bẫy:** lỗi email đã dùng: đổi email trong `org.auto.tfvars`, không sửa code, rồi plan lại.

`cd ../..` về `infra/` khi xong.

## Bước (3): `aws/log-archive`

Bucket log theo loại và hai key `alias/svp-log-archive` ở `svp-log-archive` ([04. Log Archive](../handbook/04-log-archive.md)), trước khi
`aws/org` đổi đích trail sang đây. Từ bước này buổi stg, prd chạy được: root env ghi flow log, log WAF vào các bucket này.

```sh
aws/scripts/check-account.sh mgmt
cd aws/log-archive
```

### 3a. Plan

Năm biến 12 số: `SVP_AWS_MGMT_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID` ([2c](#2c-apply-và-id-của-hai-account)),
`SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` (trang SSO khi chưa có `svp-backup`); thiếu thì `plan` dừng ở validation.

```sh
../scripts/tfvars.sh init
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
  terraform plan -input=false -out=log-archive.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color log-archive.tfplan > "$SVP_SESSION_DIR/log-archive-plan.txt"
```

- **Mong đợi:** `Plan: <n> to add, 0 to change, 0 to destroy` với `<n>` bằng tổng `to add` của mục
  [`aws/log-archive`](../reference/inventory.md#awslog-archive) ở inventory; root đã áp từ trước thì chỉ phần chưa có (lấy bảng theo phần,
  trừ phần đã có), không `change` hay `destroy`.
- **Kiểm:** hai `aws_kms_key.log`, key `waf`, mọi tài nguyên `["waf"]`, `["cloudfront"]` và hai
  `aws_cloudwatch_log_delivery_destination.cloudfront` có `region = "us-east-1"`, còn lại `ap-southeast-1`;
  `aws_s3_bucket_server_side_encryption_configuration.log["waf"]` và `["cloudfront"]` trỏ key `waf`; `destination_resource_arn` của mỗi
  destination kết thúc bằng `/<id account env đó>`.
- **Bẫy:** `AccessDenied` khi assume role là account chưa tạo xong hay profile sai; `account_id is not the management account` là
  `SVP_AWS_MGMT_ACCOUNT_ID` sai. Có dòng `change` hay `destroy`: dừng, dán plan.

### 3b. Apply

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false log-archive.tfplan && rm log-archive.tfplan
AWS_PROFILE=anhnv-sso terraform output bucket_names
AWS_PROFILE=anhnv-sso terraform output kms_key_arns
```

- **Mong đợi:** `Apply complete!`; `bucket_names` có bảy bucket, tên chứa id account log; `kms_key_arns` có hai ARN dạng
  `arn:aws:kms:<region>:<log>:key/<id>`, một `ap-southeast-1`, một `us-east-1`.
- **Kiểm:** bước (4) đổi đích trail sang đây; `get-trail-status` của [4b](#4b-apply) không lỗi giao là policy của root này đúng.

`cd ../..` về `infra/` khi xong.

## Bước (4): `aws/org` đủ

**Điểm dừng.** Sau bước (3). Plan này gắn SCP, RCP, declarative, tag policy lên root và đổi đích trail: đọc cùng trước khi apply.

```sh
aws/scripts/check-account.sh mgmt
cd aws/org
```

### 4a. Plan

Trail tổ chức chỉ là bản sao miễn phí khi không có trail management event nào khác; mong không dòng nào ngoài `svp-audit` (có thì dán
lại):

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager cloudtrail describe-trails --region ap-southeast-1 --query 'trailList[].[Name,IsOrganizationTrail]' --output text
```

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false -out=org.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color org.tfplan > "$SVP_SESSION_DIR/org-plan.txt"
```

- **Mong đợi:** `Plan: <n> to add, 2 to change, 3 to destroy`. `<n>` bằng số tài nguyên của danh sách "Thêm" dưới, cộng ba
  attachment của "Thay" (đếm ở cả add lẫn destroy). Không lấy tổng của mục [`aws/org`](../reference/inventory.md#awsorg) ở inventory:
  mục đó đếm root trên account trống, còn ở đây state đã có tổ chức, OU, account của bước (2) cùng trail, policy và Identity Center cũ.
  - Thêm: account `svp-backup` (`parent_id` là OU `Security`); delegated admin (2 GuardDuty, 1 Security Hub, 1 Inspector, 3 qua
    Organizations); `aws_iam_service_linked_role.access_analyzer`; `aws_iam_organizations_features.root_access`; 6 liên hệ `SECURITY`;
    permission set `SvpReadOnly`, `SvpLogReader` với policy và gán (12, trong đó `read_only["backup"]`); hai nhóm nền tảng;
    `aws_backup_global_settings.this`, `aws_backup_region_settings.this`; policy mới của `module.org_policies` và đích (16, trong đó
    `backup-prd`, `backup-stg`).
  - Đổi tại chỗ: `aws_ssoadmin_permission_set.admin` (chỉ `session_duration` `PT4H` → `PT1H`); `aws_cloudtrail.audit` (`s3_bucket_name`
    sang bucket của `svp-log-archive`, `kms_key_id` dạng `arn:aws:kms:ap-southeast-1:<log>:key/<id>`, `event_selector` thay bằng ba
    `advanced_event_selector`).
  - Thay (`-/+`, đếm cả ở add lẫn destroy): đúng ba `module.org_policies.aws_organizations_policy_attachment.this` của
    `deny-leave-organization`, `protect-cloudtrail`, `deny-other-regions` (`target_id` từ OU `Workloads` sang root). Ba SCP này rời đích
    cũ vài giây trước khi gắn đích mới; nội dung không đổi.
- **Thay đổi được phép:** khi `aws_backup_global_settings.this` đã có trong state (plan lại root đã áp), plan có thể thêm một đổi tại chỗ
  ở nó: `isDelegatedAdministratorEnabled "true" -> "false"`. Cờ đó đã bật ngoài Terraform (trang Cross-account management của AWS Backup
  trên console); apply là đúng thiết kế, vì `aws/org/backup.tf` giữ delegated administrator của AWS Backup tắt. Đổi khác ở
  `global_settings` thì dừng, dán plan.
- **Bẫy:** dừng (không apply) nếu tổ chức, account, KMS key hay bucket cũ có `destroy` hay `-/+`, nếu có `destroy` ngoài ba đích trên, hay
  nếu `kms_key_id` của trail là ARN alias.

### 4b. Apply

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false org.tfplan && rm org.tfplan
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform plan -input=false
```

- **Mong đợi:** `Apply complete!`, rồi plan lần hai `No changes.`; khác thì dán lại.
- **Việc tay:** tổ chức giờ có đủ năm account thành viên: `eval "$(../scripts/accounts.sh)"` đặt cả năm biến, mỗi biến một dòng
  `ok    SVP_AWS_<…>_ACCOUNT_ID: account svp-<tên>, ACTIVE`; thêm `SVP_AWS_BACKUP_ACCOUNT_ID` vào `.envrc`.
- **Bẫy:** delegated admin và cấu hình tổ chức của dịch vụ có thể chưa nhận ngay: lỗi kiểu đó thì chờ vài phút rồi chạy lại đúng bước này.

Kiểm trail ghi được vào Log Archive:

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager cloudtrail get-trail-status --name svp-audit --region ap-southeast-1 --query '[IsLogging,LatestDeliveryError,LatestDigestDeliveryError]'
```

- **Mong đợi:** `[true, null, null]`. Lỗi giao log hay digest (bucket policy, key policy của `aws/log-archive` từ chối) hiện ở hai ô sau:
  dán lại. Account mới chỉ hiện ở access portal từ lúc này (khi có gán permission set).

`cd ../..` về `infra/` khi xong.

### 4c. Profile của account thành viên

Ngay sau 4b; mọi profile chung `sso_session` của `anhnv-sso` (một lần `aws sso login`). Profile, biến, permission set: `profile_table` của
`aws/scripts/profiles.sh`.

```sh
aws/scripts/sso-profiles.sh write
aws/scripts/sso-profiles.sh check
```

- **Mong đợi:** `write` thêm hay thay khối `[profile …]` của từng profile, không đổi dòng khác của `~/.aws/config`, không gọi mạng:
  `ok    profile <tên>: added|up to date …`. `check` gọi `sts get-caller-identity` từng profile: `ok    account <12 số> of <tên>, arn:…`,
  `Arn` dạng `assumed-role/AWSReservedSSO_<permission set>_…`.
- **Dán lại:** mọi dòng `ok` của `check` (che account) và mọi dòng `FAIL`.
- **Bẫy:** `skip  profile <tên>: SVP_AWS_<…>_ACCOUNT_ID is not exported`: đặt biến rồi chạy lại. `FAIL  no [profile anhnv-sso] in …`
  hay `has no sso_session`: làm lại bước 5 của [Profile gốc](#profile-gốc-anhnv-sso). `check` đọc hết rồi mới
  `FAIL  N profile(s) failed, each named above`.

## Bước (5): `aws/security`

Bật GuardDuty, Security Hub CSPM, Inspector ECR, Config aggregator và Access Analyzer cho cả tổ chức từ `svp-security`, cùng đường
EventBridge → SNS tới email ([05. Bảo mật](../handbook/05-security.md)). Root đọc cờ `security_hub`, `inspector_ecr`: account `off` gắn
policy `svp-security-off`, không có liên kết Inspector, và có rule `svp-security-guardduty-findings` giữ email finding GuardDuty của nó.

**Điểm dừng chi phí.** Từ apply này GuardDuty tính tiền mỗi tháng ở mọi account, Security Hub CSPM và Config ở account có cờ `always`
(với file của repo chỉ `svp-security`). Áp khi đã chọn thời điểm.

- [ ] Bước (3) xong: bucket `svp-guardduty-…`, key `alias/svp-log-archive` với key policy cho GuardDuty của `svp-security`.
- [ ] Bước (4) xong: trusted access, `svp-security` là delegated admin của GuardDuty (hai region), Security Hub, Inspector, Config, Access
  Analyzer, và service-linked role `AWSServiceRoleForAccessAnalyzer` ở management. Thiếu thì plan dừng ở data source
  `aws_guardduty_detector` (không có detector) hay apply lỗi quyền delegated admin.
- [ ] Biến `SVP_AWS_MGMT_ACCOUNT_ID` (gõ tay), `SVP_AWS_SECURITY_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID` đã đặt: sau bước (4)
  `eval "$(aws/scripts/accounts.sh)"` đặt cả năm biến thành viên, kể cả `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` của bước (6);
  trước bước (4) script in `FAIL  no account svp-backup in the organization` ([Mở terminal](#mở-terminal)).

```sh
aws/scripts/check-account.sh mgmt
cd aws/security
```

- **Mong đợi:** `ok    account <12 số> of mgmt, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_…`; `FAIL  profile anhnv-sso is account …`
  thì dừng.

### 5a. Giá trị cá nhân và init

Tạo `security.auto.tfvars` (git bỏ qua) giữ hộp thư nhận cảnh báo, rồi `init` với backend của management.

```sh
../scripts/tfvars.sh example aws/security
AWS_PROFILE=anhnv-sso terraform init -backend-config=../backend.hcl
```

- **Mong đợi:** lệnh đầu chép `security.auto.tfvars.example` thành `security.auto.tfvars` (mode 600) khi file chưa có, không ghi đè, và
  in một dòng `note` cho mỗi giá trị còn `<…>`. `init` đã chạy sẵn cho mọi root của management ở bước (1) (`aws/scripts/tfvars.sh init`).
- **Việc tay:** sửa `security_alert_email` trong editor: hộp thư nhận mọi cảnh báo bảo mật (alias `+svp-security-alerts`, mục
  [Điền giá trị lần đầu](#điền-giá-trị-lần-đầu)). Giá trị cá nhân giữ tay, không commit.

### 5b. Plan

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
  terraform plan -input=false -out=security.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color security.tfplan > "$SVP_SESSION_DIR/security-plan.txt"
```

- **Mong đợi:** với `aws/paid-features.json` của repo `to add` bằng tổng của mục [`aws/security`](../reference/inventory.md#awssecurity) ở
  inventory, `1 to import`, `1 to change`, `0 to destroy` (inventory không có `1 to change`: nó chỉ hiện khi Inspector đã tự bật ở
  account thật). Mỗi region của hai region
  một cấu hình tổ chức, sáu protection plan, một publishing destination, một detector management, một member, một analyzer, một rule
  `svp-security-guardduty-findings`; bốn tài nguyên Security Hub, policy `svp-security-off` và năm association (management,
  `svp-log-archive`, `svp-backup`, `svp-stg`, `svp-prd`); cấu hình tổ chức Inspector, hai liên kết thành viên (`svp-log-archive`,
  `svp-backup`), enabler `members`; role, policy attachment và aggregator Config; bus, policy bus, hai rule, hai target; target topic và
  target bus của rule GuardDuty, role `svp-security-guardduty-forwarder` và policy của nó; năm tài nguyên của module `alarms`. Import và
  đổi là enabler `security`. File cờ khác thì tính lại: mỗi account `off` của `security_hub` một association, mỗi account thành viên có
  `inspector_ecr` khác `off` một liên kết.
- **Kiểm:** phần Inspector theo [5c](#5c-kiểm-plan-inspector).
- **Bẫy:** dừng và dán plan lại nếu có dòng `destroy`, hay `aws_guardduty_detector` nào khác `aws_guardduty_detector.management`.

### 5c. Kiểm plan Inspector

- `aws_inspector2_enabler.security` mang dòng `(imported from "<security>-ECR")`; `account_ids` giữ đúng id của `svp-security`,
  `resource_types` bỏ các loại khác `"ECR"` (`EC2`, `LAMBDA`, `LAMBDA_CODE`…) và giữ `"ECR"`. `account_ids` cũ rỗng là Inspector chưa
  bật ở `svp-security`: `aws/org` chưa chỉ định delegated admin, dừng.
- `aws_inspector2_member_association.members` và `account_ids` của `aws_inspector2_enabler.members` đúng id của các account thành viên
  khác `svp-security` có `inspector_ecr` khác `off` (`svp-log-archive`, `svp-backup` với file của repo; thêm `svp-prd` khi prd vắng khỏi
  file).

### 5d. Apply

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false security.tfplan && rm security.tfplan
```

- **Mong đợi:** `Apply complete!`; bật cấu hình tập trung và gắn policy có thể mất vài phút.
- **Bẫy:** `DataUnavailableException` (dữ liệu tổ chức còn đồng bộ sau bước (4)): đợi vài phút rồi chạy lại plan và apply.
  `ConflictException: Access Analyzer Service Linked Role is not in the organizational management account` ở
  `aws_accessanalyzer_analyzer.org`: management chưa có role; apply `aws/org` theo [mục nâng
  cấp](#thêm-service-linked-role-access-analyzer-vào-tổ-chức-đã-áp), rồi plan, apply lại root này (chỉ còn hai analyzer, phần chưa tạo).

### 5e. Xác nhận email SNS

Apply tạo subscription ở `PendingConfirmation`; topic không gửi gì tới khi người nhận bấm link xác nhận.

```sh
../scripts/verify.sh subscriptions mgmt
```

- **Việc tay:** mở thư "AWS Notification - Subscription Confirmation" gửi tới `security_alert_email` (xem cả thư rác), bấm **Confirm
  subscription**. Giữ tay vì token nằm trong thư, không có API.
- **Mong đợi:** `ok    topic svp-security-alarms: every subscription is confirmed`, mọi subscription có ARN thật.
- **Bẫy:** `FAIL  topic svp-security-alarms: a subscription is still PendingConfirmation` là chưa bấm link. Token của link chỉ dùng được
  hai ngày và SNS xoá subscription chưa xác nhận sau 48 giờ: quá hạn thì apply lại root để AWS gửi thư mới.

### 5f. Kiểm nhanh

Chỉ đọc; cần profile `anhnv-sso` và bốn profile chỉ đọc của bước (4)
([4c](#4c-profile-của-account-thành-viên)), cùng năm biến
`SVP_AWS_MGMT_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID`.
Từ `infra/aws/security`:

```sh
../scripts/verify.sh org
```

- **Mong đợi:** mỗi kiểm một dòng `ok`, `FAIL` hay `note`; một `FAIL` không dừng kiểm sau, cuối cùng
  `FAIL  N check(s) failed, each named above` và exit 1. Phần của root này:
  - `7a: GuardDuty in <region>: auto-enable ALL, …, findings PUBLISHING`: mỗi region, cấu hình tổ chức và sáu protection plan `ALL`, mọi
    account `ACTIVE` trừ `svp-security` là member, destination `PUBLISHING`.
  - `7a: Access Analyzer svp-org ACTIVE in <region>`: analyzer tổ chức.
  - `7a: Security Hub is CENTRAL ENABLED, …`: cấu hình tập trung; association của root và của account có `security_hub` `off`.
  - `7a: every source of the Config aggregator svp-org is SUCCEEDED, …`: sau khi bước (6) bật recorder; script bỏ qua nguồn của account
    có `config_recording` `off` (không recorder thì aggregator không nhận dữ liệu mới, không phải lỗi).
  - `7a: Inspector scans only ECR in …`: chỉ ECR bật; thành viên là account có `inspector_ecr` khác `off`.
- **Bẫy:** lần dựng đầu lệnh chạy trước bước (6), nên các kiểm cần `aws/baseline` báo `FAIL` là mong đợi:
  `FAIL  <profile> <region>: no Config recorder with CONTINUOUS recording` (hay `… is not recording …`) của `anhnv-security-ro` (account
  có `config_recording` `off` in `note … config_recording is off`), `FAIL  7a: Config aggregator sources not SUCCEEDED: …` và
  `FAIL  7a: rule svp-security-admin-sso not found …`. Bước (7) chạy lại `verify.sh org` sau bước (6), khi các dòng đó phải `ok`.
  Account mới có thể cần tới 24 giờ mới hiện đủ member (`PENDING` ở association cũng vậy): `FAIL` ở các dòng đó trong ngày đầu thì chạy
  lại sau.
- **Việc tay:** dòng `note  7a: Security score` chỉ bảng điều khiển của Security Hub trên console của `svp-security` (profile
  `anhnv-security-ro`), không có API đọc điểm: đọc bằng mắt.
- **Dán lại:** dòng `Plan:`, `Apply complete!`, mọi dòng `FAIL` và `note` của lệnh trên. Cảnh báo thử và phép thử guardrail ở bước (7).

`cd ../..` về `infra/` khi xong.

## Bước (6): `aws/baseline`

Baseline của mọi account và CMK EBS ([06. Baseline](../handbook/06-baseline.md)), sau (3) bucket Config, (4) SCP và profile
[4c](#4c-profile-của-account-thành-viên), (5) bus `svp-security-events` và email đã xác nhận. Account thêm vào tổ chức khi root đã áp
(như `svp-backup`): 6a, 6c, 6d, bỏ 6b; bucket Config và bus nhận account mới theo id tổ chức, không đổi policy.

### 6a. Biến và giá trị cá nhân

```sh
eval "$(aws/scripts/accounts.sh)"
aws/scripts/check-account.sh mgmt
cd aws/baseline
../scripts/tfvars.sh example aws/baseline
```

- **Mong đợi:** mỗi biến một dòng `ok    SVP_AWS_<…>_ACCOUNT_ID: account svp-<tên>, ACTIVE`; `ok    account … of mgmt, …`;
  `baseline.auto.tfvars` (mode 600) được chép khi chưa có, một dòng `note` mỗi giá trị còn `<…>`.
- **Việc tay:** sửa `sso_region` của `baseline.auto.tfvars` cho bằng `sso_region` của `aws/org/org.auto.tfvars`.
- **Bẫy:** `FAIL  no account svp-backup in the organization` và không đặt gì: làm [bước (4)](#bước-4-awsorg-đủ) trước (bước đó luôn
  tạo account này; plan của root đòi `backup_account_id` đủ 12 số).

### 6b. Kiểm cái đã có

Dịch vụ khác hay thao tác tay có thể đã tạo role, recorder của Config; đọc ngay trước plan (`svp-log-archive`, `svp-backup` chỉ root
qua role ghi, không cần đọc).

```sh
for p in anhnv-sso anhnv-security-ro anhnv-stg-ro anhnv-prd-ro; do echo "== $p"
  AWS_PROFILE=$p aws --no-cli-pager iam get-role --role-name AWSServiceRoleForConfig --query Role.Arn --output text --region us-east-1 2>&1 | tail -1
  for r in ap-southeast-1 us-east-1; do
    AWS_PROFILE=$p aws --no-cli-pager configservice describe-configuration-recorders --region $r --query 'ConfigurationRecorders[].name' --output text
  done
done
```

- **Mong đợi:** mỗi account một dòng `NoSuchEntity` và hai dòng rỗng.
- **Bẫy:** có role hay recorder: dừng, dán output; nhập chúng vào state bằng khối `import` trước plan, địa chỉ
  `module.<mgmt|security|stg|prd>.aws_iam_service_linked_role.config`, `…aws_config_configuration_recorder.this["<region>"]`,
  `…aws_config_delivery_channel.this["<region>"]`.

### 6c. Plan

```sh
../scripts/tfvars.sh init
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
  terraform plan -input=false -out=baseline.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color baseline.tfplan > "$SVP_SESSION_DIR/baseline-plan.txt"
```

- **Mong đợi:** với `aws/paid-features.json` của repo (`config_recording` tắt ở mọi account trừ `svp-security`) `Plan: <n> to add, 0 to
  change, 0 to destroy` với `<n>` bằng tổng `to add` của mục [`aws/baseline`](../reference/inventory.md#awsbaseline) ở inventory (bảng
  "Phần" chia theo `module.<account>` và key EBS). Mỗi account có `config_recording` `always` thêm 6 ở module của nó (recorder, delivery
  channel, trạng thái recorder của hai region). Root đã áp, thêm account mới: chỉ module của account đó, số là dòng `module.<account>` của
  bảng "Phần".
- **Kiểm:** `aws_ebs_default_kms_key` chỉ ở stg, prd, `key_arn` là key `svp-ebs` của chính account đó; `svp-security-root-signin` của
  mọi account ở ba region (`us-east-1`, `us-east-2`, `us-west-2`); `s3_kms_key_arn` của mọi delivery channel dạng `key/<id>`.
- **Bẫy:** `AccessDenied` khi assume role là account hay profile sai; lỗi đọc alias `alias/svp-log-archive` là bước (3) chưa áp. Có dòng
  `change` hay `destroy`: dừng, dán plan.

### 6d. Apply

```sh
AWS_PROFILE=anhnv-sso terraform apply -input=false baseline.tfplan && rm baseline.tfplan
AWS_PROFILE=anhnv-sso terraform output ebs_kms_key_arns
```

- **Mong đợi:** `Apply complete!`; `ebs_kms_key_arns` có hai ARN `arn:aws:kms:ap-southeast-1:<stg|prd>:key/<id>`. Account có cờ
  `config_recording` `off` không có recorder, delivery channel ở hai region: đúng ý.
- **Việc tay:** apply sinh email từ chính rule của nó: `svp-security-detection` (recorder, delivery channel; thiếu ở account nào chưa
  phải lỗi, rule có thể tạo sau recorder) và loạt thư `… PutRule`, `PutTargets` … `svp-terraform error .` (`error` trống là lời gọi
  thành công, chỉ ở apply đầu). Lọc Gmail theo tiêu đề `svp-terraform`; thư có `error` khác rỗng mới là lỗi.
- **Kiểm:** đường cảnh báo kiểm thật ở [7d](#7d-phép-thử-guardrail), [7e](#7e-cảnh-báo-thử). Đổi cờ sau lần đầu: theo thứ tự của
  [`paid-features.md`](paid-features.md#thứ-tự-apply-cờ).

`cd ../..` về `infra/` khi xong.

## Bước (7): kiểm sau áp

Sau bước (6) ít nhất 30 phút (GuardDuty, Security Hub nhận account có sẵn tới 24 giờ: chưa đủ thì đọc lại hôm sau); chỉ đọc, trừ 7d,
7e. Dán output từng mục, che 8 số đầu của account ID.

- **Việc tay:** console qua access portal, role `SvpReadOnly`: GuardDuty, Security Hub, Inspector xem ở `svp-security`. Nút "Get
  started", "Enable", "1-click setup" của chúng ở account khác: **không bấm**, nó tạo tài nguyên ngoài Terraform và tính tiền.

### 7a. Dịch vụ bật

Một lệnh đọc 7a, 7c và phần chỉ đọc của 7b. Cần profile `anhnv-sso`, `anhnv-security-ro`, `anhnv-stg-ro`, `anhnv-prd-ro`,
`anhnv-log-ro`, bốn biến account thành viên của [Mở terminal](#mở-terminal) và `aws/org` đã `init` (`aws/scripts/tfvars.sh init`).

```sh
aws/scripts/verify.sh org
```

- **Mong đợi:** mỗi kiểm một dòng `ok`, `FAIL` hay `note`; một `FAIL` không dừng kiểm sau, cuối cùng `FAIL  N check(s) failed, each
  named above` và exit 1. Trước mỗi nhóm `ok    profile <tên> is the account of <tên>`; dòng `FAIL` đó bỏ cả nhóm của profile ấy. Rồi:

| Dòng `ok` | Nghĩa |
| --- | --- |
| `7a: svp-security administers GuardDuty, Security Hub, Config, Access Analyzer and Inspector` | Sáu principal delegated admin |
| `7a: SCP, RCP, EC2 declarative and tag policies of the root and of OU Prod as aws/org declares them` | Root: SCP `FullAWSAccess` với năm SCP `svp-*`, RCP `RCPFullAWSAccess` với `svp-data-perimeter`, `svp-ec2-baseline`, `svp-tags`; OU `Prod`: `FullAWSAccess` với `svp-prod-guardrails` ([`org-policies`](../../aws/modules/org-policies/README.md)); lệch: `FAIL  7a: policies wrong (apply aws/org): <target> <type> is '<có>', not '<mong>'`; Backup policy ở `verify.sh backup` ([`backup-setup.md`](backup-setup.md)) |
| `7a: GuardDuty in <region>`, `Access Analyzer svp-org ACTIVE`, `Security Hub is CENTRAL ENABLED`, `every source of the Config aggregator`, `Inspector scans only ECR` | Như [5f](#5f-kiểm-nhanh); GuardDuty chỉ đòi `ALL` cho member và sáu feature của `local.guardduty_features` (`aws/security/guardduty.tf`), feature AWS thêm sau là `note  7a: GuardDuty in <region>: features outside aws/security, left as AWS sets them: …` |
| `7a: every ACTIVE account but svp-security is a Security Hub member as its cost flag says` | Account có `security_hub` `off` không là member |
| `7a: <profile> <region>: Security Hub standards and Config recorder as expected` | Hai chuẩn `READY`, recorder `CONTINUOUS` và `True SUCCESS` ở hai region của management, `svp-security`, stg, prd; account có cờ `off` thì `note` |
| `7a: rule svp-security-admin-sso ENABLED in the region of Identity Center` | Rule ở đúng `sso_region` của `org.auto.tfvars`, không thì im lặng |
| `7b: RootCredentialsManagement and RootSessions are on` | Root tập trung |
| `7c: trail svp-audit is logging with no delivery error` | `[true,null,null]` |
| `7c: the Log Archive bucket holds logs of every ACTIVE account, management included` | Đọc bằng `SvpLogReader`; sau bước (4) ít nhất một giờ |

- **Bẫy:** ngay sau apply, các dòng `… (Security Hub can take 24 h)`, `… (new accounts can take 24 h)`, `FAIL  7a: Security Hub member
  status wrong for: …` và `note  7a: Security Hub association PENDING for: …` là việc AWS chưa xong, tự hết trong tối đa 24 giờ; còn
  sau một ngày thì dán.
- **Bẫy:** account đã đóng mà chưa rời tổ chức làm association Security Hub của nó và của root `FAILED` (Security Hub không assume được
  service-linked role ở đó): `note  7a: Security Hub association FAILED for accounts not ACTIVE: …`, tự hết 90 ngày sau khi đóng. Mỗi
  account của dòng đó phải có ở lệnh dưới, `SUSPENDED`; `FAIL  7a: Security Hub configuration policy association not SUCCESS for: …`
  (account `ACTIVE`, hay `root(FAILED)` không account nào giải thích) là lỗi thật.

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager organizations list-accounts --region us-east-1 \
  --query "Accounts[?Status!='ACTIVE'].[Id,Name,Status,State]" --output text
```

- **Dán lại:** mọi `FAIL` khác (policy, cấu hình, delegated admin, trail) và lỗi quyền của profile chỉ đọc là lỗi thật: dừng, dán. Dòng
  `note`: `7a: control <id> FAILED …` là control FAILED ban đầu, việc sửa sau; `7c: last write to the old management trail bucket` không
  mới hơn apply bước (4) vài phút; `7a: Security score`: đọc trang Summary của Security Hub ở `svp-security` (không API), dán điểm.

### 7b. Root tập trung

Credential root của từng account kiểm tay: mỗi `sts assume-root` (task policy `IAMAuditRootUserCredentials`) mở một phiên root, gửi
một thư `svp-security-root-session` (7e); credential của phiên là bí mật, chỉ nằm trong subshell, không in ra.

```sh
for id in "$SVP_AWS_LOG_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID" "$SVP_AWS_STG_ACCOUNT_ID" "$SVP_AWS_PRD_ACCOUNT_ID"; do
  (
    creds=$(AWS_PROFILE=anhnv-sso aws --no-cli-pager sts assume-root --target-principal "$id" --region ap-southeast-1 \
      --task-policy-arn arn=arn:aws:iam::aws:policy/root-task/IAMAuditRootUserCredentials \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || exit 1
    read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_PROFILE
    printf '%s password: ' "${id: -4}"; aws --no-cli-pager iam get-login-profile --region us-east-1 2>&1 | grep -q NoSuchEntity && echo none || echo PRESENT
    printf '%s access keys: ' "${id: -4}"; aws --no-cli-pager iam list-access-keys --region us-east-1 --query 'length(AccessKeyMetadata)' --output text
    printf '%s mfa: ' "${id: -4}"; aws --no-cli-pager iam list-mfa-devices --region us-east-1 --query 'length(MFADevices)' --output text
  )
done
```

- **Mong đợi:** mỗi account `none`, `0`, `0`; `PRESENT` hay số khác `0`: dọn theo [`break-glass.md`](break-glass.md#gỡ).

### 7c. Trail

`verify.sh org` (7a) đọc trail `svp-audit` và bucket Log Archive; `get-trail-status` của [4b](#4b-apply) chỉ khi nó báo `FAIL  7c: …`.

### 7d. Phép thử guardrail

Giữ tay: mỗi probe là lệnh ghi mà guardrail phải từ chối, chọn sao cho không đổi gì nếu guardrail hỏng (`--dry-run`, giá trị đang có,
user tạm có lệnh xoá). Chạy bằng `SvpAdmin` (`anhnv-stg`, Spot bằng `anhnv-prd`); lệnh bị từ chối phải nói `explicit deny in a service
control policy`, lỗi EC2 chỉ có `Encoded authorization failure message` thì giải mã, mong `"explicitDeny":true`:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager sts decode-authorization-message --encoded-message <chuỗi> --region ap-southeast-1 --query DecodedMessage --output text |
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
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam create-user --user-name "$U" --region us-east-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam delete-user --user-name "$U" --region us-east-1        # hoàn tác
```

S3 Block Public Access cấp account, đúng bốn cờ `true` đang có (không cần hoàn tác):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3control put-public-access-block --account-id "$SVP_AWS_STG_ACCOUNT_ID" --region ap-southeast-1 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3control get-public-access-block --account-id "$SVP_AWS_STG_ACCOUNT_ID" --region ap-southeast-1 --output text
```

EBS mã hoá mặc định (`--dry-run` không đổi gì; `DryRunOperation` là guardrail hỏng); mong sau lệnh bị từ chối `True`, key mặc định là
ARN của key `alias/svp-ebs` của stg (lệnh CMK EBS dưới in ARN đó):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 disable-ebs-encryption-by-default --dry-run --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 get-ebs-encryption-by-default --region ap-southeast-1 --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 get-ebs-default-kms-key-id --region ap-southeast-1 --output text
```

CMK EBS (API không nhận alias: lấy ARN trước; không thử `disable-key`, `schedule-key-deletion`: guardrail hỏng thì volume mới hỏng);
mong `True` ở dòng cuối:

```sh
K="$(AWS_PROFILE=anhnv-stg aws --no-cli-pager kms describe-key --key-id alias/svp-ebs --region ap-southeast-1 --query KeyMetadata.Arn --output text)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager kms disable-key-rotation --key-id "$K" --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager kms enable-key-rotation --key-id "$K" --region ap-southeast-1 # hoàn tác
AWS_PROFILE=anhnv-stg aws --no-cli-pager kms get-key-rotation-status --key-id "$K" --region ap-southeast-1 --query KeyRotationEnabled --output text
```

Rule cảnh báo (probe của dịch vụ API JSON, mã `AccessDeniedException`); mong `ENABLED` ở dòng cuối:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager events disable-rule --name svp-security-trail --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager events enable-rule --name svp-security-trail --region ap-southeast-1 # hoàn tác
AWS_PROFILE=anhnv-stg aws --no-cli-pager events describe-rule --name svp-security-trail --region ap-southeast-1 --query State --output text
```

Spot ở prd (`--dry-run`: không instance nào được tạo dù guardrail hỏng; `DryRunOperation` là guardrail hỏng; lỗi khác hai mã của bảng,
ví dụ account không có VPC mặc định: dán lại, không kết luận):

```sh
aws/scripts/check-account.sh prd
AMI="$(AWS_PROFILE=anhnv-prd aws --no-cli-pager ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --region ap-southeast-1 --query Parameter.Value --output text)"
AWS_PROFILE=anhnv-prd aws --no-cli-pager ec2 run-instances --dry-run --image-id "$AMI" --instance-type t4g.nano --region ap-southeast-1 \
  --instance-market-options MarketType=spot --metadata-options HttpTokens=required
```

Declarative policy EC2 (chỉ đọc, ở stg):

```sh
for c in get-instance-metadata-defaults get-serial-console-access-status get-snapshot-block-public-access-state \
  get-image-block-public-access-state; do
  AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 "$c" --region ap-southeast-1 --output json
done
```

- **Mong đợi:** `HttpTokens` `required`, `HttpPutResponseHopLimit` `1`, `InstanceMetadataTags` `disabled`; serial console `false`;
  snapshot `block-all-sharing`; AMI `block-new-sharing`; mỗi kết quả có `ManagedBy` `declarative-policy`. Giá trị đủ ở
  [ADR-0059 §5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md#5-declarative-policy-ec2).

### 7e. Cảnh báo thử

Giữ tay: finding mẫu mức HIGH ghi vào GuardDuty của `svp-stg`, đi về `svp-security`, tới email qua rule `svp-security-findings` (cờ
`security_hub` của stg `always`) hay `svp-security-guardduty-findings` (`off`).

```sh
D="$(AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty list-detectors --region ap-southeast-1 --query 'DetectorIds[0]' --output text)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty create-sample-findings --detector-id "$D" --region ap-southeast-1 \
  --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS'
```

- **Mong đợi:** trong 30 phút sau 7d và lệnh trên, hộp thư `security_alert_email` có năm thư của năm probe chặn ở 7d (cột Email), bốn
  thư `AssumeRoot` của 7b và một thư finding `[SAMPLE] …` mức HIGH của stg; mỗi thư một dòng: sự kiện hay finding, account, region, URL
  [`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md). Dán tiêu đề, giờ nhận và
  nguyên văn một thư (che account).
- **Bẫy:** thiếu thư: đọc lại subscription ([5e](#5e-xác-nhận-email-sns)), dán lệnh của probe đó và giờ chạy; rule nguồn theo [ADR-0060
  phụ lục §10][adr0060-10]. Finding Inspector không tới email: đọc ở [Phép kiểm nền tảng
  managed](session-stg-check-managed.md#phép-kiểm-nền-tảng-managed), phép (a). Finding mẫu ở lại 90 ngày; đổi trạng thái theo
  `security-alert.md`.

### 7f. Chi phí sau 1 và 7 ngày

Sau 1 ngày và sau 7 ngày kể từ bước (5) (Cost Explorer trễ khoảng 24 giờ), theo dịch vụ, cả tổ chức; ngày dạng `yyyy-mm-dd`:

```sh
aws/scripts/verify.sh cost mgmt <ngày áp bước 5>
```

- **Mong đợi:** mỗi dòng `note  <ngày>  <dịch vụ>  <số> USD` cho GuardDuty, Security Hub, Config, KMS, S3, CloudTrail, cuối
  `ok    N row(s) from <ngày> to <hôm nay>, <tổng> USD`; chưa có dữ liệu thì `note  no cost data from … yet (Cost Explorer lags about
  24 hours)`. So với [ADR-0060 §12][adr0060-12].
- **Việc tay:** trong dùng thử (GuardDuty, Security Hub 30 ngày; Inspector 15; Config không có) hai dịch vụ ghi $0: đọc ước sau
  dùng thử ở trang "Usage" của chúng trên console `svp-security` (không API), dán cả hai (hai dòng `note` cuối nhắc). Monitor,
  subscription Cost Anomaly Detection và tag: hai lệnh của [1e](#1e-áp-thay-đổi-khi-state-đã-ở-bucket), mong `svp-services`, ba
  tag `Active` (`Env` chỉ sau buổi đầu, trước đó `Inactive`).
- **Bẫy:** `FAIL  ce get-cost-and-usage (first use: turn Cost Explorer on once in the console …)`: chỉ bật được trên console
  ([nguồn](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-enable.html)), một lần ở management bằng quyền ghi:
  **Billing and Cost Management** → **Cost Explorer** → **Launch Cost Explorer**; mọi account thành viên dùng được theo. Dữ liệu hiện
  sau khoảng 24 giờ. AWS tạo kèm monitor `Default-Services-Monitor`: nhận quản nó ở [1c](#1c-apply-lần-đầu-trên-state-local).

## Đồ ngoài Terraform

| Thứ | Vì sao còn | Khi nào dọn | Cách |
| --- | --- | --- | --- |
| OU `Development`, `Production` và hai account demo cũ (`SUSPENDED`) | account đã đóng, AWS giữ 90 ngày rồi tự đưa ra khỏi tổ chức | khi hai OU rỗng | [Xoá OU cũ](lab-teardown.md#xoá-ou-cũ) |
| SCP tạo tay từ trước khi có code | không có trong state | khi không còn gắn vào đâu | [Xoá SCP tạo tay](lab-teardown.md#xoá-scp-tạo-tay) |
| Key `alias/svp-cloudtrail` và bucket trail cũ ở management | Object Lock 365 ngày sau lần ghi cuối | sau khi khoá hết hạn; xoá sớm (bỏ qua retention) là mất lịch sử audit còn trong hạn | [Gỡ bucket trail cũ](lab-teardown.md#gỡ-bucket-trail-cũ) |

## Gỡ

Mọi root của runbook này sống suốt lab, không gỡ cuối buổi. Gỡ có chủ đích khi lab kết thúc, ngược thứ tự áp:
[`lab-teardown.md`](lab-teardown.md).

## Khi một bước đỏ

- Lỗi ở `plan`: không có gì đổi trên account; đọc lỗi, sửa nguyên nhân (biến terminal, file `.auto.tfvars`, phiên SSO), chạy lại đúng bước.
- `Error acquiring the state lock` kèm Lock ID (thường sau Ctrl+C một lệnh đang chờ nhập):
  [`operations.md`, Khoá state kẹt](../reference/operations.md#khoá-state-kẹt).
- Lỗi giữa `apply`: phần đã tạo nằm trong state; `plan` lại cùng root chỉ còn phần chưa tạo. Dán lỗi và plan mới trước khi apply lại;
  `-target`, áp code của PR chưa merge:
  [`operations.md`, Khi apply lỗi giữa chừng](../reference/operations.md#khi-apply-lỗi-giữa-chừng). Đọc plan gọn mà không để file lộ
  account ID: [`operations.md`, Đọc plan an toàn](../reference/operations.md#đọc-plan-an-toàn).
- Plan có `destroy` hay `-/+` ở tổ chức, account, bucket hay key có sẵn: dừng, không apply, dán plan. `-/+` lặp lại ở mọi plan là lỗi code.
- Mất đường vào (Identity Center hỏng, phiên SSO không đăng nhập được): [`break-glass.md`](break-glass.md).

## Nâng cấp tổ chức dựng trước

### Thêm service-linked role Access Analyzer vào tổ chức đã áp

Khi bước (4) đã chạy trước khi `aws/org` có role này (bước (5) lỗi `ConflictException` ở analyzer tổ chức): áp `aws/org` trước
`aws/security`, bằng lệnh `plan`, `apply` của [4a](#4a-plan), [4b](#4b-apply).

- **Mong đợi:** chỉ thêm một tài nguyên, `aws_iam_service_linked_role.access_analyzer`, không `destroy`; `1 to change` chỉ khi có thêm
  **Thay đổi được phép** của [4a](#4a-plan); khác thì dừng, dán plan.
- **Bẫy:** apply lỗi `Service role name AWSServiceRoleForAccessAnalyzer has been taken in this account` là role đã có (ai đó mở Access
  Analyzer trên console của management): đưa nó vào state thay vì tạo.

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
  terraform import -input=false aws_iam_service_linked_role.access_analyzer \
    "arn:aws:iam::$SVP_AWS_MGMT_ACCOUNT_ID:role/aws-service-role/access-analyzer.amazonaws.com/AWSServiceRoleForAccessAnalyzer"
```

- **Kiểm:** plan lần hai `No changes.`; rồi plan và apply lại `aws/security` ([5b](#5b-plan)).

### Thêm rule đăng nhập root ở us-east-2, us-west-2 vào tổ chức đã áp

Khi bước (6) đã áp lúc account thành viên chỉ có `svp-security-root-signin` ở `us-east-1`. CloudTrail ghi đăng nhập root ở `us-east-1`,
`us-east-2` hay `us-west-2` ([tra cứu đường cảnh báo](../reference/security-alerts.md#rule-chuyển-sự-kiện)), nên mọi account cần rule ở
cả ba. Thứ tự bắt buộc: `aws/org` trước, vì SCP `svp-deny-other-regions` cũ từ chối `events:PutRule` của account thành viên ở hai region
mới; `aws/baseline` chạy trước thì apply lỗi giữa chừng.

1. **`aws/org`: mở rule ở hai region trong SCP.**

   ```sh
   aws/scripts/check-account.sh mgmt
   cd aws/org
   AWS_PROFILE=anhnv-sso \
   TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
     terraform plan -input=false -out=org.tfplan
   AWS_PROFILE=anhnv-sso terraform show -no-color org.tfplan > "$SVP_SESSION_DIR/org-plan.txt"
   ```

   - **Mong đợi:** `Plan: 0 to add, 1 to change, 0 to destroy`, hay `2 to change` khi có thêm **Thay đổi được phép** của [4a](#4a-plan).
     Đổi tại chỗ duy nhất `module.org_policies.aws_organizations_policy.this["deny-other-regions"]`: `description` thêm "and the root
     sign-in rule aside"; `content` thêm các action `events:` của rule vào `NotAction` của `DenyOtherRegions` và statement mới
     `DenyOtherRegionsButRootSigninRule` với `NotResource` là `arn:aws:events:us-east-2:*:rule/svp-security-root-signin`,
     `arn:aws:events:us-west-2:*:rule/svp-security-root-signin`.
   - **Bẫy:** `destroy` hay `-/+` ở policy hay đích của nó, hay đổi ở policy khác: dừng, dán plan.

   ```sh
   AWS_PROFILE=anhnv-sso terraform apply -input=false org.tfplan && rm org.tfplan
   AWS_PROFILE=anhnv-sso \
   TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
     terraform plan -input=false
   cd ../..
   ```

   - **Mong đợi:** `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`, rồi `No changes.`; khác thì dán lại. Thư `UpdatePolicy`
     của rule `svp-security-org` là của chính lần apply này.

2. **`aws/baseline`: thêm rule ở hai region cho năm account thành viên.**

   ```sh
   eval "$(aws/scripts/accounts.sh)"
   aws/scripts/check-account.sh mgmt
   cd aws/baseline
   AWS_PROFILE=anhnv-sso \
   TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
   TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
   TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
   TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
   TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
   TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform plan -input=false -out=baseline.tfplan
   AWS_PROFILE=anhnv-sso terraform show -no-color baseline.tfplan > "$SVP_SESSION_DIR/baseline-plan.txt"
   ```

   - **Mong đợi:** không `change`, `destroy`; `to add` bằng số tài nguyên liệt kê: ở mỗi `module.log_archive`,
     `module.backup`, `module.security`, `module.stg`, `module.prd` bốn tài nguyên, `aws_cloudwatch_event_rule.forward` và
     `aws_cloudwatch_event_target.forward` khoá
     `"svp-security-root-signin/us-east-2"`, `"svp-security-root-signin/us-west-2"`; `module.mgmt` đã có cả ba region nên không đổi.
   - **Bẫy:** `AccessDeniedException` `explicit deny in a service control policy` là bước 1 chưa áp. `Backend initialization required`:
     `../scripts/tfvars.sh init` rồi plan lại. Có `change` hay `destroy`: dừng, dán plan.

   ```sh
   AWS_PROFILE=anhnv-sso terraform apply -input=false baseline.tfplan && rm baseline.tfplan
   AWS_PROFILE=anhnv-sso \
   TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
   TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
   TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
   TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
   TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
   TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform plan -input=false
   cd ../..
   ```

   - **Mong đợi:** `Apply complete! Resources: 20 added, 0 changed, 0 destroyed.`, rồi `No changes.`. Không có thư `PutRule`, `PutTargets`
     như ở [6d](#6d-apply): rule `svp-security-alert-rules` chỉ ở region nhà và `us-east-1`.

3. **Kiểm** từng account thành viên ở từng region của rule, bằng profile chỉ đọc (`ListTargetsByRule` là action SCP mở cho rule này; SCP
   không mở `ListRules`, `ViewOnlyAccess` của `anhnv-log-ro` không có `DescribeRule`):

   ```sh
   for p in anhnv-log-ro anhnv-security-ro anhnv-backup-ro anhnv-stg-ro anhnv-prd-ro; do
     for r in us-east-1 us-east-2 us-west-2; do echo "== $p $r"
       AWS_PROFILE=$p aws --no-cli-pager events list-targets-by-rule --rule svp-security-root-signin --region "$r" \
         --query 'Targets[].[Id,Arn]' --output text
     done
   done
   ```

   - **Mong đợi:** dưới mỗi dòng `==` đúng một dòng hai cột: `svp-security-events` và
     `arn:aws:events:ap-southeast-1:<security>:event-bus/svp-security-events` (`<security>` là `SVP_AWS_SECURITY_ACCOUNT_ID`). Dán lại
     output, che 8 số đầu của account ID.
   - **Bẫy:** `ResourceNotFoundException` là account đó chưa có rule ở region đó (bước 2 chưa áp, hay apply lỗi giữa chừng);
     `AccessDeniedException` `explicit deny in a service control policy` ở `us-east-2`, `us-west-2` là SCP của bước 1 chưa áp.

4. **Gỡ** (ngược thứ tự áp): revert code, rồi `aws/baseline` trước bằng lệnh plan, apply của bước 2 (mong `Plan: 0 to add, 0 to change,
   20 to destroy`, đúng hai rule và hai target ở mỗi account thành viên), rồi `aws/org` bằng lệnh của bước 1 (mong `1 to change` ở
   `deny-other-regions`). Đảo thứ tự thì SCP cũ chặn Terraform xoá rule ở `us-east-2`, `us-west-2`.

[adr0060-10]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#10-đường-cảnh-báo
[adr0060-12]: https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md#12-chi-phí-liên-tục
