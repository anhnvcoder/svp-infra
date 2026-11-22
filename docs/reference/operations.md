# Vận hành Terraform: account, profile, biến, script

Trang này tra cách chạy Terraform và script của repo từ máy: account và profile của mỗi root, biến account, region, backend, script của
`aws/scripts/`, cách đọc plan và xử lý apply lỗi. Thứ tự dựng và từng bước ở [mục lục runbook](../runbooks/README.md); lý do thiết kế ở
[handbook](../handbook/README.md); luật cho agent ở [`AGENTS.md`](../../AGENTS.md).

## Ai chạy

Chỉ người học chạy lệnh chạm account, từ máy, bằng SSO, theo script và runbook của repo. Trước mọi lệnh ghi:
`aws/scripts/check-account.sh mgmt|stg|prd` (`aws sts get-caller-identity` với profile của chính account đó) và so account. Provider
của root ghim account bằng `allowed_account_ids` từ `TF_VAR_account_id` (root chạy qua role: từ biến id của account đích). Xem trước toàn
bộ lệnh của một buổi, không chạy gì và không cần credential: `aws/scripts/session.sh --print stg` (hay `prd`).

## Account và profile

Mỗi account một biến chứa 12 số của account, nạp qua direnv ([Biến account và direnv](#biến-account-và-direnv)); mọi lệnh viết sẵn ghi
profile ngay trong lệnh, `TF_VAR_account_id` từ biến của account mà profile vào, và `--region`:

| Account | Profile ghi | Profile chỉ đọc | Biến account | Root |
| --- | --- | --- | --- | --- |
| management (account sandbox) | `anhnv-sso` | — | `SVP_AWS_MGMT_ACCOUNT_ID` | `aws/bootstrap`, `aws/org`, `aws/log-archive`, `aws/security`, `aws/baseline`, `aws/backup`, `github/` |
| `svp-log-archive` | — (qua management) | `anhnv-log-ro` | `SVP_AWS_LOG_ACCOUNT_ID` | không root riêng |
| `svp-security` | — (qua management) | `anhnv-security-ro` | `SVP_AWS_SECURITY_ACCOUNT_ID` | không root riêng |
| `svp-backup` | — (qua management) | `anhnv-backup-ro` | `SVP_AWS_BACKUP_ACCOUNT_ID` | không root riêng |
| `svp-stg` | `anhnv-stg` | `anhnv-stg-ro` | `SVP_AWS_STG_ACCOUNT_ID` | `aws/accounts/stg`, `aws/envs/stg`, `aws/gitops/stg` |
| `svp-prd` | `anhnv-prd` | `anhnv-prd-ro` | `SVP_AWS_PRD_ACCOUNT_ID` | `aws/accounts/prd`, `aws/envs/prd`, `aws/gitops/prd` |

Profile ghi bằng `aws/scripts/sso-profiles.sh write`; script buổi lấy profile và account từ [bảng env](#bảng-env-của-libsh) của
`aws/scripts/lib.sh`.

**Profile AWS không nằm trong code** (khuyến nghị của HashiCorp và AWS: thông tin đăng nhập là của môi trường chạy, không của cấu hình; CI
cần credential thì dùng OIDC, máy khác đặt tên profile khác). Code chỉ chặn nhầm account bằng `allowed_account_ids = [var.account_id]`.

## Root chạy từ management qua role

`aws/log-archive`, `aws/security`, `aws/baseline`, `aws/backup` chạy bằng `anhnv-sso` với `TF_VAR_account_id` của management; provider
của mỗi account đích assume `OrganizationAccountAccessRole` của account đó, `allowed_account_ids` đúng account đó, id từ
`TF_VAR_<log_archive|security|backup|stg|prd>_account_id` đặt trong lệnh từ biến tương ứng. Account của OU `Security` (`svp-log-archive`,
`svp-security`, `svp-backup`) không có profile ghi, bucket state riêng hay root chạy trong chính nó: baseline và vault áp từ một chỗ, như
execution role của Control Tower.

Root `aws/envs/<env>` cần thêm `SVP_AWS_LOG_ACCOUNT_ID` (tên bucket flow log, log WAF và ARN delivery destination của log CloudFront ở
account Log Archive) và `SVP_AWS_BACKUP_ACCOUNT_ID` (account mà key RDS cho dùng khi copy snapshot của AWS Backup); `tf.sh` đặt
`TF_VAR_log_archive_account_id`, `TF_VAR_backup_account_id` từ chúng và dừng khi rỗng. Root `aws/accounts/<env>` nhận
`TF_VAR_backup_account_id` trong lệnh của README root đó (key policy của key vault env).

## Biến account và direnv

Mọi thiết lập shell cá nhân của svp nằm ở một chỗ: file `.envrc` của [direnv](https://direnv.net/) ở thư mục chứa các bản clone (thư mục
cha của `infra/`, `backend/`, `labs/`…; không phải git repo nên không có đường commit). File chỉ chứa `export SVP_AWS_<…>_ACCOUNT_ID=…` của
từng account (`MGMT`, `STG`, `PRD`; `LOG`, `SECURITY`, `BACKUP` khi đã có) và mặc định `AWS_PROFILE=anhnv-sso`, `AWS_REGION=ap-southeast-1`;
không `TF_VAR_*` nào. Lý do: ID account không được nằm trong cây repo public, một chỗ dùng chung cho mọi repo của lab, và không phải gõ lại
biến mỗi buổi. direnv tìm `.envrc` ngược lên các thư mục cha, nên mọi repo bên dưới đều nạp nó. Vì direnv chỉ dùng file gần nhất, repo
không giữ `.envrc` riêng: một file trong repo sẽ che file chung.

Tạo file lần đầu (đọc 12 số trên trang SSO; chỉ ghi các account đã có, thêm dòng còn thiếu khi account được tạo), rồi cho direnv tin nó:

```sh
cd <thư mục chứa các bản clone>
touch .envrc && chmod 600 .envrc
cat > .envrc <<'ENV'
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số>
export SVP_AWS_STG_ACCOUNT_ID=<12 số>
export SVP_AWS_PRD_ACCOUNT_ID=<12 số>
export AWS_PROFILE=anhnv-sso
export AWS_REGION=ap-southeast-1
ENV
direnv allow
```

direnv chỉ nạp file đã được tin: sau mỗi lần sửa `.envrc`, chạy `direnv allow` rồi kiểm bằng
`printf '%s\n' "${SVP_AWS_STG_ACCOUNT_ID: -4}"` (4 số cuối).

**Mọi `TF_VAR_*` nằm trong lệnh**, không trong file: lệnh viết sẵn ghi từng biến mà root của nó cần, mỗi biến một dòng, từ biến
`SVP_AWS_*` tương ứng (`TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID"`, `TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID"`…), hay
script đặt chúng (`tf.sh`). Biến bắt buộc của một root là các biến không `default` trong `variables.tf` của nó. Lý do: đọc lệnh là thấy
đủ giá trị root nhận, và `TF_VAR_account_id` đổi theo root (mỗi root thuộc một account, lệnh đặt nó từ biến của account mà profile vào).
Lệnh thiếu một biến dừng ở lỗi `No value for required variable` nhờ `-input=false` ([Đọc plan an toàn](#đọc-plan-an-toàn)).

`SVP_AWS_MGMT_ACCOUNT_ID` luôn gõ tay vào file, không lấy từ Organizations: đó là giá trị mà `check_account` của mọi script đối chiếu với
account thật của `anhnv-sso`. Biến của account thành viên (kể cả `LOG`, `SECURITY`, `BACKUP`) kiểm và đặt lại bằng
`eval "$(aws/scripts/accounts.sh)"`: lệnh đọc Organizations, đặt biến trong terminal hiện tại và in `ok` mỗi biến; chép giá trị vào file
khi cần giữ sang buổi sau.

Lệnh viết sẵn và script vẫn ghi profile và `--region` trong lệnh (ghi đè mặc định của file); lệnh tay ở account thành viên phải ghi
profile. Mọi lệnh `aws` trao người học còn có `--no-cli-pager` ngay sau `aws` (AWS CLI v2 mở `less` khi output dài và vòng lặp dừng ở
`(END)` mỗi lượt); script của `aws/scripts/` đặt `AWS_PAGER=""` trong `lib.sh`. `SVP_SESSION_DIR` vẫn export mỗi buổi, từ thư mục `infra/`
(`export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"`): script từ chối đường dẫn ngoài `infra/.session/`, nơi duy nhất git
bỏ qua cho file của buổi.

## Region

`ap-southeast-1` cho dịch vụ theo region và STS, `us-east-1` cho Organizations, IAM, Cost Explorer, WAF, cert ACM và log chuẩn của
CloudFront (delivery destination ở `aws/log-archive`, delivery source và delivery ở account env), KMS key, alarm và query log của DNSSEC
Route 53, Pricing Plan Manager và API Free Tier, region của instance Identity Center cho `sso-admin`, `identitystore`. Lệnh không dựa vào
region của profile.

## Terraform và backend

Terraform của máy (Homebrew) phải nằm trong `required_version` của root. Backend S3, khoá bằng lock file native của S3 (`use_lockfile`):
root của management đọc `aws/backend.hcl` (sinh từ output `backend_hcl` của `aws/bootstrap`); root của account thành viên đọc
`aws/backend-<env>.hcl` (sinh từ output `backend_hcl` của `aws/accounts/<env>`, có bucket, region, KMS, không có `key`) cộng một
`-backend-config=key=<key của root>` thứ hai, `init -reconfigure` (script buổi `tf.sh` làm vậy). Không file nào trong hai loại được commit.

### Khoá state kẹt

Lệnh `plan`, `apply` giữ một lock file cạnh state của root trong bucket tới khi xong. Lệnh bị ngắt giữa chừng (Ctrl+C một `plan` đang chờ
nhập biến, terminal đóng) có thể để lock file lại; lệnh sau ở cùng root dừng ở:

```text
Error: Error acquiring the state lock
…
Lock Info:
  ID:        <Lock ID>
  Operation: OperationTypePlan
  Who:       <user>@<máy>
```

1. Kiểm không còn lệnh Terraform nào giữ khoá: `pgrep -fl terraform`. Dòng `terraform-ls` (language server của editor) không giữ khoá, bỏ
   qua. Dòng `terraform plan`, `apply` nào khác là lệnh còn chạy: chờ nó xong hay dừng nó ở terminal của nó, không gỡ khoá. `Who` là máy
   khác thì lệnh chạy ở đó: hỏi người chạy, không gỡ.
2. Gỡ khoá trong thư mục root, với cùng profile và biến của lệnh bị kẹt (ví dụ root `aws/org`):

   ```sh
   AWS_PROFILE=anhnv-sso \
   TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
     terraform force-unlock -force <Lock ID>
   ```

- **Mong đợi:** `Terraform state has been successfully unlocked!`; rồi chạy lại đúng lệnh bị kẹt, theo khuôn có `-input=false`
  ([Đọc plan an toàn](#đọc-plan-an-toàn)).
- **Bẫy:** gỡ khoá khi một lệnh khác còn chạy là cho hai lệnh cùng ghi một state; state hỏng thì lấy bản trước từ versioning của bucket.

## Script của `aws/scripts/`

Hai nhóm, dùng chung `lib.sh`, chạy từ terminal của máy Mac (bash 3.2 là đủ):

- **Script buổi** chạy theo thứ tự ở runbook [`session-stg.md`](../runbooks/session-stg.md) và
  [`session-prd.md`](../runbooks/session-prd.md); `session-test.sh` thử mọi bước của buổi.
- **Script dựng** thay lệnh gõ tay của các runbook dựng một lần (`sso-profiles.sh`, `accounts.sh`, `platform-member.sh`, `tfvars.sh`,
  `verify.sh`, `preflight.sh`, `cache-secrets.sh`, `grafana-tokens.sh`); bảng việc và runbook dùng chúng ở
  [mục lục runbook](../runbooks/README.md). Mỗi script dựng có test `<tên>-test.sh` cạnh nó.

`profiles.sh` (bảng profile của các account ngoài env của buổi, nạp sau `lib.sh`) và `testlib.sh` (bộ chung của các `*-test.sh`) là thư
viện dùng chung, không chạy riêng. `make session-test` chạy mọi test với `aws`, `terraform`, `gh` giả.

Mỗi script nhận `--print` làm đối số đầu để in, theo thứ tự, mọi lệnh nó sẽ chạy rồi không chạy lệnh nào: không gọi `aws`, `kubectl`,
`helm`, `terraform`, `make`, `git`, `nc` hay `dig`, không đọc gì từ account và không ghi gì. Mọi lệnh chạm AWS mang profile và region
ngay trong lệnh (`AWS_PROFILE=anhnv-stg ... --region ap-southeast-1`), không qua biến shell mà người đọc phải tra. Mỗi bước in một dòng:
`ok`, `FAIL` (script dừng), `note` hay `skip`. Không giá trị bí mật nào được in hay ghi vào file.

### Bảng env của `lib.sh`

`env_table` mỗi env một dòng và là nơi duy nhất các env khác nhau: không script nào rẽ nhánh theo tên env, script đọc các trường của dòng:

| Trường | Nghĩa |
| --- | --- |
| `name` | đối số của script; cluster, kubectl context và các root Terraform mang tên này |
| `profile` | AWS profile (IAM Identity Center) của account của env, người học ghi bằng `aws/scripts/sso-profiles.sh write` |
| `account` | biến chứa 12 số của account đó, nạp qua direnv từ `.envrc` ở thư mục chứa các clone, không bao giờ trong file commit |
| `zone` | `1` khi account có hosted zone, tên là `zone_name` của `aws/accounts/<name>/<name>.auto.tfvars` (`env_zone`); `-` khi không có |
| `kept` | tag `Stack` của thứ ở lại account giữa các buổi (`sweep.sh`), cách nhau bằng dấu phẩy |
| `tunnel` | cổng local của tunnel SSM tới endpoint API private; `-` khi endpoint public |
| `teardown` | file của `aws/envs/<name>` nhấc các bảo vệ mà destroy cần; `-` khi không có |
| `ladder` | `1` khi `measure.sh` chạy thang k6 sau smoke; `-` khi chỉ có smoke và seed |
| `session` | `1` khi env có ba root của buổi, `aws/accounts/<name>`, `aws/envs/<name>` và `aws/gitops/<name>` |

### `bootstrap.sh`

Mỏng có chủ đích: secret và GlitchTip là target `make` của repo code, Argo CD là của Terraform; script chỉ chạy chúng theo thứ tự, có kiểm
account và có giới hạn cho mỗi lần chờ. `secrets` chạy sau `tf.sh <env> env apply` và trước root gitops (nguồn của các Secret trong
cluster có trước Argo CD); `wait` chạy sau `tf.sh <env> gitops apply`. Luồng secret của env:
chương [10. EKS](../handbook/10-eks.md).

### `tf.sh`

`tf.sh <env> env|gitops|account <thao tác>` chạy Terraform của ba root buổi (`env`, `gitops`, `account`); dòng `Usage` đầu file liệt kê đủ
thao tác và cờ. Mọi thao tác kiểm account trước và đặt `TF_VAR_*` của root. Root env có thêm hai thao tác sửa state bằng tay, dùng khi
khôi phục RDS thay chỗ (instance cũ đổi tên, bản khôi phục mang tên cũ, state vẫn trỏ instance cũ); mỗi thao tác ghi một mốc vào timeline
của buổi:

| Thao tác | Lệnh Terraform | Mốc timeline |
| --- | --- | --- |
| `tf.sh <env> env state-rm <địa chỉ>` | `terraform state rm <địa chỉ>` | `env-state-rm` |
| `tf.sh <env> env import <địa chỉ> <id>` | `terraform import -input=false -var-file=<env>.tfvars <địa chỉ> <id>` | `env-import` |

Địa chỉ đi nguyên một đối số (giữ `[` và `"` của khoá `for_each`). Root gitops và root account từ chối cả hai; không có thao tác state nào
khác (`mv`, `pull`, `push`, `list`). Sau `import`, `tf.sh <env> env plan` không được thay (replace) hay xoá instance vừa nhập; nó vẫn sửa
tại chỗ các thiết lập mà bản khôi phục không mang theo (tag, `copy_tags_to_snapshot`, monitoring, deletion protection,
`skip_final_snapshot`, `delete_automated_backups`). Đọc plan rồi `tf.sh <env> env apply` để đưa chúng về như code.

`tf.sh <env> account init|plan --open|plan --close|apply` chạy root `aws/accounts/<env>` trong buổi: `plan --open` plan với
`-var session_open=true` (phần của cờ `session` của env trong `aws/paid-features.json`, như workspace AMG), `plan --close` với `false`,
`apply` áp plan đã lưu và ghi mốc `account-open-applied` hay `account-close-applied`. `env plan` từ chối tới khi phần đó mở, `plan --close`
tới khi root env đã destroy; env không có cờ `session` thì mọi lệnh `account` in `ok no session feature …` và không chạy gì.

## Đọc plan an toàn

Mọi lệnh `terraform plan`, `apply` trần mà runbook hay README trao để dán theo một khuôn (ví dụ root `aws/backup`, trong thư mục root):

```sh
AWS_PROFILE=anhnv-sso \
TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
  terraform plan -input=false -out=backup.tfplan
AWS_PROFILE=anhnv-sso terraform show -no-color backup.tfplan > "$SVP_SESSION_DIR/backup-plan.txt"
```

- **Mỗi biến môi trường một dòng**, cuối dòng là `\`: một dòng dài bị terminal cắt khi dán thì mất `TF_VAR_*` ở cuối mà không báo gì.
- **`-input=false`**: thiếu biến bắt buộc thì plan dừng ngay ở lỗi thay vì ngồi chờ nhập (chạy qua `| grep` thì không thấy câu hỏi);
  Ctrl+C một lệnh đang chờ để lại [khoá state kẹt](#khoá-state-kẹt).
- **`-out` rồi `terraform show`**: bản văn bản đủ của plan vào thư mục của buổi, để đọc hết trước khi apply.
- **`apply` chỉ nhận file plan đã đọc**: `AWS_PROFILE=anhnv-sso terraform apply -input=false backup.tfplan && rm backup.tfplan`. File plan
  giữ giá trị biến của lượt plan, nên lệnh apply chỉ cần profile.
- **Plan kiểm `No changes.`** sau apply cùng dạng, không `-out`. `terraform destroy` trần cũng đi qua plan: `terraform plan -destroy
  -input=false -out=<tên>-destroy.tfplan`, `show` ra `"$SVP_SESSION_DIR/<tên>-destroy-plan.txt"`, rồi apply file đó.
- Lệnh qua `aws/scripts/tf.sh` đã làm đủ những điều trên.

File `.tfplan` được git bỏ qua. Bản văn bản chỉ ghi vào `$SVP_SESSION_DIR` (dưới `infra/.session/`, git bỏ qua): `.txt` ở chỗ khác trong
repo là để lộ account ID và tên tài nguyên vào cây repo public. Dòng mỗi tài nguyên đổi và dòng tổng:

```sh
grep -E '^\s*# .* (will|must) be|^Plan:' "$SVP_SESSION_DIR/<tên>-plan.txt"
```

Mong đợi: mỗi dòng `# <địa chỉ> will be created|updated in-place|destroyed` hay `must be replaced`, cuối cùng `Plan: N to add, N to change,
N to destroy`. So với số mong đợi ở README của root rồi mới apply.

## Khi apply lỗi giữa chừng

1. Đọc lỗi, đừng apply lại ngay. Phần đã tạo nằm trong state; `plan` lại cùng root chỉ còn phần chưa tạo.
2. Áp phần không lỗi bằng `-target=<địa chỉ>` khi cần. `-target` kéo theo mọi thứ địa chỉ đó phụ thuộc: attachment phụ thuộc cả resource
   policy của nó, nên target attachment kéo theo policy đang lỗi và lỗi lại.
3. Áp code của một PR chưa merge (để thử bản sửa): `git switch --detach origin/<nhánh>`, apply, rồi `git switch main`. Không tạo nhánh
   cục bộ cho việc này, và chỉ apply từ `main` sau khi PR đã merge.
4. Dòng `-/+` (thay thế) lặp lại ở mọi plan dù đã apply là lỗi code: chênh lệch vĩnh viễn giữa code và nơi chạy. Không apply, dán plan
   và báo để sửa code.

Runbook của từng bước trỏ về đây ở mục "Khi một bước đỏ".
