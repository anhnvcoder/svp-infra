# Handbook svp-infra

Handbook giải thích hạ tầng AWS và GitHub của svp: mỗi chương một bước của luồng áp, nói dựng gì, vì sao, giá bao nhiêu, cái giá của lựa
chọn và nó nối với đề AWS Certified Solutions Architect – Professional (SAP-C03) ở đâu. Handbook giải thích, không là checklist để chạy:
bước làm ở [runbook](../runbooks/README.md), tra cứu ở `docs/reference/` và README của mỗi root, module.

## Đọc thế nào

- **Lần đầu:** đọc [00. Tổng quan](00-tong-quan.md) cả chương, rồi theo số chương chỉ đọc `## Tổng quan` (lời thường, bảng câu hỏi →
  dịch vụ, bảng account) và sơ đồ của `## Kiến trúc`. Sau một lượt đã có bức tranh: account nào, dịch vụ nào, sống lâu hay trong buổi.
- **Khi học SAP:** đọc đủ một chương. `## Kịch bản thực tế` đi một tình huống thật từng bước; `## Các dịch vụ và cách svp dùng` nói mỗi
  dịch vụ bắt được gì kèm ví dụ thật, ở đâu trong svp, tính phí theo gì; `## Thiết kế và đánh đổi` là phần đề hay hỏi;
  `## Liên hệ đề SAP` chép đúng Task, Skill của đề và phân biệt các dịch vụ dễ nhầm.
- **Khi chạy lại sau nhiều tháng:** chương tự đủ nghĩa, không giả định nhớ buổi nào. Cột Runbook ở bảng dưới trỏ checklist làm được từ đầu
  tới cuối; chương chỉ trả lời "vì sao bước này tồn tại".

Mỗi chương mở bằng dòng điều hướng `← chương trước · Mục lục · chương sau →`, nên đọc nối được từ 00 tới 15 mà không quay lại trang này.

## Chương

Thứ tự đọc là thứ tự áp: bootstrap → github → org → log-archive → security → baseline → backup → accounts → envs → gitops → CI → chi phí.
Cột Domain SAP theo năm domain của đề: 1 kiến trúc cho cloud, 2 bảo mật, tuân thủ, quản trị, 3 tối ưu chi phí, 4 phục hồi, di chuyển,
liên tục, 5 vận hành và tự động hoá.

| Chương | Root | Runbook | Domain SAP |
| --- | --- | --- | --- |
| [00. Tổng quan](00-tong-quan.md) | mọi root ([bản đồ](../../README.md#bản-đồ)) | [Mục lục runbook](../runbooks/README.md) | 2, 5 |
| [01. Bootstrap](01-bootstrap.md) | [`aws/bootstrap`](../../aws/bootstrap/README.md) | [`org-security-setup.md`, bước (1)](../runbooks/org-security-setup.md#bước-1-awsbootstrap) | 3, 2 |
| [02. GitHub](02-github.md) | [`github`](../../github/README.md) | [`github-setup.md`](../runbooks/github-setup.md) | 5 |
| [03. Tổ chức](03-org.md) | [`aws/org`](../../aws/org/README.md) | [`org-security-setup.md`, bước (2), (4)](../runbooks/org-security-setup.md#bước-2-awsorg-chỉ-tổ-chức-ou-account) | 2, 3 |
| [04. Log Archive](04-log-archive.md) | [`aws/log-archive`](../../aws/log-archive/README.md) | [`org-security-setup.md`, bước (3)](../runbooks/org-security-setup.md#bước-3-awslog-archive) | 2, 3 |
| [05. Bảo mật](05-security.md) | [`aws/security`](../../aws/security/README.md) | [`org-security-setup.md`, bước (5)](../runbooks/org-security-setup.md#bước-5-awssecurity) | 2 |
| [06. Baseline](06-baseline.md) | [`aws/baseline`](../../aws/baseline/README.md) | [`org-security-setup.md`, bước (6)](../runbooks/org-security-setup.md#bước-6-awsbaseline) | 2 |
| [07. Backup](07-backup.md) | [`aws/backup`](../../aws/backup/README.md) | [`backup-setup.md`](../runbooks/backup-setup.md) | 4, 3, 2 |
| [08. Account env](08-accounts.md) | [`aws/accounts/<env>`](../../aws/accounts/README.md) | [`accounts-setup.md`](../runbooks/accounts-setup.md), [`edge-setup.md`](../runbooks/edge-setup.md), [`platform-setup.md`](../runbooks/platform-setup.md) | 5, 1, 3 |
| [09. Env và mạng](09-envs-network.md) | `aws/envs/<env>` ([stg](../../aws/envs/stg/README.md), [prd](../../aws/envs/prd/README.md)) | [`session-stg.md`](../runbooks/session-stg.md), [`session-prd.md`](../runbooks/session-prd.md) | 1, 2, 3 |
| [10. EKS](10-eks.md) | `aws/envs/<env>` (module `eks`, `external-secrets`) | [`session-stg-deploy.md`](../runbooks/session-stg-deploy.md), [`eks-upgrade.md`](../runbooks/eks-upgrade.md) | 1, 2 |
| [11. Dữ liệu](11-data.md) | `aws/envs/<env>` (module `rds`, `msk`, `elasticache`, `alarms`) | [`session-stg-check-managed.md`](../runbooks/session-stg-check-managed.md) | 1, 5 |
| [12. Media và edge](12-media-edge.md) | `aws/envs/<env>` (module `media`, `edge`, `waf`, `transcode`) | [`edge-setup.md`](../runbooks/edge-setup.md), [`media-signing-keys.md`](../runbooks/media-signing-keys.md), [`session-stg-check-edge-media.md`](../runbooks/session-stg-check-edge-media.md) | 1, 3, 2 |
| [13. GitOps](13-gitops.md) | [`aws/gitops/<env>`](../../aws/gitops/README.md) | [`session-stg-deploy.md`](../runbooks/session-stg-deploy.md), [`session-prd-deploy.md`](../runbooks/session-prd-deploy.md) | 5 |
| [14. CI](14-ci.md) | `.github/workflows/`, `ci/` | [`github-setup.md`](../runbooks/github-setup.md), [`ci.md`](../reference/ci.md) | 5, 2 |
| [15. Chi phí](15-cost.md) | [`aws/paid-features.json`](../../aws/paid-features.json) | [`paid-features.md`](../runbooks/paid-features.md) | 3 |

Runbook khi cần, ngoài chuỗi dựng: [`break-glass.md`](../runbooks/break-glass.md) khi đường thường hỏng,
[`lab-teardown.md`](../runbooks/lab-teardown.md) khi gỡ nền sống lâu có chủ đích.

## Khuôn của một chương

Mọi chương cùng thứ tự mục, nên biết tìm gì ở đâu:

| Mục | Trả lời |
| --- | --- |
| `## Tổng quan` | Phần này là gì, vì sao svp cần, sống thế nào giữa các buổi; câu hỏi → dịch vụ; account, region, root |
| `## Kiến trúc` | Sơ đồ tổng quan ít nút; bảng thành phần chính |
| `## Kịch bản thực tế` | Câu hỏi của chương và một tình huống thật của svp từng bước, đúng tên tài nguyên trong code |
| `## Các dịch vụ và cách svp dùng` | Mỗi dịch vụ: làm gì kèm ví dụ thật, ở svp nằm đâu, tính phí theo gì, cái gì cố ý tắt |
| `## Chi phí` | Phí giữa các buổi và trong buổi, mỗi số có nguồn |
| `## Kiểm tra và vận hành` | Xem gì trên console, ở account và region nào, trạng thái mong đợi; bước runbook kiểm nó |
| `## Thiết kế và đánh đổi` | Lý do không gắn một dịch vụ; lựa chọn của svp, cái giá, phương án khác |
| `## Liên hệ đề SAP` | Task, Skill chép đúng từ hướng dẫn đề; tình huống đề → dịch vụ nên chọn |
| `## Đọc sâu` | Chi tiết triển khai ngắn; link runbook, README root và module, ADR |
