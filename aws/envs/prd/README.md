# `aws/envs/prd`: env prd của một buổi, cùng code với stg ở mức production

**Account** `svp-prd` · **region** `ap-southeast-1` (web ACL, cert, log CloudFront ở `us-east-1`) · **profile** `anhnv-prd` · **state**
bucket của `aws/accounts/prd` (`../../backend-prd.hcl`), key `aws/prd/terraform.tfstate`

Giải thích: [09. Env và mạng](../../../docs/handbook/09-envs-network.md), [10. EKS](../../../docs/handbook/10-eks.md); dữ liệu ở
[11. Dữ liệu](../../../docs/handbook/11-data.md), đường vào, media, transcode ở chương [12. Media và
edge](../../../docs/handbook/12-media-edge.md), backup của env ở chương [07. Backup](../../../docs/handbook/07-backup.md).

Chạy root này tạo gì: mục [`aws/envs/prd`](../../../docs/reference/inventory.md#awsenvsprd) của
[inventory](../../../docs/reference/inventory.md) (số tài nguyên theo phần, theo loại, kèm sơ đồ).

## Dựng gì

Cùng `*.tf`, cùng module, cùng đối số với root stg: bảng tài nguyên, biến, tài nguyên sống lâu và output ở
[README `aws/envs/stg`](../stg/README.md), thay `stg` bằng `prd`. Dưới đây chỉ phần khác.

| Khác ở | stg | prd |
| --- | --- | --- |
| Dòng `env` của `locals` (`main.tf`) | `"stg"` | `"prd"` |
| Tệp cỡ | `stg.tfvars` | `prd.tfvars`, thêm `teardown.tfvars` (mục [Gỡ](#gỡ)) |
| Mạng | 2 AZ, một NAT, ENI của endpoint ở một AZ | 3 AZ, NAT mỗi AZ, ENI mỗi AZ |
| Cổng tunnel tới API | `api_tunnel_port` của `stg.tfvars` | `api_tunnel_port` của `prd.tfvars` |
| Dữ liệu | RDS một AZ, MSK RF 2, Valkey một node | RDS `db.m7g` Multi-AZ, MSK RF 3 min ISR 2, Valkey có replica và failover tự động |
| Retention log CloudWatch | 1 ngày | 30 ngày |
| Bảo vệ xoá, snapshot cuối | tắt | RDS, ALB edge bảo vệ; final snapshot, backup tự động giữ sau khi xoá |
| Media | flat-rate Free, `force_destroy` | pay-as-you-go, log chuẩn về Log Archive; bucket không tự rỗng khi `destroy` |
| Zone | `stg.aws.<domain>`, uỷ quyền từ zone prd | `aws.<domain>`, uỷ quyền từ DNS cha (bản ghi `NS` ngoài Terraform) |

Giá trị từng dòng và lý do: comment của `prd.tfvars` (cùng thứ tự dòng với `stg.tfvars`) và bảng của
[`environments.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/explanation/environments.md). Khác biệt được phép ngoài các
tệp đó: `README.md`, `backend.hcl.example`, `example.auto.tfvars.example`; lệnh kiểm
`diff -r -x .terraform -x '*.auto.tfvars' -x '*.auto.tfvars.json' aws/envs/stg aws/envs/prd`. Root không có `validation` ép giá trị prd:
test của từng module có một `run` với giá trị prd. Endpoint công khai của API tắt; không có IP của máy người học.

## Chạy

Người học chạy mọi lệnh; AI chỉ chạy `make check`, `make lock`.

- Điều kiện: `aws/accounts/prd` đã apply, uỷ quyền DNS đã xong (chương [08. Account env](../../../docs/handbook/08-accounts.md)),
  `aws/log-archive` có bucket và delivery destination `svp-cloudfront-prd`; một buổi stg xanh với cùng code.
- Mỗi buổi prd, dựng root (`init`, `plan`, `apply` với `-var-file=prd.tfvars` và ba biến `TF_VAR_*` như stg): [trang dựng của buổi
  prd](../../../docs/runbooks/session-prd-deploy.md).
- Mở tunnel tới API: [09. Env và mạng, Kịch bản thực tế](../../../docs/handbook/09-envs-network.md#kịch-bản-thực-tế), với `anhnv-prd` và
  `--context svp-prd`.
- Cuối buổi: mục [Gỡ](#gỡ).

## Gỡ

Bảo vệ của `prd.tfvars` chặn `destroy`, nên gỡ đi hai bước với cả `prd.tfvars` và `teardown.tfvars`: `apply` nhấc bảo vệ, rồi
`aws/scripts/restore-drill.sh prd cleanup`, rồi `destroy`. Trước đó `aws/scripts/pre-destroy.sh prd` và destroy `aws/gitops/prd`, cả hai
qua tunnel. Lệnh từng bước: [trang chủ buổi prd](../../../docs/runbooks/session-prd.md).

`teardown.tfvars` chỉ đặt `rds_deletion_protection = false` (RDS từ chối xoá instance còn bảo vệ), `media_force_destroy = true` (bucket
có versioning không bao giờ rỗng) và `edge_alb_deletion_protection = false` (ALB edge còn bảo vệ thì `destroy` dừng ở nó); không đổi cỡ,
log hay mã hoá. MSK và ElastiCache không có bảo vệ xoá để nhấc: `destroy` gỡ chúng cùng secret `AmazonMSK_*` (xoá ngay) và để KMS key
của root ở `PendingDeletion`. `rds_skip_final_snapshot` vẫn `false` và backup tự động vẫn giữ: runbook đọc rồi xoá final snapshot và
backup tự động sau `destroy`, rồi chạy lệnh quét tài nguyên sót.

`cleanup` chạy sau `apply` cuối cùng vào root này (apply nào cũng gắn lại tag `Backup`) và ngay trước `destroy`: gỡ tag `Backup` khỏi
instance và hai bucket, chờ mọi job AWS Backup của account kết thúc, xoá recovery point của vault `svp-prd` đã có bản copy `COMPLETED`
trong `svp-prd-copy`, in lệnh cho cái chưa có. Vault và bản copy giữ; key RDS, key `uploads` chỉ bị xoá ở `destroy` sau bước này. Lý do:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §11.

## Output

Như root stg ([bảng output](../stg/README.md#output)), với profile `anhnv-prd`, tên `svp-prd` và cổng `api_tunnel_port` của `prd.tfvars`
trong `api_tunnel_command`, `kubeconfig_command`. Root `aws/gitops/prd` đọc state này qua `terraform_remote_state` (key
`aws/prd/terraform.tfstate`).

## Ngoại lệ trivy

`make trivy DIRS=aws/envs/prd` quét root với `prd.tfvars`, không ngoại lệ chỉ-stg nào: root không có `#trivy:ignore` nào; ngoại lệ trong
module mang `Scope: every environment` hay có điều kiện khớp giá trị stg (không khớp giá trị prd).

## Tham chiếu

- [README `aws/envs/stg`](../stg/README.md): tài nguyên, biến, tài nguyên sống lâu, hợp đồng `cluster_values`.
- [09. Env và mạng](../../../docs/handbook/09-envs-network.md#hai-env-một-bộ-code): hai env, một bộ code.
- [ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md): env prd; chi phí ở phụ lục.
- [ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) §6: khác biệt được phép.
