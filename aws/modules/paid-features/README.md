# Module `paid-features`

Module chỉ trả dữ liệu (không provider, không resource): đọc cờ chi phí của mọi account trong org từ file commit
[`aws/paid-features.json`](../../paid-features.json), kiểm, rồi trả giá trị đủ của mọi cờ ở mọi account. Thiết kế, lý do và chi phí của từng
cờ: [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md). File JSON không có comment; lý do mỗi giá
trị nằm ở ADR đó.

Mọi root bật, tắt dịch vụ theo cờ gọi module này với `features = jsondecode(file("<đường tương đối tới aws/>paid-features.json"))`, không root
nào tự đọc giá trị trong JSON: `aws/security` (Security Hub, Inspector), `aws/baseline` (AWS Config), `aws/accounts/<env>` (Amazon Managed
Grafana, quét ECR). Script buổi đọc cùng file qua `paid_feature`, `session_features` của `aws/scripts/lib.sh`.

## Khối cờ

File là object `{"<khoá account>": {"<cờ>": "<giá trị>"}}` và chỉ ghi giá trị khác `always`; account vắng, cờ vắng là `always` (mặc định theo
prd). Khoá account, tên cờ, tập giá trị và account đặt được của từng cờ do `validation` của biến `features` ở
[`variables.tf`](variables.tf) giữ; tài nguyên mỗi cờ điều khiển ở [ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md).

## Kiểm

`validation` của biến `features` dừng plan khi:

- khoá account hay tên cờ ngoài tập khai báo (biến có kiểu `map(map(string))`, không `object`: Terraform bỏ thuộc tính mà kiểu `object` không
  khai báo, nên cờ gõ sai sẽ âm thầm thành `always`);
- giá trị ngoài tập của cờ;
- cờ của Account env (Managed Grafana, Inspector ECR) có mặt ở account khác, kể cả khi giá trị là `always`;
- tổ hợp cờ phụ thuộc nhau sai (Security Hub cần AWS Config đang ghi);
- cờ của delegated administrator mà cả org dựa vào (Security Hub của `security`) bị tắt.

## Output

- `flags`: mọi khoá account, mỗi khoá đủ mọi cờ; cờ file không đặt là `always`.
- `off_accounts`, `session_accounts`: mỗi cờ một danh sách khoá account (sắp xếp) có giá trị `off`, `session`; danh sách rỗng khi không account
  nào.

Test ở `tests/paid-features.tftest.hcl` (`make test`) chạy mỗi giá trị của mỗi cờ, giá trị của `stg` trong file và mỗi luật `validation`.
`make test` chỉ mount thư mục module nên test chép lại giá trị `stg` thay vì đọc file.

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
