# Runbook: gỡ nền lâu dài của lab

[Mục lục](README.md)

> **Tóm tắt**
>
> - **Làm gì:** gỡ có chủ đích mọi thứ sống giữa các buổi (baseline của account env, backup, bảo mật, log, tổ chức, bucket state), ngược
>   thứ tự áp, mỗi root một mục; đóng năm account thành viên; trả tổ chức về như trước khi có code.
> - **Khi nào và bao lâu:** chỉ khi lab kết thúc. Lệnh chạy trong một buổi, nhưng account đóng ở trạng thái đóng 90 ngày trước khi AWS gỡ
>   hẳn, nên bước cuối của `aws/org` làm sau 90 ngày; bucket trail cũ chờ Object Lock hết hạn.
> - **Phí trong lúc chạy:** không thêm; phí giữ giảm dần theo từng root gỡ xong. KMS key bị xoá vào trạng thái chờ xoá (7 hay 30 ngày,
>   huỷ được trong thời gian đó).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account. Giữ tay hoàn toàn: đóng account không đảo ngược, `destroy` có
`-target` theo thứ tự, và xoá dữ liệu không khôi phục được; mỗi bước là quyết định của người học sau khi đọc lệnh. Mọi lệnh chạy từ gốc
repo (`infra/`) trừ chỗ ghi `cd`. Vì sao mỗi root tồn tại: [handbook](../handbook/README.md).

## Điều kiện trước

- [ ] **Không còn env:** buổi stg, prd đã gỡ theo runbook buổi, `sweep.sh <env>` và `sweep.sh mgmt` sạch.
- [ ] **Lịch sử không còn cần:** log audit, finding, bản copy backup sẽ mất khi đóng account; tải về trước những gì muốn giữ.
- [ ] **Code trên `main`**, mọi root đã `init` (`aws/scripts/tfvars.sh init`), biến của năm account thành viên đã đặt
  (`eval "$(aws/scripts/accounts.sh)"`).

## Mở terminal

Như [Mở terminal của `org-security-setup.md`](org-security-setup.md#mở-terminal): đăng nhập `anhnv-sso`, kiểm biến account,
`check-account.sh mgmt`. Lệnh `aws` không có `allowed_account_ids` như provider Terraform, nên đối chiếu account trước lệnh ghi đầu tiên:

```sh
AWS_PROFILE=anhnv-sso aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text
```

- **Kiểm:** `Account` bằng `$SVP_AWS_MGMT_ACCOUNT_ID`, `Arn` là role SSO của người học. Khác thì dừng, không chạy bước nào dưới đây.

## Thứ tự gỡ

Ngược luồng áp; mỗi dòng xong mới sang dòng sau.

| Thứ tự | Root | Vì sao ở vị trí này | Mục |
| --- | --- | --- | --- |
| 1 | `aws/accounts/<env>` | Baseline env dùng vault, key của `aws/backup` và rule gửi về `svp-security` | [`aws/accounts/<env>`](#awsaccountsenv) |
| 2 | `aws/backup` | Vault copy nhận bản từ account env; sau khi đóng account, management không vào được nữa | [`aws/backup`](#awsbackup) |
| 3 | `aws/baseline` | Rule nguồn của mọi account trỏ bus của `aws/security` | [`aws/baseline`](#awsbaseline) |
| 4 | `aws/security` | Cần delegated admin còn đó để tắt dịch vụ của thành viên | [`aws/security`](#awssecurity) |
| 5 | `aws/org`, phần 1 | Tắt trail, bỏ delegated admin; còn đọc alias của Log Archive | [Phần 1](#phần-1-trail-delegated-admin-quyền-sso) |
| 6 | `aws/log-archive` (tuỳ chọn) | Chỉ khi muốn xoá log trước khi đóng account; sau khi đóng, không vào account được nữa | [`aws/log-archive`](#awslog-archive) |
| 7 | `aws/org`, phần 2–5 | Đóng account, chờ 90 ngày, xoá policy, OU, trả tổ chức | [Phần 2](#phần-2-đóng-năm-account-thành-viên) |
| 8 | `aws/bootstrap` | Giữ state của mọi root trên tới cuối | [Xoá bootstrap](#xoá-bootstrap) |

## `aws/accounts/<env>`

Đầu tiên trong thứ tự gỡ, chỉ khi bỏ hẳn env đó: bucket giữ state của mọi root của account, key giữ quyền đọc state. Gỡ cũng xoá bản phát
hành trong ECR (GHCR còn bản gốc), metric, log, span và workspace Grafana của env. Gỡ cả hai env thì stg trước (zone prd chứa uỷ quyền của
stg). Ví dụ là stg; với prd thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`, `SVP_AWS_STG_ACCOUNT_ID` bằng `SVP_AWS_PRD_ACCOUNT_ID`.

- [ ] Mọi root khác của account đã `destroy` (`aws/gitops/<env>`, `aws/envs/<env>`), quét sót của buổi sạch.
- [ ] Vault `svp-<env>` trống: AWS Backup không xoá vault còn recovery point (`restore-drill.sh <env> cleanup` của buổi cuối đã chạy). Bản
  copy trong `svp-<env>-copy` của `svp-backup` không gỡ cùng env, giữ tới hết retention hay tới mục [`aws/backup`](#awsbackup).

1. **Bỏ uỷ quyền trước khi xoá zone**: bản ghi `NS` ở zone cha còn trỏ tới name server của zone đã xoá thì người khác tạo zone cùng tên
   trên các name server đó chiếm được tên (subdomain takeover).
   - stg: xoá mục `stg.aws.<domain>` khỏi `delegated_subdomains` trong `aws/accounts/prd/prd.auto.tfvars`, kiểm account prd bằng
     `AWS_PROFILE=anhnv-prd aws sts get-caller-identity --region ap-southeast-1`, rồi từ `aws/accounts/prd` plan, đọc, apply:

     ```sh
     AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform plan -out=prd.tfplan
     AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan
     ```

   - prd: gỡ stg trước (bước 3 đòi zone chỉ còn `NS`, `SOA`, `CAA` ở đỉnh). Rồi làm [đường lui của
     `edge-setup.md`](edge-setup.md#đường-lui): gỡ bản ghi `DS` `aws`, chờ TTL của nó, apply `-var dnssec_signing=false`. Rồi xoá bốn bản
     ghi `NS` `aws` trong Cloudflare.
   - **Mong đợi:** plan của stg là `0 to add, 0 to change, 1 to destroy`, đúng
     `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`. Với prd, `dig NS aws.<domain> +short @1.1.1.1` không còn ra name
     server nào của zone prd (cache có thể giữ tới 48 giờ).
2. **Kiểm account của env** trước lệnh đầu tiên bằng profile env (các bước dưới ghi vào account đó):
   `AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '[Account,Arn]' --output text`.
   - **Kiểm:** `Account` bằng `$SVP_AWS_STG_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`. Khác thì dừng.
3. **Zone chỉ còn `NS`, `SOA` và `CAA` ở đỉnh** (`CAA` thuộc baseline, `destroy` xoá nó; bản ghi sót của buổi chặn việc xoá zone, xoá chúng
   trước), từ `aws/accounts/stg`:

   ```sh
   AWS_PROFILE=anhnv-stg aws route53 list-resource-record-sets --region ap-southeast-1 --hosted-zone-id "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw zone_id)" --query 'ResourceRecordSets[].[Name,Type]' --output text
   ```

4. **Đưa state về local** (bucket và key sắp bị xoá): tạo lại `local_override.tf` như
   [`accounts-setup.md`, bước (3)](accounts-setup.md#bước-3-apply-lần-đầu-state-local), rồi
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state` (trả lời yes).
5. **Gỡ bảo vệ, sửa local, không commit**: đổi `prevent_destroy = true` thành `false` trong `aws/modules/account-baseline/state.tf`,
   `kms.tf`, `aws/modules/registry/kms.tf` và `aws/modules/observability/kms.tf`; thêm `force_destroy = true` vào `aws_s3_bucket.state` (xoá
   được bucket còn version cũ và state của các root khác) và `force_delete = true` vào `aws_ecr_repository.release` của
   `aws/modules/registry/repositories.tf` (ECR không xoá repo còn image). Rồi
   `AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform apply`
   (ở prd, khi mặc định của `dnssec_signing` còn `true`, thêm `-var dnssec_signing=false` như bước 1).
   - **Mong đợi:** `0 to add`, `0 to destroy`, `change` chỉ đổi `force_destroy` của bucket và `force_delete` của mọi repo phát hành.
6. **Xoá repo do pull-through cache tạo**: ECR tạo chúng khi node kéo image qua cache, nên chúng nằm ngoài state, mã hoá bằng key
   `alias/svp-<env>-ecr` mà bước 8 lên lịch xoá. Liệt kê theo tiền tố của các rule cache:

   ```sh
   AWS_PROFILE=anhnv-stg aws ecr describe-pull-through-cache-rules --region ap-southeast-1 \
     --query 'pullThroughCacheRules[].ecrRepositoryPrefix' --output json | jq -r '.[]' > cache-prefixes.txt
   while read -r p; do
     AWS_PROFILE=anhnv-stg aws ecr describe-repositories --region ap-southeast-1 --output json \
       --query "repositories[?starts_with(repositoryName, '$p/')].repositoryName" < /dev/null | jq -r '.[]'
   done < cache-prefixes.txt > cache-repos.txt
   cat cache-prefixes.txt cache-repos.txt
   ```

   - **Kiểm:** `cache-prefixes.txt` là tiền tố của `local.cache_rules` (module `registry`); mỗi dòng của `cache-repos.txt` bắt đầu bằng một
     tiền tố đó, không dòng nào là `svp-backend/`, `svp-frontend/`. Đúng vậy thì xoá chúng cùng image (upstream còn bản gốc):

   ```sh
   while read -r r; do
     AWS_PROFILE=anhnv-stg aws ecr delete-repository --region ap-southeast-1 --force --repository-name "$r" \
       --query repository.repositoryName --output text < /dev/null
   done < cache-repos.txt
   rm cache-prefixes.txt cache-repos.txt
   ```

7. **Chỉ prd: bỏ key DNSSEC khỏi state** ngay trước `destroy` (Terraform không bao giờ xoá nó, `dnssec.tf` giữ `prevent_destroy`), như
   bước 1 của [`edge-setup.md`, Gỡ hẳn](edge-setup.md#gỡ-hẳn):
   `AWS_PROFILE=anhnv-prd terraform state rm 'module.baseline.aws_kms_key.dnssec[0]' 'module.baseline.aws_kms_alias.dnssec[0]'`.
   - **Bẫy:** không apply sau lệnh này: config còn DNSSEC thì Terraform tạo key mới.
8. **Destroy** (ở prd Terraform tắt DNSSEC của zone trước, rồi xoá KSK):

   ```sh
   AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform destroy
   ```

   - **Mong đợi:** key của state, `alias/svp-<env>-ecr`, `alias/svp-<env>-observability` và `alias/svp-<env>-backup` vào `PendingDeletion`
     30 ngày (không tính phí), huỷ được trong thời gian đó (id mỗi key in ở output của `destroy`):
     `AWS_PROFILE=anhnv-stg aws kms cancel-key-deletion --key-id <id key> --region ap-southeast-1`.
   - **Bẫy:** hai secret `ecr-pullthroughcache/ghcr`, `ecr-pullthroughcache/docker-hub` cũng chờ xoá 30 ngày, trong thời gian đó không tạo
     được secret cùng tên: dựng lại env này sớm hơn thì xoá hẳn chúng trước (giá trị ghi lại sau apply như lần đầu):

     ```sh
     for s in ghcr docker-hub; do
       AWS_PROFILE=anhnv-stg aws secretsmanager delete-secret --secret-id "ecr-pullthroughcache/$s" \
         --force-delete-without-recovery --region ap-southeast-1
     done
     ```

9. **Chỉ prd: lên lịch xoá key DNSSEC** (còn ở AWS, ngoài state) bằng hai lệnh ở bước 3 của [`edge-setup.md`, Gỡ
   hẳn](edge-setup.md#gỡ-hẳn) (profile `anhnv-prd`, `--region us-east-1`, chờ 30 ngày, huỷ được trong thời gian đó).
10. **Gỡ thứ của X-Ray còn lại ngoài state**: `destroy` không đổi đích segment của account (vẫn `CloudWatchLogs`), và log group `aws/spans`
    (cùng `/aws/application-signals/data` nếu có) do X-Ray tạo vẫn giữ span. Đưa đích về `XRay`, kiểm, rồi xoá hai log group:

    ```sh
    AWS_PROFILE=anhnv-stg aws xray update-trace-segment-destination --destination XRay --region ap-southeast-1
    AWS_PROFILE=anhnv-stg aws xray get-trace-segment-destination --region ap-southeast-1   # Destination: XRay
    for g in aws/spans /aws/application-signals/data; do
      AWS_PROFILE=anhnv-stg aws logs delete-log-group --log-group-name "$g" --region ap-southeast-1
    done
    ```

    - **Mong đợi:** `ResourceNotFoundException` của một group nghĩa là X-Ray chưa từng tạo nó.
11. **Dọn file local**: `rm -f terraform.tfstate* ../../backend-stg.hcl stg.auto.tfvars local_override.tf`, hoàn tác sửa của bước 5
    (`git checkout -- ../../modules/account-baseline ../../modules/registry ../../modules/observability`).

## `aws/backup`

Sau `aws/accounts/<env>` và trước `aws/baseline`. Chỉ khi không cần bản copy nữa: mục này xoá mọi bản copy, kể cả bản còn trong hạn lock.
Vault `svp-<env>` của account env phải gỡ trước (AWS Backup không xoá vault còn recovery point), và mục này phải xong trước phần 2 của
`aws/org` (account đóng thì management không assume role vào được).

- [ ] Mọi buổi đã gỡ, `sweep.sh <env>` sạch: vault `svp-<env>` không còn recovery point, không job nào chạy.
- [ ] Vault env, key và role của nó đã gỡ cùng baseline của `aws/accounts/<env>` (dòng 1 của [Thứ tự gỡ](#thứ-tự-gỡ)): không copy job nào
  còn tới đây.

1. **Sửa local, không commit**: ở `aws/backup/kms.tf`, `aws_kms_key.copy` đổi `prevent_destroy = true` thành `false`; ở
   `aws/modules/backup-vault/main.tf`, thêm `force_destroy = true` vào `aws_backup_vault.this`. `force_destroy` cho provider xoá mọi
   recovery point của vault trước khi xoá vault. Không apply root nào khác khi sửa này còn.
2. **Ghi `force_destroy` vào state, rồi gỡ:**

   ```sh
   aws/scripts/check-account.sh mgmt
   cd aws/backup
   ```

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
     TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
     TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform apply
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" \
     TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
     TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform destroy
   ```

   - **Mong đợi:** plan của `apply` là `0 to add, 2 to change, 0 to destroy`, chỉ `force_destroy` của hai
     `module.vaults.aws_backup_vault.this`; khác thì trả lời `no` và dán plan. `destroy` là `8 to destroy`, theo thứ tự phụ thuộc: bỏ hai
     lock (governance gỡ được bằng `OrganizationAccountAccessRole`) và hai vault access policy, xoá recovery point rồi hai vault, cuối
     cùng key vào `PendingDeletion` 30 ngày.
   - **Bẫy:** copy job đang chạy làm việc xoá vault lỗi: chờ nó xong rồi chạy lại `destroy`.
   - **Kiểm:** trong 30 ngày chờ xoá, `aws kms cancel-key-deletion` còn cứu được key; sau đó bản copy nào còn mã hoá bằng nó không đọc
     được nữa.
3. **Kiểm sạch** bằng profile chỉ đọc:

   ```sh
   AWS_PROFILE=anhnv-backup-ro aws backup list-backup-vaults --region ap-southeast-1 \
     --query "BackupVaultList[?starts_with(BackupVaultName, 'svp-')].BackupVaultName" --output text
   ```

   - **Mong đợi:** không in tên nào (vault mặc định của AWS không bắt đầu bằng `svp-`).
4. **Hoàn tác sửa local** (`git checkout -- kms.tf ../modules/backup-vault/main.tf`), `cd ../..`. Account `svp-backup`, Backup policy,
   cross-account backup, trusted access và policy type `BACKUP_POLICY` gỡ ở phần 2, 4, 5 của [`aws/org`](#awsorg).

Phí của backup dừng khi key ở `PendingDeletion` (không tính) và account `svp-backup` đóng.

## `aws/baseline`

Sau `aws/accounts/<env>`, `aws/backup`, và trước `aws/security` (rule nguồn của mọi account trỏ bus của root đó). Destroy gỡ S3 Block
Public Access cấp account, tắt EBS mã hoá mặc định, xoá recorder, delivery channel, rule, role ở mọi account và đưa hai CMK EBS vào
trạng thái chờ xoá 30 ngày. SCP `svp-protect-baseline` không chặn lệnh này: provider của account thành viên đi qua
`OrganizationAccountAccessRole`.

- [ ] Volume, snapshot còn mã hoá bằng CMK EBS (`alias/svp-ebs`) của stg, prd đã xoá: key xoá xong thì chúng không đọc được nữa.

```sh
aws/scripts/check-account.sh mgmt
cd aws/baseline
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
  TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform destroy
```

- **Mong đợi:** plan chỉ có `destroy`, đúng các tài nguyên trong state của root; `Destroy complete!`. Lệnh có thể sinh thư
  `svp-security-alert-rules` (`DeleteRule`, `RemoveTargets`) và `svp-security-detection` (`DeleteConfigurationRecorder`) trước khi rule
  của chính account bị xoá: đúng ý.
- **Kiểm:** trong 30 ngày chờ xoá, `aws kms cancel-key-deletion` (profile ghi của stg, prd) còn cứu được CMK EBS.

`cd ../..` khi xong.

## `aws/security`

Sau `aws/baseline` (rule nguồn trỏ bus của root này) và trước khi `aws/org` bỏ delegated admin.

```sh
aws/scripts/check-account.sh mgmt
cd aws/security
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" \
  TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" terraform destroy
```

- **Mong đợi:** `Destroy complete!`. Gỡ cấu hình tổ chức, publishing destination, member và detector của management, policy và aggregator
  Security Hub, Inspector theo thứ tự `depends_on` (tắt quét ở thành viên và đặt lại cấu hình tổ chức, gỡ liên kết thành viên, tắt
  `svp-security`), aggregator Config, analyzer, bus, rule, role `svp-security-guardduty-forwarder`, topic; KMS key của topic chờ xoá 7
  ngày.
- **Kiểm:** GuardDuty và Security Hub của chính `svp-security` còn bật: chúng tắt khi `aws/org` bỏ delegated admin (phần 1 dưới).

`cd ../..` khi xong.

## `aws/org`

Root này không bao giờ `terraform destroy` cả khối; các phần theo thứ tự, lệnh `terraform` chạy trong `infra/aws/org` với
`TF_VAR_account_id` của management. `aws/log-archive` còn nguyên ở phần 1 (phần đó đọc alias `alias/svp-log-archive` qua provider
`aws.log_archive`).

```sh
aws/scripts/check-account.sh mgmt
cd aws/org
```

### Phần 1: trail, delegated admin, quyền SSO

Tắt trail, bỏ delegated admin, role Access Analyzer, root tập trung, liên hệ, quyền SSO, nhóm nền tảng. Không tài nguyên nào trong số này có
`prevent_destroy`; log đã ghi vẫn còn.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_cloudtrail.audit \
  -target=aws_guardduty_organization_admin_account.security -target=aws_securityhub_organization_admin_account.security \
  -target=aws_inspector2_delegated_admin_account.security \
  -target=aws_organizations_delegated_administrator.security -target=aws_iam_service_linked_role.access_analyzer \
  -target=aws_iam_organizations_features.root_access \
  -target=aws_account_alternate_contact.security \
  -target=aws_ssoadmin_account_assignment.learner -target=aws_ssoadmin_managed_policy_attachment.admin -target=aws_ssoadmin_permission_set.admin \
  -target=aws_ssoadmin_account_assignment.read_only -target=aws_ssoadmin_managed_policy_attachment.read_only \
  -target=aws_ssoadmin_permission_set_inline_policy.read_only -target=aws_ssoadmin_permission_set.read_only \
  -target=aws_ssoadmin_account_assignment.log_reader -target=aws_ssoadmin_managed_policy_attachment.log_reader \
  -target=aws_ssoadmin_permission_set_inline_policy.log_reader -target=aws_ssoadmin_permission_set.log_reader \
  -target=aws_identitystore_group.platform
```

- **Mong đợi:** plan chỉ có `destroy` của các tài nguyên trên; trả lời `yes` sau khi đọc. Muốn xoá log trước khi đóng account: làm mục
  [`aws/log-archive`](#awslog-archive) ngay sau phần này, rồi quay lại phần 2.

### Phần 2: đóng năm account thành viên

Sau phần 1, và sau mục [`aws/log-archive`](#awslog-archive) nếu đã chọn xoá log.

Đóng theo quy trình của AWS, không bằng destroy (`close_on_deletion = false`, `prevent_destroy`): destroy chỉ gỡ account khỏi tổ chức.
Account đã đóng ở trạng thái đóng 90 ngày, vẫn thuộc tổ chức và OU, vẫn tính vào hạn mức số account; email của nó không dùng lại được;
mỗi 30 ngày chỉ đóng được một phần số account thành viên, nên có thể phải chia nhiều đợt
([Organizations: close account](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_close.html)). Đóng
`svp-log-archive` là bỏ log của tổ chức.

```sh
for id in "$SVP_AWS_STG_ACCOUNT_ID" "$SVP_AWS_PRD_ACCOUNT_ID" "$SVP_AWS_SECURITY_ACCOUNT_ID" "$SVP_AWS_LOG_ACCOUNT_ID" \
  "$SVP_AWS_BACKUP_ACCOUNT_ID"; do
  AWS_PROFILE=anhnv-sso aws organizations close-account --account-id "$id" --region us-east-1
done
AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_account.member aws_organizations_account.log_archive \
  aws_organizations_account.security aws_organizations_account.backup
```

- **Bẫy:** `close-account` báo vượt hạn mức đóng trong 30 ngày: các account trước đã đóng; chạy lại cho account còn lại ở đợt sau.

### Phần 3: bucket trail cũ

Nếu còn: như [Gỡ bucket trail cũ](#gỡ-bucket-trail-cũ). Object Lock chưa hết hạn thì thêm `--bypass-governance-retention` vào
`delete-objects` (cần `s3:BypassGovernanceRetention`, có ở `AdministratorAccess`) và thay PR bằng bản sửa local không commit: đổi
`prevent_destroy = true` thành `false` ở `aws_s3_bucket.trail`, `aws_s3_bucket.access_logs`, `aws_kms_key.cloudtrail`, rồi:

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=aws_s3_bucket.trail \
  -target=aws_s3_bucket.access_logs -target=aws_kms_alias.cloudtrail -target=aws_kms_key.cloudtrail
```

### Phần 4: policy và OU, sau 90 ngày

Sau khi AWS gỡ hẳn năm account đã đóng khỏi tổ chức (OU còn account thì không xoá được). Kiểm: lệnh
`AWS_PROFILE=anhnv-sso aws organizations list-accounts --region us-east-1 --query 'Accounts[].[Id,Name,Status]' --output text` không còn
account `svp-*`.

```sh
AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply -destroy -target=module.org_policies \
  -target=aws_organizations_organizational_unit.prod -target=aws_organizations_organizational_unit.nonprod \
  -target=aws_organizations_organizational_unit.workloads -target=aws_organizations_organizational_unit.security
```

### Phần 5: trả tổ chức về như trước

Tổ chức có trước root này, không xoá: bỏ khỏi state, tắt cross-account backup, trusted access và loại policy mà root này bật, xoá state của
root. Opt-in của management giữ nguyên: mọi loại `true` là giá trị AWS đặt cho account dùng AWS Backup.

```sh
R="$(AWS_PROFILE=anhnv-sso terraform output -raw root_id)"
AWS_PROFILE=anhnv-sso terraform state rm aws_organizations_organization.this aws_backup_global_settings.this aws_backup_region_settings.this
AWS_PROFILE=anhnv-sso aws backup update-global-settings --global-settings isCrossAccountBackupEnabled=false --region ap-southeast-1
for p in access-analyzer account backup cloudtrail config-multiaccountsetup config ec2 guardduty iam inspector2 malware-protection.guardduty \
  securityhub; do
  AWS_PROFILE=anhnv-sso aws organizations disable-aws-service-access --service-principal "$p.amazonaws.com" --region us-east-1
done
for t in BACKUP_POLICY DECLARATIVE_POLICY_EC2 TAG_POLICY; do
  AWS_PROFILE=anhnv-sso aws organizations disable-policy-type --root-id "$R" --policy-type "$t" --region us-east-1
done
AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-tfstate-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1/aws/org/terraform.tfstate" --region ap-southeast-1
rm -f org.auto.tfvars
```

- **Việc tay:** hoàn tác sửa local của phần 3 (`git checkout -- audit-trail.tf`); xoá thư mục root bằng PR nếu không dùng nữa.

`cd ../..` khi xong.

## `aws/log-archive`

Tuỳ chọn, giữa phần 1 và phần 2 của `aws/org`: xoá mọi log của tổ chức, kể cả version còn trong hạn Object Lock. Chỉ làm khi không cần
lịch sử audit nữa; bỏ qua thì log còn tới khi account `svp-log-archive` đóng hẳn (90 ngày sau phần 2). Phải sau phần 1 (trail đã tắt,
phần 1 còn đọc alias `alias/svp-log-archive`) và trước phần 2 (account đã đóng thì management không assume role vào được). Cần năm biến
`SVP_AWS_MGMT_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID`;
đối chiếu account bằng lệnh của [Mở terminal](#mở-terminal) trước lệnh ghi đầu tiên.

1. **Sửa local, không commit**: ở `aws/log-archive/buckets.tf`, `aws_s3_bucket.log` đổi `prevent_destroy = true` thành `false` và thêm
   `force_destroy = true`; ở `kms.tf`, `aws_kms_key.log` đổi `prevent_destroy = true` thành `false`. `force_destroy` cho provider xoá
   mọi version và delete marker, kể cả version còn khoá governance (cần `s3:BypassGovernanceRetention`, `OrganizationAccountAccessRole`
   có).
2. **Ghi `force_destroy` vào state, rồi gỡ:**

   ```sh
   aws/scripts/check-account.sh mgmt
   cd aws/log-archive
   ```

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
     TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
     TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform apply
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
     TF_VAR_security_account_id="$SVP_AWS_SECURITY_ACCOUNT_ID" TF_VAR_stg_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
     TF_VAR_prd_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
     terraform destroy
   ```

   - **Mong đợi:** plan của `apply` là `0 to add, 7 to change, 0 to destroy`, chỉ `force_destroy` của bảy `aws_s3_bucket.log`; khác thì
     trả lời `no` và dán plan. `destroy` là `59 to destroy`; bucket nhiều object xoá lâu.
   - **Kiểm:** hai key vào `PendingDeletion` 30 ngày: huỷ được trong thời gian đó, sau đó log nào còn mã hoá bằng chúng không đọc được.
3. **Hoàn tác sửa local** (`git checkout -- buckets.tf kms.tf`), `cd ../..`, rồi phần 2 của `aws/org`.

## Gỡ bucket trail cũ

Bucket `svp-cloudtrail-<mgmt>-ap-southeast-1`, bucket access log của nó và key `alias/svp-cloudtrail` giữ log trước khi trail đổi đích
sang Log Archive. Gỡ khi Object Lock của version cuối hết hạn (365 ngày sau lần ghi cuối, tức sau bước (4) của
[`org-security-setup.md`](org-security-setup.md#bước-4-awsorg-đủ)), không cần bỏ qua retention. Kiểm hạn:

```sh
B="svp-cloudtrail-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1"
AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$B" --region ap-southeast-1 \
  --query 'max_by(Versions, &LastModified).[Key,VersionId]' --output text
AWS_PROFILE=anhnv-sso aws s3api get-object-retention --bucket "$B" --key <Key> --version-id <VersionId> --region ap-southeast-1
```

- **Kiểm:** `RetainUntilDate` ở quá khứ; chưa tới thì chờ.

Xoá mọi version và delete marker (lặp tới khi `versions.json` rỗng), rồi rỗng bucket access log:

```sh
AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$B" --region ap-southeast-1 --output json \
  --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' > versions.json
jq -c '.Objects | _nwise(1000) | {Objects: ., Quiet: true}' versions.json | while read -r batch; do
  AWS_PROFILE=anhnv-sso aws s3api delete-objects --bucket "$B" --region ap-southeast-1 --delete "$batch"
done
rm versions.json
AWS_PROFILE=anhnv-sso aws s3 rm "s3://svp-cloudtrail-access-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1" --recursive --region ap-southeast-1
```

- **Việc tay:** một PR bỏ khỏi `audit-trail.tf` key `aws_kms_key.cloudtrail`, alias, hai bucket cùng mọi tài nguyên và policy document của
  chúng, cùng `local.trail_arn`, `log_retention_days`, `log_cold_after_days` khi không còn ai dùng.
- **Mong đợi:** plan sau PR chỉ có `destroy` của các tài nguyên đó; apply đưa key vào trạng thái chờ xoá 30 ngày (huỷ được trong thời gian
  đó).

## Xoá OU cũ

OU `Production`, `Development` dưới root chứa hai account demo đã đóng (`SUSPENDED`); `aws/org` không quản chúng. Khi AWS gỡ hẳn hai
account khỏi tổ chức (90 ngày sau khi đóng), xoá hai OU rỗng. Chạy từ `infra/aws/org` (lệnh đầu đọc output của root):

```sh
AWS_PROFILE=anhnv-sso aws organizations list-organizational-units-for-parent --parent-id "$(AWS_PROFILE=anhnv-sso terraform output -raw root_id)" \
  --region us-east-1 --query 'OrganizationalUnits[].[Id,Name]' --output text
AWS_PROFILE=anhnv-sso aws organizations list-accounts-for-parent --parent-id <ou-… của Production> --region us-east-1 --query 'Accounts[].Id' --output text
AWS_PROFILE=anhnv-sso aws organizations delete-organizational-unit --organizational-unit-id <ou-… của Production> --region us-east-1
```

- **Kiểm:** lệnh thứ hai không in id nào thì mới chạy lệnh xoá; lặp lại với `Development`.

## Xoá SCP tạo tay

SCP tạo tay từ trước khi có code không nằm trong state của `aws/org`. Liệt kê policy không do AWS quản, so với `local.policies` của
[`org-policies`](../../aws/modules/org-policies/README.md): cái nào không có trong code là của ngoài Terraform. Lệnh thứ hai cho biết nó
còn gắn ở đâu.

```sh
AWS_PROFILE=anhnv-sso aws organizations list-policies --filter SERVICE_CONTROL_POLICY --region us-east-1 \
  --query 'Policies[?AwsManaged==`false`].[Id,Name]' --output text
AWS_PROFILE=anhnv-sso aws organizations list-targets-for-policy --policy-id <p-… của policy tạo tay> --region us-east-1 \
  --query 'Targets[].[TargetId,Name]' --output text
```

- **Kiểm:** lệnh thứ hai không in dòng nào thì policy không gắn ở đâu: xoá bằng
  `AWS_PROFILE=anhnv-sso aws organizations delete-policy --policy-id <p-…> --region us-east-1`.
- **Bẫy:** còn gắn thì đọc xem nó đang chặn gì, gỡ khỏi từng đích bằng `detach-policy` trước; không xoá policy đang gắn.

## Xoá bootstrap

Chỉ khi không còn root nào dùng bucket: mọi mục trên xong, script quét sót sạch. Lệnh chạy trong `infra/aws/bootstrap`.

1. **Chuyển state của `github/`.** Root `aws/org` đã gỡ ở trên. Root `github/` (cài đặt GitHub) giữ state ở bucket này và không bao giờ
   `destroy`: chuyển state của nó sang backend khác bằng `terraform init -migrate-state` với backend mới, như
   [1d của `org-security-setup.md`](org-security-setup.md#1d-chuyển-state-vào-bucket). Bỏ qua bước này thì state mới rỗng: `plan` đòi tạo
   mọi tài nguyên đã có trên GitHub, phải nhận quản lại theo mục "Nhận quản repo đã có" của `github/README.md`.
2. **Đưa state của root này về local** (bucket sắp bị xoá): tạo lại `local_override.tf` như 1c, rồi `init -migrate-state` (trả lời
   `yes`).

   ```sh
   aws/scripts/check-account.sh mgmt
   cd aws/bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform init -migrate-state
   ```

3. **Gỡ bảo vệ có chủ đích**, chỉ trong bản sửa local này (không commit): trong `state.tf` đổi cả hai `prevent_destroy = true` (bucket và
   `aws_kms_key.state`) thành `false`, thêm `force_destroy = true` vào `aws_s3_bucket.state` (xoá được bucket còn version cũ). Rồi apply
   (chỉ đổi `force_destroy`) và destroy:

   ```sh
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform apply
   AWS_PROFILE=anhnv-sso TF_VAR_account_id="$SVP_AWS_MGMT_ACCOUNT_ID" terraform destroy
   ```

   - **Mong đợi:** key vào trạng thái chờ xoá 30 ngày; trong thời gian đó `aws kms cancel-key-deletion` còn cứu được nó.
4. **Dọn file local:** `rm -f terraform.tfstate* ../backend.hcl bootstrap.auto.tfvars local_override.tf`, hoàn tác sửa của bước 3
   (`git checkout -- state.tf`), xoá thư mục root bằng PR nếu không dùng nữa.

## Khi một bước đỏ

- Lỗi ở `plan` của `destroy`: không có gì đổi trên account; đọc lỗi, sửa nguyên nhân (biến terminal, phiên SSO), chạy lại đúng mục.
- `destroy` lỗi giữa chừng: phần đã gỡ ra khỏi state; chạy lại cùng lệnh, plan chỉ còn phần chưa gỡ. Dán lỗi trước khi chạy lại.
- Plan đòi gỡ thứ không có trong mục (tổ chức, account, bucket state khi chưa tới mục đó): dừng, không trả lời `yes`, dán plan.
- Mất đường vào (Identity Center hỏng sau phần 1): [`break-glass.md`](break-glass.md).
