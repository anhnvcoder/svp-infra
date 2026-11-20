# Module `paid-features`

Module chỉ trả dữ liệu, không provider, không resource: nhận cờ chi phí của mọi account từ file commit
[`aws/paid-features.json`](../../paid-features.json), từ chối khoá, cờ, giá trị và tổ hợp sai bằng `validation` của biến `features`, rồi trả
đủ mọi cờ ở mọi account (cờ hay account vắng trong file là `always`). Root `aws/security`, `aws/baseline`, `aws/accounts/<env>`,
`aws/envs/<env>` gọi module này thay vì tự đọc JSON; script buổi đọc cùng file qua `paid_feature`, `session_features` của
`aws/scripts/lib.sh`. Vì sao có cờ, giá trị nào ở account nào và cái giá: [15. Chi phí](../../../docs/handbook/15-cost.md); test:
`make test DIRS=aws/modules/paid-features` (test chép giá trị của file vì `make test` chỉ mount thư mục module).

## Ví dụ

Lời gọi trong `aws/security/main.tf`; root khác chỉ đổi đường tương đối tới `aws/`:

```hcl
module "paid_features" {
  source = "../modules/paid-features"

  features = jsondecode(file("${path.root}/../paid-features.json"))
}
```

Đọc kết quả: `module.paid_features.flags["stg"].managed_grafana` (`always`, `session` hay `off`),
`module.paid_features.off_accounts.security_hub` (khoá account có cờ `off`, đã sắp xếp).

## Tham chiếu

- [15. Chi phí](../../../docs/handbook/15-cost.md): ghi chú thiết kế mà `main.tf` và các root gọi module trỏ tới.
- [`paid-features.md`](../../../docs/runbooks/paid-features.md): đổi một cờ, thứ tự áp các root.
- [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md),
  [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md): quyết định và số tiền.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| features | Cost flags per account, as decoded from aws/paid-features.json: account key (mgmt, log-archive, security, backup, stg, prd) to the flags (managed\_grafana, inspector\_ecr, security\_hub, config\_recording) whose value differs from always. An absent account or flag is always. | `map(map(string))` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| flags | Every account key (mgmt, log-archive, security, backup, stg, prd) to every flag (managed\_grafana, inspector\_ecr, security\_hub, config\_recording) and its value, always where aws/paid-features.json sets none. |
| off\_accounts | Every flag to the sorted account keys where it is off; an empty list when no account turns it off. |
| session\_accounts | Every flag to the sorted account keys where it is session (only managed\_grafana takes it); an empty list when no account does. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
