# Runbook: dựng phần GitHub của các repo

← [org-security-setup](org-security-setup.md) · [Mục lục](README.md) · [backup-setup](backup-setup.md) →

> **Tóm tắt**
>
> - **Làm gì:** từ sáu repo trong `local.repositories` (`github/repositories.tf`) tới mọi cài đặt GitHub mà CI, promote và Argo CD cần:
>   GitHub App từ manifest, Terraform `github/`, Renovate, ba cài đặt không có resource, secret của CI, khoá Infracost, environment
>   `terraform-plan`, package GHCR public; rồi các thay đổi về sau (đổi cài đặt, nhận quản repo, xoay khoá).
> - **Khi nào và bao lâu:** bước 1–6 một lần trên account mới, sau org-security-setup (state của `github/` nằm ở bucket của
>   `aws/bootstrap`); bước 7–9 sau khi role của `aws/accounts/<env>` có (platform-setup bước (7)), bước 9 ở buổi cloud; bước 10 sau
>   lượt `images.yml` đầu của mỗi repo code. Mỗi bước là vài lệnh và vài cú bấm; không có số đo thời gian.
> - **Phí trong lúc chạy:** 0: mọi cài đặt nằm trong gói Free của GitHub cho repo public; state thêm một object vào bucket state
>   ([02. GitHub](../handbook/02-github.md#chi-phí)).

**Người giữ account chạy mọi lệnh ở đây**, từ gốc repo này (`infra/`). AI không chạy lệnh ghi nào; AI chạy được `make github-check` (chỉ
đọc, không mở `backend/.env`; phần đó chỉ chạy với `WITH_APP_KEYS=1`) và `make github-app-test`. Không dán khoá hay token vào đâu cả:
script ghi khoá thẳng vào nơi dùng nó và không in ra. Terraform `github/` lo phần có resource; phần provider không quản (bảng "Không
quản" của [`github/README.md`](../../github/README.md#không-quản-và-vì-sao)) làm theo thứ tự dưới đây. Vì sao chia như vậy: chương
[02. GitHub](../handbook/02-github.md).

## Điều kiện trước

- [ ] Bước 2 trở đi: org-security-setup bước (1) xong, `aws/backend.hcl` có (`tfvars.sh backend mgmt` ghi nó).
- [ ] `gh` đăng nhập bằng tài khoản admin của mọi repo trong `local.repositories`, scope `repo` (`gh auth status` liệt kê scope).
- [ ] Terraform 1.15 trên máy (`terraform version`; khớp Terraform của máy dev, cài bằng Homebrew, và `TERRAFORM_IMAGE` của `Makefile`;
  `use_lockfile` của backend S3 đòi 1.10 trở lên, khối `import {}` dùng tạm để nhận quản repo đã có đòi 1.5 trở lên), `jq`, `python3`.
- [ ] `SVP_AWS_MGMT_ACCOUNT_ID` nạp qua direnv từ `.envrc` ở thư mục chứa các clone; bước 7, 9 cần thêm biến account của env.
- [ ] Repo đã có trên GitHub mà state chưa có (account mới, state mới): nhận quản trước `apply` đầu, mục
  [Nhận quản repo đã có trên GitHub](#nhận-quản-repo-đã-có-trên-github); không thì `plan` đòi tạo lại mọi repo và `apply` lỗi ở repo đầu.

## Mở terminal

```sh
cd infra
gh auth status
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1
printf 'mgmt …%s\n' "${SVP_AWS_MGMT_ACCOUNT_ID: -4}"   # từ .envrc (direnv)
```

- **Mong đợi:** `gh auth status` có tài khoản admin và scope `repo`; dòng cuối in bốn số cuối của account management.
- **Kiểm:** `make github-plan` tự kiểm `AWS_PROFILE=anhnv-sso aws sts get-caller-identity` trả đúng `SVP_AWS_MGMT_ACCOUNT_ID` trước
  `init`; account khác thì `FAIL` và không chạy Terraform.

## Thứ tự trên một account mới

Bước 1–6 là lần ghé đầu (sau org-security-setup, trước backup-setup); bước 7–11 là lần ghé sau, khi role của env đã có.

1. **App promote và App phát hành:** tạo ba App trước `plan` đầu, vì biến client ID của chúng không được rỗng. Cách script làm và cú bấm
   tay ở mục [Tạo một App](#tạo-một-app).

   ```sh
   make github-app APP=svp-gitops-promoter
   ```

   Lặp lại với `APP=svp-web-promoter`, `APP=svp-release-please`.

   - **Mong đợi:** khoá được giữ ở `github/.keys/` vì environment chưa có (script in lệnh đặt sau); client ID vào `github.auto.tfvars`.
2. **Terraform:** `make github-plan`, đọc plan, rồi `make github-apply` theo mục
   [Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply), bỏ `make github-tfvars` (biến chưa có trên GitHub, bước 1 đã ghi
   `github.auto.tfvars`). Tạo repo nếu chưa có, ruleset, quyền Actions (action được phép, gồm `aws-actions/configure-aws-credentials` ở
   `svp-backend`, `svp-frontend` cho job ECR, `googleapis/release-please-action` ở `svp-backend`), environment `promote`, `promote-prd`,
   `ecr-rescan` (chỉ `main`, không người duyệt: trust của role rescan ECR ghi tên environment này), `release` (chỉ `main`),
   `terraform-plan` (người học duyệt), biến client ID, biến `SVP_TF_PLAN_ENVS` (`[]`), ruleset tag `gitops-check-tags`.

   - **Bẫy:** ruleset `main` của `svp-infra` đòi check `infra-ok`, của `svp-labs`, `.github` đòi check `docs`; check chưa chạy lần nào thì
     mọi PR đứng chờ. Chỉ `apply` `github_repository_ruleset.infra_main` sau khi `svp-infra` có nhánh mặc định `main` và lượt `check.yml`
     đầu xanh trên `main` (B1 của runbook `svp-infra-setup.md` của `svp-backend`); `labs_main`, `dotgithub_main` sau khi `docs.yml` đã ở
     `main` của `svp-labs`, `.github` và đã chạy xanh ở đó.
3. **Khoá chờ environment:** chạy các lệnh `make github-app-key …` script đã in ở bước 1 (cả `KEY=release` của `svp-release-please`);
   khoá thứ hai `prd` theo mục [Khoá thứ hai, xoay khoá](#khoá-thứ-hai-xoay-khoá).
4. **App notifier:** `make github-app APP=svp-argocd-notifier` (khoá vào `backend/.env`).
5. **Renovate:** chọn repo cho bản cài, mục [Renovate](#renovate).
6. **Cài đặt không có resource:** `make github-settings`. Ba cài đặt: báo lỗ hổng riêng (`SECURITY.md` và mẫu issue của `.github` dẫn
   tới đây) và duyệt workflow của PR fork cho mọi người ngoài (`all_external_contributors`) ở mọi repo của `REPOSITORIES`, CodeQL default
   setup ở repo của `CODEQL_DEFAULT_SETUP` (hai danh sách ở `github/scripts/github-app.py`). Script đọc từng cài đặt và chỉ ghi cái khác
   giá trị cần, nên chạy lại an toàn.

   - **Mong đợi:** mỗi repo mỗi cài đặt một dòng: `ok` (đã đúng, chỉ đọc) hay `changed` (vừa ghi).
   - **Bẫy:** `FAIL  gh api …` kèm lỗi của GitHub: thường `gh` thiếu quyền admin hay scope `repo` (`gh auth status`); sửa rồi chạy lại.
7. **Secret account của CI ECR:** `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID` ở các repo của `ECR_SECRET_REPOS` (workflow dựng ARN
   role OIDC từ chúng; secret để GitHub che account ID trong log), sau khi role của `aws/accounts/<env>` có
   ([platform-setup bước (7)](platform-setup.md#bước-7-biến-ci-ecr)). Hai biến cùng
   tên đã nạp qua direnv từ `.envrc`, rồi:

   ```sh
   make github-secrets
   ```

   - **Mong đợi:** mỗi repo hai dòng `ok    secret SVP_AWS_<STG|PRD>_ACCOUNT_ID of <repo>`. Giá trị đi qua stdin của `gh`, không lên
     dòng lệnh hay màn hình.
   - **Kiểm:** `gh secret list -R anhnvcoder/<repo>` có hai tên đó.
   - **Bẫy:** biến thiếu hay không đủ 12 chữ số: `FAIL  SVP_AWS_<…>_ACCOUNT_ID is not set` (hay `is not 12 digits`) và chưa secret nào
     được ghi.
8. **Khoá Infracost:** secret repo `INFRACOST_API_KEY` của `svp-infra`, mục [Khoá Infracost](#khoá-infracost).
9. **Environment `terraform-plan`:** ở buổi cloud, sau khi role plan của env có, mục
   [Environment `terraform-plan`](#environment-terraform-plan). Trước đó `SVP_TF_PLAN_ENVS` là `[]` và `plan.yml` bỏ qua có thông báo.
10. **Package GHCR public:** sau lượt `images.yml` đầu của mỗi repo code. Giữ tay: package mới mặc định private, và REST API của
    package không có lệnh đổi visibility hay gắn repo. Trang
    `https://github.com/users/anhnvcoder/packages/container/package/<repo>%2F<image>` → **Package settings**:

    - **Change visibility** → **Public**. Danh sách image: `PUBLIC_PACKAGES` của `github/scripts/github-app.py`.
    - Cột phải không có repo nguồn: **Connect Repository** → repo đó.
    - **Manage Actions access** có repo nguồn với role Write; thiếu thì **Add Repository**.

    - **Kiểm:** `make github-check` dòng `package ghcr.io/anhnvcoder/<repo>/<image> pulls anonymously: True`.
    - **Bẫy:** package còn private thì overlay stg, prd của `svp-gitops` kéo image lỗi xác thực, và check của PR promote đỏ tới khi
      package public; sau khi đổi, chạy lại check của PR đó.
11. **Kiểm cả bộ:** `make github-check WITH_APP_KEYS=1`.

    - **Mong đợi:** mọi dòng `ok` (hay `skip` cho secret của `terraform-plan` khi `SVP_TF_PLAN_ENVS` là `[]`), dòng cuối
      `every setting matches`.

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

- **Việc tay:** script mở trình duyệt tới trang tạo App đã điền sẵn theo manifest; đọc tên và quyền rồi bấm **Create GitHub App**.
  GitHub trả về một mã dùng một lần cho script (qua `http://127.0.0.1:<port>/callback`), script đổi mã lấy App ID, client ID và khoá.
- **Script làm:**
  1. ghi khoá vào nơi đầu tiên của App trong `destinations.json` (secret của environment, hay `backend/.env` mode 600); environment chưa
     có (account mới, Terraform chưa tạo nó) thì giữ khoá ở `github/.keys/<app>-<khoá>.pem` (git bỏ qua, mode 600) và in lệnh đặt sau;
  2. ghi client ID vào `github/github.auto.tfvars` (App promote);
  3. mở trang cài App: chọn **Only select repositories**, đúng repo ở cột "Cài trên", **Install**; quay lại terminal bấm Enter;
  4. đăng nhập bằng chính App (JWT ký bằng khoá vừa nhận) đọc bản cài: phải đúng các repo của cột "Cài trên", sai thì `FAIL` nêu repo;
     App có khoá `local` thì ghi thêm installation ID vào `backend/.env`.
- **Kiểm:** `make github-check` dòng `<app> key in …` là `True` (hay `variables in backend/.env` là `all present`);
  `make github-check WITH_APP_KEYS=1` thêm dòng bản cài của App có khoá `local`. Bản cài của App promote xem trên
  <https://github.com/settings/installations> → **Configure**: "Only select repositories", đúng `svp-gitops`.
- **Bẫy:** trình duyệt không mở được trang `127.0.0.1` (máy khác, chặn loopback): sau khi bấm Create, thanh địa chỉ có `?code=…`; chạy
  `python3 github/scripts/github-app.py create <app> --code <mã>` trong 1 giờ.

### Khoá thứ hai, xoay khoá

GitHub không có API tạo khoá. Trên `https://github.com/settings/apps/<app>` → **Private keys** → **Generate a private key**, rồi:

```sh
make github-app-key APP=svp-gitops-promoter KEY=prd PEM=~/Downloads/<file>.pem
```

Script ghi khoá vào nơi `KEY` của App và xoá file `.pem`. Xoay khoá: tạo khoá mới, đặt bằng lệnh trên, rồi xoá khoá cũ trên trang App.
Một khoá lộ: xoá nó trên trang App trước (mọi token đã cấp hết hạn trong một giờ), rồi tạo và đặt khoá mới.

### Renovate

App công khai của Mend, không có khoá. Giữ tay: chọn repo cho bản cài làm trên trang, không qua API (token của `gh` bị 403 ở đường API,
tạo PAT cho việc một lần mỗi repo không đáng):

<https://github.com/apps/renovate> → **Configure** → `anhnvcoder` → **Only select repositories**: sáu repo → **Save**.

- **Kiểm:** <https://github.com/settings/installations> → **Renovate** → **Configure**: đủ sáu repo; mỗi repo có PR "Configure Renovate"
  hay đã có `renovate.json`.
- **Bẫy:** thêm repo khi `renovate.json` chưa ở `main` của nó thì Renovate mở PR onboarding "Configure Renovate"; repo sẽ có
  `renovate.json` thì thêm sau khi file đó đã ở `main`.

## Lệnh người học chạy (`plan`, `apply`)

AI không chạy lệnh nào dưới đây.

**1. `github.auto.tfvars`** (một lần mỗi máy, và sau khi biến trên GitHub đổi):

```sh
make github-tfvars
```

Script đọc client ID của ba App và `SVP_TF_PLAN_ENVS` từ biến Actions trên GitHub (nguồn ở `TFVARS_SOURCES` của
`github/scripts/github-app.py`), không chép tay từ trang cài đặt App: một ký tự khác là `plan` đòi ghi đè biến của environment `promote`.
File ghi qua file tạm rồi đổi tên, dòng khác của file giữ nguyên.

- **Mong đợi:** mỗi biến một dòng `ok    <biến tfvars> ← <biến GitHub> of <repo> …` (giá trị không in), rồi
  `ok    github/github.auto.tfvars written (mode 600)`.
- **Mong đợi** khi biến chưa có: `note  … is not on GitHub yet`: biến chưa có (environment `release` hay biến `SVP_TF_PLAN_ENVS` trước
  `apply` đầu); dòng của biến đó trong file giữ như cũ (`make github-app APP=svp-release-please` đã ghi `svp_release_app_client_id`),
  `terraform_plan_envs` thiếu thì mặc định `[]`.
- **Bẫy:** `FAIL … does not look like a client ID` hay `is not a JSON list`: `gh api` trả thân lỗi JSON hay giá trị sai dạng; file không
  đổi. Sửa đăng nhập `gh` (`gh auth status`) rồi chạy lại.

**2. `plan`:**

```sh
make github-plan
```

Script kiểm `AWS_PROFILE=anhnv-sso aws sts get-caller-identity` trả đúng `SVP_AWS_MGMT_ACCOUNT_ID` (state nằm ở account này), lấy
`GITHUB_TOKEN` từ `gh auth token` chỉ cho tiến trình `terraform` (không vào dòng lệnh, file hay shell của bạn), rồi
`terraform init -backend-config=../aws/backend.hcl` và `terraform plan -out=github.tfplan` trong `github/`.

- **Mong đợi:** `ok    profile anhnv-sso reaches SVP_AWS_MGMT_ACCOUNT_ID`, plan, rồi dòng `next  read the plan above; …`.
- **Bẫy:** phiên SSO hết hạn hay chưa đăng nhập: `FAIL` in lệnh `AWS_PROFILE=anhnv-sso aws sso login --region us-east-1`. Account khác:
  `FAIL` trước `init`. Thiếu `aws/backend.hcl`: `FAIL`, ghi nó theo org-security-setup bước (1).

**3. Đọc `plan`:** chỉ thay đổi bạn định làm; `No changes.` khi code và GitHub khớp nhau. Dòng nào khác là cài đặt trên GitHub đã đổi
so với code: dừng, không `apply`, so với `gh api` GET của repo đó.

**4. `apply`** khi đúng mong đợi:

```sh
make github-apply
```

Script chỉ apply đúng `github/github.tfplan` đã lưu (không có file thì từ chối), xoá file đó (plan chứa giá trị của biến), rồi plan lại.

- **Mong đợi:** `ok    applied; github/github.tfplan deleted`, rồi `ok    plan after apply: No changes.`.
- **Bẫy:** còn thay đổi thì `FAIL  plan after apply still shows changes`: đọc chúng trước mọi việc khác.

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

- **Mong đợi:** `ok    secret INFRACOST_API_KEY of svp-infra (from <nguồn>)`.
- **Kiểm:** `make github-check` dòng `ok    svp-infra secret INFRACOST_API_KEY: True`. Khoá rỗng hay chưa đặt thì `cost.yml` bỏ qua có
  thông báo.
- **Việc tay:** trang đăng ký mời cài GitHub App "Infracost", App này xin quyền ghi code ở mọi repo: bấm **Cancel**. `cost.yml` tự đăng
  comment bằng token của job, không cần App.
- **Bẫy:** `FAIL` khi khoá rỗng, có khoảng trắng hay nhiều dòng (chép thừa), hay khi không có stdin lẫn CLI; dòng `FAIL` nêu lại hai cách
  trên. `auth login` và `configure get api_key` là lệnh của dòng CLI trong `INFRACOST_IMAGE` của `Makefile`. Homebrew có thể cài dòng CLI
  khác (so `infracost --version` với tag của image): tài liệu dòng đó tả đăng nhập lưu token phiên, không có lệnh in khoá API, nên
  `make infracost-key` `FAIL`. Khi đó dùng cách dashboard.

Xoay khoá: tạo khoá mới ở **Org Settings**, `pbpaste | make infracost-key`, rồi thu hồi khoá cũ.

## Environment `terraform-plan`

Job `plan` của `plan.yml` (`svp-infra`) đọc account bằng role plan chỉ đọc của env
([ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §4, §9). Terraform tạo
environment; secret do người học đặt, mỗi env một lần, ở buổi cloud **sau khi** role plan của env đã apply
(`aws/accounts/<env>`). Thứ tự: secret trước, biến `SVP_TF_PLAN_ENVS` sau, vì env có trong biến thì mọi PR đổi `aws/**` chạy plan của nó.

1. Secret của env (ví dụ stg; prd thay `stg`). `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID` đã nạp
   qua direnv từ `.envrc` ở thư mục chứa các clone ([`operations.md`](../reference/operations.md#biến-account-và-direnv));
   `aws/accounts/stg/stg.auto.tfvars` và `aws/envs/stg/stg.auto.tfvars` đã có:

   ```sh
   make github-secrets ENV=stg
   ```

   Tên secret lấy từ `plan_secret_names` của `github/scripts/github-app.py`. Account vào từ ba biến, `SVP_TFVARS_ACCOUNT_STG`,
   `SVP_TFVARS_ENV_STG` là nội dung hai file trên; mọi giá trị qua stdin của `gh`, không in ra. Hai secret `LOG`, `BACKUP` dùng chung cho
   hai env: đặt lại ở env thứ hai không đổi gì.

   - **Mong đợi:** mỗi tên một dòng `ok    secret <tên> of svp-infra environment terraform-plan`.
   - **Bẫy:** biến thiếu hay không đủ 12 chữ số, file không có hay rỗng: `FAIL` nêu biến hay file (file thiếu thì dòng `FAIL` trỏ README
     của root giữ file đó), và chưa secret nào được ghi. `ENV` ngoài `stg`, `prd` bị từ chối.
2. Bật env: sửa dòng `terraform_plan_envs` trong `github/github.auto.tfvars` thành `["stg"]` (hay `["stg", "prd"]`), rồi `make github-plan`,
   đọc plan, `make github-apply` theo mục [Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply).

   - **Mong đợi:** `Plan: 0 to add, 1 to change, 0 to destroy`: đúng `github_actions_variable.terraform_plan_envs`.
3. Kiểm: `make github-check`.

   - **Mong đợi:** mỗi secret của env đã bật một dòng `ok    svp-infra terraform-plan secret <tên>: True`.

Mỗi lượt plan dừng chờ người học duyệt **Review deployments** trên trang lượt chạy; đọc toàn bộ diff của PR (workflow, `ci/`, `Makefile`,
HCL và lock file dưới `aws/`) trước khi duyệt; cách duyệt và Reject ở [`ci.md`](../reference/ci.md#duyệt-environment-terraform-plan). Tắt
plan một env: bỏ nó khỏi `terraform_plan_envs`, `make github-plan`, `make github-apply`; secret giữ nguyên. File `*.auto.tfvars` của env
đổi thì chạy lại `make github-secrets ENV=<env>`.

## Thay đổi thường gặp

### Đổi cài đặt

1. PR vào `svp-infra` sửa `.tf` của `github/`; `make check DIRS=github` trên máy, `infra-ok` trên PR.
2. Merge, rồi từ `main`: `make github-plan`, đọc plan (chỉ thay đổi của PR), `make github-apply`.
3. Không sửa cài đặt đã quản ở UI: `plan` lần sau thấy lệch và sẽ đưa về code. Lỡ sửa thì hoặc làm PR đưa giá trị đó vào code, hoặc
   `apply` để trả về.

Đổi các chỗ ở mục [Khác runbook `svp-infra-setup.md`](#khác-runbook-svp-infra-setupmd) là một PR riêng (một thay đổi mỗi lần, `plan` thấy
rõ).

### Thêm repo mới tạo bằng Terraform

Thêm nó vào `local.repositories` (trường `vulnerability_alerts` chọn tài nguyên Dependabot alerts `this` hay `off`); `plan` thấy
`create` cho repo và các tài nguyên đi kèm; `apply`.

### Nhận quản repo đã có trên GitHub

Thêm repo vào `local.repositories` như trên, kèm một khối `import {}` tạm cho đúng các tài nguyên của repo đó (id theo cách provider nhận;
`<repo>` là tên repo):

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
`gh api repos/anhnvcoder/<repo>/rulesets -q '.[] | {id, name}'`; id environment là `<repo>:<tên environment>`; luật nhánh của
environment là `<repo>:<tên environment>:<id luật>`, lấy bằng
`gh api repos/anhnvcoder/<repo>/environments/<tên environment>/deployment-branch-policies -q '.branch_policies[] | {id, name}'`; biến
environment là `<repo>:<tên environment>:<TÊN_BIẾN>`).

- **Mong đợi:** `plan` thấy các import và, với provider 6.13.0, hai trường chỉ sống trong state ở mỗi `github_repository` được import:
  `+ archive_on_destroy = true` (cờ của Terraform, GitHub không có) và `+ ignore_vulnerability_alerts_during_read = false` (trường đã
  deprecated của provider, không bao giờ đọc lại). Mỗi `github_actions_environment_variable` được import hiện `update` không đổi giá trị.
- **Kiểm:** không có thay đổi nào khác (in tên tài nguyên và tên thuộc tính, không in giá trị; chạy trong `github/` sau
  `make github-plan`):

  ```sh
  terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
    | "\(.address) \(.change.actions | join(","))"'
  terraform show -json github.tfplan | jq -r '.resource_changes[] | select(.change.actions == ["update"])
    | .address as $a | (.change.before // {}) as $b | .change.after | to_entries[] | select(.value != $b[.key]) | "\($a) \(.key)"'
  ```

  Dòng nào ngoài import và hai trường trên là cài đặt trên GitHub khác với code: dừng, không `apply`, so với `gh api` GET của repo đó.
  Đúng mong đợi thì `make github-apply` (nó plan lại, phải ra `No changes.`). Xoá khối `import {}` tạm trong PR sau.

### Tfvars

Giá trị các biến lấy từ biến GitHub bằng `make github-tfvars` (bước 1 của mục
[Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply)); không chép tay.

### Thôi quản một tài nguyên

Bỏ một repo khỏi `local.repositories` hay một repo khỏi `local.promote_environments` thì `plan` dừng ở `prevent_destroy` (repo, quyền
Actions, environment `promote`). Muốn thôi quản một tài nguyên thì dùng khối `removed { from = …  lifecycle { destroy = false } }` (thiếu
`destroy = false` thì Terraform xoá nó trên GitHub: `prevent_destroy` mất theo khối resource); đổi địa chỉ resource thì dùng khối
`moved {}`.

### Provider mới

PR của Renovate: đọc changelog, `make lock DIRS=github` nếu CI báo thiếu hash, rồi `plan` phải ra `No changes.` trước khi merge thay đổi
nào khác.

## Khác runbook `svp-infra-setup.md`

Mã hoá đúng như đang chạy:

- `svp-infra`: danh sách action ngoài có thêm `hashicorp/setup-terraform@*`, `terraform-linters/setup-tflint@*` mà `check.yml` không dùng;
  runbook `svp-infra-setup.md` của `svp-backend` (A2, nguyên nhân 6) muốn không có hai action này. `delete_branch_on_merge` bật; runbook
  không nói.

## Kiểm định kỳ

`make github-check` (chỉ đọc) sau mỗi `apply` của `github/`, sau khi thêm repo hay App, và khi nghi có ai sửa tay. Một dòng `FAIL` nêu
cài đặt, giá trị đang có và giá trị cần; sửa bằng đúng lệnh của bước tương ứng ở trên.

## Gỡ

Không có bước gỡ: cài đặt GitHub sống cùng repo, không theo buổi, và repo không bao giờ bị xoá (`archive_on_destroy`, `prevent_destroy`).
Thôi quản một tài nguyên: mục [Thôi quản một tài nguyên](#thôi-quản-một-tài-nguyên). Thu hồi một App: xoá khoá của nó trên trang App
(mục [Khoá thứ hai, xoay khoá](#khoá-thứ-hai-xoay-khoá)).

## Khi một bước đỏ

| Dấu hiệu | Nguyên nhân thường gặp | Làm gì |
| --- | --- | --- |
| `FAIL  gh api …` | `gh` thiếu quyền admin hay scope `repo` | `gh auth status`, đăng nhập lại, chạy lại bước |
| `FAIL` của `make github-plan` trước `init` | Phiên SSO hết hạn, account khác, thiếu `aws/backend.hcl` | Mục [Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply), bước 2 |
| `plan` có dòng ngoài thay đổi của PR | Cài đặt trên GitHub bị sửa tay | Dừng, so với `gh api` GET; PR đưa giá trị vào code hay `apply` trả về |
| `FAIL  plan after apply still shows changes` | Code và GitHub còn khác sau `apply` | Đọc các thay đổi plan in ra trước mọi việc khác |
| `FAIL` của `make github-app` nêu repo | Bản cài chọn sai repo | Trang cài App → **Configure**, sửa repo, chạy lại |
| Dòng `FAIL` của `make github-check` | Một cài đặt ngoài Terraform lệch | Bước của cài đặt đó ở mục [Thứ tự](#thứ-tự-trên-một-account-mới) |

## Nâng cấp tổ chức dựng trước

### Environment `ecr-rescan` và action AWS cho job ECR

Một lần, sau khi PR thêm chúng merge; trước khi workflow của `svp-backend`, `svp-frontend` dùng chúng chạy trên `main`. `make github-plan`,
đọc plan, `make github-apply`.

- **Mong đợi:** `Plan: 4 to add, 2 to change, 0 to destroy`: environment `ecr-rescan` và luật nhánh `main` của nó ở hai repo;
  `github_actions_repository_permissions` của `svp-backend`, `svp-frontend` đổi tại chỗ, `patterns_allowed` thêm đúng một dòng
  `+ "aws-actions/configure-aws-credentials@*"`, không dòng `-`. Dòng nào khác: dừng như bước 3 của mục
  [Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply).

### Environment `release`, `terraform-plan`, ruleset tag checker và action release-please

Một lần, sau khi PR thêm chúng merge; trước khi `release.yml` của `svp-backend` chạy trên `main`, vì job nêu environment chưa có thì
GitHub tự tạo nó ngoài Terraform. App `svp-release-please` tạo trước (bước 1 của [Thứ tự](#thứ-tự-trên-một-account-mới)).

- **Mong đợi:** `Plan: 6 to add, 1 to change, 0 to destroy`: environment `release`, luật nhánh `main` và biến
  `SVP_RELEASE_APP_CLIENT_ID` của nó; environment `terraform-plan`; biến `SVP_TF_PLAN_ENVS` (`[]`); ruleset `gitops-check-tags`;
  `github_actions_repository_permissions` của `svp-backend` đổi tại chỗ, `patterns_allowed` thêm đúng một dòng
  `+ "googleapis/release-please-action@*"`, không dòng `-`. Dòng nào khác: dừng như bước 3 của mục
  [Lệnh người học chạy](#lệnh-người-học-chạy-plan-apply).
