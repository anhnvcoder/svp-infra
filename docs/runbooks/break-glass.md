# Runbook: break-glass

Đường vào khẩn cấp khi đường thường không đủ: Identity Center hỏng, việc chỉ root làm được ở một account thành viên, hay baseline bị SCP chặn
cần đổi gấp. Thiết kế: [ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) §2 (vai trò
triển khai baseline), §3 (bộ SCP), §7 (root tập trung, break-glass); cảnh báo ở
[ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §10.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account. Mỗi lần dùng một đường dưới đây sinh email tới `security_alert_email`
(cột Email ở từng mục): email tới mà không ai đang làm break-glass là sự cố, xử lý theo runbook
[`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md). Mỗi lần dùng kết thúc bằng mục
[Dọn sau khi dùng](#dọn-sau-khi-dùng).

## Đường vào thường và đường khẩn cấp

| Cần | Đường thường | Đường khẩn cấp |
| --- | --- | --- |
| Quản trị management (Terraform `aws/bootstrap`, `aws/org`, ba root qua role) | profile `anhnv-sso` (Identity Center) | root của management, MFA phần cứng: [Identity Center hỏng](#identity-center-hỏng) |
| Việc chỉ root làm ở account thành viên | không có: root thành viên không có credential | `sts:AssumeRoot` từ management: [Việc chỉ root làm](#việc-chỉ-root-làm-ở-account-thành-viên) |
| Đổi baseline (BPA, EBS mặc định, Config, rule `svp-security-*`, CMK EBS) | PR rồi apply `aws/baseline` | như đường thường; tháo SCP chỉ khi Terraform không làm được: [Đổi baseline bị SCP chặn](#đổi-baseline-bị-scp-chặn) |

Không tạo IAM user hay access key nào làm đường khẩn cấp, kể cả ở management (SCP `svp-deny-iam-users` không áp lên management, nhưng CIS AWS
Foundations v5.0.0 đòi root không có access key và người dùng vào qua danh tính tập trung).

## Identity Center hỏng

Dấu hiệu: AWS access portal không đăng nhập được, `aws sso login --profile anhnv-sso` lỗi, hay permission set, gán quyền của người học bị xoá,
sửa sai.

1. Đăng nhập console bằng **root của management** (email root, mật khẩu, MFA phần cứng cất ngoài máy). Không tạo access key cho root: root chỉ
   làm qua console.
2. Mở IAM Identity Center ở region của instance (`sso_region` của `aws/org/org.auto.tfvars`), sửa đúng chỗ hỏng: user bị khoá hay mất MFA
   (Users), gán `AdministratorAccess` của management cho user (AWS accounts), permission set `SvpAdmin`, `SvpReadOnly`, `SvpLogReader` và gán
   của chúng (Permission sets).
3. Đăng xuất root. Đăng nhập lại bằng `aws sso login --profile anhnv-sso --region us-east-1`, rồi `aws/scripts/check-account.sh mgmt`.
4. Đưa Identity Center về đúng code: plan `aws/org` (lệnh ở [README `aws/org`, Bước (4)](../../aws/org/README.md#bước-4-đủ-root)). Plan chỉ được
   đổi đúng phần vừa sửa tay; áp để state và account khớp, rồi plan lần hai `No changes.`.

Root không assume role được (console "Switch role" và `sts:AssumeRole` từ chối root), nên khi Identity Center hỏng thì account thành viên chưa
vào được tới bước 3. Identity Center của cả region ngừng: chờ AWS khôi phục; root của management chỉ làm việc ở management.

| Bước | Email (rule, account) |
| --- | --- |
| Root đăng nhập console | `svp-security-root-signin`, management (CloudTrail ghi ở `us-east-1`, `us-east-2` hay `us-west-2`) |
| Sửa permission set, gán quyền | `svp-security-admin-sso`, management, region của Identity Center |
| Sửa user, MFA | không email riêng (rule `svp-security-admin-sso` chỉ bắt lệnh permission set và gán quyền); email đăng nhập root ở trên là dấu vết |

## Việc chỉ root làm ở account thành viên

Root của `svp-log-archive`, `svp-security`, `svp-stg`, `svp-prd` không có mật khẩu, access key, MFA (root tập trung). Việc chỉ root làm đi qua
`sts:AssumeRoot` từ management: phiên tối đa 15 phút, giới hạn bởi một task policy do AWS quản
([IAM User Guide: root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html)):

| Task policy | Dùng khi |
| --- | --- |
| `IAMAuditRootUserCredentials` | đọc root có mật khẩu, access key, MFA không (lệnh ở [`org-security-setup.md`, 7b](org-security-setup.md#7b-root-tập-trung)) |
| `S3UnlockBucketPolicy` | bucket policy sai khoá mọi principal, kể cả admin: xoá policy đó |
| `SQSUnlockQueuePolicy` | queue policy sai khoá mọi principal: xoá policy đó |
| `IAMCreateRootUserPassword` | việc cần đăng nhập root đầy đủ (danh sách "Tasks that require root user credentials" của IAM User Guide): cho phép khôi phục mật khẩu |
| `IAMDeleteRootUserCredentials` | dọn: xoá mật khẩu, access key, chứng chỉ ký, MFA của root |

Làm từ console của management bằng `anhnv-sso` (permission set `AdministratorAccess` có `sts:AssumeRoot`): IAM, **Root access management**,
chọn account, **Take privileged action**, chọn việc. Trước đó kiểm account của phiên:

```sh
aws/scripts/check-account.sh mgmt
```

Việc cần đăng nhập root đầy đủ:

1. **Take privileged action**, **Allow password recovery** (task `IAMCreateRootUserPassword`).
2. Trang đăng nhập root, email root của account (`account_emails` của `org.auto.tfvars`), **Forgot password**, đặt mật khẩu từ thư AWS gửi tới
   email đó. Console đòi đăng ký MFA thì đăng ký; bước dọn xoá nó.
3. Làm đúng việc cần làm, đăng xuất.
4. Dọn ngay: mục [Dọn sau khi dùng](#dọn-sau-khi-dùng).

**Vì sao `svp-deny-iam-users` không chặn bước 1.** SCP áp lên cả root của account thành viên. Statement của nó chặn `iam:CreateLoginProfile`
chỉ trên `arn:aws:iam::*:user/*`; task `IAMCreateRootUserPassword` gọi đúng hành động đó trên `arn:aws:iam::<id>:root`, ARN không khớp, nên
task chạy ([phụ lục ADR-0059 §3](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0059-org-structure-guardrails.md#svp-deny-iam-users)).
SCP khác vẫn áp lên phiên root: việc root cần mà `svp-protect-baseline`, `svp-deny-other-regions` hay `svp-prod-guardrails` chặn thì đi theo
mục dưới.

| Bước | Email (rule, account) |
| --- | --- |
| Mỗi `AssumeRoot` (mỗi privileged action) | `svp-security-root-session`, management, chỉ khi gọi ở `ap-southeast-1` hay `us-east-1` |
| Root thành viên đăng nhập console | `svp-security-root-signin`, account đó, `us-east-1` |
| Root thành viên thử việc mà SCP chặn | `svp-security-denied-*`, account đó |

`AssumeRoot` gọi ở region khác hai region trên không sinh email (ADR-0060, Hệ quả): lệnh CLI luôn ghi `--region ap-southeast-1`.

## Đổi baseline bị SCP chặn

SCP `svp-protect-baseline` chặn mọi principal của account thành viên, kể cả `SvpAdmin` và root, đổi baseline; chỉ
`OrganizationAccountAccessRole` (vai trò triển khai baseline, chỉ management assume được) được miễn. Đường đổi baseline vì thế luôn là:

1. PR sửa `aws/baseline` (bảng `local.accounts`) hay module `security-baseline`, `make check` xanh, merge.
2. Plan, apply `aws/baseline` theo [README của root](../../aws/baseline/README.md#apply-lần-đầu) (cùng lệnh `plan`, `apply` với biến của năm
   account).

Đổi gấp không chờ được PR: apply từ nhánh local đã sửa (cùng lệnh), rồi mở PR với đúng thay đổi đó trong ngày. Không đổi baseline bằng
console hay CLI qua `OrganizationAccountAccessRole`: state lệch và plan sau đòi đổi ngược.

**Tháo SCP** chỉ khi việc cần làm không phải tài nguyên của Terraform (ví dụ root thành viên làm một việc mà SCP chặn). Management không chịu
SCP nên tháo được từ `anhnv-sso`; tháo đúng một policy khỏi đúng một đích, làm việc, gắn lại bằng Terraform. SCP `svp-*` gắn ở root của
org, trừ `svp-prod-guardrails` gắn ở OU `Prod`:

```sh
aws/scripts/check-account.sh mgmt
R="$(AWS_PROFILE=anhnv-sso terraform -chdir=aws/org output -raw root_id)"
P="$(AWS_PROFILE=anhnv-sso terraform -chdir=aws/org output -json organizational_unit_ids | jq -r .Prod)"
for T in "$R" "$P"; do
  echo "== $T"
  AWS_PROFILE=anhnv-sso aws organizations list-policies-for-target --target-id "$T" --filter SERVICE_CONTROL_POLICY --region us-east-1 \
    --query 'Policies[].[Name,Id]' --output text
done
AWS_PROFILE=anhnv-sso aws organizations detach-policy --policy-id <p-… của policy cần tháo> --target-id <id đích in policy đó: $R hay $P> \
  --region us-east-1
```

Xong việc: plan `aws/org` (README, Bước (4)) chỉ có một `aws_organizations_policy_attachment` cần tạo lại; apply, rồi plan lần hai
`No changes.`. Không sửa nội dung SCP bằng console; đổi statement thì PR ở module `org-policies`.

| Bước | Email (rule, account) |
| --- | --- |
| `detach-policy`, gắn lại khi apply | `svp-security-org`, management, `us-east-1` |
| Apply `aws/baseline` đổi Config, rule | `svp-security-detection`, `svp-security-alert-rules`, account bị đổi |

## Dọn sau khi dùng

1. Root thành viên đã có mật khẩu (mục Việc chỉ root làm): **Take privileged action**, **Delete root user credentials** (task
   `IAMDeleteRootUserCredentials`) cho account đó, rồi đọc lại bằng vòng `IAMAuditRootUserCredentials` của
   [`org-security-setup.md`, 7b](org-security-setup.md#7b-root-tập-trung): mỗi account `none`, `0`, `0`.
2. SCP đã tháo: gắn lại như mục trên; plan `aws/org` `No changes.`.
3. Root của management đã đăng nhập: đăng xuất; MFA phần cứng cất lại chỗ cũ.
4. Plan `aws/org`, `aws/baseline` (lệnh ở README) đều `No changes.`.
5. Đối chiếu email nhận được với các bước đã làm: mỗi email có một bước sinh ra nó. Email không ứng với bước nào xử lý theo `security-alert.md`.
6. Ghi lại: lý do, mốc UTC từng bước, account bị chạm, email nhận được, vào postmortem
   (`docs/postmortems/` của repo code) khi dùng vì sự cố, hay vào mô tả PR khi dùng cho thay đổi có kế hoạch.
