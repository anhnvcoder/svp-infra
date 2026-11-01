# `github/`: cài đặt GitHub của sáu repo của account

Cài đặt GitHub mà lab trước đây bật tay theo runbook (`svp-gitops-setup.md`, `svp-frontend-setup.md`, `svp-infra-setup.md` của repo code) và
ADR-0015 §11, ADR-0025, ADR-0033 nay là code: ruleset, quyền Actions, environment `promote` có lịch sử, review và khôi phục được. Root này
quản năm repo của lab `anhnvcoder/svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra`, `svp-labs` và repo `anhnvcoder/.github` (default
community health files của account: `CONTRIBUTING.md`, `SECURITY.md`, mẫu PR) bằng provider `integrations/github` ghim `6.13.0` (chính xác,
trong `versions.tf`; Renovate mở PR khi có bản mới). Mọi giá trị là hiện trạng đọc bằng `gh api` GET lúc đưa repo vào quản lý, không "sửa
cho đẹp": chỗ hiện trạng khác runbook nằm ở mục "Khác runbook".

Root này không có provider AWS: luật `default_tags`, `allowed_account_ids` của root AWS không áp. State vẫn nằm trong bucket state của
`aws/bootstrap` (key `github/terraform.tfstate`, `use_lockfile`), nên `init`, `plan`, `apply` cần cả đăng nhập AWS lẫn token GitHub.

## Quản gì

| Tệp | Resource | Repo |
| --- | --- | --- |
| `repositories.tf` | `github_repository`: visibility, mô tả, Issues/Projects/Wiki/Discussions, cách merge (squash, merge commit, rebase, auto-merge, tiêu đề và nội dung commit squash, xoá nhánh sau merge), secret scanning và push protection; `archive_on_destroy = true` và `prevent_destroy` | cả sáu |
| `repositories.tf` | `github_repository_vulnerability_alerts` (Dependabot alerts): bật | bốn repo trừ `svp-labs`, `.github` |
| `repositories.tf` | `github_repository_vulnerability_alerts.off`: tắt (như GitHub để mặc định), ngoại lệ trivy `GIT-0003` riêng resource này | `svp-labs`, `.github` |
| `repositories.tf` | `github_actions_repository_permissions`: Actions bật, action được phép (của GitHub + danh sách pattern), ghim SHA bắt buộc; `prevent_destroy` (destroy đưa repo về cho mọi action) | cả sáu |
| `repositories.tf` | `github_workflow_repository_permissions`: `GITHUB_TOKEN` mặc định chỉ đọc, "create and approve pull requests" | cả sáu |
| `rulesets.tf` | `github_repository_ruleset`: `main` của `svp-backend`, `svp-frontend`; `main`, `owners`, `tags` của `svp-gitops`; check bắt buộc kèm `integration_id` 15368 (app GitHub Actions) | ba repo |
| `rulesets.tf` | `github_repository_ruleset.infra_main` (theo JSON của mục C1 runbook `svp-infra-setup.md`): Terraform tạo, không `import` | `svp-infra` |
| `environments.tf` | `github_repository_environment` `promote` (luật nhánh tuỳ chọn; `prevent_destroy`: xoá environment là xoá luôn secret khoá App), `github_repository_environment_deployment_policy` (chỉ `main`), biến `SVP_GITOPS_APP_CLIENT_ID` / `SVP_WEB_APP_CLIENT_ID` | `svp-backend`, `svp-frontend` |
| `imports.tf` | khối `import {}` cho 35 tài nguyên có trên GitHub trước khi vào code | |

Giá trị của hai biến (client ID của hai GitHub App) vào qua `github.auto.tfvars` (git bỏ qua; dạng file ở `github.auto.tfvars.example`,
cách ghi ở bước 1 dưới đây) hay `TF_VAR_svp_gitops_app_client_id`, `TF_VAR_svp_web_app_client_id`; hai biến `sensitive`, `plan` không in
giá trị.

## Không quản, và vì sao

| Cài đặt | Vì sao không | Kiểm bằng |
| --- | --- | --- |
| Secret `SVP_GITOPS_APP_PRIVATE_KEY`, `SVP_WEB_APP_PRIVATE_KEY` (environment `promote`) | Giá trị của secret trong resource nằm rõ trong state; khoá App đặt tay một lần, đổi khi xoay khoá | Settings → Environments → `promote` |
| GitHub App `svp-gitops-promoter`, `svp-web-promoter` (quyền, repo cài) và App Renovate (Mend) | Provider không quản App của tài khoản cá nhân hay việc cài App | trang cài đặt App, runbook của từng repo |
| Duyệt workflow của PR fork (`fork-pr-contributor-approval`) | Provider 6.13.0 không có resource | `gh api repos/anhnvcoder/<repo>/actions/permissions/fork-pr-contributor-approval` |
| CodeQL default setup (`svp-backend`) | Provider không có resource cho default setup | `docs/ci-cd.md` mục 7 của repo code |
| Package GHCR public | Không có resource cho visibility của package | runbook của repo code |
| Environment `stg` của `svp-gitops` | Không ai bật tay: API deployments của `record-stg.sh` tự tạo khi ghi bản ghi stg, không luật nào; quản nó chỉ thêm đường để Terraform xoá hay tạo lại nó | `gh api repos/anhnvcoder/svp-gitops/environments` |
| Nhánh mặc định (`github_branch_default`) | Push đầu đặt nó; cả sáu repo đang là `main` | `gh api repos/anhnvcoder/<repo> -q .default_branch` |
| `require_extra_approval_for_unattributed_changes` của luật `pull_request` | Provider không có trường này (không đọc, không gửi); GitHub đang để `true` ở năm ruleset có luật này (mặc định, file JSON cũ cũng không đặt). Sau một `apply` sửa ruleset, đọc lại trường này | `gh api repos/anhnvcoder/<repo>/rulesets/<id> -q '.rules[] \| select(.type=="pull_request") \| .parameters'` |
| Dependabot security updates | Đang tắt ở cả sáu repo, không ai bật; Renovate nâng dependency | `gh api repos/anhnvcoder/<repo> -q .security_and_analysis` |
| Ruleset của `.github` | Repo không có workflow nên không có check nào để bắt; GitHub hiện không có ruleset nào ở repo này | `gh api repos/anhnvcoder/.github/rulesets` |

## Khác runbook (mã hoá đúng như đang chạy)

- `svp-infra`: danh sách action ngoài là `hashicorp/setup-terraform@*`, `terraform-linters/setup-tflint@*`; runbook (A2, nguyên nhân 6) muốn
  để trống. `delete_branch_on_merge` bật; runbook không nói.
- `svp-labs`: mọi cài đặt là mặc định của GitHub (mọi action, không ghim SHA, duyệt PR fork chỉ người mới, Dependabot alerts tắt, cho merge
  commit và rebase, không auto-merge).
- `.github` (không runbook nào nói tới): như `svp-labs`, mọi cài đặt là mặc định của GitHub, trừ Wiki tắt.
- `svp-backend`: cho cả merge commit và rebase, commit squash lấy tiêu đề và commit message (`COMMIT_OR_PR_TITLE`, `COMMIT_MESSAGES`);
  `svp-frontend`, `svp-gitops`, `svp-infra` chỉ squash, commit lấy tiêu đề và mô tả của PR.

Đổi các chỗ này là một PR riêng (một thay đổi mỗi lần, `plan` thấy rõ).

## Lệnh người học chạy (`plan`, `apply`)

AI không chạy lệnh nào dưới đây. Cần: Terraform 1.15 trên máy, `aws/backend.hcl` (bước 3 của `aws/bootstrap/README.md`), `gh` đăng nhập
bằng tài khoản admin của sáu repo với scope `repo` (`gh auth status` liệt kê scope), `jq`.

**1. `github.auto.tfvars`** (một lần mỗi máy): ghi thẳng từ biến đang có trên GitHub, không in ra màn hình. Không chép tay client ID từ
trang cài đặt App: một ký tự khác là `plan` đòi ghi đè biến của environment `promote`.

```sh
cd infra/github
{
  printf 'svp_gitops_app_client_id = "%s"\n' \
    "$(gh api repos/anhnvcoder/svp-backend/environments/promote/variables/SVP_GITOPS_APP_CLIENT_ID --jq .value)"
  printf 'svp_web_app_client_id = "%s"\n' \
    "$(gh api repos/anhnvcoder/svp-frontend/environments/promote/variables/SVP_WEB_APP_CLIENT_ID --jq .value)"
} > github.auto.tfvars
```

`gh api` lỗi thì nó in thân lỗi JSON thay cho giá trị, `github.auto.tfvars` hỏng cú pháp và `plan` dừng ở lỗi đọc file đó: chạy lại khi
`gh api` trả đúng giá trị.

**2. `plan`:**

```sh
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
export GITHUB_TOKEN="$(gh auth token)"                  # chỉ trong terminal này; không ghi vào file nào
AWS_PROFILE=anhnv-sso terraform init -backend-config=../aws/backend.hcl
AWS_PROFILE=anhnv-sso terraform plan -out=github.tfplan
```

`Account` phải là account sandbox như mọi buổi AWS (state nằm ở đó).

**3. Đọc `plan`.** State đã có năm repo của lab (lượt import đầu xong, `plan` sau đó ra `No changes.`); code thêm repo `.github`, nên
`plan` kế ra:

```text
Plan: 4 to import, 0 to add, 1 to change, 0 to destroy.
```

- 4 import của `.github`: repo, Dependabot alerts (`github_repository_vulnerability_alerts.off`), quyền Actions, quyền workflow.
- 1 change: `github_repository.this[".github"]`, chỉ hai trường sống trong state, không phải cài đặt trên GitHub.

Một lượt import (repo mới thêm vào `local.repositories`, hay state mới) với provider 6.13.0 luôn hiện các `update` sau, không cái nào đổi
cài đặt trên GitHub:

- mỗi `github_repository` được import: `+ archive_on_destroy = true` (cờ của Terraform, GitHub không có) và
  `+ ignore_vulnerability_alerts_during_read = false` (trường đã deprecated của provider, mặc định `false`, không bao giờ đọc lại);
  `apply` gửi PATCH với đúng cài đặt đang có của repo.
- mỗi `github_actions_environment_variable` được import: `update` không kèm thuộc tính nào khác, chỉ các trường tính sau `apply`; giá trị
  trước và sau như nhau, đúng giá trị trên GitHub khi tfvars ghi theo bước 1.

Kiểm không có thay đổi nào khác (in tên tài nguyên và tên thuộc tính, không in giá trị):

```sh
terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
  | "\(.address) \(.change.actions | join(","))"'
terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions == ["update"])
  | .address as $a | (.change.before // {}) as $b | .change.after | to_entries[] | select(.value != $b[.key]) | "\($a) \(.key)"'
```

Mong đợi với `plan` kế ở trên: lệnh đầu in đúng 1 dòng `github_repository.this[".github"] update`; lệnh hai in đúng 2 dòng
`github_repository.this[".github"] archive_on_destroy` và `github_repository.this[".github"] ignore_vulnerability_alerts_during_read`
(biến environment khi được import có dòng ở lệnh đầu, không dòng nào ở lệnh hai). Dán lại dòng `Plan:` và output hai lệnh. Dòng nào khác
là cài đặt trên GitHub đã đổi so với lúc đọc: dừng, không `apply`, so với `gh api` GET của repo đó.

**4. `apply`** khi đúng mong đợi:

```sh
AWS_PROFILE=anhnv-sso terraform apply github.tfplan
AWS_PROFILE=anhnv-sso terraform plan                    # mong đợi: No changes.
rm github.tfplan                                        # plan chứa giá trị của biến
```

**Account mới:** ruleset `main` của `svp-infra` (`github_repository_ruleset.infra_main`) không có khối `import`, `apply` tạo nó. Chỉ
`apply` nó sau khi `svp-infra` có nhánh mặc định `main` và lượt `check.yml` đầu xanh trên `main` (B1 của runbook `svp-infra-setup.md`):
ruleset nhắm `~DEFAULT_BRANCH` và đòi check `infra-ok`, check chưa chạy lần nào thì mọi PR đứng chờ.

## Đổi cài đặt sau này

1. PR vào `svp-infra` sửa `.tf` của thư mục này; `make check DIRS=github` trên máy, `infra-ok` trên PR.
2. Merge, rồi từ `main`: cùng các lệnh `export GITHUB_TOKEN`, `terraform plan -out=github.tfplan` như trên, đọc plan (chỉ thay đổi của PR),
   `terraform apply github.tfplan`.
3. Không sửa cài đặt đã quản ở UI: `plan` lần sau thấy lệch và sẽ đưa về code. Lỡ sửa thì hoặc làm PR đưa giá trị đó vào code, hoặc
   `apply` để trả về.

Khối `import {}` giữ nguyên sau lần đầu: tài nguyên đã ở state thì khối không làm gì. Bỏ một repo khỏi `local.repositories` hay một repo
khỏi `local.promote_environments` thì `plan` dừng ở `prevent_destroy` (repo, quyền Actions, environment `promote`); muốn thôi quản một
tài nguyên thì dùng khối `removed { from = …  lifecycle { destroy = false } }` (thiếu `destroy = false` thì Terraform xoá nó trên GitHub:
`prevent_destroy` mất theo khối resource), đổi địa chỉ resource thì dùng khối `moved {}`.

**File ruleset JSON trùng lặp:** `backend/.github/rulesets/`, `svp-gitops/.github/rulesets/` và `svp-frontend/.github/rulesets/` là bản
trùng của `rulesets.tf`. Chúng được xoá và tài liệu trỏ về đây ở một thay đổi riêng; tới lúc đó nguồn đúng là `rulesets.tf`.

**Provider mới** (PR của Renovate): đọc changelog, `make lock DIRS=github` nếu CI báo thiếu hash, rồi `plan` phải ra `No changes.` trước
khi merge thay đổi nào khác.
