# Runbook: dựng phần GitHub của các repo

Từ một account có sáu repo trong `local.repositories` (`github/repositories.tf`) tới mọi cài đặt GitHub mà CI, promote và Argo CD cần:
Terraform `github/` lo phần có resource; phần provider không quản (bảng "Không quản" của [`github/README.md`](../../github/README.md)) làm
theo thứ tự dưới đây. Mỗi bước có lệnh kiểm; cuối cùng `make github-check` đọc lại tất cả.

**Người giữ account chạy mọi lệnh ở đây**, từ gốc repo này (`infra/`), với `gh` đăng nhập tài khoản admin của mọi repo (scope `repo`,
`gh auth status`). AI không chạy lệnh ghi nào; AI chạy được `make github-check` (chỉ đọc, không mở `backend/.env`; phần đó chỉ chạy với `WITH_APP_KEYS=1`) và `make github-app-test`.
Không dán khoá hay token vào đâu cả: script ghi khoá thẳng vào nơi dùng nó và không in ra.

## GitHub App

Ba App của account, khai báo bằng [manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)
trong `github/apps/<tên>.json` (tên, quyền, webhook tắt, chỉ cài trên account này); nơi đặt khoá và repo được cài ở
`github/apps/destinations.json`:

| App | Quyền repository | Cài trên | Khoá | Client ID |
| --- | --- | --- | --- | --- |
| `svp-gitops-promoter` | Contents, Pull requests: write | `svp-gitops` | `stg`: secret `SVP_GITOPS_APP_PRIVATE_KEY` của environment `promote` (`svp-backend`); `prd`: khoá thứ hai, cùng tên secret ở environment `promote-prd` | `svp_gitops_app_client_id` của `github.auto.tfvars` |
| `svp-web-promoter` | Contents, Pull requests: write | `svp-gitops` | `stg`: secret `SVP_WEB_APP_PRIVATE_KEY` của environment `promote` (`svp-frontend`) | `svp_web_app_client_id` |
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

1. **App promote:** `make github-app APP=svp-gitops-promoter`, `make github-app APP=svp-web-promoter` (khoá được giữ ở `github/.keys/`
   vì environment chưa có; client ID vào `github.auto.tfvars`).
2. **Terraform:** `plan` rồi `apply` `github/` theo [`github/README.md`](../../github/README.md) mục "Lệnh người học chạy" (bỏ bước 1 ghi
   `github.auto.tfvars`: bước 1 ở đây đã ghi). Tạo repo nếu chưa có, ruleset, quyền Actions (action được phép, gồm
   `aws-actions/configure-aws-credentials` ở `svp-backend`, `svp-frontend` cho job ECR), environment `promote`, `promote-prd`, `ecr-rescan`
   (chỉ `main`, không người duyệt: trust của role rescan ECR ghi tên environment này), biến client ID.
3. **Khoá chờ environment:** các lệnh `make github-app-key …` script đã in ở bước 1; khoá thứ hai `prd` như mục trên.
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
8. **Package GHCR public:** sau lượt `images.yml` đầu của mỗi repo code (package mới mặc định private, không API đổi): trang
   `https://github.com/users/anhnvcoder/packages/container/package/<repo>%2F<image>` → **Package settings** → **Change visibility** →
   **Public**. Danh sách image: `PUBLIC_PACKAGES` của `github/scripts/github-app.py`.
9. **Kiểm cả bộ:** `make github-check WITH_APP_KEYS=1`: mọi dòng `ok`, dòng cuối `every setting matches`.

## Kiểm định kỳ

`make github-check` (chỉ đọc) sau mỗi `apply` của `github/`, sau khi thêm repo hay App, và khi nghi có ai sửa tay. Một dòng `FAIL` nêu
cài đặt, giá trị đang có và giá trị cần; sửa bằng đúng lệnh của bước tương ứng ở trên.
