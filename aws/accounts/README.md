# `aws/accounts`: phần sống giữa các buổi của account stg và prd

**Account** `svp-stg` (root `stg/`), `svp-prd` (root `prd/`) · **region** `ap-southeast-1` (DNSSEC, query log, alarm của prd:
`us-east-1`) · **profile** `anhnv-<env>` (chỉ đọc: `anhnv-<env>-ro`) · **state** bucket của chính account, key
`aws/accounts/<env>/terraform.tfstate`

Giải thích: [08. Account env](../../docs/handbook/08-accounts.md); phần backup: [07. Backup](../../docs/handbook/07-backup.md).

## Dựng gì

Mọi tài nguyên mang tag `Stack=baseline` (script quét sót của buổi bỏ qua) và sống giữa các buổi, trừ phần AMG khi cờ `managed_grafana`
của [`aws/paid-features.json`](../paid-features.json) không là `always`: với `session` nó chỉ có trong buổi, với `off` không bao giờ có.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `module.baseline` ([`account-baseline`](../modules/account-baseline/README.md)): bucket state, key `alias/svp-tfstate`, zone, `CAA`, budget `svp-<env>-monthly` | env, `ap-southeast-1`; zone toàn cục | State của mọi root trong account, zone của env |
| `module.baseline`: DNSSEC, query log, bản ghi uỷ quyền `stg.aws.<domain>` | `svp-prd`, `us-east-1`; bản ghi toàn cục | Chỉ prd: zone ký, ghi truy vấn, uỷ quyền zone stg |
| `module.alarms` ([`alarms`](../modules/alarms/README.md)): topic `svp-prd-dns-alarms` | `svp-prd`, `us-east-1` | Nhận hai alarm `page` của DNSSEC |
| `module.registry` ([`registry`](../modules/registry/README.md)): repo phát hành, rule cache, OIDC provider, role `ci_roles` | env, `ap-southeast-1` | Registry ECR và role CI chép bản phát hành vào nó |
| `module.ci_plan_role` ([`ci-plan-role`](../modules/ci-plan-role/README.md)): role `svp-ci-terraform-plan` | env, IAM | Role chỉ đọc của `terraform plan` trên PR của `svp-infra` |
| `module.observability` ([`observability`](../modules/observability/README.md)): AMP, `/svp/<env>/otel`, X-Ray, AMG theo cờ | env, `ap-southeast-1` | Metric, log, span sống qua các buổi |
| `module.paid_features` ([`paid-features`](../modules/paid-features/README.md)) | — | Đọc hai cờ `inspector_ecr`, `managed_grafana` của env |
| `backup.tf`: key `alias/svp-<env>-backup`, vault `svp-<env>`, opt-in, role `svp-<env>-backup` | env, `ap-southeast-1` | Phần của account env trong backup của tổ chức |
| `aws_iam_service_linked_role.spot` | `svp-stg`, IAM | Chỉ stg: role `AWSServiceRoleForEC2Spot` cho node Spot của Karpenter |

Hai root chỉ khác `local.env` và giá trị cạnh nó trong `locals` của `main.tf` (`ci_roles`, retention), `key` của backend, role Spot (chỉ
stg) và phần chỉ prd có (biến `delegated_subdomains`, `dnssec_signing`, `alarm_email`; DNSSEC, query log, `module.alarms`). Bucket của
mỗi account còn giữ state của `aws/envs/<env>` (key `aws/<env>/terraform.tfstate`) và `aws/gitops/<env>` (key
`aws/gitops/<env>/terraform.tfstate`).

## Giá trị ngoài repo

- Id account đặt trong mỗi lệnh từ biến của terminal, không vào file nào: `TF_VAR_account_id` từ `SVP_AWS_<ENV>_ACCOUNT_ID`,
  `TF_VAR_backup_account_id` từ `SVP_AWS_BACKUP_ACCOUNT_ID` (key vault backup chia sẻ cho `svp-backup`); biến không có `default` nên
  thiếu nó thì `plan` dừng ([`operations.md`](../../docs/reference/operations.md#biến-account-và-direnv)).
- `<env>.auto.tfvars` (git bỏ qua, mode 600) chép từ `<env>.auto.tfvars.example` bằng `aws/scripts/tfvars.sh example aws/accounts/<env>`:
  `zone_name`, `budget_emails`, `budget_limit_usd`; `platform_admin_group_id`, `platform_viewer_group_id` (ghi bằng
  `tfvars.sh groups <env>`); ở prd thêm `alarm_email` và `delegated_subdomains` (ghi bằng `tfvars.sh delegation`).
- Biến `session_open` không nằm trong file nào: trong buổi `aws/scripts/tf.sh <env> account plan --open|--close` đặt nó; plan trên PR
  (`ci/terraform-plan.sh`) cũng đặt khi plan root này.

## State và `backend-<env>.hcl`

Bucket state do chính root này tạo, nên lần apply đầu chạy trên state local rồi chuyển vào bucket
([`accounts-setup.md`, bước (3), (4)](../../docs/runbooks/accounts-setup.md#bước-3-apply-lần-đầu-state-local)).
`aws/scripts/tfvars.sh backend <env>` ghi output `backend_hcl` thành `aws/backend-<env>.hcl` (git bỏ qua): bucket, region, encrypt,
`kms_key_id`, `use_lockfile` của account, không có `key`. Mọi root của account đọc nó bằng `-backend-config=../../backend-<env>.hcl`.

**`init` một lần** mỗi bản clone, trước khi script đọc output của root (`check-dns.sh`, `grafana-tokens.sh`, `tfvars.sh`):

```sh
AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg init -backend-config=../../backend-stg.hcl
```

## Uỷ quyền DNS

Zone prd `aws.<domain>` được DNS cha của domain (Cloudflare) uỷ quyền bằng bốn bản ghi `NS` tên `aws`, đặt tay một lần. Zone stg
`stg.aws.<domain>` được zone prd uỷ quyền bằng biến `delegated_subdomains` của root prd. Name server lấy từ output `name_servers` của
root env. Mỗi buổi mở bằng `aws/scripts/check-dns.sh <env>`: uỷ quyền sai hay chưa lan truyền thì không `apply`. Cách đặt, kiểm và thứ
tự khi zone stg dựng lại: [`accounts-setup.md`, bước (5)](../../docs/runbooks/accounts-setup.md#bước-5-uỷ-quyền-zone-của-env).

## Chạy

Người học chạy mọi lệnh; AI không chạy lệnh nào chạm account.

- Dựng lần đầu mỗi account (prd trước stg, sau `aws/org`, `aws/security`, `aws/backup`):
  [`accounts-setup.md`](../../docs/runbooks/accounts-setup.md).
- Account đã có baseline từ bản trước của root này: [`accounts-setup.md`, Nâng cấp tổ chức dựng
  trước](../../docs/runbooks/accounts-setup.md#nâng-cấp-tổ-chức-dựng-trước).
- `CAA`, DNSSEC, chuỗi tin cậy, đường lui tắt ký: [`edge-setup.md`](../../docs/runbooks/edge-setup.md).
- Registry, observability, role CI, credential của cache, retention `aws/spans`:
  [`platform-setup.md`](../../docs/runbooks/platform-setup.md).
- Đổi cờ `inspector_ecr`, `managed_grafana`: [`paid-features.md`](../../docs/runbooks/paid-features.md#awsaccountsenv).
- Trong buổi: chỉ qua `aws/scripts/tf.sh <env> account plan --open|--close` rồi `tf.sh <env> account apply`; `plan`, `apply` trần ở đây
  khi buổi đang mở xoá workspace AMG của env có cờ `session`.
- Gỡ có chủ đích bucket, key state và cả baseline (bỏ hẳn env): [`lab-teardown.md`,
  `aws/accounts/<env>`](../../docs/runbooks/lab-teardown.md#awsaccountsenv).

## Output

| Output | Dùng ở |
| --- | --- |
| `state_bucket`, `backend_hcl` | `aws/backend-<env>.hcl` của mọi root trong account |
| `zone_id`, `name_servers` | `hosted_zone_id` của `aws/envs/<env>`; bản ghi `NS` uỷ quyền ở zone trên |
| `registry_host` | khoá `ecrRegistry` của cluster values; host registry trong lệnh kiểm |
| `ci_role_arns`, `ci_plan_role_arn` | đối chiếu tên role mà workflow dựng từ secret `SVP_AWS_<ENV>_ACCOUNT_ID` |
| `amp_workspace_id`, `grafana_url` | khoá `ampWorkspaceId`, `grafanaUrl` của cluster values; `grafana_url` là `null` khi không có workspace |
| `session_features` | cờ có giá trị `session` của env; rỗng thì mọi tài nguyên của root sống giữa các buổi |
| `spans_retention_command` | lệnh đặt retention của log group `aws/spans`, chạy một lần mỗi account |
| `backup_vault_arn`, `backup_key_arn`, `backup_role_arn` | vault đích, key và `--iam-role-arn` của job backup, restore theo yêu cầu |

## Tham chiếu

- [08. Account env](../../docs/handbook/08-accounts.md): vì sao phần sống lâu ở root riêng, zone stg là con của zone prd, role Spot;
  chi tiết triển khai ở mục Đọc sâu (ghi chú thiết kế mà `main.tf` trỏ tới).
- [07. Backup](../../docs/handbook/07-backup.md): key, vault, opt-in, role của `backup.tf` (ghi chú thiết kế mà `backup.tf` trỏ tới).
- [ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §2: state, DNS, budget mỗi account; zone
  prd ở đỉnh và lý do của nó: chương 08 ở trên.
- [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §5: bảng **Role CI ECR**.
