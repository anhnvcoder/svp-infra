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
AWS_PROFILE=anhnv-stg \
TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false -out=stg.tfplan
AWS_PROFILE=anhnv-stg terraform show -no-color stg.tfplan > "$SVP_SESSION_DIR/stg-plan.txt"
```

- **Mong đợi:** `Plan: <n> to add, 0 to change, 0 to destroy` với `<n>` bằng tổng `to add` của mục
  [`aws/accounts/stg`](../reference/inventory.md#awsaccountsstg) (hay [`aws/accounts/prd`](../reference/inventory.md#awsaccountsprd))
  ở inventory: cột "Phần" chia số đó theo `module.baseline`, `module.registry`, `module.observability`, `backup.tf`, `module.ci_plan_role`
  và `main.tf` (role Spot ở stg). Inventory tính theo `aws/paid-features.json` của repo (`managed_grafana` của stg, prd là `off`, nên không
  có phần AMG). Ở prd, plan của bước này không có bản ghi `delegation` mà inventory đếm (`delegated_subdomains` còn trống tới bước (5)):
  số `to add` kém inventory một.

```sh
AWS_PROFILE=anhnv-stg terraform apply -input=false stg.tfplan && rm stg.tfplan
../../scripts/tfvars.sh backend stg
```

- **Mong đợi:** `Apply complete!`; `ok    aws/backend-stg.hcl: output backend_hcl of aws/accounts/stg written (N lines, mode 600)`. File
  (git bỏ qua, ghi qua file tạm rồi `mv`) là cấu hình backend mà mọi root của account stg đọc bằng `-backend-config`.
- **Bẫy:** apply báo `InvalidInput: Service role name AWSServiceRoleForEC2Spot has been taken in this account` (account từng tạo Spot từ
  console): nhập role vào state rồi `plan` lại:

  ```sh
  AWS_PROFILE=anhnv-stg \
  TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
  TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
    terraform import -input=false aws_iam_service_linked_role.spot \
    "arn:aws:iam::$SVP_AWS_STG_ACCOUNT_ID:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
  ```

  Mong `Plan: 0 to add, 1 to change, 0 to destroy`: `aws_iam_service_linked_role.spot` sửa tại chỗ (`~`), `tags_all` thêm bốn tag của
  `default_tags` (`Project`, `Env`, `ManagedBy`, `Stack`); role có mô tả thì thêm dòng `description` về `null` (code không đặt mô tả). Có
  thay đổi khác thì dừng, dán plan; không thì apply plan đó (hai lệnh `plan`, `show` đầu bước, rồi `apply`), và plan lần hai phải là
  `No changes.`.
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
rm local_override.tf
# init hỏi có chép state lên bucket không: trả lời yes
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform init -migrate-state -backend-config=../../backend-stg.hcl
AWS_PROFILE=anhnv-stg \
TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false   # mong đợi: No changes.
AWS_PROFILE=anhnv-stg aws s3api head-object --region ap-southeast-1 \
  --bucket "$(AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform output -raw state_bucket)" \
  --key aws/accounts/stg/terraform.tfstate --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId}'
```

- **Mong đợi:** `init` chép state lên bucket; `plan` là `No changes.`; `head-object` in `SSE` `aws:kms` và `Key` là ARN của key state.
- **Bẫy profile mặc định:** từ bước này state nằm trong bucket của account env. Lệnh thiếu dòng `AWS_PROFILE=anhnv-<env>` chạy bằng
  `anhnv-sso`, mặc định của `.envrc`, nên ra `AccessDenied` trên bucket state hay key KMS của account env. Mọi lệnh ở root của account
  env ghi profile của env ngay trong lệnh; gặp lỗi này thì thêm dòng đó rồi chạy lại.
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
AWS_PROFILE=anhnv-prd \
TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false -out=prd.tfplan
AWS_PROFILE=anhnv-prd terraform show -no-color prd.tfplan > "$SVP_SESSION_DIR/prd-plan.txt"
```

- **Mong đợi:** `tfvars.sh delegation` đọc zone stg từ `zone_name` của `stg.auto.tfvars`, bốn name server từ output `name_servers` của
  `aws/accounts/stg`, đặt lại cả biến `delegated_subdomains` của file prd thành đúng mục đó, không đổi dòng khác (`ok    …
  delegated_subdomains: zone of stg, 4 name servers written`). Plan chỉ thêm một tài nguyên, đúng
  `module.baseline.aws_route53_record.delegation["stg.aws.<domain>"]`, không `change` hay `destroy`.
- **Bẫy:** output không đúng bốn tên DNS thì `FAIL  output name_servers of aws/accounts/stg has N names, not 4` và không ghi gì.
  Validation của biến chỉ chạy lúc `plan`: tên không phải con của zone prd hay số name server khác bốn thì dừng ở đó.

```sh
AWS_PROFILE=anhnv-prd terraform apply -input=false prd.tfplan && rm prd.tfplan
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
3. Thêm lại mục bằng `aws/scripts/tfvars.sh delegation` và làm lại 5b (plan chỉ thêm bản ghi `delegation`, không `change` hay `destroy`).

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
- `Error acquiring the state lock` kèm Lock ID (thường sau Ctrl+C một lệnh đang chờ nhập):
  [`operations.md`, Khoá state kẹt](../reference/operations.md#khoá-state-kẹt).
- Lỗi giữa `apply`: phần đã tạo nằm trong state; `plan` lại chỉ còn phần chưa tạo. Dán lỗi và plan mới trước khi apply lại;
  `-target`: [`operations.md`, Khi apply lỗi giữa chừng](../reference/operations.md#khi-apply-lỗi-giữa-chừng).
- Plan có `destroy` hay `-/+` ở zone, bucket, key có sẵn: dừng, không apply, dán plan.
- `AccessDenied` khi ghi state ở bước (4): profile không phải `SvpAdmin` (bước (1)).

## Nâng cấp tổ chức dựng trước

### Thêm vào account đã có baseline

Khi account đã apply một bản trước của root này, và root nay có phần mà account chưa có. `plan` luôn tính cả root: một lượt `plan`,
`apply` tạo mọi phần còn thiếu cùng lúc.

#### N1. Phần của root và số tài nguyên

Số tài nguyên mỗi phần nằm ở bảng "Phần" của mục [`aws/accounts/stg`](../reference/inventory.md#awsaccountsstg) và
[`aws/accounts/prd`](../reference/inventory.md#awsaccountsprd) trong inventory (account trống chạy lần đầu). Nâng cấp account đã có một
phần: lấy bảng theo phần, trừ phần account đã có. Các phần:

| Phần | Gồm |
| --- | --- |
| `module.baseline` | key và bucket state, zone, `CAA`; ở prd thêm DNSSEC, query log của zone |
| `module.alarms` (chỉ prd) | key, topic, subscription email của alarm DNS |
| `module.registry`, `module.observability` | ECR, cache, role CI; AMP, log group, X-Ray (cờ `managed_grafana` thêm phần AMG) |
| `backup.tf`, `module.backup_vault` | vault, key của env ([`backup-setup.md`](backup-setup.md#bước-6-awsaccountsstg-awsaccountsprd)) |
| `module.ci_plan_role` | role plan chỉ đọc của CI |
| `main.tf` (chỉ stg) | `aws_iam_service_linked_role.spot` |

Số repo `release` và `ci_roles` của registry theo `local.release_repositories` và `ci_roles` ở `locals` của root: inventory đếm theo
code hiện tại; registry có từ trước khi `local.release_repositories` thêm repo thì chỉ thiếu một `aws_ecr_repository.release` mỗi repo mới.

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
AWS_PROFILE=anhnv-stg \
TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false -out=stg.tfplan
AWS_PROFILE=anhnv-stg terraform show -no-color stg.tfplan > "$SVP_SESSION_DIR/stg-plan.txt"
```

- **Mong đợi:** `check-account.sh` in `ok    account … of stg, …AWSReservedSSO_SvpAdmin_…`. Plan chỉ thêm (`0 to destroy`); mọi tài nguyên
  thuộc một phần của bảng N1; phần account chưa có thì plan thêm đủ số của nó ở inventory, và `to add` bằng tổng các phần đó. Riêng
  `module.baseline`, `module.alarms` của account đời đầu (chỉ có baseline cũ) thì chỉ thêm phần còn thiếu, không đủ số inventory:
  - `module.baseline`: `aws_route53_record.caa`; ở prd còn 6 tài nguyên DNSSEC (`aws_kms_key.dnssec[0]`, `aws_kms_alias.dnssec[0]`,
    `aws_route53_key_signing_key.this[0]`, `aws_route53_hosted_zone_dnssec.this[0]`, hai `aws_cloudwatch_metric_alarm.dnssec`) và 3 query
    log (`aws_cloudwatch_log_group.query_log[0]`, `aws_cloudwatch_log_resource_policy.query_log[0]`, `aws_route53_query_log.this[0]`);
  - `module.alarms` (chỉ prd): đủ 5 (key, alias, topic, policy của topic, subscription email).

  Thay đổi được phép, tối đa `2 to change`, chỉ hai sửa tại chỗ:
  - `module.baseline.aws_kms_key.state` khi phần role plan có trong plan: chỉ `policy` thêm statement `CiPlanReadsState`;
  - `module.baseline.aws_budgets_budget.monthly`: chỉ `limit_amount`, về giá trị mà `budget_limit_usd` của `<env>.auto.tfvars` cho.
- **Kiểm:** `to add` bằng tổng các phần của [`aws/accounts/<env>`](../reference/inventory.md#awsaccountsstg) trong inventory, trừ tài
  nguyên account đã có. Ví dụ prd đời đầu chỉ có baseline cũ (11 tài nguyên, gồm bản ghi `delegation` của bước (5)): 80 − 11 = 69 trước
  khi áp 5a, tức 15 của baseline, alarms ở trên (1 + 6 + 3 + 5) cộng 54 của `backup.tf` 8, `module.backup_vault` 1,
  `module.ci_plan_role` 4, `module.observability` 9, `module.registry` 32; sau 5a (hai secret cache đã có) còn 67 cho 5b. Cùng tối đa
  `2 to change`, `0 to destroy`.
- **Bẫy:** lệnh thiếu `AWS_PROFILE=anhnv-<env>`: [bẫy profile mặc định của bước (4)](#bước-4-chuyển-state-vào-bucket). Dừng (không apply,
  dán plan) nếu có `change` ngoài hai sửa trên, `destroy`, `-/+`, hay tài nguyên ngoài bảng và ngoài danh sách tài nguyên còn thiếu ở
  trên; trừ khi account đã có
  AMG mà cờ `managed_grafana` của env là `session` hay `off`, hay đã quét `ENHANCED` mà cờ `inspector_ecr` là `off`: plan còn xoá, sửa
  đúng phần đổi cờ, áp theo [`paid-features.md`](paid-features.md#awsaccountsenv).

```sh
AWS_PROFILE=anhnv-stg terraform apply -input=false stg.tfplan && rm stg.tfplan
AWS_PROFILE=anhnv-stg \
TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false   # expect: No changes.
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
