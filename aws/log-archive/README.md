# `aws/log-archive`: bucket log của cả tổ chức ở account `svp-log-archive`

**Account** `svp-log-archive` qua `OrganizationAccountAccessRole` · **region** `ap-southeast-1` và `us-east-1` (log WAF, CloudFront) ·
**profile** `anhnv-sso` · **state** bucket của `aws/bootstrap`, key `aws/log-archive/terraform.tfstate`

Giải thích: [04. Log Archive](../../docs/handbook/04-log-archive.md).

## Dựng gì

`<log>` là id của `svp-log-archive`, tính lúc chạy; root khác suy cùng tên bucket từ id đó, không đọc state của root này. Mọi tài nguyên
mang tag `Stack=log-archive` và sống suốt lab.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `aws_s3_bucket.log["cloudtrail"]` `svp-cloudtrail-<log>-ap-southeast-1` | `svp-log-archive`, nhà | Trail tổ chức `svp-audit`; Object Lock governance 365 ngày (`aws_s3_bucket_object_lock_configuration.cloudtrail`) |
| `aws_s3_bucket.log["cloudtrail_access"]` `svp-cloudtrail-access-<log>-ap-southeast-1` | `svp-log-archive`, nhà | Server access log của bucket trail (`aws_s3_bucket_logging.cloudtrail`); SSE-S3 |
| `aws_s3_bucket.log["config"]`, `["guardduty"]`, `["flowlogs"]` | `svp-log-archive`, nhà | Lịch sử Config, finding GuardDuty của `svp-security`, flow log VPC của stg, prd |
| `aws_s3_bucket.log["waf"]` `aws-waf-logs-svp-<log>-us-east-1`, `["cloudfront"]` `svp-cloudfront-<log>-us-east-1` | `svp-log-archive`, `us-east-1` | Log WAF, log CloudFront của stg, prd |
| Versioning, public access block, ownership, lifecycle, policy của mỗi bucket | cùng bucket | Retention, lớp lưu trữ, tiền tố stg ở `local.buckets` của `main.tf`; policy ở `bucket-policies.tf` |
| `aws_kms_key.log["home"]`, `["waf"]`, alias `alias/svp-log-archive` | `svp-log-archive`, mỗi region một key | Mã hoá mọi bucket trừ bucket access log; key policy theo dịch vụ ở `kms.tf` |
| `aws_cloudwatch_log_delivery_destination.cloudfront`, policy | `svp-log-archive`, `us-east-1` | `svp-cloudfront-<env>`, mỗi env một destination, chỉ account env đó tạo delivery |

Biến: `account_id` (management), `log_archive_account_id`, `security_account_id`, `stg_account_id`, `prd_account_id`, đặt bằng
`TF_VAR_*` từ biến `SVP_AWS_*_ACCOUNT_ID` trong lệnh; không file `.auto.tfvars`. Output: `bucket_names`, `bucket_arns`, `kms_key_arns`
(dạng `key/<id>`), `kms_alias_name`, `cloudfront_delivery_destination_arns` (`outputs.tf`); root khác suy cùng giá trị, output để kiểm.

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account.

- Áp lần đầu (sau `aws/org` lượt `-target`, trước `aws/org` đủ):
  [`org-security-setup.md`, bước (3)](../../docs/runbooks/org-security-setup.md#bước-3-awslog-archive).
- Code đổi (bucket, policy, retention): cùng lệnh `plan`, `apply` của bước (3); plan không được có `destroy` hay `-/+` ở bucket, key.
- Trong buổi: không chạy root này; log của buổi đọc bằng `SvpLogReader` (profile `anhnv-log-ro`).
- Gỡ có chủ đích (lab kết thúc): mục dưới.

## Gỡ có chủ đích

Bucket và key có `prevent_destroy`: root này không bao giờ `terraform destroy` khi chưa sửa local có chủ đích. Gỡ xoá mọi log, kể cả
version còn trong hạn Object Lock (bỏ qua governance), nên chỉ làm khi lab kết thúc và không cần lịch sử audit nữa; bỏ qua thì log còn
tới khi account `svp-log-archive` đóng hẳn. Thứ tự với root khác và lệnh:
[`lab-teardown.md`, `aws/log-archive`](../../docs/runbooks/lab-teardown.md#awslog-archive).

## Tham chiếu

- [04. Log Archive](../../docs/handbook/04-log-archive.md): vì sao account riêng, retention, Object Lock, delivery destination; chi tiết
  triển khai ở mục Đọc sâu (ghi chú thiết kế mà `main.tf` trỏ tới).
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §7: bucket Log Archive;
  [phụ lục §7](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#7-bucket-log-archive):
  retention, bucket policy, key policy.
- [ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) §8: log CloudFront chéo
  account.
