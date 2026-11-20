# Runbook: dựng baseline của account stg, prd

← [backup-setup](backup-setup.md) · [Mục lục](README.md) · [edge-setup](edge-setup.md) →

> **Tóm tắt**
>
> - **Làm gì:** áp root `aws/accounts/<env>` lần đầu ở mỗi account env: bucket state và key, zone của env (prd: DNSSEC, query log, alarm),
>   registry ECR, role CI, observability, phần backup, role Spot của stg; chuyển state vào bucket; uỷ quyền zone ở DNS cha và ở zone prd.
>   Với account đã có baseline từ bản trước của root, thêm phần còn thiếu.
> - **Khi nào và bao lâu:** một lần mỗi account, ngoài buổi, prd trước stg; sau [`backup-setup.md`](backup-setup.md) bước (5), trước
>   buổi đầu của env. Khoảng một giờ cho hai account; uỷ quyền DNS lan truyền thường vài phút, có thể tới 48 giờ.
> - **Phí trong lúc chạy:** phí giữ bắt đầu từ apply đầu và tính cả khi không buổi (key, zone, lưu trữ ECR; prd thêm DNSSEC); số tiền ở
>   [08. Account env, Chi phí](../handbook/08-accounts.md#chi-phí).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output dán lại. Mọi lệnh chạy từ gốc
repo này (`infra/`) trừ chỗ ghi `cd`. Bước nào đỏ thì dừng ở đó, dán output, không đi tiếp. Ví dụ dưới là stg; với prd thay `stg` bằng
`prd`, `anhnv-stg` bằng `anhnv-prd`, `SVP_AWS_STG_ACCOUNT_ID` bằng `SVP_AWS_PRD_ACCOUNT_ID`. Vì sao từng phần:
[08. Account env](../handbook/08-accounts.md).

Runbook này là bước (6) của `backup-setup.md` với tổ chức dựng mới: phần backup (`backup.tf`) đi cùng apply đầu ở bước (3). Kiểm phần
backup sau khi cả hai account xong: [`backup-setup.md`, bước (7)](backup-setup.md#bước-7-kiểm-sau-áp).

## Điều kiện trước

- [ ] **Tổ chức đã áp** theo [`org-security-setup.md`](org-security-setup.md): `aws/org` đã tạo account và gán permission set
  `SvpAdmin`, `aws/security` đã áp.
- [ ] **Backup** theo [`backup-setup.md`](backup-setup.md) tới hết bước (5): account `svp-backup` có, vault copy có.
- [ ] **Profile** `anhnv-stg`, `anhnv-prd` đã ghi bằng `aws/scripts/sso-profiles.sh write`
  ([`org-security-setup.md`, 4c](org-security-setup.md#4c-profile-của-account-thành-viên)).
- [ ] **Nhóm nền tảng** có id: `aws/org` đã áp và `init` (output `platform_admin_group_id`, `platform_viewer_group_id`).
- [ ] **Trên máy:** Terraform 1.15, AWS CLI v2, `jq`, `dig`.
- [ ] **Dựng mới cả hai env:** prd trước; zone stg được uỷ quyền từ zone prd (bước (5)).

## Mở terminal

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1      # one login for every profile of the same sso_session
printf 'mgmt …%s\n' "${SVP_AWS_MGMT_ACCOUNT_ID: -4}"   # from .envrc (direnv), 4 last digits only
eval "$(aws/scripts/accounts.sh)"                           # sets the other five SVP_AWS_*_ACCOUNT_ID, no file
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"   # check-account.sh marks its timeline here
aws/scripts/check-account.sh mgmt
```

- **Mong đợi:** năm dòng `ok    SVP_AWS_<…>_ACCOUNT_ID: account svp-<tên>, ACTIVE` trên stderr (không in id) rồi `ok    account <12 số>
  of mgmt, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_…`.
- **Bẫy:** `accounts.sh` lỗi (`FAIL  no account svp-backup in the organization`, account không `ACTIVE`, mgmt sai) thì stdout rỗng nên
  `eval` không đặt gì. Biến account nạp qua direnv: [`operations.md`](../reference/operations.md#biến-account-và-direnv).

## Bước (1): kiểm account và role

```sh
cd aws/accounts/stg
../../scripts/check-account.sh stg
```

- **Mong đợi:** `ok    account <12 số> of stg, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_SvpAdmin_…`: account bằng
  `SVP_AWS_STG_ACCOUNT_ID`, `Arn` chứa `AWSReservedSSO_SvpAdmin_`.
- **Bẫy:** `FAIL  profile anhnv-stg is account …`: dừng, dán dòng đó. Key policy chỉ cho role SSO của `SvpAdmin` mã hoá, giải mã, nên apply
  bằng role khác (`OrganizationAccountAccessRole`) tạo được key nhưng không ghi được state vào bucket ở bước (4).

## Bước (2): giá trị cá nhân

```sh
../../scripts/tfvars.sh example aws/accounts/stg
../../scripts/tfvars.sh groups stg
```

- **Mong đợi:** lệnh đầu chép `stg.auto.tfvars.example` thành `stg.auto.tfvars` (mode 600) khi file chưa có và in mỗi giá trị còn `<…>` một
  dòng `note  … still holds a placeholder <...>`. Lệnh sau ghi hai id nhóm từ output của `aws/org`, chỉ hai dòng đó đổi: `ok
  aws/accounts/stg/stg.auto.tfvars: platform_admin_group_id, platform_viewer_group_id from aws/org written (N lines, mode 600)`.
- **Việc tay:** sửa trong editor (git bỏ qua) `budget_emails`, `zone_name` (không dấu chấm cuối: `stg.aws.<domain>` ở stg, `aws.<domain>`
  ở prd), `budget_limit_usd` nếu muốn khác 20; ở prd thêm `alarm_email` (hộp thư của topic `svp-prd-dns-alarms`).
- **Bẫy:** ở prd bỏ khối `delegated_subdomains` của file ví dụ cho tới bước (5): zone stg chưa có.

## Bước (3): apply lần đầu, state local

Bucket state chưa có, nên lần đầu chạy trên state local: file override (git bỏ qua) thay khối `backend "s3"` của `versions.tf`.

```sh
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform plan -out=stg.tfplan
```

- **Mong đợi** (số ứng với `aws/paid-features.json` của repo: `managed_grafana` của stg và prd là `off`): ở stg `Plan: 68 to add, 0 to
  change, 0 to destroy`: 11 của `module.baseline` (key và alias, bucket cùng 5 cấu hình, zone, bản ghi `caa`, budget; không bản ghi
  `delegation`), 43 của `module.registry`, `module.observability` (danh sách ở [N1](#n1-phần-của-root-và-số-tài-nguyên); không phần AMG),
  9 của `backup.tf`, 4 của `module.ci_plan_role` và 1 `aws_iam_service_linked_role.spot`. Ở prd `Plan: 79 to add, 0 to change, 0 to
  destroy`: 41 của hai module đó, 11 của `module.baseline`, 9 của `backup.tf`, 4 của `module.ci_plan_role`, thêm 6 của DNSSEC
  (`aws_kms_key.dnssec` và alias ở `us-east-1`, `aws_route53_key_signing_key.this`, `aws_route53_hosted_zone_dnssec.this`, hai
  `aws_cloudwatch_metric_alarm.dnssec`), 3 của query log (log group, resource policy, `aws_route53_query_log.this`) và 5 của `module.alarms`
  (key, alias, topic, topic policy, subscription email).

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform apply stg.tfplan
../../scripts/tfvars.sh backend stg
```

- **Mong đợi:** `Apply complete!`; `ok    aws/backend-stg.hcl: output backend_hcl of aws/accounts/stg written (N lines, mode 600)`. File
  (git bỏ qua, ghi qua file tạm rồi `mv`) là cấu hình backend mà mọi root của account stg đọc bằng `-backend-config`.
- **Bẫy:** apply báo `InvalidInput: Service role name AWSServiceRoleForEC2Spot has been taken in this account` (account từng tạo Spot từ
  console): nhập role vào state rồi `plan` lại:

  ```sh
  AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
    terraform import aws_iam_service_linked_role.spot \
    "arn:aws:iam::$SVP_AWS_STG_ACCOUNT_ID:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
  ```

  Mong `Plan: 0 to add, 1 to change, 0 to destroy`: `aws_iam_service_linked_role.spot` sửa tại chỗ (`~`), `tags_all` thêm bốn tag của
  `default_tags` (`Project`, `Env`, `ManagedBy`, `Stack`); role có mô tả thì thêm dòng `description` về `null` (code không đặt mô tả). Có
  thay đổi khác thì dừng, dán plan; không thì apply plan đó, và plan lần hai phải là `No changes.`.
- **Bẫy:** apply đỏ ở `aws_ecr_pull_through_cache_rule` của `ghcr` hay `docker-hub` với `SecretNotFoundException` hay
  `UnableToAccessSecretException`: hai secret `ecr-pullthroughcache/*` đã tạo nhưng chưa có giá trị. Ghi credential theo
  [`platform-setup.md`, bước (6)](platform-setup.md#bước-6-credential-của-pull-through-cache) rồi `plan`, `apply` lại; lệnh `-target`
  tạo secret trước là [5a của trang đó](platform-setup.md#5a-vỏ-secret-cache-trước).

Retention của log group `aws/spans` (X-Ray tạo, Terraform không quản) đặt một lần mỗi account bằng lệnh mà output in ra:

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw spans_retention_command; echo
```

- **Mong đợi:** chạy đúng lệnh đã in; nó không in gì là thành công.
- **Bẫy:** `ResourceNotFoundException` là group chưa có (X-Ray chưa nhận span nào): làm sau buổi đầu của env, theo
  [`platform-setup.md`, bước (10)](platform-setup.md#bước-10-retention-của-awsspans).

## Bước (4): chuyển state vào bucket

```sh
rm local_override.tf stg.tfplan
# init hỏi có chép state lên bucket không: trả lời yes
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state -backend-config=../../backend-stg.hcl
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan    # mong đợi: No changes.
AWS_PROFILE=anhnv-stg aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/accounts/stg/terraform.tfstate --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId}'
```

- **Mong đợi:** `init` chép state lên bucket; `plan` là `No changes.`; `head-object` in `SSE` `aws:kms` và `Key` là ARN của key state.
- **Việc tay:** cả ba đúng thì xoá state local còn lại: `rm -f terraform.tfstate terraform.tfstate.backup`, rồi `cd ../../..` về `infra/`.

## Bước (5): uỷ quyền zone của env

Zone của env chỉ trả lời được khi zone ở trên có bốn bản ghi `NS` trỏ về bốn name server của nó, theo
[Route 53: subdomain không chuyển domain cha](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingNewSubdomain.html).
Mỗi buổi bắt đầu bằng `aws/scripts/check-dns.sh <env>`; sai thì không `apply`. Output `zone_id` là `hosted_zone_id` của root
`aws/envs/<env>`.

### 5a. prd: DNS cha uỷ quyền `aws.<domain>`

Lấy bốn name server (từ `infra/`):

```sh
cd aws/accounts/prd
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]'
```

- **Việc tay:** giữ tay vì Cloudflare chỉ nhận thay đổi DNS qua API token mà lab không giữ (token ghi DNS của zone cha là quyền lớn hơn
  việc bốn bản ghi một lần). Cloudflare → **DNS** → **Records** của `<domain>`: bốn bản ghi **Type** `NS`, **Name** `aws`, mỗi bản ghi
  **Nameserver** một trong bốn tên vừa in (không dấu chấm cuối), **TTL** Auto. Đã có bốn bản ghi `NS` `aws` thì sửa **Nameserver** của
  chúng, không thêm bản ghi thứ năm. Không đổi gì khác của domain. Có sẵn token **DNS Edit** thì dùng được API
  ([Create DNS record](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)); không tạo token chỉ
  cho việc này.
- **Bẫy:** **Proxied** không áp dụng cho `NS`; gõ nhầm một tên thì chỉ một phần lượt tra cứu qua, nên kiểm bằng cả hai resolver dưới.

Kiểm lan truyền (lặp lại tới khi qua; thường vài phút, có thể tới 48 giờ do cache):

```sh
ns=$(AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]' | sort)
for r in 1.1.1.1 8.8.8.8; do
  diff <(dig NS aws.<domain> +short @"$r" | sed 's/\.$//' | sort) <(echo "$ns") && echo "$r: delegation OK"
done
dig NS aws.<domain> +short          # resolver của máy: cũng đúng bốn name server đó
```

- **Mong đợi:** hai dòng `delegation OK`; lệnh cuối in đúng bốn name server đó. `cd ../../..` về `infra/` khi xong.

### 5b. stg: zone prd uỷ quyền `stg.aws.<domain>`

Sau khi baseline của stg và của prd đã apply. Lấy bốn name server của zone stg (từ `infra/`):

```sh
cd aws/accounts/stg
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]'
```

Ghi `delegated_subdomains` của `aws/accounts/prd/prd.auto.tfvars` bằng script, rồi plan với profile prd:

```sh
cd ../../..
aws/scripts/tfvars.sh delegation
cd aws/accounts/prd
../../scripts/check-account.sh prd
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform plan -out=prd.tfplan
```

- **Mong đợi:** `tfvars.sh delegation` đọc zone stg từ `zone_name` của `stg.auto.tfvars`, bốn name server từ output `name_servers` của
  `aws/accounts/stg`, đặt lại cả biến `delegated_subdomains` của file prd thành đúng mục đó, không đổi dòng khác (`ok    …
  delegated_subdomains: zone of stg, 4 name servers written`). Plan: `Plan: 1 to add, 0 to change, 0 to destroy`, đúng
  `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`.
- **Bẫy:** output không đúng bốn tên DNS thì `FAIL  output name_servers of aws/accounts/stg has N names, not 4` và không ghi gì.
  Validation của biến chỉ chạy lúc `plan`: tên không phải con của zone prd hay số name server khác bốn thì dừng ở đó.

```sh
AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan
ns=$(cd ../stg && AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json name_servers | jq -r '.[]' | sort)
for r in 1.1.1.1 8.8.8.8; do
  diff <(dig NS stg.aws.<domain> +short @"$r" | sed 's/\.$//' | sort) <(echo "$ns") && echo "$r: delegation OK"
done
```

- **Mong đợi:** `Apply complete!`, hai dòng `delegation OK`.

### 5c. Zone stg dựng lại

Gỡ rồi dựng lại baseline stg cho zone stg bốn name server mới. Bản ghi `NS` ở zone prd không bao giờ được trỏ tới zone stg đã xoá, nên:

1. Bỏ mục `stg.aws.<domain>` khỏi `delegated_subdomains` trong `prd.auto.tfvars` (sửa trong editor: `tfvars.sh delegation` đặt lại cả
   biến, không bỏ được mục), plan và apply prd như bước 1 của
   [`lab-teardown.md`, `aws/accounts/<env>`](lab-teardown.md#awsaccountsenv) (mong `0 to add, 0 to change, 1 to destroy`, đúng bản ghi
   `delegation` đó).
2. Gỡ baseline stg theo các bước còn lại của mục đó, rồi dựng lại từ bước (1) của runbook này.
3. Thêm lại mục bằng `aws/scripts/tfvars.sh delegation` và làm lại 5b (plan mong `1 to add, 0 to change, 0 to destroy`).

Từ bước 1 tới khi apply ở bước 3 xong, `stg.aws.<domain>` không phân giải.

## Bước (6): alarm và DNSSEC của prd

Apply của prd tạo subscription email của topic `svp-prd-dns-alarms` ở trạng thái chờ. Lệnh chạy trong `aws/accounts/prd`.

```sh
../../scripts/verify.sh subscriptions prd
```

- **Việc tay:** mở link **Confirm subscription** của thư "AWS Notification - Subscription Confirmation" gửi tới `alarm_email` (xem cả thư
  rác), rồi chạy lệnh trên. Giữ tay vì token nằm trong thư. Link chỉ dùng được trong hai ngày và SNS xoá subscription chưa xác nhận sau
  48 giờ: quá hạn thì apply lại để AWS gửi thư mới.
- **Mong đợi:** `ok    topic svp-prd-dns-alarms: every subscription is confirmed`.
- **Bẫy:** `FAIL  topic svp-prd-dns-alarms: a subscription is still PendingConfirmation` là chưa bấm link; dán dòng đó nếu đã bấm mà vẫn
  thế.

Zone prd ký ngay sau apply, nhưng chuỗi tin cậy chỉ nối khi DNS cha của `<domain>` có bản ghi `DS` tên `aws`:

```sh
../../scripts/verify.sh dnssec
```

- **Mong đợi:** `ok    zone <zone> is SIGNING and its KSK svp_prd_ksk is ACTIVE`; dòng `note  registrar: DS of <domain> is key tag …,
  algorithm …, digest type …, digest …` là bốn giá trị của domain cha. Các dòng về `DS` của `aws` đỏ tới khi làm xong
  [`edge-setup.md`](edge-setup.md) bước (3): runbook đó giữ thứ tự đặt `DS`, cách kiểm và đường lui.

## Gỡ

Mọi thứ của runbook này sống suốt lab. Gỡ hẳn một env (bucket, key state, zone, registry, telemetry): [`lab-teardown.md`,
`aws/accounts/<env>`](lab-teardown.md#awsaccountsenv). Tắt ký DNSSEC mà không gỡ env: [`edge-setup.md`, Đường lui](edge-setup.md#đường-lui).

## Khi một bước đỏ

- Lỗi ở `plan`: không gì đổi trên account; sửa nguyên nhân (biến terminal, `.auto.tfvars`, phiên SSO), chạy lại đúng bước.
- Lỗi giữa `apply`: phần đã tạo nằm trong state; `plan` lại chỉ còn phần chưa tạo. Dán lỗi và plan mới trước khi apply lại;
  `-target`: [`operations.md`, Khi apply lỗi giữa chừng](../reference/operations.md#khi-apply-lỗi-giữa-chừng).
- Plan có `destroy` hay `-/+` ở zone, bucket, key có sẵn: dừng, không apply, dán plan.
- `AccessDenied` khi ghi state ở bước (4): profile không phải `SvpAdmin` (bước (1)).

## Nâng cấp tổ chức dựng trước

### Thêm vào account đã có baseline

Khi account đã apply một bản trước của root này, và root nay có phần mà account chưa có. `plan` luôn tính cả root: một lượt `plan`,
`apply` tạo mọi phần còn thiếu cùng lúc.

#### N1. Phần của root và số tài nguyên

| Phần | Tài nguyên | stg | prd |
| --- | --- | --- | --- |
| `CAA` | `module.baseline.aws_route53_record.caa` | 1 | 1 |
| DNSSEC, query log của zone prd | 6 của DNSSEC, 3 của query log, 5 của `module.alarms` ([bước (3)](#bước-3-apply-lần-đầu-state-local)) | — | 14 |
| Registry, observability | `module.registry`, `module.observability` (danh sách dưới bảng) | 43 | 41 |
| Backup | 9 của `backup.tf` ([`backup-setup.md`, bước (6)](backup-setup.md#bước-6-awsaccountsstg-awsaccountsprd)) | 9 | 9 |
| Role plan của CI | `module.ci_plan_role`: `aws_iam_role.this`, `aws_iam_role_policy_attachment.read_only`, `aws_iam_role_policy.read`, `aws_iam_role_policy.deny` | 4 | 4 |
| Role Spot | `aws_iam_service_linked_role.spot` | 1 | — |

- `module.registry` (stg 34, prd 32): key KMS và alias, 8 `aws_ecr_repository.release` (`local.release_repositories`),
  `aws_ecr_registry_scanning_configuration.this`, 5 `aws_ecr_pull_through_cache_rule.this`, 2 `aws_secretsmanager_secret.cache`, 5
  `aws_ecr_repository_creation_template.cache`, role `svp-<env>-ecr-template` và policy của nó, `aws_iam_openid_connect_provider.github`,
  mỗi role của `ci_roles` một `aws_iam_role.ci` và một `aws_iam_role_policy.ci` (stg 4, prd 3).
- `module.observability` (stg 9, prd 9 với file của repo): key KMS và alias, workspace AMP và `aws_prometheus_workspace_configuration`, log
  group `/svp/<env>/otel` và stream `otel-collector`, `aws_cloudwatch_log_resource_policy.xray_spans`,
  `aws_xray_trace_segment_destination.this`, `aws_xray_indexing_rule.default`; khi cờ `managed_grafana` của env là `always` (env vắng khỏi
  file), hay `session` và buổi đang mở, thêm 7 của AMG: role `svp-<env>-grafana` và policy, workspace, hai `aws_grafana_role_association`,
  service account `svp-grafana-operator`, tham số SSM `/svp/<env>/grafana-workspace-id`.

#### N2. Điều kiện

Mọi biến của root không có `default` đều bắt buộc, kể cả biến của phần account đã có:

- [ ] `aws/org`, `aws/security` đã áp bản có Inspector và nhóm nền tảng ([`platform-setup.md`, Nâng cấp tổ chức dựng
  trước](platform-setup.md#nâng-cấp-tổ-chức-dựng-trước)); `aws/org` đã tạo `svp-backup` ([`backup-setup.md`, Nâng cấp tổ chức dựng
  trước](backup-setup.md#nâng-cấp-tổ-chức-dựng-trước)).
- [ ] `stg.auto.tfvars` có `platform_admin_group_id`, `platform_viewer_group_id` (`aws/scripts/tfvars.sh groups stg`); `prd.auto.tfvars`
  có thêm `alarm_email`.
- [ ] Terminal có `SVP_AWS_STG_ACCOUNT_ID` và `SVP_AWS_BACKUP_ACCOUNT_ID` ([Mở terminal](#mở-terminal)).

#### N3. Plan và apply

Từ `infra/`:

```sh
cd aws/accounts/stg
../../scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -backend-config=../../backend-stg.hcl
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform plan -out=stg.tfplan
```

- **Mong đợi:** `check-account.sh` in `ok    account … of stg, …AWSReservedSSO_SvpAdmin_…`. Plan chỉ thêm (`0 to destroy`); mọi tài nguyên
  thuộc một phần của bảng N1; phần nào có trong plan thì đủ số ở cột của env; số `to add` bằng tổng các phần đó. Thay đổi duy nhất được
  phép là `1 to change` khi phần role plan có trong plan: `module.baseline.aws_kms_key.state` sửa tại chỗ, chỉ `policy` thêm statement
  `CiPlanReadsState`.
- **Kiểm:** account chỉ có baseline (cùng `CAA` và, ở prd, DNSSEC, query log): stg `Plan: 57 to add, 1 to change, 0 to destroy`, prd
  `Plan: 54 to add, 1 to change, 0 to destroy`. Đã có registry, observability: stg `14 to add`, prd `13 to add` (backup, role plan, ở stg
  role Spot), cùng `1 to change`. Đã có cả backup: stg `5 to add`, prd `4 to add`, cùng `1 to change`. Registry có từ trước khi
  `local.release_repositories` thêm repo: phần registry chỉ thiếu một `aws_ecr_repository.release` mỗi repo mới.
- **Bẫy:** dừng (không apply, dán plan) nếu có `change`, `destroy`, tài nguyên ngoài bảng hay phần thiếu tài nguyên; trừ khi account đã có
  AMG mà cờ `managed_grafana` của env là `session` hay `off`, hay đã quét `ENHANCED` mà cờ `inspector_ecr` là `off`: plan còn xoá, sửa
  đúng phần đổi cờ, áp theo [`paid-features.md`](paid-features.md#awsaccountsenv).

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform apply stg.tfplan && rm stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan    # expect: No changes.
```

#### N4. Việc sau apply của từng phần

- DNSSEC, query log: [bước (6)](#bước-6-alarm-và-dnssec-của-prd) (xác nhận subscription), rồi [`edge-setup.md`](edge-setup.md) bước (2a),
  (3) cho bản ghi `DS`.
- Registry, observability: lệnh `output` dưới in đúng tên role của `ci_roles` của env; rồi [`platform-setup.md`](platform-setup.md) bước
  (4) (gán người vào nhóm nền tảng), (6) (credential của cache), (10) (retention của `aws/spans`).
- Role plan của CI: [`platform-setup.md`, Role plan của CI](platform-setup.md#role-plan-của-ci).
- Backup: lệnh `describe-region-settings` dưới in `RDS` và `S3` là `True`.

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -json ci_role_arns | jq -r 'keys[]'
AWS_PROFILE=anhnv-stg aws backup describe-region-settings --region ap-southeast-1 \
  --query 'ResourceTypeOptInPreference.{RDS:RDS,S3:S3}' --output table
```
