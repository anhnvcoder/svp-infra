# Runbook: dựng phần GitHub của các repo

Từ một account có sáu repo trong `local.repositories` (`github/repositories.tf`) tới mọi cài đặt GitHub mà CI, promote và Argo CD cần:
Terraform `github/` lo phần có resource; phần provider không quản (bảng "Không quản" của [`github/README.md`](../../github/README.md)) làm
theo thứ tự dưới đây. Mỗi bước có lệnh kiểm; cuối cùng `make github-check` đọc lại tất cả.

**Người giữ account chạy mọi lệnh ở đây**, từ gốc repo này (`infra/`), với `gh` đăng nhập tài khoản admin của mọi repo (scope `repo`,
`gh auth status`). AI không chạy lệnh ghi nào; AI chạy được `make github-check` (chỉ đọc, không mở `backend/.env`; phần đó chỉ chạy với `WITH_APP_KEYS=1`) và `make github-app-test`.
Không dán khoá hay token vào đâu cả: script ghi khoá thẳng vào nơi dùng nó và không in ra.

## GitHub App

Các App của account, khai báo bằng [manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)
trong `github/apps/<tên>.json` (tên, quyền, webhook tắt, chỉ cài trên account này); nơi đặt khoá và repo được cài ở
`github/apps/destinations.json`:

| App | Quyền repository | Cài trên | Khoá | Client ID |
| --- | --- | --- | --- | --- |
| `svp-gitops-promoter` | Contents, Pull requests: write | `svp-gitops` | `stg`: secret `SVP_GITOPS_APP_PRIVATE_KEY` của environment `promote` (`svp-backend`); `prd`: khoá thứ hai, cùng tên secret ở environment `promote-prd` | `svp_gitops_app_client_id` của `github.auto.tfvars` |
| `svp-web-promoter` | Contents, Pull requests: write | `svp-gitops` | `stg`: secret `SVP_WEB_APP_PRIVATE_KEY` của environment `promote` (`svp-frontend`) | `svp_web_app_client_id` |
| `svp-release-please` | Contents, Pull requests: write | `svp-backend` | `release`: secret `SVP_RELEASE_APP_PRIVATE_KEY` của environment `release` (`svp-backend`) | `svp_release_app_client_id` |
| `svp-argocd-notifier` | Commit statuses: write | `svp-gitops` | `local`: `SVP_ARGOCD_NOTIFY_APP_ID`, `_INSTALLATION_ID`, `_PRIVATE_KEY_B64` trong `backend/.env` | không dùng |

Đổi quyền thì sửa manifest trước (review qua PR), rồi sửa trên trang App cho khớp: manifest chỉ dùng lúc tạo, GitHub không đọc lại nó.

### Tạo một App

```sh
make github-app APP=svp-gitops-promoter
```

Script mở trình duyệt tới trang tạo App đã điền sẵn theo manifest; đọc tên và quyền rồi bấm **Create GitHub App**. GitHub trả về một mã
dùng một lần cho script (qua `http://127.0.0.1:<port>/callback`), script đổi mã lấy App ID, client ID và khoá, rồi:

1. ghi khoá vào nơi đầu tiên của App trong `destinations.json` (secret của environment, hay `backend/.env` mode 600); environment chưa có
   (account mới, Terraform chưa tạo nó) thì giữ khoá ở `github/.keys/<app>-<khoá>.pem` (git bỏ qua, mode 600) và in lệnh đặt sau;
2. ghi client ID vào `github/github.auto.tfvars` (App promote);
3. mở trang cài App: chọn **Only select repositories**, đúng repo ở cột "Cài trên", **Install**; quay lại terminal bấm Enter;
4. đăng nhập bằng chính App (JWT ký bằng khoá vừa nhận) đọc bản cài: phải đúng các repo của cột "Cài trên", sai thì `FAIL` nêu repo; App
   có khoá `local` thì ghi thêm installation ID vào `backend/.env`.

Trình duyệt không mở được trang `127.0.0.1` (máy khác, chặn loopback): sau khi bấm Create, thanh địa chỉ có `?code=…`; chạy
`python3 github/scripts/github-app.py create <app> --code <mã>` trong 1 giờ.

**Kiểm:** `make github-check` dòng `<app> key in …` là `True` (hay `variables in backend/.env` là `all present`);
`make github-check WITH_APP_KEYS=1` thêm dòng bản cài của App có khoá `local`. Bản cài của App promote xem trên
<https://github.com/settings/installations> → **Configure**: "Only select repositories", đúng `svp-gitops`.

### Khoá thứ hai, xoay khoá

GitHub không có API tạo khoá. Trên `https://github.com/settings/apps/<app>` → **Private keys** → **Generate a private key**, rồi:

```sh
make github-app-key APP=svp-gitops-promoter KEY=prd PEM=~/Downloads/<file>.pem
```

Script ghi khoá vào nơi `KEY` của App và xoá file `.pem`. Xoay khoá: tạo khoá mới, đặt bằng lệnh trên, rồi xoá khoá cũ trên trang App.
Một khoá lộ: xoá nó trên trang App trước (mọi token đã cấp hết hạn trong một giờ), rồi tạo và đặt khoá mới.

### Renovate

App công khai của Mend: <https://github.com/apps/renovate> → **Configure** → **Only select repositories**: sáu repo. Không có khoá.
Kiểm: mỗi repo có PR "Configure Renovate" hay đã có `renovate.json`.

## Thứ tự trên một account mới

1. **App promote và App phát hành:** `make github-app APP=svp-gitops-promoter`, `make github-app APP=svp-web-promoter`,
   `make github-app APP=svp-release-please` (khoá được giữ ở `github/.keys/` vì environment chưa có; client ID vào `github.auto.tfvars`:
   biến của nó không được rỗng, nên App có trước `plan` đầu).
2. **Terraform:** `plan` rồi `apply` `github/` theo [`github/README.md`](../../github/README.md) mục "Lệnh người học chạy" (bỏ bước 1 ghi
   `github.auto.tfvars`: bước 1 ở đây đã ghi). Tạo repo nếu chưa có, ruleset, quyền Actions (action được phép, gồm
   `aws-actions/configure-aws-credentials` ở `svp-backend`, `svp-frontend` cho job ECR, `googleapis/release-please-action` ở `svp-backend`),
   environment `promote`, `promote-prd`, `ecr-rescan` (chỉ `main`, không người duyệt: trust của role rescan ECR ghi tên environment này),
   `release` (chỉ `main`), `terraform-plan` (người học duyệt), biến client ID, biến `SVP_TF_PLAN_ENVS` (`[]`), ruleset tag `gitops-check-tags`.
3. **Khoá chờ environment:** các lệnh `make github-app-key …` script đã in ở bước 1 (cả `KEY=release` của `svp-release-please`); khoá
   thứ hai `prd` như mục trên.
4. **App notifier:** `make github-app APP=svp-argocd-notifier` (khoá vào `backend/.env`).
5. **Renovate** như mục trên.
6. **Cài đặt không có resource**, mỗi lệnh cho cả sáu repo:

   ```sh
   R="svp-backend svp-frontend svp-gitops svp-infra svp-labs .github"
   # Báo lỗ hổng riêng (SECURITY.md và mẫu issue của .github dẫn tới đây)
   for r in $R; do gh api -X PUT repos/anhnvcoder/$r/private-vulnerability-reporting; done
   # Workflow của PR fork chờ duyệt, mọi người ngoài
   for r in $R; do gh api -X PUT repos/anhnvcoder/$r/actions/permissions/fork-pr-contributor-approval \
     -f approval_policy=all_external_contributors; done
   # CodeQL default setup ở hai repo có code ứng dụng
   for r in svp-backend svp-frontend; do gh api -X PATCH repos/anhnvcoder/$r/code-scanning/default-setup -f state=configured; done
   ```

7. **Secret account của CI ECR:** `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` ở `svp-backend`, `svp-frontend` (workflow dựng ARN role
   OIDC từ chúng; secret để GitHub che account ID trong log), giá trị qua stdin bằng `gh secret set`: bước (7) của
   [`platform-setup.md`](platform-setup.md#bước-7-biến-ci-ecr), sau khi role của `aws/accounts/<env>` có. Kiểm: `gh secret list -R
   anhnvcoder/<repo>` có hai tên đó.
8. **Khoá Infracost:** secret repo `INFRACOST_API_KEY` của `svp-infra`, mục [Khoá Infracost](#khoá-infracost).
9. **Environment `terraform-plan`:** ở buổi cloud, sau khi role plan của env có, mục [Environment
   `terraform-plan`](#environment-terraform-plan). Trước đó `SVP_TF_PLAN_ENVS` là `[]` và `plan.yml` bỏ qua có thông báo.
10. **Package GHCR public:** sau lượt `images.yml` đầu của mỗi repo code (package mới mặc định private, không API đổi): trang
   `https://github.com/users/anhnvcoder/packages/container/package/<repo>%2F<image>` → **Package settings** → **Change visibility** →
   **Public**. Danh sách image: `PUBLIC_PACKAGES` của `github/scripts/github-app.py`.
11. **Kiểm cả bộ:** `make github-check WITH_APP_KEYS=1`: mọi dòng `ok` (hay `skip` cho secret của `terraform-plan` khi
    `SVP_TF_PLAN_ENVS` là `[]`), dòng cuối `every setting matches`.

## Khoá Infracost

`cost.yml` của `svp-infra` cần khoá API miễn phí của Infracost
([ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §10: mức dùng, dữ liệu gửi đi;
trang đăng ký đòi thẻ hay gói trả phí thì dừng). Đăng ký Infracost Cloud, chép khoá ở **Org Settings** → **API key** (không dán vào đâu
khác), rồi đặt qua stdin:

```sh
pbpaste | gh secret set INFRACOST_API_KEY -R anhnvcoder/svp-infra
gh secret list -R anhnvcoder/svp-infra
```

Mong dòng `INFRACOST_API_KEY`. Khoá rỗng hay chưa đặt thì `cost.yml` bỏ qua có thông báo. Xoay khoá: tạo khoá mới trên trang đó, đặt bằng
lệnh trên, rồi thu hồi khoá cũ.

## Environment `terraform-plan`

Job `plan` của `plan.yml` (`svp-infra`) đọc account bằng role plan chỉ đọc của env
([ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §4, §9). Terraform tạo
environment; secret do người học đặt, mỗi env một lần, ở buổi cloud **sau khi** role plan của env đã apply
(`aws/accounts/<env>`). Thứ tự: secret trước, biến `SVP_TF_PLAN_ENVS` sau, vì env có trong biến thì mọi PR đổi `aws/**` chạy plan của nó.

1. Secret của env (ví dụ stg; prd thay `STG`, `stg`). `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID` export
   trong terminal (đọc trên trang SSO, không ghi vào file nào); giá trị qua stdin, không lên dòng lệnh:

   ```sh
   printf '%s' "$SVP_AWS_LOG_ACCOUNT_ID" | gh secret set SVP_AWS_LOG_ACCOUNT_ID --env terraform-plan -R anhnvcoder/svp-infra
   printf '%s' "$SVP_AWS_BACKUP_ACCOUNT_ID" | gh secret set SVP_AWS_BACKUP_ACCOUNT_ID --env terraform-plan -R anhnvcoder/svp-infra
   printf '%s' "$SVP_AWS_STG_ACCOUNT_ID" | gh secret set SVP_AWS_STG_ACCOUNT_ID --env terraform-plan -R anhnvcoder/svp-infra
   gh secret set SVP_TFVARS_ACCOUNT_STG --env terraform-plan -R anhnvcoder/svp-infra < aws/accounts/stg/stg.auto.tfvars
   gh secret set SVP_TFVARS_ENV_STG --env terraform-plan -R anhnvcoder/svp-infra < aws/envs/stg/stg.auto.tfvars
   gh secret list --env terraform-plan -R anhnvcoder/svp-infra
   ```

   Mong năm tên đó (đủ tên của env đã bật: `plan_secret_names` của `github/scripts/github-app.py`). Hai secret `LOG`, `BACKUP` dùng chung cho
   hai env: đặt lại ở env thứ hai không đổi gì.
2. Bật env: `terraform_plan_envs = ["stg"]` (hay `["stg", "prd"]`) trong `github/github.auto.tfvars`, rồi `plan`, `apply` `github/` theo
   [`github/README.md`](../../github/README.md#lệnh-người-học-chạy-plan-apply). Mong `Plan: 0 to add, 1 to change, 0 to destroy`: đúng
   `github_actions_variable.terraform_plan_envs`.
3. Kiểm: `make github-check`: mỗi secret của env đã bật một dòng `ok    svp-infra terraform-plan secret <tên>: True`.

Mỗi lượt plan dừng chờ người học duyệt **Review deployments** trên trang lượt chạy; đọc diff `.github/`, `ci/`, `Makefile` của PR trước khi
duyệt. Tắt plan một env: bỏ nó khỏi `terraform_plan_envs`, `apply`; secret giữ nguyên. File `*.auto.tfvars` đổi thì đặt lại secret tương ứng.

## Kiểm định kỳ

`make github-check` (chỉ đọc) sau mỗi `apply` của `github/`, sau khi thêm repo hay App, và khi nghi có ai sửa tay. Một dòng `FAIL` nêu
cài đặt, giá trị đang có và giá trị cần; sửa bằng đúng lệnh của bước tương ứng ở trên.
