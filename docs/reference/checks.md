# Lệnh kiểm

Trang này tra mọi phép kiểm tĩnh của repo: target `make` làm gì, image nào chạy nó, file cấu hình nào nó đọc, chạy song song an toàn ra
sao, hook pre-commit và ngoại lệ trivy. Không phép nào ở đây chạm account AWS. Plan và chi phí trên PR:
[`docs/reference/ci.md`](ci.md).

## Bảng lệnh

Chạy từ gốc repo, không cần credential AWS, cần Docker và mạng (registry Terraform, GitHub cho plugin tflint, GHCR cho bộ luật trivy):

| Lệnh | Làm gì |
| --- | --- |
| `make check` | bốn nhóm `check-terraform`, `check-lint`, `check-test`, `check-scripts` rồi `docs-check`, `diagrams-check`; target của mỗi nhóm ở dòng của nhóm trong `Makefile` (`make help` in ra) |
| `make check-terraform` / `check-lint` / `check-test` / `check-scripts` | từng nhóm của `make check`, mỗi nhóm một job của CI |
| `make hooks` / `make pre-commit [FILES='<file …>']` | bật hook / chạy phép kiểm nhanh của hook (mục [Hook pre-commit](#hook-pre-commit)) |
| `make check DIRS="aws/modules/x aws/envs/stg"` | như trên, sáu phép Terraform chỉ trên các thư mục đó; thư mục không có, không có `*.tf` hay nằm ngoài repo thì dừng, nêu thư mục |
| `make fmt-check` / `make fmt` | `terraform fmt -check -diff -recursive` / viết lại file |
| `make validate` | mỗi thư mục: `terraform init -backend=false -input=false`, rồi `terraform validate`; provider và module nằm ở thư mục tạm (`TF_DATA_DIR`), nên `.terraform/` của người học đã `init` với backend S3 không bị đọc hay ghi |
| `make tflint` | mỗi thư mục: `tflint --init`, rồi `tflint` với `.tflint.hcl` |
| `make trivy` | `trivy config` mỗi thư mục; HIGH và CRITICAL làm đỏ (mục [Cách `make trivy` quét](#cách-make-trivy-quét)) |
| `make shellcheck [SH='<file …>']` | shellcheck trên mọi `*.sh` (bản image, `--network none`; máy không cài shellcheck); `SH` chỉ kiểm các file đó, cho lúc sửa một script |
| `make session-test` | tự kiểm script của `aws/scripts` với lệnh giả trên PATH, không account, cluster hay mạng: `session-test.sh` (mọi bước của buổi, khớp bảng bước của runbook buổi với `session.sh --print`), rồi mỗi `*-test.sh` còn lại; mỗi file lỗi một dòng `FAIL: <file>` |
| `make zizmor` | lint bảo mật workflow bằng zizmor (`--persona=regular`), mọi finding làm đỏ; có `GH_TOKEN` thì chạy thêm audit online (impostor commit, action có lỗ hổng), không thì offline; `ZIZMOR_FORMAT=github` in annotation |
| `make docs-check [DOCS='<file hay glob>']` | markdownlint-cli2 theo `.markdownlint.yaml`, rồi lychee `--offline --include-fragments` (link tương đối và anchor heading; link ra ngoài không kiểm), container `--network none`; mặc định mọi `.md` git theo dõi và file mới chưa theo dõi, trừ `.claude/` (cấu hình agent, không phải tài liệu của repo) |
| `make diagrams [NAMES='<tên …>'] [PNG=1] [OUT=<thư mục>]` | D2 sinh `docs/diagrams/<tên>.svg` (theme sáng) và `<tên>-dark.svg` (theme tối) từ `<tên>.d2`, container ghim digest `--network none`; cờ và luật ở [`docs/diagrams/README.md`](../diagrams/README.md) |
| `make diagrams-check [NAMES='<tên …>']` | sinh vào thư mục tạm và so với SVG đã commit; đỏ khi SVG lệch, thiếu, hay (khi không `NAMES`) SVG không còn `.d2` cùng tên |
| `make lock [DIRS=<root>]` | `init -backend=false` rồi `terraform providers lock` cho ba nền tảng; module bị bỏ qua |
| `make tfdocs` / `make tfdocs-check` | terraform-docs ghi / kiểm khối sinh (requirements, providers, resources, inputs, outputs) giữa `<!-- BEGIN_TF_DOCS -->` và `<!-- END_TF_DOCS -->` của `README.md` mỗi module; `tfdocs-check` đỏ khi README lệch `.tf`, root bị bỏ qua; container `--network none` |
| `make test` | `terraform test` của mỗi module (`tests/*.tftest.hcl`): `init -backend=false` trong một container, rồi `terraform test` trong container `--network none` với image `TERRAFORM_IMAGE` ghim digest, chỉ thư mục module và cache provider được mount (chỉ đọc), không biến `AWS_*` nào (bỏ bằng `env -u`), không `~/.aws`, `.envrc`, `backend.hcl`; file test chỉ được nhận khi theo khuôn: đúng một dòng `mock_provider "aws" {`, mỗi `run "<tên>" {` có `command = plan` ở dòng không trống đầu tiên, không dòng nào khác bắt đầu bằng `run`, `mock_provider`, `provider`, `override_`, `module`, `command`, `/*`, không `alias`, `*/`, heredoc, symlink hay `*.tftest.json`; sai thì bị từ chối, nêu file và dòng; root bị bỏ qua |
| `make test-guard` | tự kiểm ba luật của `make test` với `docker` giả trên PATH: file test sai bị từ chối, lệnh docker có `--network none`, image ghim digest, chỉ mount thư mục dữ liệu, module và cache provider (chỉ đọc), không biến hay file credential AWS nào tới container |
| `make inventory` | sinh lại [`inventory.md`](inventory.md) (tài nguyên mỗi root tạo trên account trống) và sơ đồ của nó ở `docs/diagrams/inventory/` từ plan của `terraform test` trên provider giả, mọi root, mỗi env; chạy sau khi đổi root, module, cờ hay `<env>.tfvars` (mục [Inventory](#inventory)) |
| `make inventory-check` | sinh vào thư mục tạm và so với bản commit; đỏ khi trang, `.d2` hay SVG lệch hay thiếu, hay file trong `docs/diagrams/inventory/` không còn được sinh, nêu file |
| `make inventory-test` | tự kiểm `ci/inventory.sh` với `docker` giả trên PATH và một cây giả có file cá nhân mang giá trị canary: lượt `terraform test` có `--network none`, không biến `AWS_*` hay file credential nào tới container, chỉ mount bản chép (chỉ đọc), thư mục dữ liệu và cache provider (chỉ đọc), bản chép không có canary, `*.auto.tfvars`, `backend*.hcl`, `.envrc`, state, override hay symlink; trang đếm đúng phần, loại, import; `check` nêu file lệch và file thừa; file cá nhân đã `git add -f` vẫn không vào bản chép (mỗi mẫu của bộ lọc một ca); root thiếu `notes` hay thiếu trong `ROOTS` thì dừng |
| `make github-app-test` | unit test của `github/scripts/github-app.py` và phép kiểm manifest của nó (không mạng, `gh` hay account) |
| `make ci-plan-test` | tự kiểm `ci/terraform-plan.sh` với `docker`, `curl`, `gh` giả trên PATH và một bản chép của repo ở thư mục tạm: từ chối chạy ngoài Actions, cổng (biến bật plan, fork, gốc không plan, PR Renovate), buổi mở hay không, thứ tự lệnh Terraform, token mới mỗi lệnh, secret account cần và không cần, khoá media lấy từ state, giá trị che vắng khỏi log và tóm tắt, stdout của `plan` không vào log, lỗi `init`, `plan` làm đỏ với stderr đã che, tóm tắt đúng số và address của `ci/testdata/plan.json`; bước đăng comment của `plan.yml` chạy đúng như trong file với `gh` giả (đăng mới, sửa comment dính, cắt khi quá dài) |
| `make ci-plan ENV=<stg\|prd>` | plan của job `plan` trong `plan.yml`; từ chối chạy khi thiếu `GITHUB_ACTIONS=true` và `ACTIONS_ID_TOKEN_REQUEST_URL`, nên không bao giờ chạy trên máy dev |
| `make infracost-test` | tự kiểm `ci/infracost.sh` với `docker` giả trên PATH và một bản chép của script ở thư mục tạm: không khoá thì từ chối trên máy, bỏ qua có notice trong Actions, PR từ fork bỏ qua, thứ tự lệnh (breakdown cây base, breakdown cây PR, `diff`), hai cây mount chỉ đọc, khoá và token GitHub chỉ vào container theo tên, không bao giờ trong tham số, output hay job summary, bảng tổng mỗi project, lệnh `comment` đúng cờ; `INFRACOST_IMAGE` ghim digest có dòng `# renovate:` |
| `make infracost BASE=<cây base>` | chi phí tháng theo HCL của các project trong `infracost.yml` ở cây base và ở cây này, rồi `diff`, cho job `infracost` của `cost.yml`; cần `INFRACOST_API_KEY`, thiếu thì từ chối trên máy |
| `make infracost-comment` | đăng diff của `make infracost` lên PR `PR` của `REPO` bằng `infracost comment github --behavior update`, cho job `infracost-comment`; cần `INFRACOST_API_KEY`, `GITHUB_TOKEN` |
| `make help` | liệt kê target |

Target ghi cài đặt GitHub (`github-*`, `infracost-key`) là việc của người học: bảng "Script và target dựng" của
[mục lục runbook](../runbooks/README.md).

## Image và chỗ chạy

Chưa có thư mục `*.tf` nào thì sáu phép Terraform in một dòng và qua. Mọi công cụ chạy bằng image ghim digest ở đầu `Makefile`, mỗi image
một biến `*_IMAGE` có dòng `# renovate:` ngay trên; `MARKDOWNLINT_IMAGE`, `LYCHEE_IMAGE`, `TRIVY_IMAGE`, `ZIZMOR_IMAGE` cùng bản ghim của
repo code. terraform-docs chỉ có tag theo kiến trúc nên ghim cả hai cùng bản (`TFDOCS_IMAGE_AMD64`, `TFDOCS_IMAGE_ARM64`), `Makefile`
chọn theo `uname -m`. Cùng một tham chiếu trên máy dev và trong CI, nên không cài gì thêm và không tin action setup nào. jq của
`ci/inventory.sh` và `ci/terraform-plan.sh` cũng chạy trong image ghim (`JQ_IMAGE`): jq của runner và của Mac khác bản, nhận chương trình
khác nhau, nên chương trình chạy được trên máy vẫn có thể đỏ trên runner.

Các target tự kiểm chạy trên máy chủ, không container: `session-test` chỉ cần bash, git và jq mà máy Mac và runner CI đều có, `test-guard`
chạy với `docker` giả, `github-app-test` dùng python3, `ci-plan-test` chạy với `docker` (vai terraform), `curl`, `gh` giả còn jq của
script chạy thật trong `JQ_IMAGE`, `infracost-test` chạy với `docker` giả, `inventory-test` chạy với `docker` giả. Image chạy qua
`env -u DOCKER_DEFAULT_PLATFORM docker run` (shell của máy đặt `linux/amd64` cho dự án khác), container chạy dưới uid của người gọi.

Không target nào gọi `apply`, `destroy`, `import`, `output` hay `aws`. Chỉ `ci-plan`, target của job CI, đọc account: `state pull` và
`plan` chỉ đọc; ngoài nó không target nào gọi `state`, và `plan` duy nhất là các `run` của `make test` và của `make inventory`,
`inventory-check`, trên provider giả (`mock_provider`), không mạng, không credential.

## Tệp cấu hình

| Tệp | Việc |
| --- | --- |
| `Makefile` | mọi target kiểm, image ghim digest, `make lock`, `make fmt`, `make tfdocs`, `make ci-plan` (chỉ job CI) |
| `.tflint.hcl` | ruleset terraform (recommended) và aws ghim version |
| `.trivyignore.yaml` | ngoại lệ của trivy trong module tải từ registry (mục [Ngoại lệ trivy](#ngoại-lệ-trivy)) |
| `.terraform-docs.yml` | cấu hình khối sinh của README module |
| `.markdownlint.yaml` | luật markdownlint của `make docs-check` (cùng file của repo code) |
| `lychee.toml` | cấu hình lychee của `make docs-check` (cùng file của repo code) |
| `.github/zizmor.yml` | ngoại lệ của zizmor, mỗi mục một lý do (tạo khi có ngoại lệ đầu tiên) |
| `renovate.json` | Renovate nâng provider, module, ruleset tflint, image ghim của `Makefile`, action |
| `CODEOWNERS` | đường có chủ: PR đổi chúng cần Code Owner duyệt (danh sách ở file) |
| `LICENSE` | Apache-2.0 |

Workflow, `infracost.yml`, `infracost-usage.yml`: [`docs/reference/ci.md`](ci.md).

## Root và module

Thư mục nằm dưới một thư mục `modules/` là module, mọi thư mục `*.tf` khác là cấu hình gốc (root). Root commit `.terraform.lock.hcl` (hash
của `darwin_arm64`, `linux_amd64`, `linux_arm64`) và `make check` dùng nó ở chế độ chỉ đọc (`init -lockfile=readonly`), nên đổi provider
của root phải chạy `make lock DIRS=<root>` trước. Module không commit lock file (`.gitignore`): root gọi nó quyết version provider.

## Khối sinh của README module

Khối nằm giữa `<!-- markdownlint-disable MD033 -->` và `<!-- markdownlint-enable MD033 -->`: terraform-docs viết giá trị mặc định dạng
danh sách bằng HTML (`<pre>`, `<br/>`) và chép nguyên mô tả của biến, output, nên `docs-check` không đòi luật inline HTML trong khối đó;
phần viết tay ngoài khối vẫn theo đủ luật.

## Test của module

`aws/modules/<module>/tests/*.tftest.hcl`: mỗi rule `validation` trong `variables.tf` có một `run` với giá trị chỉ rule đó từ chối và
`expect_failures` trỏ biến, mỗi module một `run` giá trị hợp lệ; data source cần giá trị có hình (JSON của policy, ARN, danh sách zone) lấy
từ `mock_data` của file test vì provider giả vẫn kiểm đối số. Policy IAM được kiểm qua đối số của các data source
`aws_iam_policy_document` (provider giả trả JSON cố định cho chúng), nên JSON đó phải là một policy. Ví dụ, test của `account-baseline`
kiểm ai dùng được key state, bucket state được bảo vệ ra sao, tên zone, uỷ quyền zone con và bốn cảnh báo budget, rồi mỗi rule
`validation` một plan. Thêm rule `validation` thì thêm `run` trong cùng thay đổi.

`make test` từ chối file test sai khuôn thay vì dò từng cách phá luật (một `run` không có `command` thì apply; một mock đặt dưới `alias`
để provider thật làm mặc định). Chỉ `init`, trong một container riêng, tải provider và module registry; container chạy test có `HOME` là
`/tmp` của container và chỉ mount thư mục module (chỉ đọc), không bao giờ `~/.aws`, gốc repo hay thư mục env. Chuỗi trong HCL không xuống
dòng, nên khi khối comment và heredoc bị cấm thì mỗi dòng được đọc đúng như HCL đọc nó. Vì thế dòng chứa `*/` (kể cả dòng comment, vì `/*`
có thể nằm trong chuỗi như một origin) hay `<<` (heredoc) bị từ chối: dòng của hai thứ đó có thể giả làm dòng khuôn. Khuôn đủ ở
[`AGENTS.md`](../../AGENTS.md); `make test-guard` kiểm ba luật mà không khởi động container nào.

## Inventory

`make inventory` trả lời "chạy root này trên account trống thì tạo gì, bao nhiêu" cho từng root (mỗi env của `aws/accounts`, `aws/envs`,
`aws/gitops`), ghi vào [`inventory.md`](inventory.md) cùng một sơ đồ D2 mỗi root có icon dịch vụ AWS. Mỗi root một lượt:

1. Chép các file git theo dõi dưới `aws/`, `github/` vào thư mục tạm, bỏ mọi file có thể chứa giá trị cá nhân dù đã lỡ commit
   (`*.auto.tfvars*`, `terraform.tfvars*`, `backend*.hcl` trừ `.example`, `.envrc`, `.terraform/`, state, plan, `.session/`, override) và
   symlink; bản chép còn file nào như vậy thì dừng.
2. Đặt `ci/inventory/<root>.tftest.hcl` vào `tests/` của root trong bản chép: provider giả cho mọi provider và alias của root, giá trị giả
   cho data source quyết định `count`, `for_each`, validation (danh sách account, zone, repo ECR, file của svp-gitops), một `run` với
   `command = plan`. Root có env dùng chung một file cho stg và prd.
3. `terraform init -backend=false` trong container có mạng (tải provider vào `.plugin-cache/`, khoá như `make test`), rồi `terraform test
   -json -verbose` trong container `--network none`, mount bản chép và cache chỉ đọc, không biến `AWS_*`; biến từ `<env>.tfvars`, rồi
   `*.auto.tfvars.example`.
4. Đếm `resource_changes` của plan (tài nguyên managed, `create` hay import) theo phần (lời gọi module cấp root, hay file `.tf` khai báo
   tài nguyên của root) và loại; mỗi loại AWS ứng một dịch vụ và icon ở `docs/diagrams/icons/` (bảng `SERVICES` của
   `ci/inventory.sh`: loại AWS mới ngoài bảng làm lượt chạy đỏ, để chọn icon một lần).

Plan đỏ vì giá trị giả (validation, precondition) thì sửa giá trị giả trong `ci/inventory/`, không sửa root; giả định nào đổi số thì ghi ở
mục của root trong trang (hàm `notes` của `ci/inventory.sh`). Một lượt đủ mất khoảng hai phút khi cache đã có provider. `inventory-check`
ở job `check (test)` của CI; PR chỉ đổi `docs/reference/inventory.md`, `docs/diagrams/inventory/`, `docs/diagrams/icons/` hay
`docs/diagrams/tokens.d2` vẫn chạy job đó. Thư mục có `*.tf` ngoài `modules/` (cách `LIST_DIRS` của `Makefile` tìm root) mà không nằm trong
`ROOTS` của `ci/inventory.sh` làm `inventory-check` đỏ, nêu thư mục đó.

## Chạy song song

Chạy trên hai thư mục khác nhau (`make check DIRS=a` và `make check DIRS=b` cùng lúc) an toàn: mỗi lượt ghi dưới thư mục nó kiểm, còn
cache dùng chung chỉ có một người ghi mỗi lúc:

- thư mục tạm của lượt (`TF_DATA_DIR`): module tải về và link tới provider trong cache, xoá khi lượt kết thúc;
- `.plugin-cache/` (gitignore): provider Terraform (`TF_PLUGIN_CACHE_DIR`, bản Linux của container, hàng trăm MB cho provider AWS) và
  ruleset tflint (`TFLINT_PLUGIN_DIR`), mỗi version tải một lần cho mọi thư mục. `init` và `tflint --init` chỉ thêm version còn thiếu, lần
  lượt (khoá `.plugin-cache/lock`, `mkdir` nguyên tử); `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE` cho module chưa có lock file dùng
  bản trong cache, hash trong lock của root vẫn được kiểm. Container `terraform test` thấy cache chỉ đọc. Cache giữ mọi version đã tải: xoá
  `.plugin-cache/` cùng lock file của module (`aws/modules/**/.terraform.lock.hcl`) khi không có `make` nào chạy, để lấy lại đĩa hay sửa
  một bản giải nén dở;
- `<dir>/.terraform.lock.hcl` của module (root chỉ đọc lock của nó; `make lock` thì ghi);
- cache của trivy, zizmor nằm trong container (`/tmp/trivy`, `/tmp/zizmor`) và mất khi container dừng; `session-test` chỉ ghi trong một thư
  mục tạm riêng của nó và xoá thư mục đó; shellcheck, `docs-check` không ghi gì.

`.terraform/` mà người học `init` với backend thật không bị `make check` đọc hay ghi.

## Hook pre-commit

`make hooks` (một lần mỗi clone) cài hook `pre-commit` của git chạy `make pre-commit`; hook khác đã có thì không bị ghi đè. Hook chỉ kiểm
bản đã stage của file đổi, chép ra thư mục tạm, mỗi phép một container ghim digest không mạng, vài giây mỗi lần commit:

- `terraform fmt -check` trên `*.tf`, `*.tfvars`, `*.tftest.hcl`;
- markdownlint trên `*.md` (trừ `.claude/`), shellcheck trên `*.sh`;
- gitleaks (cùng version với repo code) trên các dòng commit thêm vào, không cả file: fixture của test đã commit chứa khoá giả.

`validate`, `tflint`, `trivy`, `test` và link của `docs-check` để CI chạy. `make pre-commit FILES='<file …>'` kiểm các file đó trong cây làm
việc (cả file) mà không cần stage. Hook cần Docker đang chạy; `git commit --no-verify` bỏ qua hook, CI vẫn chặn. Mọi worktree của clone
dùng chung hook: ở nhánh mà `Makefile` chưa có target `pre-commit`, hook cho commit qua kèm một dòng nhắc.

## Ngoại lệ trivy

Finding trong file `.tf` của repo này bỏ qua ngay cạnh resource bằng dòng `#trivy:ignore:<id>`, lý do ở comment ngay trên; finding trong
module tải từ registry (không comment được) vào `.trivyignore.yaml`, `paths` tương đối với thư mục được kiểm. Sửa được thì sửa, không ghi
ngoại lệ. Mỗi mục của `.trivyignore.yaml` có `id`, `paths` (không bao giờ một id cho mọi file), `statement` (lý do) và, khi quyết định đang
chờ việc khác, `expired_at` (yyyy-mm-dd). trivy so `paths` với đường nó báo, với module registry là
`<namespace>/<name>/<provider>/<file>` (ví dụ `terraform-aws-modules/eks/aws/main.tf`). Luật ghi phạm vi (`Scope:`) trong lý do, và vì
sao ngoại lệ chỉ-stg không che finding của prd, ở mục "Ngoại lệ trivy" của [`AGENTS.md`](../../AGENTS.md).

## Cách `make trivy` quét

Finding HIGH hoặc CRITICAL làm đỏ; ngoại lệ có chủ đích nằm ở `.trivyignore.yaml`, mỗi mục kèm lý do. `--skip-dirs` bỏ thư mục `examples/`
mà module registry kèm theo (manifest Kubernetes và root mẫu mà Terraform không bao giờ apply), dù module được gọi từ root nào, nên không
ngoại lệ nào phải lặp theo từng root. `--skip-check-update` giữ bộ luật dựng sẵn trong image ghim: bộ luật trivy sẽ tải về nằm sau một tag
trôi, nên luật mới có thể làm check bắt buộc đỏ trên code không đổi, hay một luật biến mất mà không ai hay. Module registry do chính trivy
tải về và được quét với cấu hình gọi nó. Mỗi root được quét với giá trị của env nó chạy: `<thư mục>/<phần cuối của tên thư mục>.tfvars`
(`aws/envs/prd/prd.tfvars`), khi file đó có, đi vào `--tf-vars`, nên ngoại lệ chỉ đúng cho một env (ignore có điều kiện thuộc tính, ignore
trên lời gọi module trong root của env đó) không bao giờ che finding của env khác. Module, hay root không có file đó, được quét với giá trị
mặc định của biến.

## CI

`check.yml` chạy mỗi nhóm `check-*` thành một job song song và `docs-check`, `diagrams-check` thành job `docs` (chạy mọi PR, kể cả PR
chỉ đổi tài liệu, nên mỗi lượt render sơ đồ một lần); check bắt buộc của ruleset `main` là
`infra-ok`. Job, quyền, phút billable, tiêu đề PR và Scorecard: chương [14. CI](../handbook/14-ci.md).
