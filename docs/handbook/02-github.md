# 02. GitHub

← [01. Bootstrap](01-bootstrap.md) · [Mục lục](README.md) · [03. Tổ chức](03-org.md) →

## Tổng quan

Chương này tả phần GitHub của svp: các repo public của tài khoản `anhnvcoder` (`local.repositories` của `github/repositories.tf`) và các
cài đặt quyết định ai được đổi gì. Root `github/` viết các cài đặt đó thành Terraform: ruleset của nhánh `main`, quyền GitHub Actions,
environment và biến Actions. Đổi một cài đặt vì thế đi qua PR, có lịch sử, review được và khôi phục được như code.

svp cần lớp này vì mọi đường thay đổi đều đi qua GitHub. Code vào `main` chỉ khi check bắt buộc xanh; bản phát hành tới `svp-gitops` nhờ
khoá của một GitHub App nằm trong environment; promote prd và job plan đọc account đều dừng chờ người học duyệt. Một cài đặt sửa tay
trên trang Settings mà không ai biết là một cổng bị mở lặng lẽ; với Terraform, lần `plan` sau thấy nó lệch.

Phần này sống lâu, không theo buổi và không tạo tài nguyên AWS tính tiền. State nằm trong bucket state của management, nên áp nó cần cả
đăng nhập AWS lẫn token GitHub. Cái provider không giữ được (giá trị secret, GitHub App, ba cài đặt không có resource) do một script đặt
và đọc lại; README của root liệt kê từng thứ và lý do.

| Câu hỏi | Dịch vụ |
| --- | --- |
| PR nào được merge vào `main`, ai được đẩy thẳng hay force push? | Ruleset `main`: PR, check bắt buộc, chỉ squash |
| PR của bot đổi workflow, `Makefile`, `aws/` có tự merge được không? | Ruleset `owners` và `CODEOWNERS` |
| Workflow được chạy action nào, `GITHUB_TOKEN` mặc định có quyền gì? | Quyền GitHub Actions của repo |
| Lỡ đẩy một khoá lên repo public thì có bị chặn không? | Secret scanning, push protection |
| Job nào được dùng khoá ghi `svp-gitops`, ai duyệt promote prd và plan account? | Environment có luật nhánh và người duyệt |
| CI ghi vào repo khác bằng danh tính nào, không phải token cá nhân? | GitHub App tạo từ manifest |
| Ai mở PR nâng provider, image, action? | Renovate (GitHub App của Mend) |

| Account | Region | Vòng đời | Root Terraform |
| --- | --- | --- | --- |
| GitHub `anhnvcoder`; state ở management | `ap-southeast-1` (bucket state) | sống lâu | `github` |

## Kiến trúc

![Cài đặt GitHub của repo đi từ máy người học bằng hai đường nào, cái gì không vào state?](../diagrams/02-github.svg#gh-light-mode-only)
![Cài đặt GitHub của repo đi từ máy người học bằng hai đường nào, cái gì không vào state?](../diagrams/02-github-dark.svg#gh-dark-mode-only)

Mũi tên nét đứt là điều khiển, nét liền là dữ liệu. Cột trái của GitHub là cái Terraform giữ: `plan` so code với GitHub và thấy mọi
lệch. Cột phải là cái script `github/scripts/github-app.py` ghi một lần rồi `make github-check` đọc lại. Không cài đặt nào do CI áp.

| Thành phần | Ở đâu | Làm gì |
| --- | --- | --- |
| Root `github` | máy người học; state key `github/terraform.tfstate` ở bucket của `aws/bootstrap` | Áp cài đặt của mọi repo trong `local.repositories` bằng provider `integrations/github` |
| `local.repositories` | `github/repositories.tf` | Một mục mỗi repo: cách merge, Dependabot alerts, action được phép |
| Ruleset `main`, `owners`, tag | `github/rulesets.tf` | Luật của nhánh mặc định và tag; check bắt buộc chỉ nhận từ app GitHub Actions |
| Environment và biến Actions | `github/environments.tf` | Nơi giữ khoá App và cổng duyệt; biến client ID, `SVP_TF_PLAN_ENVS` |
| `github-app.py` | `github/scripts/`, chạy qua `make github-*` | Tạo App từ manifest, đặt khoá và secret, ghi ba cài đặt không có resource, đọc lại tất cả |
| Manifest App | `github/apps/<tên>.json`, nơi đặt khoá ở `github/apps/destinations.json` | Tên, quyền, repo cài của từng App |

## Kịch bản thực tế

**Câu hỏi của chương:** Một PR vào `svp-infra` có job `check` đỏ thì vì sao không merge được, kể cả bởi admin?

Điều kiện: ruleset `main` của `svp-infra` (`github_repository_ruleset.infra_main`) đã áp, `check.yml` đã có lượt xanh trên `main`.

1. Người học mở PR `docs: …` vào `main` và đổi một file dưới `aws/`. `check.yml` chạy các job `changes`, `check`, `docs`; job `infra-ok`
   chạy sau cùng và chỉ xanh khi ba job kia `success` (riêng `check` được `skipped` khi PR chỉ đổi tài liệu).
2. Job `check` đỏ, nên `infra-ok` đỏ. Ruleset `main` nhắm `~DEFAULT_BRANCH` và có luật `required_status_checks` đòi `infra-ok` và
   `pr-title`, mỗi check kèm `integration_id` 15368 (app GitHub Actions). Nút merge bị khoá.
3. Ruleset `main` không có `bypass_actors`: vai admin cũng không merge được. Một status `infra-ok` xanh do token khác ghi lên commit cũng
   không thoả luật, vì check chỉ được nhận từ đúng app GitHub Actions.
4. Đường vòng cũng đóng: luật `pull_request` chặn push thẳng lên `main`, `non_fast_forward` chặn force push, `deletion` chặn xoá nhánh.
5. Người học sửa và push commit mới. `dismiss_stale_reviews_on_push` của ruleset bỏ mọi lượt duyệt cũ; `infra-ok`, `pr-title` chạy lại.
6. PR đổi `aws/`, đường có chủ trong `CODEOWNERS`, nên ruleset `owners` đòi Code Owner duyệt. Người học là Code Owner duy nhất và là tác
   giả; GitHub coi luật đã thoả (đã đo ở `svp-gitops`, ADR-0041 (b)). Với PR của Renovate trên cùng đường, luật này chặn thật.
7. Hai check xanh: merge được, chỉ bằng squash (`allowed_merge_methods = ["squash"]`, lịch sử thẳng); commit trên `main` lấy tiêu đề và
   mô tả của PR. Nhánh của PR tự xoá (`delete_branch_on_merge` của `svp-infra`).

`strict_required_status_checks_policy = false`: PR không phải cập nhật theo `main` trước khi merge. Hai PR xanh riêng có thể đỏ khi ghép;
lượt `check.yml` trên `main` sau merge bắt lỗi đó. Ba repo code khác cùng khuôn với check của chúng (`ci-ok`, `images-ok`, `gitops-ok`).

## Các dịch vụ và cách svp dùng

### Cài đặt repo và secret scanning

- **Làm gì:** cài đặt mức repo: cách merge, tính năng bật, quét bí mật. Ví dụ đời thực:
  - Push protection chặn một push chứa token có định dạng GitHub nhận ra, trước khi commit vào repo public.
  - Secret scanning cảnh báo bí mật đã nằm trong lịch sử.
  - Dependabot alerts báo một dependency có lỗ hổng đã biết; Renovate mở PR vá, không phải Dependabot.
  - Repo chỉ cho squash merge: nút "Create a merge commit" và "Rebase and merge" không hiện.
- **Ở svp:** `github_repository.this` cho mọi repo trong `local.repositories`: `visibility = "public"`, chỉ squash với `PR_TITLE` và
  `PR_BODY`, auto-merge ở các repo có bot, secret scanning và push protection bật; Dependabot alerts bật ở các repo có dependency
  (`github_repository_vulnerability_alerts.this`), tắt ở `svp-labs`, `.github` (`.off`).
- **Phí theo:** gói của tài khoản; repo public trên gói Free có đủ các tính năng trên.
- **Cố ý tắt:** Dependabot security updates, vì Renovate nâng dependency; xoá repo khi bỏ khỏi code
  (`archive_on_destroy` lưu trữ thay vì xoá, `prevent_destroy` dừng mọi plan định xoá).

### Ruleset

- **Làm gì:** bộ luật nhắm nhánh hay tag, áp cho mọi người kể cả admin trừ `bypass_actors` nêu tên. Ví dụ đời thực:
  - Luật `required_status_checks` khoá merge tới khi `infra-ok`, `pr-title` xanh từ app GitHub Actions.
  - Luật `pull_request` với `require_code_owner_review` đòi Code Owner duyệt PR đổi file có chủ.
  - Luật `non_fast_forward`, `deletion` chặn force push và xoá `main`.
  - Ruleset tag `gitops-check-tags` cho tạo tag `gitops-check-v*` nhưng cấm đổi, xoá: `svp-gitops` ghim checker theo tag đó.
- **Ở svp:** ruleset `main` ở mọi repo (`docs` là check bắt buộc của `svp-labs`, `.github`); `owners` ở các repo có CI, vai admin
  bypass chỉ trong PR, mỗi lần bypass có bản ghi; `tags` của `svp-gitops` chỉ admin tạo, đổi, xoá tag.
- **Phí theo:** gói của tài khoản; ruleset có ở gói Free cho repo public.
- **Cố ý tắt:** số lượt duyệt bắt buộc (0: tác giả không tự duyệt PR của mình, lab một người); `strict_required_status_checks_policy`.

### GitHub Actions: action được phép và `GITHUB_TOKEN`

- **Làm gì:** giới hạn workflow được gọi action nào và token tự cấp của mỗi job có quyền gì. Ví dụ đời thực:
  - Workflow gọi một action ngoài danh sách được phép thì lượt chạy thất bại ngay khi khởi động.
  - Action tham chiếu bằng tag thay vì SHA đầy đủ bị từ chối (`sha_pinning_required`).
  - `GITHUB_TOKEN` mặc định chỉ đọc; job cần ghi phải khai `permissions` của riêng nó.
  - `GITHUB_TOKEN` không tạo, không duyệt PR được; PR promote dùng token của App.
- **Ở svp:** `github_actions_repository_permissions.this`: `allowed_actions = "selected"`, action của GitHub cộng `patterns_allowed`
  của từng repo, không `verified_allowed`; `github_workflow_repository_permissions.this`: `default_workflow_permissions = "read"`.
- **Phí theo:** phút runner; runner chuẩn miễn phí cho repo public (chương [14. CI](14-ci.md)).
- **Cố ý tắt:** action của publisher đã xác minh nói chung (`verified_allowed = false`): chỉ pattern nêu tên.

### Environment và biến Actions

- **Làm gì:** environment là cổng cho job nêu tên nó: luật nhánh, người duyệt bắt buộc, secret và biến riêng. Ví dụ đời thực:
  - Job `promote-prd` dừng ở trạng thái chờ tới khi người học bấm **Review deployments** và duyệt.
  - Job chạy từ nhánh khác `main` bị từ chối vào environment `promote` (deployment branch policy).
  - Trust của role AWS ghi tên environment trong claim `sub` của OIDC, nên chỉ job trong `terraform-plan` nhận được role plan.
  - Xoá environment là xoá luôn secret của nó.
- **Ở svp:** `promote` (`svp-backend`, `svp-frontend`), `promote-prd` (người duyệt là người học, admin không bypass), `release`,
  `ecr-rescan`, `terraform-plan` (`svp-infra`, người duyệt, không luật nhánh vì job chạy ở ref merge của PR); biến client ID của App và
  biến repo `SVP_TF_PLAN_ENVS`. Environment giữ khoá có `prevent_destroy`.
- **Phí theo:** không tính riêng; người duyệt bắt buộc có ở gói Free cho repo public.
- **Cố ý tắt:** `prevent_self_review` (người dispatch là người duyệt duy nhất: bật thì không ai duyệt được).

## Chi phí

| Khoản | Đơn vị tính | Giữa các buổi | Trong buổi | Nguồn |
| --- | --- | --- | --- | --- |
| Repo, ruleset, environment, secret scanning | gói tài khoản GitHub | 0: gói Free, repo public | 0 | ADR-0041 (yếu tố quyết định) |
| Object state `github/terraform.tfstate` | GB-tháng, request S3 | không có số đo riêng; nằm trong bucket state của chương 01 | 0 | không có số đo |
| GitHub App, Renovate | — | không có số đo | không có số đo | không có số đo |

Nguồn: [ADR-0041](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0041-github-hardening.md), mục "Yếu tố quyết định": chỉ
dùng tính năng có ở gói Free cho repo public của tài khoản cá nhân. Phút runner và khoá Infracost ở chương [14. CI](14-ci.md).

## Kiểm tra và vận hành

| Muốn xem | Account | Region | Vào đâu | Trạng thái mong đợi |
| --- | --- | --- | --- | --- |
| Ruleset của một repo | GitHub | — | Repo → Settings → Rules → Rulesets | `main` (và `owners` ở các repo có CI) `Active` |
| Action được phép, quyền token | GitHub | — | Repo → Settings → Actions → General | Action chọn lọc, ghim SHA bắt buộc; Workflow permissions chỉ đọc |
| Environment và người duyệt | GitHub | — | Repo → Settings → Environments | `promote-prd`, `terraform-plan` có Required reviewers |
| Secret, biến | GitHub | — | Repo → Settings → Secrets and variables → Actions | Đúng tên ở bảng "Không quản" của README root |
| App và repo được cài | GitHub | — | <https://github.com/settings/installations> → Configure | Only select repositories, đúng repo ở `install_on` của `github/apps/destinations.json` |
| Bản ghi bypass | GitHub | — | Repo → Settings → Rules → Insights | Mỗi lần admin bypass `owners` có một dòng |
| State của root | management | `ap-southeast-1` | S3 → bucket state → `github/terraform.tfstate` | Có object và có version |

Bảng trên là trạng thái mà code khai báo. Runbook [`github-setup.md`](../runbooks/github-setup.md) dựng và kiểm: bước 2 áp Terraform rồi
plan lại phải ra `No changes.`; bước 11 chạy `make github-check WITH_APP_KEYS=1` đọc lại mọi cài đặt ngoài Terraform. Một phần chỉ coi là
đã kiểm khi bước đó ra đúng mong đợi. `make github-check` chỉ đọc, chạy lại sau mỗi `apply` và khi nghi có ai sửa tay.

## Thiết kế và đánh đổi

### Bí mật không vào state

Terraform ghi giá trị của mọi resource vào state, kể cả biến `sensitive`. Secret đặt bằng resource vì thế nằm rõ trong
`github/terraform.tfstate`. svp giữ ranh giới: Terraform tạo environment và biến không bí mật (client ID của App), còn khoá App, account
ID của role CI và khoá Infracost do `github-app.py` ghi thẳng qua stdin của `gh`, không qua dòng lệnh hay màn hình. Khoá vẫn chạm đĩa khi
chờ hay khi tải về: khoá App mới chờ environment trong `github/.keys/<app>-<key>.pem` (mode 600, git bỏ qua) tới khi
`make github-app-key` ghi nó rồi xoá file; khoá thứ hai tải về từ trang App là file `.pem` mà cùng lệnh xoá sau khi ghi; khoá của
`svp-argocd-notifier` nằm trong `.env` của svp-backend; khi ký JWT, khoá nằm trong file tạm xoá ngay sau lệnh `openssl`. Cái giá là hai
nơi giữ cài đặt; `make github-check` nối chúng lại bằng cách đọc lại mọi hàng có API. Vì environment giữ secret mà Terraform không biết,
mọi environment có khoá mang `prevent_destroy`: một `destroy` nhầm làm promote hỏng tới khi có người đặt lại khoá.

GitHub App thay token cá nhân: App chỉ có quyền khai trong manifest, chỉ cài trên repo cần, token cấp cho mỗi job hết hạn sau một giờ, và
mỗi khoá thu hồi riêng (khoá stg và prd của `svp-gitops-promoter` là hai khoá). GitHub không có API tạo hay cài App, nên hai cú bấm giữ
tay; script làm phần còn lại và kiểm bản cài bằng chính khoá của App.

### Một check tổng, từ đúng app

Ruleset chỉ đòi check tổng (`ci-ok` và `images-ok` ở `svp-backend`, `svp-frontend`; `gitops-ok`; `infra-ok`) cùng `pr-title`, hay
`docs` ở `svp-labs`, `.github`, không đòi từng job. Thêm, đổi tên hay tách job
trong workflow không đụng ruleset. Mỗi check ghim `integration_id` của app GitHub Actions: một status trùng tên do App khác hay token khác
ghi không thoả luật. Check bắt buộc chưa chạy lần nào thì mọi PR đứng chờ, nên ruleset mới (hay `pr-title` ở repo mới) chỉ áp sau khi
check đó đã xanh trên `main` (ADR-0047).

### Nhận quản hiện trạng, không sửa cho đẹp

Mỗi repo vào Terraform bằng `import` với giá trị là hiện trạng đọc bằng `gh api` GET, không phải cài đặt mong muốn. Đổi sau đó đi qua PR,
một thay đổi mỗi lần, `plan` thấy rõ. Chỗ code khác runbook dựng repo được ghi lại thay vì âm thầm sửa. Provider ghim chính xác: một bản
mới có thể đọc lại cài đặt khác đi và hiện thành thay đổi ở mọi repo.

| Lựa chọn của svp | Cái giá | Phương án khác | Khi nào chọn nó |
| --- | --- | --- | --- |
| Cài đặt GitHub bằng Terraform, người học apply | Cần cả SSO AWS lẫn token admin; state có giá trị biến | Sửa tay ở Settings; Probot Settings App đọc file trong repo | Ít repo, không cần drift hay lịch sử |
| 0 lượt duyệt bắt buộc | Không ai thứ hai xem PR; Scorecard Code-Review luôn thấp | 1 lượt duyệt, tài khoản thứ hai | Có người thứ hai có quyền ghi |
| `strict = false` | Hai PR xanh riêng có thể đỏ khi ghép, lộ ở lượt `main` | `strict = true`; merge queue | Repo thuộc organization (merge queue chỉ có ở đó) |
| Secret ngoài Terraform | Hai nơi giữ cài đặt, cần lệnh đọc lại | Resource secret với giá trị trong state có KMS | State đã mã hoá, quyền đọc state hẹp hơn quyền repo |
| GitHub App cho bot | Mỗi App một khoá phải xoay, hai cú bấm tay khi tạo | Token cá nhân (PAT) fine-grained | Việc một lần, không chạy trong CI |
| Environment người duyệt cho prd và plan | Người học vắng thì không promote prd, không plan | Chỉ Code Owner duyệt PR | Có cổng khác chặn được admin |

## Liên hệ đề SAP

- "Skill 5.1.1: Implement infrastructure as code by using declarative and imperative approaches (for example, AWS CloudFormation, AWS
  CDK)." Cài đặt của mọi repo khai báo trong root `github`; repo đã có nhận quản bằng khối `import {}`.
- "Skill 5.1.2: Design policy as code to perform proactive validation, enforcement, and drift remediation (for example, by using AWS
  CloudFormation Hooks, AWS CDK aspects, AWS Config rules, SCPs)." Ruleset chặn trước merge; `plan` thấy cài đặt sửa tay và `apply` đưa về.
- "Skill 5.1.3: Manage secrets in infrastructure code (for example, by using AWS Secrets Manager, AWS Systems Manager Parameter Store)."
  Khoá App, account ID không vào state hay tfvars commit; client ID là biến `sensitive`.
- "Skill 5.2.1: Design CI/CD solutions to orchestrate automated build and deployment pipelines (for example, by using AWS CodePipeline, AWS
  CodeBuild, AWS CodeDeploy, AWS CodeCommit)." Check bắt buộc và environment có người duyệt là cổng của pipeline phát hành.

| Tình huống trong đề | Chọn | Vì sao không chọn cái gần giống |
| --- | --- | --- |
| Pipeline dừng chờ một người duyệt trước khi deploy production | CodePipeline manual approval action | CodeDeploy blue/green chỉ chờ trước khi chuyển traffic (`ContinueDeployment`), không là cổng duyệt của pipeline |
| Chặn tài nguyên sai chuẩn trước khi CloudFormation tạo nó | CloudFormation Hooks | AWS Config rules chế độ detective đánh giá sau khi tài nguyên đã có; chế độ proactive chỉ trả kết quả, không tự chặn gì khi không có Hook |
| Biết stack nào bị sửa tay ngoài template | CloudFormation drift detection | AWS Config ghi lịch sử cấu hình tài nguyên, không so với template |
| Template cần mật khẩu mà không ghi giá trị vào template | Dynamic reference tới Secrets Manager | Tham số thường của template hiện giá trị khi đọc stack |
| Pipeline ngoài AWS cần vào account mà không giữ khoá dài hạn | IAM OIDC identity provider và role | Access key của IAM user sống lâu, phải tự xoay |

## Đọc sâu

- Provider `integrations/github` ghim chính xác trong `versions.tf`; Renovate mở PR khi có bản mới, `plan` phải ra `No changes.` trước khi
  merge thay đổi khác.
- Token GitHub đi vào `terraform` qua biến môi trường `GITHUB_TOKEN` (`gh auth token`), chỉ cho tiến trình đó; root không có provider AWS
  nên không `default_tags`, `allowed_account_ids`, nhưng backend S3 vẫn cần phiên SSO `anhnv-sso`.
- Biến client ID nằm trong một map riêng (`promote_app_client_ids`) vì Terraform từ chối giá trị `sensitive` trong đối số `for_each`.
- Provider không có trường `require_extra_approval_for_unattributed_changes` của luật `pull_request`; GitHub để `true`; `make github-check`
  đọc lại sau mỗi `apply` sửa ruleset.
- `github_actions_repository_permissions` có `prevent_destroy`: destroy đưa repo về cho phép mọi action. Thôi quản một tài nguyên dùng
  khối `removed` với `destroy = false`.
- Import repo với provider 6.13.0 hiện hai trường chỉ sống trong state (`archive_on_destroy`, `ignore_vulnerability_alerts_during_read`).

Làm và tra cứu:

- [`github-setup.md`](../runbooks/github-setup.md): dựng trên account mới, đổi cài đặt, xoay khoá, environment `terraform-plan`.
- [`github`](../../github/README.md): tài nguyên của root, bảng "Không quản, và vì sao".
- [14. CI](14-ci.md): workflow dùng các check, environment và role plan.
- [ADR-0041](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0041-github-hardening.md): Code Owner, chỉ squash, `promote-prd`.
- [ADR-0015](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0015-cicd-devsecops-stage5.md) §11: ruleset và check bắt buộc.
- [ADR-0076](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0076-terraform-plan-infracost-pr.md) §9: environment
  `terraform-plan`.
