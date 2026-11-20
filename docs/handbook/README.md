# Handbook svp-infra

Handbook giải thích hạ tầng AWS và GitHub của svp: mỗi chương một bước của luồng áp, nói dựng gì, vì sao, giá bao nhiêu, cái giá của lựa
chọn và nó nối với đề AWS Certified Solutions Architect – Professional (SAP-C03) ở đâu. Handbook không có lệnh để chạy: bước làm ở
[runbook](../runbooks/README.md), tra cứu ở `docs/reference/` và README của mỗi root, module.

## Đọc thế nào

- **Lần đầu:** đọc [00. Tổng quan](00-tong-quan.md) cả chương, rồi theo số chương chỉ đọc khối **Tóm tắt** và dòng **Câu hỏi của
  chương**. Sau một lượt đã có bức tranh: account nào, dịch vụ nào, sống lâu hay trong buổi, phí cỡ nào.
- **Khi học SAP:** đọc đủ một chương. `## Dịch vụ` nói mỗi dịch vụ bắt được gì kèm ví dụ thật, ở đâu trong svp, tính phí theo gì;
  `## Kịch bản` đi một tình huống thật từng bước; `## Cái giá và phương án khác` là phần đề hay hỏi; `## Liên hệ đề SAP` chép đúng Task,
  Skill của đề.
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
| 01. Bootstrap <!-- link-chờ: docs/handbook/01-bootstrap.md --> | [`aws/bootstrap`](../../aws/bootstrap/README.md) | [`org-security-setup.md`](../runbooks/org-security-setup.md) | 3, 5 |
| 02. GitHub <!-- link-chờ: docs/handbook/02-github.md --> | [`github`](../../github/README.md) | [`github-setup.md`](../runbooks/github-setup.md) | 5 |
| 03. Tổ chức <!-- link-chờ: docs/handbook/03-org.md --> | [`aws/org`](../../aws/org/README.md) | [`org-security-setup.md`](../runbooks/org-security-setup.md) | 2 |
| 04. Log Archive <!-- link-chờ: docs/handbook/04-log-archive.md --> | [`aws/log-archive`](../../aws/log-archive/README.md) | [`org-security-setup.md`](../runbooks/org-security-setup.md) | 2 |
| 05. Bảo mật <!-- link-chờ: docs/handbook/05-security.md --> | [`aws/security`](../../aws/security/README.md) | [`org-security-setup.md`](../runbooks/org-security-setup.md) | 2 |
| 06. Baseline <!-- link-chờ: docs/handbook/06-baseline.md --> | [`aws/baseline`](../../aws/baseline/README.md) | [`org-security-setup.md`](../runbooks/org-security-setup.md) | 2 |
| 07. Backup <!-- link-chờ: docs/handbook/07-backup.md --> | [`aws/backup`](../../aws/backup/README.md) | [`backup-setup.md`](../runbooks/backup-setup.md) | 4, 3 |
| 08. Account env <!-- link-chờ: docs/handbook/08-accounts.md --> | [`aws/accounts/<env>`](../../aws/accounts/README.md) | `accounts-setup.md` <!-- link-chờ: docs/runbooks/accounts-setup.md -->, [`edge-setup.md`](../runbooks/edge-setup.md), [`platform-setup.md`](../runbooks/platform-setup.md) | 1, 5 |
| 09. Env và mạng <!-- link-chờ: docs/handbook/09-envs-network.md --> | `aws/envs/<env>` ([stg](../../aws/envs/stg/README.md), [prd](../../aws/envs/prd/README.md)) | [`session-stg.md`](../runbooks/session-stg.md), [`session-prd.md`](../runbooks/session-prd.md) | 1 |
| 10. EKS <!-- link-chờ: docs/handbook/10-eks.md --> | `aws/envs/<env>` (module `eks`, `external-secrets`) | [`session-stg.md`](../runbooks/session-stg.md), [`eks-upgrade.md`](../runbooks/eks-upgrade.md) | 1, 2 |
| 11. Dữ liệu <!-- link-chờ: docs/handbook/11-data.md --> | `aws/envs/<env>` (module `rds`, `msk`, `elasticache`, `alarms`) | [`session-stg.md`](../runbooks/session-stg.md) | 1 |
| 12. Media và edge <!-- link-chờ: docs/handbook/12-media-edge.md --> | `aws/envs/<env>` (module `media`, `edge`, `waf`, `transcode`) | [`edge-setup.md`](../runbooks/edge-setup.md), [`media-signing-keys.md`](../runbooks/media-signing-keys.md) | 1, 3 |
| 13. GitOps <!-- link-chờ: docs/handbook/13-gitops.md --> | [`aws/gitops/<env>`](../../aws/gitops/README.md) | [`session-stg.md`](../runbooks/session-stg.md) | 5 |
| 14. CI <!-- link-chờ: docs/handbook/14-ci.md --> | `.github/workflows/`, `ci/` | [`github-setup.md`](../runbooks/github-setup.md) | 5 |
| 15. Chi phí <!-- link-chờ: docs/handbook/15-cost.md --> | [`aws/paid-features.json`](../../aws/paid-features.json) | [`paid-features.md`](../runbooks/paid-features.md) | 3 |

Runbook khi cần, ngoài chuỗi dựng: [`break-glass.md`](../runbooks/break-glass.md) khi đường thường hỏng,
`lab-teardown.md` <!-- link-chờ: docs/runbooks/lab-teardown.md --> khi gỡ nền sống lâu có chủ đích.

## Khuôn của một chương

Mọi chương cùng thứ tự mục, nên biết tìm gì ở đâu:

| Mục | Trả lời |
| --- | --- |
| **Tóm tắt** | Dựng gì, vì sao, phí (số có nguồn) |
| **Câu hỏi của chương** | Câu hỏi thiết kế chương trả lời |
| `## Kiến trúc` | Sơ đồ chính: ranh giới account, luồng dữ liệu |
| `## Dịch vụ` | Mỗi dịch vụ: làm gì kèm ví dụ thật, ở svp nằm đâu, tính phí theo gì, cái gì cố ý tắt |
| Mục chủ đề | Lý do không gắn một dịch vụ (delegated admin, luồng secret…) |
| `## Kịch bản` | Một tình huống thật của svp từng bước, đúng tên tài nguyên trong code |
| `## Cái giá và phương án khác` | Lựa chọn của svp, cái giá, phương án khác, khi nào chọn nó |
| `## Liên hệ đề SAP` | Task, Skill chép đúng từ hướng dẫn đề, kèm chỗ chương minh hoạ |
| `## Làm và tra cứu` | Bước runbook, README root và module, ADR |
