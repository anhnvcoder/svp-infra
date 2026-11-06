# `aws/accounts`: baseline của account stg và prd (chạy một lần mỗi account)

Mỗi account thành viên của org (`svp-stg`, `svp-prd`) có một root ở đây, gọi module
[`account-baseline`](../modules/account-baseline/README.md): bucket state và KMS key của nó, zone DNS của env, budget tháng. Mọi thứ sống
giữa các buổi AWS, mang tag `Stack=baseline` (script quét sót của buổi giữ lại tag này).

Zone của prd là zone gốc của lab, `aws.<domain>` (web prd ở đỉnh zone, API `api.aws.<domain>`), được DNS của domain cha (Cloudflare) uỷ
quyền bằng bốn bản ghi `NS` tên `aws`. Zone của stg là `stg.aws.<domain>`, zone con mà zone prd uỷ quyền bằng bản ghi `NS` của biến
`delegated_subdomains` (chỉ root prd có). Management account không giữ hosted zone nào. Lý do và cái giá (đổi name server của zone stg cần
`apply` ở account prd): [ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md).

| Root | Profile SSO | Biến account | State |
| --- | --- | --- | --- |
| `stg/` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` | key `aws/accounts/stg/terraform.tfstate` trong bucket của account stg |
| `prd/` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` | key `aws/accounts/prd/terraform.tfstate` trong bucket của account prd |

Hai root chỉ khác `local.env` (`main.tf`), `key` của backend (`versions.tf`), biến `delegated_subdomains` (chỉ prd khai báo và truyền vào
module) và mô tả của biến, output theo zone của env. Trong bucket của mỗi account còn có state của root
`aws/envs/<env>` (key `aws/<env>/terraform.tfstate`) và `aws/gitops/<env>` (key `aws/gitops/<env>/terraform.tfstate`), cả hai đọc
`-backend-config=../../backend-<env>.hcl`.

## Phí giữ giữa các buổi

Mỗi account, trong khi baseline còn:

| Tài nguyên | Phí | Nguồn |
| --- | --- | --- |
| KMS key `alias/svp-tfstate` | $1/tháng (tính theo giờ); xoay vòng tự động cộng $1/tháng ở lần xoay thứ nhất và thứ hai (mỗi năm một lần), từ lần thứ ba không cộng thêm: $1, $2 rồi $3/tháng | [AWS KMS pricing](https://aws.amazon.com/kms/pricing/), đọc 2026-11-05 |
| Request KMS của state | trong 20 000 request/tháng miễn phí (vài lần `plan`, `apply` mỗi buổi, S3 Bucket Key bật) | như trên; lượng là ước lượng |
| Hosted zone của env (`aws.<domain>` ở prd, `stg.aws.<domain>` ở stg); bản ghi uỷ quyền stg trong zone prd không tính thêm (10 000 bản ghi đầu mỗi zone nằm trong phí zone) | $0,50/tháng (không chia theo ngày) | [Route 53 pricing](https://aws.amazon.com/route53/pricing/), đọc 2026-11-05 |
| Bucket state | < $0,01/tháng (vài file state, cả version cũ) | ước lượng |
| Budget `svp-<env>-monthly` | miễn phí (budget không có action) | [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/), đọc 2026-11-05 |

Tổng R mỗi account khoảng $1,51/tháng năm đầu ($3,02 cho hai account), tăng lên $2,51 rồi $3,51 sau mỗi lần xoay key. Key đang chờ xoá
(`PendingDeletion`) không tính phí. Management account không giữ hosted zone: mỗi account prd, stg đúng một zone, tổng hai zone.

## Dựng baseline

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Làm sau khi root `aws/org` đã tạo account và gán permission set
`SvpAdmin`, trước buổi AWS đầu của env đó. Dựng mới cả hai env thì prd trước: zone stg được uỷ quyền từ zone prd (mục 5). Ví dụ dưới là
stg; với prd thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`, `SVP_AWS_STG_ACCOUNT_ID` bằng `SVP_AWS_PRD_ACCOUNT_ID`.

Cần: Terraform 1.15, AWS CLI v2, `jq`, `dig`; profile `anhnv-stg` đã tạo bằng `aws configure sso` (permission set `SvpAdmin` của account
stg) và `aws sso login --profile anhnv-stg`; trong terminal của buổi (không file commit nào) đã `export SVP_AWS_STG_ACCOUNT_ID=<12 số>`.

### 1. Kiểm account và role

```sh
cd infra/aws/accounts/stg
AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_STG_ACCOUNT_ID"
```

`Account` phải bằng số vừa in, `Arn` phải chứa `assumed-role/AWSReservedSSO_SvpAdmin_`. Sai một trong hai thì dừng: key policy chỉ cho role
SSO của `SvpAdmin` mã hoá, giải mã, nên apply bằng role khác (vd `OrganizationAccountAccessRole`) tạo được key nhưng không ghi được state vào
bucket ở bước 4.

### 2. Giá trị cá nhân

```sh
cp stg.auto.tfvars.example stg.auto.tfvars
```

Sửa `stg.auto.tfvars` (git bỏ qua): `budget_emails`, `zone_name` (không dấu chấm cuối: `stg.aws.<domain>` ở stg, `aws.<domain>` ở prd),
`budget_limit_usd` nếu muốn khác $20. Ở prd bỏ khối `delegated_subdomains` của file ví dụ cho tới mục 5 (zone stg chưa có).

### 3. Apply lần đầu, state local

Bucket state chưa có, nên lần đầu chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan -out=stg.tfplan
```

Đọc plan: `Plan: 10 to add, 0 to change, 0 to destroy` (KMS key và alias, bucket cùng 5 cấu hình của nó, hosted zone, budget; không bản
ghi `delegation` nào). Rồi:

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw backend_hcl > ../../backend-stg.hcl
cat ../../backend-stg.hcl     # bucket, region, encrypt, kms_key_id, use_lockfile của account stg
```

`aws/backend-stg.hcl` (git bỏ qua) là cấu hình backend mà mọi root của account stg đọc bằng `-backend-config`.

### 4. Chuyển state vào bucket

```sh
rm local_override.tf stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state -backend-config=../../backend-stg.hcl   # trả lời yes
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform plan                                                         # mong đợi: No changes.
AWS_PROFILE=anhnv-stg aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/accounts/stg/terraform.tfstate --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId}'   # SSE: aws:kms, Key: ARN của key state
```

Ba lệnh đều đúng mong đợi thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`.

### 5. Uỷ quyền zone của env

Zone của env chỉ trả lời được khi zone ở trên có bốn bản ghi `NS` trỏ về bốn name server của nó, theo
[Route 53: tạo subdomain dùng Route 53 mà không chuyển domain cha](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingNewSubdomain.html).
Mỗi buổi AWS bắt đầu bằng phép kiểm uỷ quyền (`aws/scripts/check-dns.sh <env>`); sai thì không `apply`. Output `zone_id` là
`hosted_zone_id` của root `aws/envs/<env>`.

**prd: DNS của domain cha uỷ quyền `aws.<domain>`.** Lấy bốn name server:

```sh
cd infra/aws/accounts/prd
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]'
```

Trong Cloudflare (DNS đang phục vụ domain): **DNS** → **Records** của `<domain>`, bốn bản ghi **Type** `NS`, **Name** `aws`, mỗi bản ghi
**Nameserver** một trong bốn tên vừa in (không dấu chấm cuối), **TTL** Auto. Đã có bốn bản ghi `NS` `aws` thì sửa **Nameserver** của chúng,
không thêm bản ghi thứ năm. Không đổi gì khác của domain (không đổi name server của domain, không xoá bản ghi nào khác).

Kiểm lan truyền (lặp lại tới khi qua; thường vài phút, có thể tới 48 giờ do cache):

```sh
ns=$(AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]' | sort)
for r in 1.1.1.1 8.8.8.8; do
  diff <(dig NS aws.<domain> +short @"$r" | sed 's/\.$//' | sort) <(echo "$ns") && echo "$r: delegation OK"
done
dig NS aws.<domain> +short          # resolver của máy: cũng đúng bốn name server đó
```

**stg: zone prd uỷ quyền `stg.aws.<domain>`.** Làm sau khi baseline của stg và của prd đã apply. Lấy bốn name server của zone stg:

```sh
cd infra/aws/accounts/stg
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]'
```

Thêm vào `aws/accounts/prd/prd.auto.tfvars` (git bỏ qua; dạng ở `prd.auto.tfvars.example`), tên zone kết thúc bằng `.<zone_name của prd>`,
đúng bốn name server:

```hcl
delegated_subdomains = {
  "stg.aws.<domain>" = ["<ns 1>", "<ns 2>", "<ns 3>", "<ns 4>"]
}
```

Rồi với profile prd:

```sh
cd ../prd
AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table   # Account = $SVP_AWS_PRD_ACCOUNT_ID
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -out=prd.tfplan
```

Đọc plan: `Plan: 1 to add, 0 to change, 0 to destroy`, đúng `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`, không gì
khác. Validation của biến chỉ chạy lúc `plan`: tên không phải con của zone prd hay số name server khác bốn thì dừng ở đó. Rồi:

```sh
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan
ns=$(cd ../stg && AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]' | sort)
for r in 1.1.1.1 8.8.8.8; do
  diff <(dig NS stg.aws.<domain> +short @"$r" | sed 's/\.$//' | sort) <(echo "$ns") && echo "$r: delegation OK"
done
```

Zone stg bị thay (gỡ rồi dựng lại baseline stg) thì có bốn name server mới. Bản ghi `NS` ở zone prd không bao giờ được trỏ tới zone stg đã
xoá, nên thứ tự là:

1. Bỏ mục `stg.aws.<domain>` khỏi `delegated_subdomains` trong `prd.auto.tfvars`, plan và apply prd như bước 1 của mục
   [Gỡ baseline](#gỡ-baseline-có-chủ-đích) (mong đợi `0 to add, 0 to change, 1 to destroy`, đúng
   `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`).
2. Gỡ baseline stg theo các bước còn lại của mục đó, rồi dựng lại từ [Dựng baseline](#dựng-baseline).
3. Thêm lại mục `stg.aws.<domain>` với bốn name server mới (output `name_servers` của `aws/accounts/stg`) và làm lại các lệnh trên với
   profile prd (plan mong đợi `1 to add, 0 to change, 0 to destroy`, đúng bản ghi `delegation` đó).

Từ bước 1 tới khi apply ở bước 3 xong, `stg.aws.<domain>` không phân giải.

## Gỡ baseline (có chủ đích)

Chỉ khi bỏ hẳn env đó: bucket giữ state của mọi root của account, key giữ quyền đọc state. Trước hết mọi root của account đã `destroy`
(`aws/gitops/<env>`, `aws/envs/<env>`), quét sót của buổi sạch.

1. Bỏ uỷ quyền trước khi xoá zone: bản ghi `NS` ở zone cha còn trỏ tới name server của zone đã xoá thì người khác tạo zone cùng tên trên
   các name server đó chiếm được tên (subdomain takeover).
   - stg: xoá mục `stg.aws.<domain>` khỏi `delegated_subdomains` trong `aws/accounts/prd/prd.auto.tfvars`, rồi từ `aws/accounts/prd`:
     `AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -out=prd.tfplan` (mong đợi
     `0 to add, 0 to change, 1 to destroy`, đúng `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`), rồi
     `AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan` (kiểm account prd
     bằng `AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1` trước).
   - prd: gỡ stg trước (zone prd chứa uỷ quyền của stg; bước 3 đòi zone chỉ còn `NS`, `SOA` ở đỉnh). Rồi xoá bốn bản ghi `NS` `aws` trong
     Cloudflare; `dig NS aws.<domain> +short @1.1.1.1` không còn ra name server nào của zone prd (cache có thể giữ tới 48 giờ).
2. Kiểm account của env trước lệnh đầu tiên bằng profile env (các bước dưới đây ghi vào account đó):
   `AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text`:
   `Account` phải bằng `$SVP_AWS_STG_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`. Khác thì dừng.
3. Kiểm zone chỉ còn `NS`, `SOA` ở đỉnh (bản ghi sót của ExternalDNS hay `_acme-challenge` chặn việc xoá zone; xoá chúng trước):
   `AWS_PROFILE=anhnv-stg aws route53 list-resource-record-sets --region ap-southeast-1 --hosted-zone-id "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw zone_id)" --query 'ResourceRecordSets[].[Name,Type]' --output text`
4. Đưa state về local (bucket và key sắp bị xoá): tạo lại `local_override.tf` như bước 3 của mục dựng, rồi
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state` (trả lời yes).
5. Gỡ bảo vệ, chỉ trong bản sửa local này (không commit): trong `aws/modules/account-baseline/state.tf` và `kms.tf` đổi
   `prevent_destroy = true` thành `false`, thêm `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ và state
   của các root khác). Rồi `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply` (chỉ đổi `force_destroy`),
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform destroy`. Key vào `PendingDeletion` 30 ngày (không tính
   phí), huỷ được trong thời gian đó (id key in ở output của `destroy`):
   `AWS_PROFILE=anhnv-stg aws kms cancel-key-deletion --key-id <id key> --region ap-southeast-1`.
6. `rm -f terraform.tfstate* ../../backend-stg.hcl stg.auto.tfvars local_override.tf`, hoàn tác sửa của bước 5
   (`git checkout -- ../../modules/account-baseline`).
