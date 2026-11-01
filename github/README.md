# `github/`: cài đặt GitHub của các repo của account

Cài đặt GitHub mà ADR-0015 §11, ADR-0025, ADR-0033 quyết định, viết thành code: ruleset, quyền Actions, environment `promote` có lịch sử,
review và khôi phục được. Root này
quản mọi repo trong `local.repositories` của `repositories.tf` (repo của lab và `anhnvcoder/.github`, default community health files của
account: `CONTRIBUTING.md`, `SECURITY.md`, mẫu PR) bằng provider `integrations/github` ghim `6.13.0` (chính xác,
trong `versions.tf`; Renovate mở PR khi có bản mới). Mọi giá trị là hiện trạng đọc bằng `gh api` GET lúc đưa repo vào quản lý, không "sửa
cho đẹp": chỗ hiện trạng khác runbook nằm ở mục "Khác runbook".

Root này không có provider AWS: luật `default_tags`, `allowed_account_ids` của root AWS không áp. State vẫn nằm trong bucket state của
`aws/bootstrap` (key `github/terraform.tfstate`, `use_lockfile`), nên `init`, `plan`, `apply` cần cả đăng nhập AWS lẫn token GitHub.

## Quản gì

| Tệp | Resource | Repo |
| --- | --- | --- |
| `repositories.tf` | `github_repository`: visibility, mô tả, Issues/Projects/Wiki/Discussions, cách merge (squash, merge commit, rebase, auto-merge, tiêu đề và nội dung commit squash, xoá nhánh sau merge), secret scanning và push protection; `archive_on_destroy = true` và `prevent_destroy` | mọi repo trong `local.repositories` |
| `repositories.tf` | `github_repository_vulnerability_alerts` (Dependabot alerts): bật | repo trong `local.vulnerability_alerts_on` |
| `repositories.tf` | `github_repository_vulnerability_alerts.off`: tắt (như GitHub để mặc định), ngoại lệ trivy `GIT-0003` riêng resource này | repo trong `local.vulnerability_alerts_off` |
| `repositories.tf` | `github_actions_repository_permissions`: Actions bật, action được phép (của GitHub + danh sách pattern), ghim SHA bắt buộc; `prevent_destroy` (destroy đưa repo về cho mọi action) | mọi repo trong `local.repositories` |
| `repositories.tf` | `github_workflow_repository_permissions`: `GITHUB_TOKEN` mặc định chỉ đọc, "create and approve pull requests" | mọi repo trong `local.repositories` |
| `rulesets.tf` | `github_repository_ruleset`: `main` của `svp-backend`, `svp-frontend`; `main`, `owners`, `tags` của `svp-gitops`; check bắt buộc kèm `integration_id` 15368 (app GitHub Actions) | `svp-backend`, `svp-frontend`, `svp-gitops` |
| `rulesets.tf` | `github_repository_ruleset.infra_main`: Terraform tạo | `svp-infra` |
| `environments.tf` | `github_repository_environment` `promote` (luật nhánh tuỳ chọn; `prevent_destroy`: xoá environment là xoá luôn secret khoá App), `github_repository_environment_deployment_policy` (chỉ `main`), biến `SVP_GITOPS_APP_CLIENT_ID` / `SVP_WEB_APP_CLIENT_ID` | `svp-backend`, `svp-frontend` |

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
| Nhánh mặc định (`github_branch_default`) | Push đầu đặt nó; mọi repo trong `local.repositories` đang là `main` | `gh api repos/anhnvcoder/<repo> -q .default_branch` |
| `require_extra_approval_for_unattributed_changes` của luật `pull_request` | Provider không có trường này (không đọc, không gửi); GitHub đang để `true` ở mọi ruleset có luật này (mặc định). Sau một `apply` sửa ruleset, đọc lại trường này | `gh api repos/anhnvcoder/<repo>/rulesets/<id> -q '.rules[] \| select(.type=="pull_request") \| .parameters'` |
| Dependabot security updates | Đang tắt ở mọi repo trong `local.repositories`, không ai bật; Renovate nâng dependency | `gh api repos/anhnvcoder/<repo> -q .security_and_analysis` |
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
bằng tài khoản admin của mọi repo trong `local.repositories` với scope `repo` (`gh auth status` liệt kê scope), `jq`.

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

**3. Đọc `plan`:** chỉ thay đổi bạn định làm; `No changes.` khi code và GitHub khớp nhau. Dòng nào khác là cài đặt trên GitHub đã đổi
so với code: dừng, không `apply`, so với `gh api` GET của repo đó.

**4. `apply`** khi đúng mong đợi:

```sh
AWS_PROFILE=anhnv-sso terraform apply github.tfplan
AWS_PROFILE=anhnv-sso terraform plan                    # mong đợi: No changes.
rm github.tfplan                                        # plan chứa giá trị của biến
```

**Account mới hay state mới:** repo đã có trên GitHub phải nhận quản trước theo mục "Nhận quản repo đã có" (không thì `plan` đòi tạo
lại mọi repo và `apply` lỗi ở repo đầu tiên). Sau đó `apply` tạo `github_repository_ruleset.infra_main`. Chỉ `apply` nó sau khi `svp-infra` có nhánh mặc định `main` và lượt
`check.yml` đầu xanh trên `main` (B1 của runbook `svp-infra-setup.md`): ruleset nhắm `~DEFAULT_BRANCH` và đòi check `infra-ok`, check chưa
chạy lần nào thì mọi PR đứng chờ.

## Thay đổi thường gặp

**Đổi cài đặt.**

1. PR vào `svp-infra` sửa `.tf` của thư mục này; `make check DIRS=github` trên máy, `infra-ok` trên PR.
2. Merge, rồi từ `main`: cùng các lệnh `export GITHUB_TOKEN`, `terraform plan -out=github.tfplan` như trên, đọc plan (chỉ thay đổi của PR),
   `terraform apply github.tfplan`.
3. Không sửa cài đặt đã quản ở UI: `plan` lần sau thấy lệch và sẽ đưa về code. Lỡ sửa thì hoặc làm PR đưa giá trị đó vào code, hoặc
   `apply` để trả về.

**Thêm repo mới tạo bằng Terraform.** Thêm nó vào `local.repositories` (trường `vulnerability_alerts` chọn tài nguyên Dependabot alerts `this` hay `off`);
`plan` thấy `create` cho repo và các tài nguyên đi kèm; `apply`.

**Nhận quản repo đã có trên GitHub.** Thêm repo vào `local.repositories` như trên, kèm một khối `import {}` tạm cho đúng các tài nguyên của
repo đó (id theo cách provider nhận; `<repo>` là tên repo):

```hcl
import {
  to = github_repository.this["<repo>"]
  id = "<repo>"
}
import {
  to = github_actions_repository_permissions.this["<repo>"]
  id = "<repo>"
}
import {
  to = github_workflow_repository_permissions.this["<repo>"]
  id = "<repo>"
}
import {
  to = github_repository_vulnerability_alerts.this["<repo>"]   # hay .off["<repo>"] khi `vulnerability_alerts = false`
  id = "<repo>"
}
```

Ruleset hay environment đã có thì thêm khối tương ứng (id ruleset là `<repo>:<id>`, lấy bằng
`gh api repos/anhnvcoder/<repo>/rulesets -q '.[] | {id, name}'`; id environment là `<repo>:<tên environment>`; luật nhánh của environment là `<repo>:<tên environment>:<id luật>`, lấy bằng
`gh api repos/anhnvcoder/<repo>/environments/<tên environment>/deployment-branch-policies -q '.branch_policies[] | {id, name}'`; biến
environment là `<repo>:<tên environment>:<TÊN_BIẾN>`). `plan` thấy các import và, với
provider 6.13.0, hai trường chỉ sống trong state ở mỗi `github_repository` được import: `+ archive_on_destroy = true` (cờ của Terraform,
GitHub không có) và `+ ignore_vulnerability_alerts_during_read = false` (trường đã deprecated của provider, không bao giờ đọc lại). Mỗi
`github_actions_environment_variable` được import hiện `update` không đổi giá trị. Kiểm không có thay đổi nào khác (in tên tài nguyên và tên
thuộc tính, không in giá trị):

```sh
terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
  | "\(.address) \(.change.actions | join(","))"'
terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions == ["update"])
  | .address as $a | (.change.before // {}) as $b | .change.after | to_entries[] | select(.value != $b[.key]) | "\($a) \(.key)"'
```

Dòng nào ngoài import và hai trường trên là cài đặt trên GitHub khác với code: dừng, không `apply`, so với `gh api` GET của repo đó. Đúng
mong đợi thì `apply`, rồi `plan` phải ra `No changes.`. Xoá khối `import {}` tạm trong PR sau.

**Tfvars.** Giá trị hai biến lấy từ biến GitHub như bước 1; không chép tay.

Bỏ một repo khỏi `local.repositories` hay một repo
khỏi `local.promote_environments` thì `plan` dừng ở `prevent_destroy` (repo, quyền Actions, environment `promote`); muốn thôi quản một
tài nguyên thì dùng khối `removed { from = …  lifecycle { destroy = false } }` (thiếu `destroy = false` thì Terraform xoá nó trên GitHub:
`prevent_destroy` mất theo khối resource), đổi địa chỉ resource thì dùng khối `moved {}`.

**Provider mới** (PR của Renovate): đọc changelog, `make lock DIRS=github` nếu CI báo thiếu hash, rồi `plan` phải ra `No changes.` trước
khi merge thay đổi nào khác.
