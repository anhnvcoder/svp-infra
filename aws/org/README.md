# `aws/org`: tổ chức AWS (chạy ở management account)

Mọi thứ cấp tổ chức của lab, ở management account (account sandbox, profile `anhnv-sso`). Management account chỉ giữ phần quản trị và dùng
chung, không chạy workload; stg và prd chạy trong hai account thành viên.

| Tài nguyên | Vì sao |
| --- | --- |
| Tổ chức (`aws_organizations_organization`, có sẵn, import) | feature set `ALL`; policy type SCP và RCP (RCP đã bật từ trước, giữ nguyên); trusted access `sso.amazonaws.com` (có sẵn) và `cloudtrail.amazonaws.com` (organization trail cần) |
| OU `Workloads`, account `svp-stg`, `svp-prd` | mỗi env một account; SCP gắn vào OU nên áp cho cả hai, không áp lên management. Role `OrganizationAccountAccessRole` mặc định; IAM bên trong account thành viên không quản ở đây |
| Ba SCP (module [`org-policies`](../modules/org-policies/README.md)) | account không rời org được, không tắt hay đổi trail được, chỉ dùng `ap-southeast-1` và `us-east-1` (trừ dịch vụ toàn cục) |
| Permission set `SvpAdmin` của IAM Identity Center | `AdministratorAccess`, phiên tối đa 4 giờ, gán cho user của người học ở hai account thành viên; permission set đang có của management không đụng |
| Organization trail `svp-audit` | management event đọc + ghi của mọi account, mọi region; log file validation; mã hoá bằng KMS key `alias/svp-cloudtrail` (xoay khoá hằng năm) |
| Bucket `svp-cloudtrail-<account>-<region>` | log của trail: versioning, chặn public, `BucketOwnerEnforced`, chỉ TLS, policy theo tài liệu CloudTrail cho org trail, Object Lock governance 365 ngày, lifecycle |
| Bucket `svp-cloudtrail-access-<account>-<region>` | server access log của bucket trên (ai đọc, ai xoá log) |

Mọi tài nguyên mang tag `Project=svp`, `ManagedBy=terraform`, `Stack=org` và sống giữa các buổi. Tổ chức, account, KMS key và hai bucket
có `prevent_destroy`: root này không bao giờ `terraform destroy` cả khối, gỡ theo mục [Gỡ có chủ đích](#gỡ-có-chủ-đích).

## Chặn xoá log

CIS AWS Foundations Benchmark v5.0.0 (bản Security Hub khuyên dùng,
[Security Hub: CIS](https://docs.aws.amazon.com/securityhub/latest/userguide/cis-aws-foundations-benchmark.html), đọc 2026-11-05) đòi trail
đa region (3.1), log file validation (3.2), server access logging trên bucket của CloudTrail (3.4), mã hoá bằng KMS key (3.5), xoay khoá
(3.6); root này làm đủ năm mục. Data event của S3 (3.8, 3.9) không bật: tính tiền theo event, ngoài phạm vi lab. Về chặn xoá, CIS chỉ có MFA Delete (2.1.2), nhưng MFA Delete chỉ root user bật được và không dùng chung với
lifecycle ([Security Hub: S3.20](https://docs.aws.amazon.com/securityhub/latest/userguide/s3-controls.html), đọc 2026-11-05), nên không
dùng. Chọn **S3 Object Lock chế độ governance**, retention mặc định 365 ngày:

- Không ai xoá hay ghi đè một version log trước hạn, trừ khi có quyền `s3:BypassGovernanceRetention` **và** gửi header
  `x-amz-bypass-governance-retention:true` có chủ đích; policy deny xoá trong bucket policy thì admin gỡ policy là xong, Object Lock đòi bước
  bypass riêng, mỗi lần xoá có dấu vết trong server access log (trail chỉ ghi management event, không ghi lệnh xoá object).
- Không dùng chế độ compliance: version bị khoá không ai xoá được, kể cả root user, trước hạn (cách duy nhất là xoá account)
  ([S3: Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html), đọc 2026-11-05).
- Object Lock bật được cả trên bucket có sẵn nhưng không tắt được nữa, kéo theo versioning
  ([S3: Configuring Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-configure.html), đọc 2026-11-05).
- Bucket access log không có Object Lock và mã hoá SSE-S3: S3 không giao server access log vào bucket có Object Lock hay mã hoá mặc định
  SSE-KMS ([S3: server access logging](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html), đọc 2026-11-05).

**Lifecycle:** giữ 365 ngày (một năm lịch sử audit, mức thông dụng: PCI DSS v4 yêu cầu 10.5.1 đòi ít nhất 12 tháng, ba tháng gần nhất
đọc được ngay), sau 90 ngày chuyển Glacier Instant Retrieval (vẫn đọc ngay, đủ 90 ngày lưu tối thiểu), rồi hết hạn; version cũ bị xoá khi
đã hết retention. S3 mặc định không chuyển lớp object dưới 128 KB
([S3: lifecycle transitions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html),
đọc 2026-11-05): phần lớn file log (vài KB) ở lại S3 Standard tới khi hết hạn, vì phí request chuyển lớp và cỡ tính tiền tối thiểu 128 KB
của Glacier IR đắt hơn phần lưu trữ tiết kiệm được; chỉ file lớn chuyển lớp.

## Phí giữ (R)

| Thành phần | Phí | Nguồn (đọc 2026-11-05) |
| --- | --- | --- |
| Organizations, SCP | miễn phí | [Organizations FAQ](https://aws.amazon.com/organizations/faqs/) |
| IAM Identity Center | miễn phí | [Identity Center FAQ](https://aws.amazon.com/iam/identity-center/faqs/) |
| Organization trail, management event | bản sao đầu tiên của management event vào S3 miễn phí; bản sao thêm $2,00 / 100.000 event | [CloudTrail pricing](https://aws.amazon.com/cloudtrail/pricing/) |
| KMS key `alias/svp-cloudtrail` | $1/tháng; lần xoay thứ nhất và thứ hai mỗi lần thêm $1/tháng (năm 1: $1, năm 2: $2, từ năm 3: $3); 20.000 request/tháng miễn phí | [KMS pricing](https://aws.amazon.com/kms/pricing/) |
| Hai bucket log | vài chục MB/tháng của một lab: dưới $0,10/tháng (ước lượng) | [S3 pricing](https://aws.amazon.com/s3/pricing/) |

**R ≈ $1,1/tháng năm đầu** (tăng tới khoảng $3,1/tháng khi khoá đã xoay hai lần). Trail này là bản sao miễn phí khi trong account không có
trail nào khác ghi management event (kiểm trước apply: `AWS_PROFILE=anhnv-sso aws cloudtrail describe-trails --region ap-southeast-1
--query 'trailList[].[Name,IsOrganizationTrail]' --output text` không in dòng nào ngoài `svp-audit`; trail đa region hiện ở mọi region). Thêm
một trail management event khác ở bất kỳ account nào thì bản sao thứ hai bị tính $2,00 / 100.000 event.

## Apply lần đầu

**Người học chạy mọi lệnh dưới đây** (AI không chạy lệnh nào chạm account). Cần: `aws/bootstrap` đã apply (bucket state, file
`aws/backend.hcl`), Terraform 1.15, AWS CLI v2, `jq`, `aws sso login --profile anhnv-sso`. Mỗi lệnh `terraform` đọc biến của root (`import`,
`plan`, `apply`) đặt `TF_VAR_account_id` ngay trong lệnh từ `SVP_AWS_MGMT_ACCOUNT_ID`; mỗi lệnh AWS CLI ghi `--region`: `ap-southeast-1`
cho STS, S3, CloudTrail, DynamoDB; `us-east-1` cho Organizations.

### 1. Kiểm account

```sh
cd infra/aws/org
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của Account vừa đọc>
```

`Account` phải là management account (account sandbox), `Arn` là role SSO của người học. Khác thì dừng.

### 2. Giá trị cá nhân

```sh
cp org.auto.tfvars.example org.auto.tfvars
```

Sửa `org.auto.tfvars` (git bỏ qua): `account_emails` (mỗi account thành viên một email **chưa account AWS nào dùng**, kể cả account đã đóng
hay đang SUSPENDED: AWS không cho dùng lại email của account đã đóng), `sso_user_name` (tên user ở góc phải trên của AWS access portal),
`sso_region` (dòng `sso_region` của profile `anhnv-sso` trong `~/.aws/config`, nằm trong khối `[sso-session …]` nếu có).

### 3. Init và import tổ chức có sẵn

```sh
AWS_PROFILE=anhnv-sso terraform init -backend-config=../backend.hcl
AWS_PROFILE=anhnv-sso aws organizations describe-organization --region us-east-1 --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform import aws_organizations_organization.this <o-… vừa đọc>
```

`MasterAccountId` phải bằng `SVP_AWS_MGMT_ACCOUNT_ID`, `FeatureSet` là `ALL`. Import trước plan: không import thì plan đòi **tạo** tổ chức
mới và apply lỗi vì account đã thuộc một tổ chức.

### 4. Plan

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform plan -out=org.tfplan
```

Mong đợi `Plan: 31 to add, 1 to change, 0 to destroy`. Thay đổi duy nhất là tổ chức, `~ update in-place`, chỉ **thêm**
`cloudtrail.amazonaws.com` vào `aws_service_access_principals`. Dừng (không apply, dán plan lại) nếu tổ chức hiện `-/+` hay `destroy`, nếu
`enabled_policy_types` hay `feature_set` đổi, hay nếu có dòng `destroy` nào.

### 5. Apply

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply org.tfplan
rm org.tfplan
```

Tạo account mất vài phút mỗi account. Mỗi id account đọc bằng một lệnh, đặt vào biến của terminal buổi (không ghi vào file commit):

```sh
AWS_PROFILE=anhnv-sso terraform output -raw organization_id
export SVP_AWS_STG_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw stg_account_id)"
export SVP_AWS_PRD_ACCOUNT_ID="$(AWS_PROFILE=anhnv-sso terraform output -raw prd_account_id)"
```

### 6. Profile `anhnv-stg`, `anhnv-prd`

Mỗi account một lần (AI không sửa `~/.aws/config`):

```sh
aws configure sso --profile anhnv-stg
```

Chọn SSO session đang dùng cho `anhnv-sso`, account `svp-stg`, role `SvpAdmin`, region mặc định `ap-southeast-1`, output `json`. Lặp lại
với `--profile anhnv-prd` và account `svp-prd`. Kiểm:

```sh
AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
```

`Account` bằng `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID`; `Arn` dạng `assumed-role/AWSReservedSSO_SvpAdmin_…`.

### 7. Kiểm SCP và trail

Lệnh chỉ đọc ở region bị chặn phải bị SCP từ chối, cùng lệnh ở region được phép thì chạy:

```sh
AWS_PROFILE=anhnv-stg aws dynamodb list-tables --region eu-west-1        # AccessDeniedException ... explicit deny in a service control policy
AWS_PROFILE=anhnv-stg aws dynamodb list-tables --region ap-southeast-1   # {"TableNames": []}
AWS_PROFILE=anhnv-prd aws dynamodb list-tables --region eu-west-1        # AccessDeniedException ... explicit deny in a service control policy
```

SCP không áp lên management account: cùng lệnh với `anhnv-sso` ở `eu-west-1` vẫn chạy, đó là đúng thiết kế.

```sh
AWS_PROFILE=anhnv-sso aws cloudtrail get-trail-status --name svp-audit --region ap-southeast-1 --query '[IsLogging,LatestDeliveryError,LatestDigestDeliveryError]'
AWS_PROFILE=anhnv-sso aws s3api get-object-lock-configuration --bucket "svp-cloudtrail-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1" --region ap-southeast-1
```

Mong đợi `[true, null, null]` (một lỗi giao log hay digest, ví dụ bị bucket Object Lock hay key policy từ chối, hiện ở hai ô sau: dán lại) và
`"Mode": "GOVERNANCE", "Days": 365`. Khoảng 15 phút sau, log của account stg có trong bucket:

```sh
AWS_PROFILE=anhnv-sso aws s3api list-objects-v2 --bucket "svp-cloudtrail-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1" --region ap-southeast-1 \
  --prefix "AWSLogs/$(AWS_PROFILE=anhnv-sso terraform output -raw organization_id)/$SVP_AWS_STG_ACCOUNT_ID/" --max-items 3 --query 'Contents[].Key'
```

### 8. Quota và xác minh CloudFront của account mới

Account mới có quota EC2 mặc định (5 cho mỗi mã dưới đây ở `ap-southeast-1`), chưa đủ cho buổi stg, prd. Đọc:

```sh
for p in anhnv-stg anhnv-prd; do
  for q in L-1216C47A L-34B43A08 L-0263D0A3; do
    printf '%s %s ' "$p" "$q"
    AWS_PROFILE=$p aws service-quotas get-service-quota --service-code ec2 --quota-code $q --region ap-southeast-1 --query Quota.Value --output text
  done
done
```

| Mã | Quota | stg cần | prd cần |
| --- | --- | --- | --- |
| `L-1216C47A` | vCPU on-demand (Standard) | ≥ 4 | ≥ 16 |
| `L-34B43A08` | vCPU Spot (Standard) | ≥ 10 | — |
| `L-0263D0A3` | Elastic IP | ≥ 1 | ≥ 3 |

Thiếu thì xin tăng (mỗi mã thiếu một lệnh; `PENDING` rồi `APPROVED`, account mới thường vài giờ tới 1–2 ngày):

```sh
AWS_PROFILE=<anhnv-stg|anhnv-prd> aws service-quotas request-service-quota-increase --service-code ec2 --quota-code <mã> \
  --desired-value <số> --region ap-southeast-1 --query 'RequestedQuota.[QuotaCode,DesiredValue,Status]' --output text
```

Mỗi yêu cầu tăng quota thành một case loại "Service limits" trong Support Center của account đó.

Account mới chưa dùng được CloudFront tới khi AWS xác minh. Trên console của từng account (AWS access portal, permission set `SvpAdmin`),
Support Center mở bằng ô chat với trợ lý AI: gõ yêu cầu, ví dụ `Please verify this new account so it can create Amazon CloudFront
distributions. It is a member account of organization <o-…> (management account <id>), used for a <staging|production> environment.`; trợ lý
không tự giải quyết được thì hiện form tạo case đã điền sẵn. Kiểm Case type "Account and billing", Service "Account Activation", Category
"Account Verification", Severity "General question", liên lạc qua Web, rồi Submit; dán số case. Buổi stg, prd chỉ bắt đầu khi quota đã duyệt
và case đã xong.

## Gỡ có chủ đích

Chỉ khi lab kết thúc, sau khi mọi env và baseline của hai account thành viên đã gỡ theo runbook của chúng. Các bước theo thứ tự; lệnh
`terraform` chạy trong `infra/aws/org` với `TF_VAR_account_id` như trên.

0. **Kiểm account của phiên gỡ** (trước lệnh ghi đầu tiên; lệnh `aws` không có `allowed_account_ids` như provider Terraform):

   ```sh
   AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
   ```

   `Account` phải bằng `$SVP_AWS_MGMT_ACCOUNT_ID` (management account), `Arn` là role SSO của người học. Khác thì dừng, không chạy bước nào dưới đây.

1. **Tắt trail, gỡ quyền SSO** (không tài nguyên nào trong số này có `prevent_destroy`; log đã ghi vẫn còn):

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_cloudtrail.audit \
     -target=aws_ssoadmin_account_assignment.learner -target=aws_ssoadmin_managed_policy_attachment.admin -target=aws_ssoadmin_permission_set.admin
   ```

2. **Đóng account thành viên theo quy trình AWS, không bằng destroy** (`close_on_deletion = false`, `prevent_destroy`): destroy chỉ gỡ
   account khỏi tổ chức. Account đã đóng ở trạng thái đóng 90 ngày, vẫn thuộc tổ chức và OU, vẫn tính vào hạn mức số account; email của nó
   không dùng lại được; mỗi 30 ngày chỉ đóng được một phần số account thành viên
   ([Organizations: close account](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_close.html), đọc 2026-11-05).

   ```sh
   AWS_PROFILE=anhnv-sso aws organizations close-account --account-id "$SVP_AWS_STG_ACCOUNT_ID" --region us-east-1
   AWS_PROFILE=anhnv-sso aws organizations close-account --account-id "$SVP_AWS_PRD_ACCOUNT_ID" --region us-east-1
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_account.member
   ```

3. **Gỡ khoá chặn xoá log rồi xoá hai bucket và KMS key.** Xoá mọi version của bucket log, bỏ qua retention governance (cần
   `s3:BypassGovernanceRetention`, có ở `AdministratorAccess`); lặp lại tới khi `versions.json` rỗng:

   ```sh
   B="svp-cloudtrail-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1"
   AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$B" --region ap-southeast-1 --output json \
     --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' > versions.json
   jq -c '.Objects | _nwise(1000) | {Objects: ., Quiet: true}' versions.json | while read -r batch; do
     AWS_PROFILE=anhnv-sso aws s3api delete-objects --bucket "$B" --region ap-southeast-1 --bypass-governance-retention --delete "$batch"
   done
   ```

   Rồi gỡ bảo vệ chỉ trong bản sửa local (không commit): trong `audit-trail.tf` đổi `prevent_destroy = true` thành `false` ở
   `aws_s3_bucket.trail`, `aws_s3_bucket.access_logs`, `aws_kms_key.cloudtrail` và thêm `force_destroy = true` vào hai bucket (xoá nốt access
   log). Áp `force_destroy` trước, rồi xoá:

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -target=aws_s3_bucket.trail -target=aws_s3_bucket.access_logs
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_s3_bucket.trail \
     -target=aws_s3_bucket.access_logs -target=aws_kms_alias.cloudtrail -target=aws_kms_key.cloudtrail
   rm versions.json
   ```

   KMS key vào trạng thái chờ xoá 30 ngày (huỷ được trong thời gian đó); xoá xong thì log mã hoá bằng nó không đọc được nữa.

4. **Sau khi AWS gỡ hẳn hai account đã đóng khỏi tổ chức** (hết 90 ngày;
   `AWS_PROFILE=anhnv-sso aws organizations list-accounts --region us-east-1 --query 'Accounts[].[Id,Name,Status]' --output text` không còn
   `svp-stg`, `svp-prd`): xoá SCP và OU (OU còn account thì không xoá được).

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_organizations_organizational_unit.workloads -target=module.org_policies
   ```

5. **Trả tổ chức về như trước root này** (tổ chức có trước, không xoá): bỏ khỏi state, tắt trusted access của CloudTrail, xoá state của root.

   ```sh
   AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_organization.this
   AWS_PROFILE=anhnv-sso aws organizations disable-aws-service-access --service-principal cloudtrail.amazonaws.com --region us-east-1
   AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-tfstate-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1/aws/org/terraform.tfstate" --region ap-southeast-1
   rm -f org.auto.tfvars
   ```

   Hoàn tác sửa local của bước 3 (`git checkout -- audit-trail.tf`), xoá thư mục này bằng PR nếu không dùng nữa.
