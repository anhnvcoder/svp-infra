# svp-infra — Terraform của lab short-video-platform

Đọc trước khi làm bất cứ việc gì: [`README.md`](README.md) (bố cục, lệnh kiểm, luật an toàn) và
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) (thiết kế giai đoạn 7). Thiết kế và
quyết định chung của lab nằm ở `docs/` của repo code (bản clone `<workspace>/backend`); đổi một quyết định đã chốt thì đề xuất kèm ADR ở đó.

## An toàn cloud

- **AI chỉ chạy:** `make check` (và từng target của nó: `fmt-check`, `validate`, `tflint`, `trivy`, `shellcheck`), `make fmt`,
  `make lock`, tức `terraform fmt`, `terraform init -backend=false`, `terraform validate`, `terraform providers lock`; `bash -n`,
  test script với lệnh giả trên PATH; `aws --version`.
- **AI không chạy lệnh nào chạm account AWS, kể cả chỉ đọc:** `terraform init` có backend, `plan`, `apply`, `destroy`, `import`,
  `state`, `output`, `test`, `refresh`; `aws` (trừ `--version`); script hay chương trình dùng SDK AWS; script buổi của `aws/scripts/`.
- **Mọi lệnh chạm account do người học chạy** theo script và runbook viết sẵn: profile và region ghi ngay trong lệnh
  (`AWS_PROFILE=anhnv-sso … --region ap-southeast-1`), mỗi bước một khối, nói rõ cần dán lại output nào và tìm gì trong đó. Trước mọi lệnh
  ghi: `AWS_PROFILE=anhnv-sso aws sts get-caller-identity`, hai bên cùng đọc account. Buổi tạo tài nguyên kết thúc bằng lệnh destroy và
  lệnh quét sót; AI nhắc tới khi người học xác nhận đã chạy cả hai.
- CI (`check.yml`) không có credential AWS, secret, OIDC hay environment nào; thêm thì phải có ADR trước.

## Quy ước

- **Ngôn ngữ viết:** file `.md` viết tiếng Việt; mọi thứ trong code (comment, `description` của biến và output, message của
  `validation`, script, `*.example`) viết tiếng Anh. Comment nói lý do ngay tại chỗ, không nhắc ADR.
- **Repo public, không commit:** state (`*.tfstate*`), plan (`*.tfplan`), `backend.hcl`, `*.auto.tfvars` hay `terraform.tfvars` (chứa
  account ID, IP, email, tên miền thật), override (`*_override.tf`), `.terraform/`, `.session/`. Ví dụ và test dùng `000000000000`,
  `svp.example`, `<domain>`; tên tài nguyên không ghép từ account ID.
- **Root và module:** thư mục dưới `modules/` là module (không commit lock file), thư mục `*.tf` khác là root (commit
  `.terraform.lock.hcl` ba nền tảng bằng `make lock DIRS=<root>`). Provider ghim trong lock của root; module registry ghim version chính
  xác. Root đặt `default_tags` `Project=svp`, `ManagedBy=terraform`, `Stack=<tên>` và `allowed_account_ids = [var.account_id]`.
- **Root `github/`** (cài đặt GitHub của năm repo, provider `integrations/github`): không provider AWS nên không `default_tags`,
  `allowed_account_ids`; `plan`, `apply` cần token GitHub admin và đăng nhập AWS (state ở bucket của `aws/bootstrap`), chỉ người học chạy.
- **Ngoại lệ trivy:** finding trong `.tf` của repo bỏ qua bằng `#trivy:ignore:<id>` ngay trên resource, lý do ở comment; finding trong
  module registry vào `.trivyignore.yaml`. Sửa được thì sửa.
- **Docker** chỉ qua `Makefile` (`env -u DOCKER_DEFAULT_PLATFORM docker run …`, image ghim digest có dòng `# renovate:` ngay trên).
- **Card chạy song song** kiểm bằng `make check DIRS=<thư mục của mình>`: mỗi lượt chỉ ghi dưới thư mục đó, không có cache dùng chung.
- **Git:** conventional commits, mô tả tiếng Việt. Mọi thay đổi vào `main` qua PR có `infra-ok` xanh (từ khi bật ruleset); không force
  push, hoàn tác bằng PR revert.
