# Module `account-baseline`

Phần sống lâu hơn mọi buổi AWS của một account thành viên (`svp-stg`, `svp-prd`), gọi từ root `aws/accounts/<env>`
([README](../../accounts/README.md)): state Terraform của mọi root chạy trong account đó, zone DNS của env và budget tháng.

Tạo:

- **KMS key `alias/svp-tfstate`** (xoay vòng tự động, chờ 30 ngày khi xoá, `prevent_destroy`). Key policy theo mẫu của tài liệu KMS
  ([default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html)): account quản trị key qua IAM với
  nhóm quyền "key administrators" (không có quyền mã hoá, giải mã), nên admin nào của account (SvpAdmin, `OrganizationAccountAccessRole`)
  cũng sửa lại được policy, key không bị khoá chết dù permission set bị đổi tên hay gỡ; mã hoá, giải mã chỉ cho role SSO của permission set
  `SvpAdmin`, khớp bằng `ArnLike` `aws:PrincipalArn` với mẫu `AWSReservedSSO_SvpAdmin_*` (hậu tố ngẫu nhiên thay bằng `*`) theo
  [IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/referencingpermissionsets.html). Đường dẫn của role không
  có đoạn region khi instance Identity Center ở `us-east-1`, và có đoạn region khi ở region khác; policy liệt kê cả hai dạng nên không phụ
  thuộc instance nằm đâu. Chỉ IAM Identity Center tạo được role dưới `/aws-reserved/`. Không statement nào có principal `*`. Hệ quả: role chỉ được đọc hay liệt kê bucket không đọc được state (state chứa output, thuộc tính tài nguyên).
- **Bucket `svp-tfstate-<account>-<region>`**: versioning, mã hoá mặc định SSE-KMS bằng key trên (S3 Bucket Key bật để giảm request KMS),
  chặn public, `BucketOwnerEnforced`, policy từ chối request không TLS, `prevent_destroy`.
- **Hosted zone `zone_name`** của env: `aws.<domain>` ở prd (zone gốc của lab, DNS của domain cha uỷ quyền bằng bốn bản ghi `NS` tên
  `aws`), `stg.aws.<domain>` ở stg (zone của prd uỷ quyền). Zone ở trên uỷ quyền bằng bốn name server của output `name_servers`.
  ExternalDNS và cert-manager của env chỉ ghi zone này.
- **Bản ghi uỷ quyền zone con** (biến `delegated_subdomains`, mặc định rỗng: không bản ghi nào): mỗi mục một bản ghi `NS` TTL 172800 trong
  zone của env, trỏ tới zone ở account khác, theo
  [Route 53: tạo subdomain dùng Route 53 mà không chuyển domain cha](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingNewSubdomain.html).
  TTL 172800 là giá trị hướng dẫn đó ghi cho bản ghi `NS`: name server của một zone được giữ không đổi.
  Chỉ root `aws/accounts/prd` truyền biến này (zone `stg.aws.<domain>`). Tên mỗi mục phải là con thật của `zone_name`, đúng bốn name
  server khác nhau. Lý do chọn mô hình này: [ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md).
- **Budget `svp-<env>-monthly`**: chi phí của riêng account, email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo (cùng mẫu budget
  của `aws/bootstrap`, budget đó tính cả org).

Output `backend_hcl` là nội dung file `aws/backend-<env>.hcl` (git bỏ qua) mà mọi root của account đọc bằng `-backend-config`: `bucket`,
`region`, `encrypt`, `kms_key_id`, `use_lockfile`; không có `key`, mỗi root tự đặt key state của mình.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_record.delegation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_zone.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_iam_policy_document.state_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account of the baseline (12 digits): part of the state bucket name and of the key policy. The root passes its own account\_id, which never goes into a committed file. | `string` | n/a | yes |
| budget\_emails | Addresses that receive the budget alerts. Personal data of a public repository: the root reads them from an uncommitted *.auto.tfvars or TF\_VAR\_budget\_emails. | `list(string)` | n/a | yes |
| budget\_limit\_usd | Monthly cost budget of the account, in US dollars. Alerts go out at 50, 80 and 100 percent of actual cost and at 100 percent of forecast cost. | `number` | n/a | yes |
| delegated\_subdomains | Child zones of other accounts to delegate from this zone: zone name (ending in .<zone\_name>) to its four name servers, the name\_servers output of the child's baseline. Each entry becomes an NS record in this zone. | `map(list(string))` | `{}` | no |
| env | Environment the account runs (stg, prd): names the budget svp-<env>-monthly and appears in the comment of the hosted zone. | `string` | n/a | yes |
| region | Region of the state bucket and its KMS key, part of the bucket name; the root passes the region of its provider. | `string` | n/a | yes |
| zone\_name | Name of the environment's hosted zone, e.g. aws.svp.example or stg.aws.svp.example. The zone above it delegates it with NS records to the name\_servers output. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| backend\_hcl | Content of aws/backend-<env>.hcl, the partial backend configuration every root of this account reads with -backend-config: bucket, region, encryption with the KMS key of the state and the S3 lock file. It holds no key argument: each root sets the key of its own state. |
| name\_servers | The four name servers of the environment's zone, which the zone above it delegates with NS records: the zone of prd for stg (delegated\_subdomains of aws/accounts/prd), the NS records aws at the parent domain's DNS for prd. |
| state\_bucket | Bucket of the remote state of every root of this account. |
| zone\_id | Id of the hosted zone of the environment, zone\_name. |
<!-- END_TF_DOCS -->
