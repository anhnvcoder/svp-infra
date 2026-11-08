# svp-infra — Terraform của lab short-video-platform: hướng dẫn cho agent

File này theo định dạng [AGENTS.md](https://agents.md): luật làm việc cho mọi agent.

Đọc trước khi làm bất cứ việc gì: [`README.md`](README.md) (bố cục, lệnh kiểm, luật an toàn) và
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) (thiết kế hạ tầng AWS). Thiết kế và
quyết định chung của lab nằm ở `docs/` của repo code (bản clone `<workspace>/backend`); đổi một quyết định đã chốt thì đề xuất kèm ADR ở đó.

## An toàn cloud

- **AI chỉ chạy:** `make check` (và từng target của nó: `fmt-check`, `validate`, `tflint`, `tfdocs-check`, `trivy`, `shellcheck`, `zizmor`, `docs-check`,
  `session-test`, `test-guard`, `test`), `make fmt`,
  `make tfdocs` (terraform-docs, chỉ đọc `.tf`), `make lock`, tức `terraform fmt`, `terraform init -backend=false`, `terraform validate`, `terraform providers lock`; `bash -n`,
  test script với lệnh giả trên PATH; `aws --version`.
- **`terraform test` chỉ qua `make test`**, target tự ép ba điều kiện, không tin người viết test: (1) chạy trong container image Terraform
  ghim digest (`TERRAFORM_IMAGE`) với `--network none`; (2) không truyền credential nào: `env -u` mọi biến `AWS_*`, không `-e AWS_*`, không
  mount `~/.aws`, `.envrc`, `backend.hcl` (chỉ mount thư mục module, module chứa `.envrc` hay `backend.hcl` bị từ chối); (3) mỗi
  `tests/*.tftest.hcl` có `mock_provider "aws"` và mọi `run` là `command = plan`, kiểm theo khuôn cố định (allowlist) chứ không dò từng cách viết
  sai: đúng một dòng `mock_provider "aws" {` (hay `mock_provider "aws" {}`) đứng riêng; mỗi `run` mở bằng dòng `run "<tên>" {` (chữ, số, `_`, `-`)
  và dòng không trống đầu tiên bên trong là `command = plan`; dòng khác bắt đầu bằng `run`, `mock_provider`, `provider`, `override_`, `module`,
  `command` hay `/*`, dòng nào chứa `alias`, `*/` hay `<<` (heredoc), symlink trong thư mục module và `*.tftest.json` đều bị từ chối, target nêu
  file và dòng. `make test-guard` kiểm chính ba điều kiện với `docker` giả. AI không chạy `terraform test` trần.
- **AI không chạy lệnh nào chạm account AWS, kể cả chỉ đọc:** `terraform init` có backend, `plan`, `apply`, `destroy`, `import`,
  `state`, `output`, `test` trần (ngoài `make test`), `refresh`; `aws` (trừ `--version`); script hay chương trình dùng SDK AWS; script buổi của `aws/scripts/`.
- **Mọi lệnh chạm account do người học chạy** theo script và runbook viết sẵn, mỗi bước một khối, nói rõ cần dán lại output nào và tìm gì
  trong đó. Mỗi account một profile SSO và một biến account (export trong terminal, không ghi vào file nào): management `anhnv-sso` +
  `SVP_AWS_MGMT_ACCOUNT_ID` (`aws/bootstrap`, `aws/org`, `github/`), stg `anhnv-stg` + `SVP_AWS_STG_ACCOUNT_ID`, prd `anhnv-prd` +
  `SVP_AWS_PRD_ACCOUNT_ID` (`aws/accounts/<env>`, `aws/envs/<env>`, `aws/gitops/<env>`). Lệnh viết sẵn ghi profile của đúng account đó ngay
  trong lệnh, `TF_VAR_account_id` từ biến của account đó, và `--region` (`ap-southeast-1` cho dịch vụ theo region và STS, `us-east-1` cho
  Organizations, WAF của CloudFront, Pricing Plan Manager và API Free Tier, region của Identity Center cho `sso-admin`, `identitystore`);
  không dựa vào region của profile, không một `AWS_PROFILE` chung cho cả repo. Trước mọi lệnh ghi: `aws sts get-caller-identity` với **cùng profile** (`aws/scripts/check-account.sh
  mgmt|stg|prd`), hai bên cùng đọc account. Script buổi lấy profile và biến từ bảng env của `aws/scripts/lib.sh`. Buổi tạo tài nguyên kết
  thúc bằng lệnh destroy và lệnh quét sót (`sweep.sh <env>` rồi `sweep.sh mgmt`); AI nhắc tới khi người học xác nhận đã chạy cả hai.
- CI (`check.yml`) không có credential AWS, secret, OIDC hay environment nào; thêm thì phải có ADR trước.

## Quy ước

Quy ước chung (ngôn ngữ, tài liệu timeless, ADR, comment, Git, repo public, phụ thuộc): [`CONTRIBUTING.md` của `anhnvcoder/.github`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md); dưới đây chỉ luật riêng của repo này.

- **Ngôn ngữ viết:** file `.md` viết tiếng Việt.
- **Repo public, không commit:** state (`*.tfstate*`), plan (`*.tfplan`), `backend.hcl`, `backend-<env>.hcl`, `*.auto.tfvars` hay `terraform.tfvars` (chứa
  account ID, IP, email, tên miền thật), override (`*_override.tf`), `.terraform/`, `.session/`. Ví dụ và test dùng `000000000000`,
  `svp.example`, `<domain>`. Tên bucket theo `<tên>-<account>-<region>`, tính từ `var.account_id` lúc chạy, nên account thật vẫn không
  nằm trong file commit nào.
- **Root và module:** thư mục dưới `modules/` là module (không commit lock file), thư mục `*.tf` khác là root (commit
  `.terraform.lock.hcl` ba nền tảng bằng `make lock DIRS=<root>`). Provider ghim trong lock của root; module registry ghim version chính
  xác. Root đặt `default_tags` `Project=svp`, `ManagedBy=terraform`, `Stack=<tên>` và `allowed_account_ids = [var.account_id]`.
- **Root `github/`** (cài đặt GitHub của các repo trong `local.repositories` của `github/repositories.tf`, provider
  `integrations/github`): không provider AWS nên không `default_tags`, `allowed_account_ids`; `plan`, `apply` cần token GitHub admin và
  đăng nhập AWS (state ở bucket của `aws/bootstrap`), chỉ người học chạy.
- **Ngoại lệ trivy** (luật đủ ở đầu `.trivyignore.yaml`): sửa được thì sửa. Finding trong `.tf` của repo bỏ qua bằng `#trivy:ignore:<id>`
  ngay trên resource, lý do ở comment; finding trong module registry vào `.trivyignore.yaml` (`paths` không bao giờ là mọi file). Mỗi ngoại lệ
  ghi phạm vi trong lý do, một dòng mỗi id: `Scope: every environment.` hay `Scope: stg only; prd: <prd làm gì thay>.`. `make trivy` quét
  mỗi root với giá trị của env (`<root>/<env>.tfvars`), và ngoại lệ chỉ-stg không bao giờ che finding của prd: nó nằm ở lời gọi module trong
  root stg, hay trong module với điều kiện trên thuộc tính khác nhau giữa hai env, đặt đúng giá trị của stg
  (`#trivy:ignore:AWS-0039[create_kms_key=false]` của `aws/modules/eks/cluster.tf`). trivy khớp điều kiện trên thuộc tính chuỗi ở mọi nơi quét,
  còn trên bool hay số chỉ khi quét chính module, nên root cần ngoại lệ như vậy lặp lại nó ở lời gọi module (`aws/envs/stg/main.tf` lặp
  `#trivy:ignore:AWS-0039` trên `module "eks"`). `.trivyignore.yaml` không có mục chỉ-stg nào (`paths` không phân biệt được env).
- **Docker** chỉ qua `Makefile` (`env -u DOCKER_DEFAULT_PLATFORM docker run …`, image ghim digest có dòng `# renovate:` ngay trên).
- **Card chạy song song** kiểm bằng `make check DIRS=<thư mục của mình>`: mỗi lượt chỉ ghi dưới thư mục đó, không có cache dùng chung.
- **Git:** mọi thay đổi vào `main` qua PR có `infra-ok` xanh (từ khi bật ruleset), squash merge.
- **Tiêu đề PR** thành tiêu đề commit squash, theo Conventional Commits: `<type>[(<scope>)][!]: <mô tả>`, `type` là một trong
  `feat fix chore docs refactor test ci build perf revert`, hoặc `Revert "<tiêu đề>"`; check `pr-title` (`.github/workflows/pr-title.yml`)
  chặn tiêu đề sai. Đổi regex thì đổi cùng bộ thử ở cả bốn repo có CI.
- **Đường có chủ** (`CODEOWNERS`): `CODEOWNERS`, `.github/`, `renovate.json`, `Makefile`, `.trivyignore.yaml`, `github/`, `aws/`; PR đổi
  chúng cần Code Owner duyệt.
- **Workflow:** mọi workflow qua `make zizmor` sạch; ngoại lệ có chủ đích vào `.github/zizmor.yml`, mỗi mục một comment lý do.
