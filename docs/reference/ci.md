# GitHub Actions

Trang này tra workflow của `svp-infra`: chạy khi nào, job nào, check nào bắt buộc, lệnh `make` tương ứng; rồi chi tiết của plan trên PR
(root được plan, bỏ qua, giá trị che, comment, duyệt lượt chờ, quyền của role) và chi phí trên PR (job, project, giới hạn). Vì sao CI
như vậy và kịch bản một PR đi qua nó: [14. CI](../handbook/14-ci.md).

## Workflow

| Workflow | Chạy khi | Job | Bắt buộc | Lệnh `make` tương ứng |
| --- | --- | --- | --- | --- |
| `check.yml` | mọi PR, push `main` | `changes`, `check (<nhóm>)` mỗi nhóm `check-*` một job, `docs`, `infra-ok` | `infra-ok` | `make check-<nhóm>`, `make docs-check diagrams-check`; cả bộ `make check` |
| `pr-title.yml` | PR mở, sửa, mở lại, push | `pr-title` | `pr-title` | không có: regex và bộ thử nằm trong workflow |
| `plan.yml` | PR (cả PR fork: `gate` ra `[]` kèm notice) đổi `aws/**`, `ci/**`, `Makefile`, chính file đó; job `plan` chỉ với PR từ chính repo | `gate`, `plan (<env>)`, `plan-comment` | không | `make ci-plan ENV=<env>` (chỉ trong Actions); `make ci-plan-test` |
| `cost.yml` | PR đổi `aws/**`, `ci/**`, `Makefile`, `infracost.yml`, `infracost-usage.yml`, chính file đó | `infracost`, `infracost-comment` | không | `make infracost BASE=<cây base>`, `make infracost-comment`; `make infracost-test` |
| `scorecard.yml` | push `main`, lịch tuần, `branch_protection_rule` | `analysis` | không (không chạy trên PR) | không có |

Nhóm `check-*` và target của mỗi nhóm: `Makefile` (`make help`); bảng lệnh: [`checks.md`](checks.md#bảng-lệnh). Check bắt buộc là của
ruleset `main` (`github/rulesets.tf`). Nguồn sự thật của trigger, quyền và job là chính file trong `.github/workflows/`.

## Tệp của CI

| Tệp | Nội dung |
| --- | --- |
| `.github/workflows/check.yml` | PR và push `main`: mỗi nhóm `check-*` một job song song (bỏ qua khi PR chỉ tài liệu), job `docs`; `infra-ok` |
| `.github/workflows/plan.yml` | PR đổi `aws/`, `ci/`, `Makefile`: `terraform plan` bằng role chỉ đọc qua OIDC, comment tóm tắt đã che |
| `.github/workflows/cost.yml` | PR đổi `aws/`, `ci/`, `Makefile`, `infracost*.yml`: chi phí tháng của HCL ở base và ở PR, comment diff |
| `.github/workflows/pr-title.yml` | PR: tiêu đề theo Conventional Commits (check `pr-title`) |
| `.github/workflows/scorecard.yml` | push `main` và lịch tuần: OpenSSF Scorecard, kết quả công khai và lên code scanning |
| `.github/zizmor.yml` | ngoại lệ của zizmor, mỗi mục một lý do (có khi có ngoại lệ đầu tiên) |
| `infracost.yml` | project Infracost: mỗi root CI plan được, với tfvars đã commit nếu có |
| `infracost-usage.yml` | giả định mức dùng của Infracost, mỗi giả định một lý do |
| `ci/` | `terraform-plan.sh` (gác và plan của `plan.yml`), `infracost.sh` (`cost.yml`), test với lệnh giả, `testdata/` (`show -json` mẫu) |

## Plan trên PR

Mỗi PR từ chính repo đổi `aws/**`, `ci/**`, `Makefile` hay `.github/workflows/plan.yml` có một lượt `terraform plan` thật trên account
env, bằng role chỉ đọc `svp-ci-terraform-plan`, và một comment tóm tắt: số tạo, sửa, xoá, thay, address và hành động của mỗi thay đổi,
không giá trị thuộc tính. CI không `apply`. Workflow không nằm trong cổng PR: lượt bỏ qua hay đỏ không chặn merge. Quyết định:
[ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md).

### Job và thứ tự lệnh

Job `gate` (`ci/terraform-plan.sh gate`) chọn env từ biến Actions `SVP_TF_PLAN_ENVS` (mảng JSON, Terraform `terraform_plan_envs` của
`github/`). Job `plan` chạy mỗi env một lượt, nêu environment `terraform-plan` nên chờ người học duyệt; được duyệt thì nhận secret của
environment và token OIDC. `make ci-plan ENV=<env>` chạy `ci/terraform-plan.sh plan <env>`:

- Trước mỗi lệnh Terraform lấy token mới (audience `sts.amazonaws.com`, sống 5 phút), ghi đè file mode 600 dưới `RUNNER_TEMP`; Terraform
  trong container `TERRAFORM_IMAGE` tự assume role qua `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, không action bên thứ ba.
- Thứ tự: `init`, `state pull` của `aws/envs/<env>`, rồi `init`, `plan`, `show -json` của `aws/accounts/<env>`, rồi `plan`, `show -json`
  của `aws/envs/<env>` khi buổi mở.
- `init -lockfile=readonly` và `plan -lock=false`: không ghi state, khoá state hay lock file. Repo mount chỉ đọc; dữ liệu Terraform, file
  plan và tfvars nằm dưới `RUNNER_TEMP`, xoá khi script dừng.

### Giá trị của biến

Như `aws/scripts/tf.sh` đặt cho người học: `TF_VAR_account_id`, `TF_VAR_log_archive_account_id`, `TF_VAR_backup_account_id` từ secret
`SVP_AWS_<ENV>_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID` (id của env kia không bắt buộc); secret tfvars thành file
mode 600, `-var-file` trước `<env>.tfvars`. `media_signing_public_keys` của `aws/envs/<env>` lấy từ state của root đó: khoá công khai
`aws_cloudfront_public_key.media` của module `media` theo ô, bỏ bản deposed. File `media-signing.auto.tfvars.json` trên máy người học
không lên CI, nên plan chỉ cho thấy thay đổi của PR, không cho thấy khoá đang xoay mà chưa apply. State có resource mà không có khoá nào
(apply dở) thì plan của root env đỏ.

### Root được plan

Với mỗi env của `SVP_TF_PLAN_ENVS`:

| Root | Khi nào |
| --- | --- |
| `aws/accounts/<env>` | luôn: `-var session_open=true` khi buổi mở, `false` khi không, như người học đã apply nó |
| `aws/envs/<env>` | khi buổi mở: state của nó có ít nhất một resource; không thì tóm tắt ghi "Not planned" |

Root khác không bao giờ plan trong CI; PR đổi chúng thì job `gate` ghi notice và job summary nêu tên, lý do:

| Root | Lý do |
| --- | --- |
| `aws/bootstrap`, `aws/org` | management account, không đặt role CI ở đó |
| `aws/log-archive`, `aws/security`, `aws/baseline`, `aws/backup` | chạy từ management qua `OrganizationAccountAccessRole` |
| `aws/gitops/<env>` | API EKS chỉ qua tunnel |
| `github/` | cần token admin GitHub |

### Khi nào bỏ qua

Job xanh, có `::notice::`:

- `SVP_TF_PLAN_ENVS` rỗng hay chưa đặt: job `plan` không chạy nên environment không bị nêu.
- PR từ fork: secret và token không tới code của fork; job `plan` kiểm lại điều này từ event.
- PR chỉ đổi root không plan.

API liệt kê thiếu file của PR (trên 3 000 file) thì plan chạy: khi nghi thì chạy.

Mọi lỗi khác (assume role, `init`, `plan`) là đỏ thật, stderr của Terraform in ra đã che. Exit code 2 của `plan -detailed-exitcode` là "có
thay đổi", không phải lỗi.

### Giá trị che

- Che: account ID của mọi secret `SVP_AWS_*_ACCOUNT_ID` có đặt, mọi chuỗi và số của secret tfvars (`SVP_TFVARS_ACCOUNT_<ENV>`,
  `SVP_TFVARS_ENV_<ENV>`: nội dung `<env>.auto.tfvars` của hai root), token OIDC.
- Cách che: `::add-mask::` trước khi in gì, và `***` trong tóm tắt (add-mask chỉ che log, không che comment). Text plan và stdout của
  `plan` không in, không upload.
- Secret tfvars có heredoc, khối comment hay chuỗi không đóng thì script đỏ: mỗi giá trị trên một dòng.
- Khoá công khai media không bị che: chúng công khai, và tên ô `a`, `b` mà bị che thì mọi address mất chữ.

### Đọc comment plan

- Một comment dính (marker `<!-- svp-terraform-plan -->`), mỗi lượt sửa comment cũ.
- Mỗi env một mục, mỗi root một mục: dòng số (`N to create, N to update, N to delete, N to replace`, hay `No changes.`), danh sách trong
  khối thu gọn, mỗi dòng `` `<address>`: <hành động> `` (`create`, `update`, `delete`, `replace`, `forget`); data source và resource không
  đổi không hiện.
- `***` trong address là giá trị bị che (key `for_each` là domain hay account).
- Plan đỏ giữa chừng: dòng **Failed:**; env không có tóm tắt: "No summary".
- Comment quá giới hạn của GitHub chỉ giữ dòng số, danh sách đủ ở job summary của lượt. Artifact `plan-summary-<env>` giữ một ngày, chỉ bản
  đã che.
- Job `plan-comment` không checkout, không credential, nên bước đăng comment viết thẳng trong `plan.yml`; `make ci-plan-test` chạy chính
  bước đó.

### Duyệt environment `terraform-plan`

Mọi PR, kể cả PR Renovate: code của PR chạy với role khi lượt được duyệt, và lượt duyệt là kiểm soát duy nhất giữa code đó và account.

1. Ở tab Files của PR, đọc toàn bộ diff: workflow, `ci/`, `Makefile`, HCL và lock file dưới `aws/`.
2. PR của Renovate (nâng provider, module, lock dưới `aws/**`): đọc changelog của bản mới trước khi duyệt, vì provider mới chạy với
   credential của role; `init -lockfile=readonly` chỉ nhận provider khớp hash của lock file trong PR.
3. Duyệt lượt chờ, bằng trang hay bằng `gh api`:
   - Trang: `gh run list -R anhnvcoder/svp-infra --workflow plan.yml --status waiting`, rồi
     `gh run view <run-id> -R anhnvcoder/svp-infra --web`, chọn **Review deployments**, tick `terraform-plan`, **Approve and deploy**.
   - `gh api`
     ([Review pending deployments](https://docs.github.com/en/rest/actions/workflow-runs#review-pending-deployments-for-a-workflow-run)):

     ```sh
     gh api repos/anhnvcoder/svp-infra/actions/runs/<run-id>/pending_deployments \
       --jq '.[] | {id: .environment.id, name: .environment.name, can: .current_user_can_approve}'
     gh api -X POST repos/anhnvcoder/svp-infra/actions/runs/<run-id>/pending_deployments \
       -F 'environment_ids[]=<id của terraform-plan>' -f state=approved -f comment='diff read'
     ```

     Lệnh đầu mong một dòng `terraform-plan` với `"can":true`. `gh` không có lệnh con cho việc duyệt, nên đường này là REST.

Duyệt giữ tay có chủ đích: script tự duyệt sẽ bỏ cổng người đọc diff.

### Lượt chờ của PR đã đóng

Không tự hết: mở lượt như bước 3, **Review deployments**, **Reject**; hay lệnh `POST` ở trên với `-f state=rejected -f comment='PR
closed'`. Không Reject thì GitHub huỷ lượt sau 30 ngày; cổng PR không bị ảnh hưởng. Push mới vào PR huỷ lượt cũ, cả lượt đang chờ duyệt
(`concurrency` theo số PR).

### Bật plan cho một env

Sau khi role plan của env đã apply (root `aws/accounts/<env>`), đặt secret của environment rồi thêm env vào `terraform_plan_envs` theo
mục [Environment `terraform-plan`](../runbooks/github-setup.md#environment-terraform-plan) của runbook `github-setup.md`; danh sách secret
job đọc là khối `env` của bước `make ci-plan` trong `plan.yml`.

### Quyền của role plan

Role `svp-ci-terraform-plan` (module [`ci-plan-role`](../../aws/modules/ci-plan-role/README.md), root `aws/accounts/<env>`):

- Trust: IAM OIDC provider của GitHub Actions trong account (output `github_oidc_provider_arn` của module `registry`); `StringEquals` trên
  `aud` = `sts.amazonaws.com` và trên `sub` đúng một chuỗi dạng bất biến của job có environment,
  `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:terraform-plan`. Validation của module từ chối ký tự đại diện, dạng `ref:`,
  `pull_request`. Phiên tối đa 3 600 giây.
- `ReadOnlyAccess` (policy AWS quản lý).
- Policy inline `svp-ci-terraform-plan-read`: `StateKeyViaS3` (`kms:Decrypt` trên khoá state, ARN dạng `key/<id>`, khi `kms:ViaService`
  là S3 của region và encryption context là ARN bucket state; key policy có statement `CiPlanReadsState` của module `account-baseline`);
  `RefreshReadsMissing` (`grafana:ListWorkspaceServiceAccounts`, `pricingplanmanager:GetSubscription`: refresh gọi, `ReadOnlyAccess` thiếu).
- Policy inline `svp-ci-terraform-plan-deny` (explicit Deny thắng mọi Allow, cả của resource policy):

| Sid | Chặn |
| --- | --- |
| `DenyWorkloadData` | Đọc dữ liệu workload trên mọi resource: giá trị secret, item DynamoDB, log event, message SQS, record Kinesis, trace, truy vấn AMP, log RDS, console EC2 (danh sách ở `local.workload_data_actions` của `main.tf`) |
| `DenyObjectReads` | `s3:GetObject*` trên mọi object trừ hai khoá state của env và `media/uptime-probe.txt` của bucket media (`svp-<env>-media-<account>-<region>`) |
| `DenyDecryptOtherKeys` | `kms:Decrypt` trên mọi khoá trừ khoá state; giá trị `SecureString` của SSM cũng cần giải mã nên bị chặn theo |
| `DenyDecryptStateOutsideS3` | `kms:Decrypt` trên khoá state khi không qua S3 |
| `DenyStateWrites` | Mọi hành động S3 trừ `s3:Get*`, `s3:List*` trên bucket state và object của nó, cả file khoá `.tflock` |

Thêm resource mà refresh đọc bằng hành động trong tập Deny hay ngoài `ReadOnlyAccess` thì đối chiếu lại kiểm kê refresh (ADR-0076 §6) trước
khi đổi tập này. Test mock của module (`tests/ci-plan-role.tftest.hcl`) kiểm trust, phiên, hai policy và mỗi luật validation.

## Chi phí trên PR

Mỗi PR từ chính repo đổi `aws/**`, `ci/**`, `Makefile`, `infracost.yml`, `infracost-usage.yml` hay `.github/workflows/cost.yml` có một
comment Infracost: chi phí tháng của từng project ở commit base và ở PR, và phần chênh theo resource. Infracost CLI (image
`INFRACOST_IMAGE` của `Makefile`) đọc thẳng HCL và tfvars đã commit: không `plan`, không state, không credential AWS, nên workflow không có
environment hay lượt duyệt. Workflow không nằm trong cổng PR. Phương án, mức dùng miễn phí, dữ liệu gửi đi:
[ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §10.

### Hai job

- `infracost` (`contents: read`, secret repo `INFRACOST_API_KEY`) chạy `make infracost BASE=../base` (`ci/infracost.sh estimate`):
  `infracost breakdown` của cây base, rồi của cây PR, cả hai với `infracost.yml` và `infracost-usage.yml` của PR, rồi `infracost diff`.
  Hai cây mount chỉ đọc; module registry tải vào thư mục tạm dưới `RUNNER_TEMP`.
- `infracost-comment` (`contents: read`, `pull-requests: write`) tải artifact `infracost` (chỉ `diff.json`, giữ một ngày) rồi chạy
  `make infracost-comment`; lệnh `comment` của CLI cũng đòi khoá API.
- Khoá và token GitHub vào container chỉ theo tên biến (`-e NAME`), không bao giờ trong tham số hay log. `INFRACOST_ENABLE_CLOUD=false`:
  JSON của lượt chạy không lên Infracost Cloud, CLI chỉ gửi thuộc tính tính giá tới Cloud Pricing API.

### Khi nào bỏ qua Infracost

Job xanh, có `::notice::`: PR từ fork (secret không tới code của fork; job `infracost-comment` kiểm lại điều này từ event); secret
`INFRACOST_API_KEY` chưa đặt. Lỗi khác (HCL không đọc được, API từ chối) là đỏ thật, không chặn merge. Đặt và xoay khoá: mục [Khoá
Infracost](../runbooks/github-setup.md#khoá-infracost) của runbook `github-setup.md`.

### Project

`infracost.yml`: mỗi root mà CI plan một project, `aws/envs/<env>` với `<env>.tfvars`, `aws/accounts/<env>` không file tfvars nào (mọi
giá trị của root account nằm ở `<env>.auto.tfvars`). Cờ của `aws/paid-features.json` hiện qua chính HCL: module `paid-features` đọc file,
nên PR đổi cờ có chênh ở project của root đọc cờ đó. File không đặt cờ nào là `session`, nên buổi không mở gì ở root account và
`accounts-<env>` có cùng giá trong và ngoài buổi. Env đặt lại một cờ `session` thì thêm project `accounts-<env>-session`: cùng `path`,
`terraform_vars` là `session_open: true`, để phần chỉ có trong buổi hiện giá.

### Đọc comment Infracost

Bảng mỗi project (chi phí tháng trước, sau, chênh), dưới đó danh sách resource đổi giá. Bảng tổng mỗi project của cả hai cây nằm ở job
summary của lượt. Infracost tính một tháng 730 giờ; phần theo lượng dùng chỉ có các giả định của `infracost-usage.yml`, phần khác hiện
"depends on usage". So với số đã ghi ở ADR:

- Phần theo giờ (control plane, node, NAT, RDS, ElastiCache, MSK): chia số tháng của Infracost cho 730 là số mỗi giờ, so với bảng H₀ của
  [phụ lục ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0048-prd-aws.md#chi-phí) (prd) và bảng mỗi giờ
  của buổi stg ở [phụ lục ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0034-aws-stage7.md).
- Phần theo lượng: mỗi giả định của `infracost-usage.yml` là lượng của một buổi 4 giờ, lấy từ bảng O₀ của phụ lục ADR-0048 và bảng cờ của
  [phụ lục ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md), lý do ở comment của
  từng dòng; nên phần đó so thẳng với số mỗi buổi.

### Giới hạn của chế độ HCL

- Biến không default và không ở `<env>.tfvars` (domain, email, account ID, id nhóm) để trống, vì giá trị của chúng chỉ ở `*.auto.tfvars`,
  không commit, không lên CI. Resource mà `count`, `for_each` hay cỡ phụ thuộc các biến đó có thể vắng hay sai; cỡ, số node, retention
  nằm ở `<env>.tfvars` nên đúng.
- Thứ không do Terraform tạo (node của Karpenter, volume của PVC, load balancer của controller trong cluster) không có trong ước lượng.
- Cả hai cây dùng `infracost.yml` và `infracost-usage.yml` của PR: chênh chỉ do code đổi. PR chỉ đổi giả định mức dùng có tổng mới ở bảng,
  chênh bằng 0. PR thêm project cho root chưa có ở base thì breakdown của cây base đỏ.

## Chạy lại trên máy

| Muốn chạy lại | Lệnh | Ghi chú |
| --- | --- | --- |
| Một nhóm của job `check` | `make check-<nhóm>` | Như CI; thu hẹp phần Terraform bằng `DIRS=<thư mục>` |
| Job `docs` | `make docs-check diagrams-check` | `DOCS='<file>'`, `NAMES='<sơ đồ>'` thu hẹp |
| zizmor như CI | `make zizmor` | Không `GH_TOKEN` thì chỉ audit offline |
| Logic của `gate`, `plan`, bước đăng comment plan | `make ci-plan-test` | `docker`, `curl`, `gh` giả; không account, token hay mạng |
| Logic của `infracost`, `infracost-comment` | `make infracost-test` | `docker` giả; không khoá, token hay mạng |
| Plan thật | không có | `make ci-plan` từ chối ngoài GitHub Actions; trên máy, người học plan bằng SSO (`aws/scripts/tf.sh`) |
| Ước chi phí thật | `make infracost BASE=<cây base>` | Cần khoá API, xem dưới |

`make infracost BASE=<cây base>` trên máy cần `INFRACOST_API_KEY`, thiếu thì từ chối. Khoá lấy từ CLI Infracost đã `auth login` (mục
[Khoá Infracost](../runbooks/github-setup.md#khoá-infracost) của `github-setup.md`), chỉ cho một lệnh, không ghi vào
file: `INFRACOST_API_KEY="$(infracost configure get api_key)" make infracost BASE=<cây base>`. Lệnh đọc cả `*.auto.tfvars` có trong thư
mục root, vì Infracost nạp chúng như Terraform: số khác của CI. Image chỉ có bản `linux/amd64`, Mac chạy qua giả lập.

## Hook

Hook `pre-commit` (`make hooks` một lần mỗi clone) chạy phép kiểm nhanh trên file đã stage; phép chậm để CI:
[`checks.md`](checks.md#hook-pre-commit).
