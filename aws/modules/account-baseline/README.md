# Module `account-baseline`

Phần sống lâu hơn mọi buổi AWS của một account thành viên (`svp-stg`, `svp-prd`), gọi từ root `aws/accounts/<env>`
([README](../../accounts/README.md)): state Terraform của mọi root chạy trong account đó, zone DNS của env (cùng `CAA`, DNSSEC, query log) và
budget tháng.

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
  Bản ghi của buổi (alias tới distribution, bản ghi validation ACM) do root `aws/envs/<env>` tạo; không gì trong cluster ghi zone.
- **Bản ghi uỷ quyền zone con** (biến `delegated_subdomains`, mặc định rỗng: không bản ghi nào): mỗi mục một bản ghi `NS` TTL 172800 trong
  zone của env, trỏ tới zone ở account khác, theo
  [Route 53: tạo subdomain dùng Route 53 mà không chuyển domain cha](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingNewSubdomain.html).
  TTL 172800 là giá trị hướng dẫn đó ghi cho bản ghi `NS`: name server của một zone được giữ không đổi.
  Chỉ root `aws/accounts/prd` truyền biến này (zone `stg.aws.<domain>`). Tên mỗi mục phải là con thật của `zone_name`, đúng bốn name
  server khác nhau. Lý do chọn mô hình này: [ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md).
- **Bản ghi `CAA` ở đỉnh zone** (mọi env): `0 issue` và `0 issuewild` cho bốn CA của ACM `amazon.com`, `amazontrust.com`, `awstrust.com`,
  `amazonaws.com` theo [ACM: CAA records](https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html), TTL 3 600. Chỉ CA của Amazon
  được cấp cert cho tên trong zone; `issuewild` thiếu CA của ACM thì ACM không cấp cert wildcard. Chỉ cần ở đỉnh: CA tìm `CAA` của một tên
  ngược lên tên cha tới khi gặp ([RFC 8659 §3](https://www.rfc-editor.org/rfc/rfc8659#section-3)). Zone stg là zone riêng nên có `CAA` riêng.
- **DNSSEC** (biến `dnssec_enabled`, mặc định `false`; root prd bật): KMS key `us-east-1` `ECC_NIST_P256` `SIGN_VERIFY` (alias `alias/svp-dnssec`,
  chờ 30 ngày khi xoá, `prevent_destroy`), key signing key `svp_<env>_ksk` luôn `ACTIVE`, zone ký (`aws_route53_hosted_zone_dnssec`). Tên KSK
  dùng `_` vì Route 53 chỉ nhận chữ, số và `_` (3 tới 128 ký tự) theo
  [API `CreateKeySigningKey`](https://docs.aws.amazon.com/Route53/latest/APIReference/API_CreateKeySigningKey.html). Key phải ở
  `us-east-1` và đúng loại đó theo
  [Route 53: customer managed key cho DNSSEC](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-cmk-requirements.html);
  key bất đối xứng không xoay tự động. Key policy theo
  [Route 53: quyền key cho DNSSEC](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/access-control-managing-permissions.html):
  account quản trị key qua IAM; `dnssec-route53.amazonaws.com` được `kms:DescribeKey`, `kms:GetPublicKey`, `kms:Sign` với `aws:SourceAccount` là
  account này và `aws:SourceArn` khớp `arn:aws:route53:::hostedzone/*`, và `kms:CreateGrant` với `kms:GrantIsForAWSResource`.
- **Hai alarm DNSSEC** (cùng `dnssec_enabled`) ở `us-east-1`, namespace `AWS/Route53`, dimension `HostedZoneId`, Sum ≥ 1 trong 5 phút, tag
  `Severity = page`, gửi `alarm_topic_arn` (topic `us-east-1` của module [`alarms`](../alarms/README.md) gọi với `region`; CloudWatch chỉ gửi
  tới topic cùng region):

  | Alarm | Metric | Runbook |
  | --- | --- | --- |
  | `svp-<env>-dnssec-internal-failure` | `DNSSECInternalFailure` | [`dnssec-internal-failure.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/dnssec-internal-failure.md) |
  | `svp-<env>-dnssec-ksk-action-needed` | `DNSSECKeySigningKeysNeedingAction` | [`dnssec-ksk-action-needed.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/dnssec-ksk-action-needed.md) |

  Cả hai là `page`: KSK `ACTION_NEEDED` (key KMS không dùng được) làm zone ngừng phân giải khi chữ ký hết hạn.
- **Query log** (biến `query_log_enabled`, mặc định `false`; root prd bật): log group `/aws/route53/<zone_name>` ở `us-east-1`, giữ 90 ngày,
  resource policy `svp-route53-query-log` của CloudWatch Logs cho `route53.amazonaws.com` (`logs:CreateLogStream`, `logs:PutLogEvents` trên log
  group đó, `aws:SourceAccount` là account này, `aws:SourceArn` là ARN của zone), rồi cấu hình query log của zone, theo
  [Route 53: public DNS query logging](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs.html) (log group phải ở `us-east-1`).
- **Budget `svp-<env>-monthly`**: chi phí của riêng account, email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo (cùng mẫu budget
  của `aws/bootstrap`, budget đó tính cả org).

Zone prd ký, zone stg không ký: bản ghi `NS` uỷ quyền stg trong zone prd không có `DS` đi kèm, nên `stg.aws.<domain>` là uỷ quyền không an toàn
hợp lệ (resolver kiểm DNSSEC trả lời không cờ `ad`, không lỗi). Lý do:
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) §11.

Output `backend_hcl` là nội dung file `aws/backend-<env>.hcl` (git bỏ qua) mà mọi root của account đọc bằng `-backend-config`: `bucket`,
`region`, `encrypt`, `kms_key_id`, `use_lockfile`; không có `key`, mỗi root tự đặt key state của mình.

## Tắt ký DNSSEC

Zone ký mà DNS cha còn bản ghi `DS` trỏ tới KSK thì mọi thay đổi làm chữ ký sai (tắt ký, xoá KSK, mất key KMS) khiến resolver kiểm DNSSEC trả
`SERVFAIL` cho cả zone. Vì vậy module không bao giờ để Terraform xoá key KMS (`prevent_destroy`), và tắt ký chỉ qua `dnssec_signing`.

`dnssec_signing` (mặc định `true`, chỉ có nghĩa khi `dnssec_enabled`) đặt `signing_status` là `SIGNING` hay `NOT_SIGNING`; KSK vẫn `ACTIVE`, key
KMS vẫn giữ. KSK không chuyển `INACTIVE` cùng lượt: Route 53 từ chối tắt KSK duy nhất của zone còn ký, và Terraform cập nhật KSK trước tài nguyên
phụ thuộc nó.

**Đường lui** (root `aws/accounts/prd`, người học chạy; lệnh đủ ở runbook `edge-setup.md` của repo code):

1. Gỡ bản ghi `DS` của `aws` ở DNS cha của `<domain>`.
2. Chờ hết TTL của bản ghi `DS` đó.
3. `terraform apply -var dnssec_signing=false` ở `aws/accounts/prd`.
4. PR đổi mặc định của biến `dnssec_signing` trong `aws/accounts/prd/variables.tf` thành `false`, để lượt apply sau không ký lại.

**Gỡ hẳn** (hiếm), chỉ sau khi zone đã `NOT_SIGNING` theo đường lui. Mọi lệnh chạy ở `aws/accounts/prd` với profile prd, sau khi
`AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1` cho đúng account prd:

1. Bỏ key KMS và alias khỏi state (key và alias vẫn ở AWS):
   `AWS_PROFILE=anhnv-prd terraform state rm 'module.baseline.aws_kms_key.dnssec[0]' 'module.baseline.aws_kms_alias.dnssec[0]'`.
2. PR đổi `dnssec_enabled = true` thành `false` trong `aws/accounts/prd/main.tf`, rồi
   `AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -out=prd.tfplan` và `terraform apply prd.tfplan` với
   cùng tiền tố: Terraform tắt DNSSEC của zone trước, rồi xoá KSK (provider tắt KSK đang `ACTIVE` trước khi xoá), cùng hai alarm. Giữa bước 1
   và bước này không apply nào khác: config còn `dnssec_enabled = true` thì Terraform tạo key mới và thay KSK.
3. Lên lịch xoá key qua alias của nó (`schedule-key-deletion` chỉ nhận id hay ARN của key):

   ```sh
   key=$(AWS_PROFILE=anhnv-prd aws kms describe-key --key-id alias/svp-dnssec --region us-east-1 --query KeyMetadata.KeyId --output text)
   AWS_PROFILE=anhnv-prd aws kms schedule-key-deletion --key-id "$key" --pending-window-in-days 30 --region us-east-1
   ```

   Huỷ được trong 30 ngày: `AWS_PROFILE=anhnv-prd aws kms cancel-key-deletion --key-id "$key" --region us-east-1`.

Không bao giờ đặt `dnssec_enabled = false` khi key còn trong state: `prevent_destroy` làm plan lỗi.

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
| [aws_cloudwatch_log_group.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_cloudwatch_metric_alarm.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_kms_alias.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_hosted_zone_dnssec.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_hosted_zone_dnssec) | resource |
| [aws_route53_key_signing_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_key_signing_key) | resource |
| [aws_route53_query_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_query_log) | resource |
| [aws_route53_record.caa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.delegation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_zone.env](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_iam_policy_document.dnssec_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.query_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account of the baseline (12 digits): part of the state bucket name and of the key policy. The root passes its own account\_id, which never goes into a committed file. | `string` | n/a | yes |
| alarm\_topic\_arn | SNS topic in us-east-1 the DNSSEC alarms notify (topic\_arn of the alarms module called with region us-east-1). Required when dnssec\_enabled. | `string` | `null` | no |
| budget\_emails | Addresses that receive the budget alerts. Personal data of a public repository: the root reads them from an uncommitted *.auto.tfvars or TF\_VAR\_budget\_emails. | `list(string)` | n/a | yes |
| budget\_limit\_usd | Monthly cost budget of the account, in US dollars. Alerts go out at 50, 80 and 100 percent of actual cost and at 100 percent of forecast cost. | `number` | n/a | yes |
| delegated\_subdomains | Child zones of other accounts to delegate from this zone: zone name (ending in .<zone\_name>) to its four name servers, the name\_servers output of the child's baseline. Each entry becomes an NS record in this zone. | `map(list(string))` | `{}` | no |
| dnssec\_enabled | Sign the zone with DNSSEC: a KMS key in us-east-1 (kept with prevent\_destroy), a key signing key, zone signing and two page alarms to alarm\_topic\_arn. Turning it off once on: the steps of the module README, never this variable alone. | `bool` | `false` | no |
| dnssec\_signing | With dnssec\_enabled, whether the zone is signed (SIGNING) or not (NOT\_SIGNING); the key signing key and the KMS key stay either way. Set it to false only after the DS record at the parent is gone and its TTL has passed. | `bool` | `true` | no |
| env | Environment the account runs (stg, prd): names the budget svp-<env>-monthly and appears in the comment of the hosted zone. | `string` | n/a | yes |
| query\_log\_enabled | Log the public DNS queries of the zone to the CloudWatch Logs group /aws/route53/<zone\_name> in us-east-1, kept 90 days. | `bool` | `false` | no |
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
