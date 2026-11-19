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

GitHub không có API tạo App hay cài App lên repo, nên hai cú bấm (Create, Install) giữ tay; script làm phần còn lại và kiểm kết quả.
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

App công khai của Mend, không có khoá. Giữ tay: chọn repo cho bản cài làm trên trang, không qua API (token của `gh` bị
403 ở đường API, tạo PAT cho việc một lần mỗi repo không đáng):

<https://github.com/apps/renovate> → **Configure** → `anhnvcoder` → **Only select repositories**: sáu repo → **Save**.

Bẫy: thêm repo khi `renovate.json` chưa ở `main` của nó thì Renovate mở PR onboarding "Configure Renovate"; repo sẽ có `renovate.json`
thì thêm sau khi file đó đã ở `main`.

**Kiểm:** <https://github.com/settings/installations> → **Renovate** → **Configure**: đủ sáu repo; mỗi repo có PR "Configure Renovate"
hay đã có `renovate.json`.

## Thứ tự trên một account mới

1. **App promote và App phát hành:** `make github-app APP=svp-gitops-promoter`, `make github-app APP=svp-web-promoter`,
   `make github-app APP=svp-release-please` (khoá được giữ ở `github/.keys/` vì environment chưa có; client ID vào `github.auto.tfvars`:
   biến của nó không được rỗng, nên App có trước `plan` đầu).
2. **Terraform:** `make github-plan`, đọc plan, rồi `make github-apply` theo [`github/README.md`](../../github/README.md) mục "Lệnh người
   học chạy" (bỏ `make github-tfvars`: biến chưa có trên GitHub, bước 1 ở đây đã ghi `github.auto.tfvars`). Tạo repo nếu chưa có,
   ruleset, quyền Actions (action được phép, gồm `aws-actions/configure-aws-credentials` ở `svp-backend`, `svp-frontend` cho job ECR,
   `googleapis/release-please-action` ở `svp-backend`), environment `promote`, `promote-prd`, `ecr-rescan` (chỉ `main`, không người
   duyệt: trust của role rescan ECR ghi tên environment này), `release` (chỉ `main`), `terraform-plan` (người học duyệt), biến client
   ID, biến `SVP_TF_PLAN_ENVS` (`[]`), ruleset tag `gitops-check-tags`.
3. **Khoá chờ environment:** các lệnh `make github-app-key …` script đã in ở bước 1 (cả `KEY=release` của `svp-release-please`); khoá
   thứ hai `prd` như mục trên.
4. **App notifier:** `make github-app APP=svp-argocd-notifier` (khoá vào `backend/.env`).
5. **Renovate** như mục trên.
6. **Cài đặt không có resource:** `make github-settings`. Ba cài đặt: báo lỗ hổng riêng (`SECURITY.md` và mẫu issue của `.github` dẫn
   tới đây) và duyệt workflow của PR fork cho mọi người ngoài (`all_external_contributors`) ở mọi repo của `REPOSITORIES`, CodeQL default
   setup ở repo của `CODEQL_DEFAULT_SETUP` (hai danh sách ở `github/scripts/github-app.py`). Script đọc từng cài đặt và chỉ ghi cái khác
   giá trị cần, nên chạy lại an toàn. Mỗi repo mỗi cài đặt một dòng: `ok` (đã đúng, chỉ đọc) hay `changed` (vừa ghi).
   `FAIL  gh api …` kèm lỗi của GitHub: thường `gh` thiếu quyền admin hay scope `repo` (`gh auth status`); sửa rồi chạy lại.
7. **Secret account của CI ECR:** `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` ở các repo của `ECR_SECRET_REPOS` (workflow dựng ARN
   role OIDC từ chúng; secret để GitHub che account ID trong log), sau khi role của `aws/accounts/<env>` có
   ([`platform-setup.md`](platform-setup.md#bước-7-biến-ci-ecr) bước (7)). Hai biến cùng tên đã nạp qua direnv từ `.envrc`, rồi:

   ```sh
   make github-secrets
   ```

   Mong mỗi repo hai dòng `ok    secret SVP_AWS_<STG|PRD>_ACCOUNT_ID of <repo>`. Giá trị đi qua stdin của `gh`, không lên dòng
   lệnh hay màn hình. Biến thiếu hay không đủ 12 chữ số: `FAIL  SVP_AWS_<…>_ACCOUNT_ID is not set` (hay `is not 12 digits`) và chưa secret
   nào được ghi. Kiểm: `gh secret list -R anhnvcoder/<repo>` có hai tên đó.
8. **Khoá Infracost:** secret repo `INFRACOST_API_KEY` của `svp-infra`, mục [Khoá Infracost](#khoá-infracost).
9. **Environment `terraform-plan`:** ở buổi cloud, sau khi role plan của env có, mục [Environment
   `terraform-plan`](#environment-terraform-plan). Trước đó `SVP_TF_PLAN_ENVS` là `[]` và `plan.yml` bỏ qua có thông báo.
10. **Package GHCR public:** sau lượt `images.yml` đầu của mỗi repo code. Giữ tay: package mới mặc định private, và REST API của
    package không có lệnh đổi visibility hay gắn repo. Trang
    `https://github.com/users/anhnvcoder/packages/container/package/<repo>%2F<image>` → **Package settings**:

    - **Change visibility** → **Public**. Danh sách image: `PUBLIC_PACKAGES` của `github/scripts/github-app.py`.
    - Cột phải không có repo nguồn: **Connect Repository** → repo đó.
    - **Manage Actions access** có repo nguồn với role Write; thiếu thì **Add Repository**.

    Bẫy: package còn private thì overlay stg, prd của `svp-gitops` kéo image lỗi xác thực, và check của PR promote đỏ tới khi package
    public; sau khi đổi, chạy lại check của PR đó. **Kiểm:** `make github-check` dòng `package ghcr.io/anhnvcoder/<repo>/<image> pulls
    anonymously: True`.
11. **Kiểm cả bộ:** `make github-check WITH_APP_KEYS=1`: mọi dòng `ok` (hay `skip` cho secret của `terraform-plan` khi
    `SVP_TF_PLAN_ENVS` là `[]`), dòng cuối `every setting matches`.

## Khoá Infracost

`cost.yml` của `svp-infra` cần khoá API miễn phí của Infracost
([ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §10: mức miễn phí, dữ liệu
gửi đi; trang đăng ký đòi thẻ hay gói trả phí thì dừng). Đăng ký tài khoản giữ tay (chỉ làm được trên trình duyệt); đặt khoá vào secret
repo `INFRACOST_API_KEY` là `make infracost-key`. Lấy khoá bằng một trong hai cách:

- **Dashboard:** đăng ký Infracost Cloud, chép khoá ở **Org Settings** → **API key** (không dán vào đâu khác), rồi:

  ```sh
  pbpaste | make infracost-key
  ```

- **CLI Infracost** (tuỳ chọn, cài bằng Homebrew): `infracost auth login` mở trình duyệt để đăng ký hay đăng nhập và lưu khoá vào cấu
  hình của CLI; rồi `make infracost-key` không có stdin: script đọc khoá bằng `infracost configure get api_key`.

Script nhận khoá từ stdin khi stdin không phải terminal, không thì từ CLI; khoá đi qua stdin của `gh` và không bao giờ in ra.
Mong `ok    secret INFRACOST_API_KEY of svp-infra (from <nguồn>)`. `FAIL` khi khoá rỗng, có khoảng trắng hay nhiều dòng (chép thừa), hay
khi không có stdin lẫn CLI; dòng `FAIL` nêu lại hai cách trên.

Bẫy:

- Trang đăng ký mời cài GitHub App "Infracost", App này xin quyền ghi code ở mọi repo: bấm **Cancel**. `cost.yml` tự đăng comment bằng
  token của job, không cần App.
- `auth login` và `configure get api_key` là lệnh của dòng CLI trong `INFRACOST_IMAGE` của `Makefile`. Homebrew có thể cài dòng CLI
  khác (so `infracost --version` với tag của image): tài liệu dòng đó tả đăng nhập lưu token phiên, không có lệnh in khoá API, nên
  `make infracost-key` `FAIL`. Khi đó dùng cách dashboard.

Khoá rỗng hay chưa đặt thì `cost.yml` bỏ qua có thông báo. **Kiểm:** `make github-check` dòng `ok    svp-infra secret
INFRACOST_API_KEY: True`. Xoay khoá: tạo khoá mới ở **Org Settings**, `pbpaste | make infracost-key`, rồi thu hồi khoá cũ.

## Environment `terraform-plan`

Job `plan` của `plan.yml` (`svp-infra`) đọc account bằng role plan chỉ đọc của env
([ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §4, §9). Terraform tạo
environment; secret do người học đặt, mỗi env một lần, ở buổi cloud **sau khi** role plan của env đã apply
(`aws/accounts/<env>`). Thứ tự: secret trước, biến `SVP_TF_PLAN_ENVS` sau, vì env có trong biến thì mọi PR đổi `aws/**` chạy plan của nó.

1. Secret của env (ví dụ stg; prd thay `stg`). `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID` đã nạp
   qua direnv từ `.envrc` ở thư mục chứa các clone ([README](../../README.md#plan-và-apply)); `aws/accounts/stg/stg.auto.tfvars`
   và `aws/envs/stg/stg.auto.tfvars` đã có:

   ```sh
   make github-secrets ENV=stg
   ```

   Tên secret lấy từ `plan_secret_names` của `github/scripts/github-app.py`; mong mỗi tên một dòng `ok    secret <tên> of svp-infra
   environment terraform-plan`. Account vào từ ba biến, `SVP_TFVARS_ACCOUNT_STG`, `SVP_TFVARS_ENV_STG` là nội dung hai file trên; mọi giá
   trị qua stdin của `gh`, không in ra. Biến thiếu hay không đủ 12 chữ số, file không có hay rỗng: `FAIL` nêu biến hay file, và
   chưa secret nào được ghi. `ENV` ngoài `stg`, `prd` bị từ chối. Hai secret `LOG`, `BACKUP` dùng chung cho hai env: đặt lại ở env thứ hai
   không đổi gì.
2. Bật env: sửa dòng `terraform_plan_envs` trong `github/github.auto.tfvars` thành `["stg"]` (hay `["stg", "prd"]`), rồi `make github-plan`,
   đọc plan, `make github-apply` theo [`github/README.md`](../../github/README.md#lệnh-người-học-chạy-plan-apply). Mong `Plan: 0 to add, 1
   to change, 0 to destroy`: đúng `github_actions_variable.terraform_plan_envs`.
3. Kiểm: `make github-check`: mỗi secret của env đã bật một dòng `ok    svp-infra terraform-plan secret <tên>: True`.

Mỗi lượt plan dừng chờ người học duyệt **Review deployments** trên trang lượt chạy; đọc toàn bộ diff của PR (workflow,
`ci/`, `Makefile`, HCL và lock file dưới `aws/`) trước khi duyệt; cách duyệt và Reject ở mục "Plan trên PR" của
[`README.md`](../../README.md#plan-trên-pr). Tắt plan một env: bỏ nó khỏi
`terraform_plan_envs`, `make github-plan`, `make github-apply`; secret giữ nguyên. File `*.auto.tfvars` của env đổi thì chạy lại
`make github-secrets ENV=<env>`.

## Kiểm định kỳ

`make github-check` (chỉ đọc) sau mỗi `apply` của `github/`, sau khi thêm repo hay App, và khi nghi có ai sửa tay. Một dòng `FAIL` nêu
cài đặt, giá trị đang có và giá trị cần; sửa bằng đúng lệnh của bước tương ứng ở trên.
