# `github`: cài đặt GitHub của các repo của account, viết bằng Terraform

**Account** GitHub `anhnvcoder` · **state** management, bucket của `aws/bootstrap` (`../aws/backend.hcl`), key
`github/terraform.tfstate`, region `ap-southeast-1` · **profile** `anhnv-sso` (state) và `gh` đăng nhập admin (token)

Giải thích: [02. GitHub](../docs/handbook/02-github.md).

Chạy root này tạo gì: mục [`github`](../docs/reference/inventory.md#github) của [inventory](../docs/reference/inventory.md) (số
tài nguyên theo phần, theo loại, kèm sơ đồ).

## Dựng gì

Root quản mọi repo trong `local.repositories` của `repositories.tf`: các repo của lab và `anhnvcoder/.github` (default community health
files của account: `CONTRIBUTING.md`, `SECURITY.md`, mẫu PR). Provider `integrations/github` ghim chính xác trong `versions.tf`. Root
không có provider AWS, nên luật `default_tags`, `allowed_account_ids` của root AWS không áp; backend S3 vẫn cần phiên SSO.

| Tài nguyên | Repo | Một câu |
| --- | --- | --- |
| `github_repository.this` | mọi repo trong `local.repositories` | Visibility, mô tả, tính năng, chỉ squash (commit lấy tiêu đề và mô tả của PR), auto-merge, xoá nhánh sau merge, secret scanning và push protection; `archive_on_destroy`, `prevent_destroy` |
| `github_repository_vulnerability_alerts.this`, `.off` | `local.vulnerability_alerts_on`, `_off` | Dependabot alerts bật; tắt (như GitHub để mặc định) ở resource riêng mang ngoại lệ trivy `GIT-0003` |
| `github_actions_repository_permissions.this` | mọi repo | Actions bật, action của GitHub cộng `patterns_allowed` của từng repo, ghim SHA bắt buộc; `prevent_destroy` |
| `github_workflow_repository_permissions.this` | mọi repo | `GITHUB_TOKEN` mặc định chỉ đọc, không tạo hay duyệt PR |
| `github_repository_ruleset` `main` (`*_main`) | mọi repo | Cấm xoá, force push; lịch sử thẳng; PR chỉ squash, 0 approval; check bắt buộc kèm `integration_id` của app GitHub Actions |
| `github_repository_ruleset` `owners` (`*_owners`) | `svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra` | Đòi Code Owner duyệt; vai admin bypass chỉ trong PR |
| `github_repository_ruleset.gitops_tags` | `svp-gitops` | Chỉ admin tạo, đổi, xoá tag |
| `github_repository_ruleset.backend_checker_tags` | `svp-backend` | Tag `gitops-check-v*` tạo tự do, không ai trừ admin đổi hay xoá |
| `github_repository_environment.promote`, `promote_prd`, `release` và luật nhánh `*_main` | `svp-backend` (`promote` cả `svp-frontend`) | Environment giữ khoá App, chỉ `main`; `promote-prd` có người duyệt, admin không bypass; `prevent_destroy` |
| `github_actions_environment_variable.*_app_client_id` | `svp-backend`, `svp-frontend` | Client ID của App: `SVP_GITOPS_APP_CLIENT_ID`, `SVP_WEB_APP_CLIENT_ID`, `SVP_RELEASE_APP_CLIENT_ID` |
| `github_repository_environment.ecr_rescan` và luật nhánh | `svp-backend`, `svp-frontend` | Environment mà trust của role rescan ECR ghi tên; chỉ `main`, không người duyệt, không secret |
| `github_repository_environment.terraform_plan` | `svp-infra` | Environment mà trust của role plan ghi tên; người duyệt, admin không bypass, không luật nhánh; `prevent_destroy` |
| `github_actions_variable.terraform_plan_envs` | `svp-infra` | Biến repo `SVP_TF_PLAN_ENVS`: mảng JSON env mà `plan.yml` plan, mặc định `[]` |

Check bắt buộc của ruleset `main`: `ci-ok`, `images-ok` ở `svp-backend`, `svp-frontend`; `gitops-ok` ở `svp-gitops`; `infra-ok` ở
`svp-infra`; `pr-title` ở bốn repo đó; `docs` ở `svp-labs`, `.github`. Danh sách đúng nằm ở `rulesets.tf`.

## Chạy

Người học chạy mọi lệnh; AI chỉ chạy `make github-app-test` và `make github-check` (chỉ đọc).

- Lần đầu trên account mới: [`github-setup.md`](../docs/runbooks/github-setup.md#thứ-tự-trên-một-account-mới), bước 1–6; bước 7–11
  sau khi role của `aws/accounts/<env>` có.
- Đổi một cài đặt: PR sửa `.tf` ở đây, rồi `plan`, `apply` theo
  [`github-setup.md`](../docs/runbooks/github-setup.md#thay-đổi-thường-gặp), mục "Thay đổi thường gặp".
- Bật plan trên PR cho một env: [`github-setup.md`](../docs/runbooks/github-setup.md#environment-terraform-plan).
- Xoay khoá App: [`github-setup.md`](../docs/runbooks/github-setup.md#khoá-thứ-hai-xoay-khoá).
- Trong buổi cloud và giữa các buổi: không có gì để chạy. Root không bao giờ gỡ: repo được lưu trữ thay vì xoá (`prevent_destroy`).

## Ghi `github.auto.tfvars`

Giá trị các biến (client ID của các GitHub App, `terraform_plan_envs`) vào qua `github.auto.tfvars` (git bỏ qua; dạng file ở
`github.auto.tfvars.example`) hay `TF_VAR_<tên biến>`; biến client ID `sensitive`, `plan` không in giá trị. Ghi file từ biến Actions đang
có trên GitHub, không chép tay từ trang cài đặt App (một ký tự khác là `plan` đòi ghi đè biến của environment `promote`):

```sh
make github-tfvars
```

Đầu ra và lỗi của lệnh: bước 1 của mục "Lệnh người học chạy" của
[`github-setup.md`](../docs/runbooks/github-setup.md#lệnh-người-học-chạy-plan-apply). `terraform_plan_envs` chỉ nhận `stg`, `prd`; thêm
một env sau khi role plan của env đó đã apply và secret của nó đã đặt.

## Không quản, và vì sao

Làm theo thứ tự ở runbook [`docs/runbooks/github-setup.md`](../docs/runbooks/github-setup.md) (GitHub App tạo từ manifest `apps/<tên>.json`
bằng `make github-app`); `make github-check` đọc lại mọi hàng có API dưới đây.

| Cài đặt | Vì sao không | Kiểm bằng |
| --- | --- | --- |
| Secret `SVP_GITOPS_APP_PRIVATE_KEY`, `SVP_WEB_APP_PRIVATE_KEY` (environment `promote`); `SVP_GITOPS_APP_PRIVATE_KEY` của `promote-prd` (khoá riêng thứ hai của App `svp-gitops-promoter`, thu hồi riêng với khoá của stg) | Giá trị của secret trong resource nằm rõ trong state; khoá App đặt tay một lần, đổi khi xoay khoá | Settings → Environments → `promote`, `promote-prd` |
| Secret repo `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` (`svp-backend`, `svp-frontend`): id account của role ECR, secret để GitHub che id trong log của repo public | Như khoá App: giá trị trong resource nằm rõ trong state; người học đặt bằng `make github-secrets` | Settings → Secrets and variables → Actions, hay `gh secret list -R anhnvcoder/<repo>` |
| Secret `SVP_RELEASE_APP_PRIVATE_KEY` (environment `release` của `svp-backend`) | Như khoá App promote | Settings → Environments → `release` |
| Secret của environment `terraform-plan` (`svp-infra`): `SVP_AWS_<STG\|PRD\|LOG\|BACKUP>_ACCOUNT_ID`, `SVP_TFVARS_ACCOUNT_<ENV>`, `SVP_TFVARS_ENV_<ENV>` (nội dung `*.auto.tfvars` của `aws/accounts/<env>`, `aws/envs/<env>`) | Giá trị trong resource nằm rõ trong state; người học đặt bằng `make github-secrets ENV=<env>` sau khi role plan của env có | `make github-check` cho mỗi env trong `SVP_TF_PLAN_ENVS` |
| Secret repo `INFRACOST_API_KEY` (`svp-infra`): khoá API Infracost của `cost.yml` | Như trên; người học đặt bằng `make infracost-key` | `make github-check` |
| GitHub App `svp-gitops-promoter`, `svp-web-promoter`, `svp-release-please` (quyền, repo cài) và App Renovate (Mend) | Provider không quản App của tài khoản cá nhân hay việc cài App | trang cài đặt App, runbook của từng repo |
| Duyệt workflow của PR fork (`fork-pr-contributor-approval`: `all_external_contributors` theo ADR-0041) | Provider 6.13.0 không có resource; `make github-settings` đặt | `make github-check` |
| CodeQL default setup (repo trong `CODEQL_DEFAULT_SETUP` của `scripts/github-app.py`) | Provider không có resource cho default setup; `make github-settings` đặt | `make github-check`; `docs/ci-cd.md` mục 7 của repo code |
| Package GHCR public | Không có resource cho visibility của package | runbook của repo code |
| Environment `stg` của `svp-gitops` | Không ai bật tay: API deployments của `record-stg.sh` tự tạo khi ghi bản ghi stg, không luật nào; quản nó chỉ thêm đường để Terraform xoá hay tạo lại nó | `gh api repos/anhnvcoder/svp-gitops/environments` |
| Nhánh mặc định (`github_branch_default`) | Push đầu đặt nó; mọi repo trong `local.repositories` đang là `main` | `gh api repos/anhnvcoder/<repo> -q .default_branch` |
| `require_extra_approval_for_unattributed_changes` của luật `pull_request` | Provider không có trường này (không đọc, không gửi); GitHub đang để `true` ở mọi ruleset có luật này (mặc định). Sau một `apply` sửa ruleset, đọc lại trường này | `gh api repos/anhnvcoder/<repo>/rulesets/<id> -q '.rules[] \| select(.type=="pull_request") \| .parameters'` |
| Private vulnerability reporting | Provider 6.13.0 không có resource; `SECURITY.md` và `.github/ISSUE_TEMPLATE/config.yml` của `anhnvcoder/.github` dẫn người báo tới nó. Người học bật bằng `make github-settings` cho mọi repo trong `local.repositories` | `gh api repos/anhnvcoder/<repo>/private-vulnerability-reporting -q .enabled` in `true` |
| Dependabot security updates | Đang tắt ở mọi repo trong `local.repositories`, không ai bật; Renovate nâng dependency | `gh api repos/anhnvcoder/<repo> -q .security_and_analysis` |

## Tham chiếu

- [02. GitHub](../docs/handbook/02-github.md): vì sao cài đặt là code, bí mật ngoài state, check tổng thay từng job.
- [`github-setup.md`](../docs/runbooks/github-setup.md): mọi lệnh của root và của `github-app.py`.
- [ADR-0041](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0041-github-hardening.md): Code Owner, chỉ squash,
  environment `promote-prd`, Actions của `svp-labs`, `.github`.
- [ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §9: environment
  `terraform-plan`, biến `SVP_TF_PLAN_ENVS`.
