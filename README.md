# svp-infra

Terraform của nền tảng video ngắn [svp-backend](https://github.com/anhnvcoder/svp-backend): nền mà Argo CD triển khai
lên (mạng, cluster, dữ liệu managed, DNS) cho AWS ở giai đoạn 7, sau đó GCP (giai đoạn 8), Cloudflare (8b), GitHub dưới dạng code (7c).
Repo code giữ service, chart và CI build image; [svp-gitops](https://github.com/anhnvcoder/svp-gitops) giữ cái gì chạy ở mỗi env; repo
này dựng chỗ để chạy. Thiết kế và lý do ở
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §2; cài đặt GitHub của repo ở
[runbook `svp-infra-setup.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/svp-infra-setup.md).

Repo public: **không account ID, IP, email, tên miền thật, state hay plan nào ở đây** (mục "Luật an toàn").

## Bố cục

```text
Makefile                      make check (fmt, validate, tflint, trivy, shellcheck), make lock, make fmt
.tflint.hcl                   ruleset terraform (recommended) và aws ghim version
.trivyignore.yaml             ngoại lệ của trivy trong module tải từ registry
renovate.json                 provider, module, ruleset tflint, image ghim của Makefile, action
.github/workflows/check.yml   PR và push main: make check; check tổng infra-ok; chỉ contents: read, không secret
aws/
  bootstrap/                  một lần mỗi account, giữ giữa các buổi: bucket state, budget, hosted zone aws.<domain>
  modules/                    module nội bộ (network, eks, rds, media); lock file không commit
  envs/<env>/                 cấu hình gốc của mỗi env (stg ở 7a, prd ở 7b): một state key mỗi env
  scripts/                    script buổi AWS (kiểm account, DNS, bootstrap Argo CD, đo, pre-destroy, sweep)
github/                       cài đặt GitHub của các repo trong `local.repositories` (repo, quyền Actions, ruleset, environment promote); state trong bucket của aws/bootstrap
docs/diagrams/                sơ đồ AWS svp-aws.drawio (trang stg, prd, flows), PDF, PNG nhúng ở docs của repo code; sinh từ spec
.claude/skills/aws-drawio-diagram/   spec và checker của sơ đồ (luật vẽ ở SKILL.md)
```

**Sơ đồ** ([`docs/diagrams/svp-aws.pdf`](docs/diagrams/svp-aws.pdf)): sinh bằng
`python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py --pdf --docs`, không sửa tay trong draw.io. Cỡ của mỗi trang env đọc từ
`aws/envs/stg/stg.tfvars` và cột prd của bảng biến trong README module, nên đổi cỡ thì build lại. Kiểm trước khi commit:
`check_diagram.py docs/diagrams/svp-aws.drawio` (hình học) và `check_svp_counts.py` (số AZ, subnet, NAT, node group, RDS khớp cỡ của env),
cả hai chạy offline, không cần credential. Xuất PDF, PNG cần CLI draw.io (`brew install --cask drawio`, hay biến `DRAWIO`).

**Root và module:** thư mục nằm dưới một thư mục `modules/` là module, mọi thư mục `*.tf` khác là cấu hình gốc (root). Root commit
`.terraform.lock.hcl` (hash của `darwin_arm64`, `linux_amd64`, `linux_arm64`) và `make check` dùng nó ở chế độ chỉ đọc
(`init -lockfile=readonly`), nên đổi provider của root phải chạy `make lock DIRS=<root>` trước. Module không commit lock file
(`.gitignore`): root gọi nó quyết version provider.

## Lệnh kiểm

Chạy từ gốc repo, không cần credential AWS, cần Docker và mạng (registry Terraform, GitHub cho plugin tflint, GHCR cho bộ luật trivy):

| Lệnh | Làm gì |
| --- | --- |
| `make check` | `fmt-check`, `validate`, `tflint`, `trivy` trên mọi thư mục có `*.tf`, rồi `shellcheck` trên mọi `*.sh` |
| `make check DIRS="aws/modules/x aws/envs/stg"` | như trên, bốn phép Terraform chỉ trên các thư mục đó; thư mục không có, không có `*.tf` hay nằm ngoài repo thì dừng, nêu thư mục |
| `make fmt-check` / `make fmt` | `terraform fmt -check -diff -recursive` / viết lại file |
| `make validate` | mỗi thư mục: `terraform init -backend=false -input=false`, rồi `terraform validate`; provider và module nằm ở thư mục tạm (`TF_DATA_DIR`), nên `.terraform/` của người học đã `init` với backend S3 không bị đọc hay ghi |
| `make tflint` | mỗi thư mục: `tflint --init`, rồi `tflint` với `.tflint.hcl` |
| `make trivy` | `trivy config` mỗi thư mục; HIGH và CRITICAL làm đỏ |
| `make shellcheck` | shellcheck trên mọi `*.sh` (bản image, `--network none`; máy không cài shellcheck) |
| `make lock [DIRS=<root>]` | `init -backend=false` rồi `terraform providers lock` cho ba nền tảng; module bị bỏ qua |
| `make help` | liệt kê target |

Chưa có thư mục `*.tf` nào thì bốn phép Terraform in một dòng và qua. Mọi công cụ chạy bằng image ghim digest trong `Makefile`
(`TERRAFORM_IMAGE` 1.15.8, `TFLINT_IMAGE`, `TRIVY_IMAGE` cùng bản ghim của repo code, `SHELLCHECK_IMAGE`), qua
`env -u DOCKER_DEFAULT_PLATFORM docker run` (shell của máy đặt `linux/amd64` cho dự án khác), container chạy dưới uid của người gọi.
Không target nào gọi `plan`, `apply`, `destroy`, `import`, `state`, `output` hay `aws`.

**Chạy song song trên hai thư mục khác nhau** (`make check DIRS=a` và `make check DIRS=b` cùng lúc) an toàn vì mỗi lượt chỉ ghi dưới
thư mục nó kiểm:

- thư mục tạm của lượt (`TF_DATA_DIR`): provider (bản Linux của container, ~700 MB cho provider AWS) và module tải về, xoá khi lượt kết thúc;
- plugin tflint ở `<dir>/.terraform/tflint.d/` (`TFLINT_PLUGIN_DIR`, ~70 MB);
- `<dir>/.terraform.lock.hcl` của module (root chỉ đọc lock của nó; `make lock` thì ghi);
- cache của trivy nằm trong container (`/tmp/trivy`) và mất khi container dừng; shellcheck không ghi gì.

Không có cache plugin dùng chung (`TF_PLUGIN_CACHE_DIR` không đặt, không thư mục plugin tflint chung): hai lượt không bao giờ cùng ghi một
file, đổi lại mỗi lượt tải provider riêng. `.terraform/` mà người học `init` với backend thật không bị `make check` đọc hay ghi (trừ
`tflint.d/`).

**Ngoại lệ của trivy:** finding trong file `.tf` của repo này bỏ qua ngay cạnh resource bằng dòng `#trivy:ignore:<id>`, lý do ở comment
ngay trên; finding trong module tải từ registry (không comment được) vào `.trivyignore.yaml`, `paths` tương đối với thư mục được kiểm. Sửa
được thì sửa, không ghi ngoại lệ.

**CI** (`.github/workflows/check.yml`): mỗi PR và push `main` chạy đúng `make check` trên `ubuntu-24.04`; job `check` chỉ `contents: read`,
token của lượt chỉ vào container tflint (giới hạn tải plugin từ GitHub), không secret, không OIDC, không credential AWS; job `infra-ok`
là check bắt buộc của ruleset `main`. Chỉ action của GitHub, ghim SHA.

## Plan và apply

Chỉ người học chạy, từ máy, bằng SSO (`AWS_PROFILE=anhnv-sso`, region `ap-southeast-1` ghi trong lệnh), theo script và runbook của repo:
lần đầu mỗi account là [`aws/bootstrap/README.md`](aws/bootstrap/README.md). Terraform của máy (Homebrew) phải nằm trong
`required_version` của root (`~> 1.15`). Backend S3 của mọi root đọc bucket, region từ `aws/backend.hcl` (không commit, sinh từ output của
`aws/bootstrap`), mỗi root một `key`, khoá bằng lock file native của S3 (`use_lockfile`).

**Profile AWS không nằm trong code** (khuyến nghị của HashiCorp và AWS: thông tin đăng nhập là của môi trường chạy, không của cấu hình; CI
sau này dùng OIDC, máy khác đặt tên profile khác). Code chỉ chặn nhầm account bằng `allowed_account_ids`. Trên máy, đặt profile một lần cho
thư mục bằng [direnv](https://direnv.net) (công cụ thông dụng nạp biến môi trường theo thư mục):

```sh
brew install direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc && exec zsh       # một lần mỗi máy (bash: direnv hook bash)
printf 'export AWS_PROFILE=anhnv-sso\nexport AWS_REGION=ap-southeast-1\n' > .envrc   # ở gốc infra/; .envrc bị git bỏ qua
direnv allow
```

Từ đó trong `infra/` gõ `terraform plan` trơn. Tài liệu vẫn ghi `AWS_PROFILE=…` trong từng lệnh để người đọc thấy rõ lệnh chạy vào đâu;
không có direnv thì `export AWS_PROFILE=anhnv-sso` mỗi terminal.

## Luật an toàn

- **AI** (Claude, Codex) chỉ chạy `make check` và các phép trong đó, `terraform fmt`, `terraform init -backend=false`, `terraform validate`,
  `terraform providers lock` (`make lock`). Mọi lệnh chạm account (`plan`, `apply`, `destroy`, `import`, `state`, `output`, `aws` trừ
  `--version`, script dùng SDK) do người học chạy; trước mọi lệnh ghi, `AWS_PROFILE=anhnv-sso aws sts get-caller-identity` và so account.
  Provider của root ghim account bằng `allowed_account_ids` từ `TF_VAR_account_id`.
- **Không commit:** state (`*.tfstate*`), plan (`*.tfplan`), `backend.hcl`, `*.auto.tfvars`, `terraform.tfvars`, override
  (`*_override.tf`), `.terraform/`, thư mục số đo `.session/`. Giá trị cá nhân (account ID, IP được gọi API EKS, email, tên miền thật,
  tên bucket) chỉ qua `*.auto.tfvars` không commit hay `TF_VAR_*`; repo có file `*.example` với `svp.example`, `000000000000`.
- Tên bucket theo `<tên>-<account>-<region>` (như bucket của AWS CDK, Control Tower): duy nhất toàn cầu không cần phần ngẫu nhiên.
  Account thật vẫn không nằm trong file commit nào: tên tính từ `var.account_id` lúc chạy.
- Nghi đã lộ khoá AWS hay giá trị cá nhân: mục "Giảm thiểu" của runbook `svp-infra-setup.md`.
