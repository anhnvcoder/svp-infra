# Runbook: dựng env prd (bước 1–15)

← [session-prd](session-prd.md) · [Mục lục](README.md) · [Kiểm và đo](session-prd-checks.md) →

> **Tóm tắt**
>
> - **Làm gì:** từ tài khoản trống tới cluster `svp-prd` chạy: kiểm account và DNS, mở tính năng của account, apply root env
>   (`aws/envs/prd`), dựng khoá ký media, mở tunnel, ghi secret, apply root gitops (`aws/gitops/prd`) và chờ Argo CD đồng bộ.
> - **Khi nào và bao lâu:** ngay sau cổng promote của [trang chủ buổi prd](session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền);
>   tài nguyên tính theo giờ của env có từ bước 9. Apply root env ~65–70 phút (MSK là phần dài nhất); cả đoạn bước 1–15 theo cột Hạn
>   của bảng ở trang chủ.
> - **Phí trong lúc chạy:** bắt đầu từ bước 9 (NAT, RDS Multi-AZ, MSK, ElastiCache, ALB), tính theo giờ tới khi gỡ; số ở
>   [Chi phí và giới hạn](session-prd.md#chi-phí-và-giới-hạn) và bảng [Chi phí](../handbook/15-cost.md#chi-phí).

Trang này chỉ ghi phần riêng của prd; chỗ prd chạy giống stg thì trỏ mục tương ứng của [buổi stg](session-stg-deploy.md). **Người
học chạy mọi lệnh ở đây** (AI chỉ chạy `make check`, `make lock`); AI đọc output dán lại. Bước nào đỏ thì dừng ở đó, dán output,
đọc [Khi một bước đỏ](#khi-một-bước-đỏ).

## Điều kiện trước

- [ ] **Mọi điều kiện của trang chủ** đã đủ: [Điều kiện trước](session-prd.md#điều-kiện-trước), gồm cờ prd ở giá trị production.
- [ ] **Cổng promote prd xong**: `aws/scripts/preflight.sh promote` in đủ năm dòng `ok`
  ([Cổng promote prd](session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền)); chưa xong thì không chạy bước 1.
- [ ] **Terminal của buổi đã mở** theo [Mở terminal](session-prd.md#mở-terminal): `SVP_SESSION_DIR` và biến account đã có.

## Mở terminal

Dùng khối của [Mở terminal ở trang chủ buổi prd](session-prd.md#mở-terminal). Trang này cần: `SVP_SESSION_DIR`,
`SVP_AWS_PRD_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID` (từ `eval "$(aws/scripts/accounts.sh)"`). Mọi lệnh chạy từ
gốc repo này (`infra/`) trừ chỗ ghi `cd`.

## Bước 1: kiểm account

Loại: `lõi`. `check-account.sh prd` phải in account `svp-prd`; account khác thì dừng.

```sh
aws/scripts/check-account.sh prd
```

- **Mong đợi:** dòng `ok account …` (account, ARN) với account `svp-prd`.

## Bước 2: kiểm DNS

Loại: `lõi`.

```sh
aws/scripts/check-dns.sh prd
```

- **Kiểm:** `check-dns.sh prd` hỏi `NS aws.<domain>` (tên là `zone_name` của `aws/accounts/prd/prd.auto.tfvars`) ở `1.1.1.1` và `8.8.8.8`
  và so với output `name_servers` của `aws/accounts/prd`. Mong ba dòng `ok`.
- **Bẫy:** `FAIL` thì bốn bản ghi `NS` `aws` ở DNS cha chưa lan hay sai: sửa theo
  [`accounts-setup.md`, bước 5](accounts-setup.md#bước-5-uỷ-quyền-zone-của-env), không bắt đầu buổi. Zone stg nằm dưới zone prd nên
  `check-dns.sh stg` cũng phải xanh trước buổi stg.

## Bước 3–5: root account

Loại: `lõi`. Ba lệnh của `tf.sh prd account` (`init`, `plan --open`, `apply`) chỉ để mở tính năng của buổi:

```sh
aws/scripts/tf.sh prd account init
aws/scripts/tf.sh prd account plan --open
aws/scripts/tf.sh prd account apply
```

- **Mong đợi:** cả ba in `ok no session feature of prd in aws/paid-features.json: …` và không chạy gì. prd vắng khỏi file nên mọi
  cờ của nó là `always`, không cờ nào `session`; AMG `svp-prd` và tham số SSM của nó có từ lần áp `aws/accounts/prd` của bước [Đổi
  cờ prd trước buổi](session-prd.md#đổi-cờ-prd-trước-buổi) (mục [Cờ chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi) của buổi
  stg).
- **Bẫy:** với giá trị rẻ của file (`managed_grafana` `off`) ba bước cũng in đúng dòng đó, nên dòng này không chứng minh điều kiện **Cờ
  prd ở giá trị production**: lệnh `jq` của điều kiện đó là phép kiểm duy nhất trước bước 1.

## Bước 6–8: init, khoá ký, plan root env

Loại: `lõi`. Như bước 6–8 của buổi stg
([6–10](session-stg-deploy.md#610-root-env-init-khoá-ký-plan-lưu-file-đọc-apply-file-đó-kích-hoạt-khoá-ký)), với `prd`. Plan đọc
`prd.tfvars` (mức prd).

```sh
aws/scripts/tf.sh prd env init
aws/scripts/media-signing-key.sh prd new a
aws/scripts/tf.sh prd env plan
```

- **Mong đợi:** `init` in dòng cuối; `new a` in `ok slot a: …` cùng mọi dòng `warn`/`note` (khoá ký URL premium của buổi như stg,
  [`media-signing-keys.md`](media-signing-keys.md#lần-đầu-của-một-env)); `plan` in `Plan: N to add, 0 to change, 0 to destroy` và đường
  dẫn file text của plan.
- **Kiểm:** đọc file text `prd-env-plan.txt`: chỉ `to add`, có ba web ACL và `module.edge` như stg, với:
  - ALB `svp-prd-edge` `enable_deletion_protection = true`;
  - distribution `svp-prd-media` không gói flat-rate (không `aws_pricingplanmanager_subscription`), response headers policy
    `svp-prd-media`, delivery log, behavior mặc định tin key group `svp-prd-media` (`media/*`, `preview/*` công khai), public key
    `svp-prd-media-a-<8 hex>`;
  - bastion SSM, ba NAT gateway, RDS `multi_az = true`;
  - cluster MSK ba broker `kafka.m7g.large` (configuration RF 3, min ISR 2) cùng log group `/aws/msk/svp-prd`;
  - replication group ElastiCache hai node `cache.m7g.large` (`automatic_failover_enabled`, `multi_az_enabled` `true`);
  - cùng Karpenter, bastion, KMS key, SNS và alarm như stg, tên `svp-prd-*`.

## Bước 9: apply root env

Loại: `lõi`. Tính tiền từ đây.

```sh
aws/scripts/tf.sh prd env apply
```

- **Mong đợi:** ~65–70 phút. Dán dòng `Apply complete! …`, hai dòng `mark` và hai dòng `Creation complete after …` của cluster MSK,
  replication group ElastiCache.
- **Việc tay:** sau apply, xác nhận email của topic `svp-prd-alarms` theo mục
  [Alarm tới email](session-stg-check-security.md#alarm-tới-email) của buổi stg (`AWS_PROFILE=anhnv-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`).
- **Bẫy:** `apply` đỏ giữa chừng và lỗi apply đã biết (account chưa xác minh, delivery destination chưa có, ElastiCache không nhận
  access string) theo mục tương ứng của [buổi
  stg](session-stg-deploy.md#610-root-env-init-khoá-ký-plan-lưu-file-đọc-apply-file-đó-kích-hoạt-khoá-ký). Lượt đỏ đã ghi một tài
  nguyên mang mật khẩu của nhóm Kafka hay Valkey thì `aws/scripts/tfvars.sh bump prd msk` hay `bump prd valkey` (tăng
  `msk_password_version` hay `valkey_password_version` trong `aws/envs/prd/prd.auto.tfvars`) trước khi `plan` lại, rồi
  `bootstrap.sh prd secrets` ở bước 11. Apply đỏ mà không dựng tiếp được (vd thiếu quota): gỡ phần đã tạo theo bẫy ở bước 1 của
  [Gỡ, quét sót, trả cờ](session-prd.md#gỡ-quét-sót-trả-cờ).

## Bước 10: kích hoạt khoá ký

Loại: `lõi`. Ghi khoá ký của ô `a` vào entry `svp/prd/media-signing`:

```sh
aws/scripts/media-signing-key.sh prd activate a
```

- **Mong đợi:** dòng `ok entry …` (không có khoá). Xoay khoá, khoá bị lộ: [`media-signing-keys.md`](media-signing-keys.md#xoay-khoá-ký).

## Tunnel tới API (sau bước 9, trước bước 11)

Loại: `lõi`.

Như mục [Tunnel tới API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11) của buổi stg, với cổng `127.0.0.1:6443`
của prd (`api_tunnel_port` của `prd.tfvars`; stg `6444`). Mở ở **một terminal riêng** (mới mở, ở thư mục chứa các clone như khối
[Mở terminal](session-prd.md#mở-terminal)), giữ chạy tới hết bước 22 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/envs/prd output -raw api_tunnel_command)"
```

- **Kiểm:** context `svp-prd`: server `https://127.0.0.1:6443`, TLS server name là host của endpoint private. Root `aws/gitops/prd` tới
  API qua cùng tunnel (`api_server_url = "https://127.0.0.1:6443"` của `aws/gitops/prd/prd.tfvars`, TLS server name tính từ
  `cluster_endpoint` của state root env). Vì sao tunnel và cổng mỗi env:
  [09. Env và mạng](../handbook/09-envs-network.md#kịch-bản-thực-tế).
- **Bẫy:** `FAIL no tunnel …` của một script là tunnel chưa mở hay đã rớt: mở lại rồi chạy lại đúng bước đó.

## Bước 11: secret và làm nóng cache

Loại: `lõi`.

```sh
aws/scripts/bootstrap.sh prd secrets
```

- **Mong đợi:** mọi dòng `ok`/`FAIL`; gồm token Grafana Operator (entry `svp/prd/grafana-operator`). Dán lại hết.
- **Việc tay:** chat Telegram lấy từ `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (giá trị trần hay trong một cặp nháy kép hoặc nháy
  đơn, như `make eks-secrets` đọc).
- **Làm nóng cache** giữa bước 11 và 12, như mục
  [Làm nóng cache](session-stg-deploy.md#làm-nóng-cache-sau-bước-11-trước-bước-12) của buổi stg, với danh sách của prd (render chart ở
  `revision` của `envs/prd/charts.yaml`):

```sh
(cd ../backend && deploy/ci/image-list.sh ../gitops prd) >"$SVP_SESSION_DIR/images-prd.txt"
aws/scripts/ecr-warm.sh prd "$SVP_SESSION_DIR/images-prd.txt"
```

## Bước 12–14: root gitops

Loại: `lõi`. Như bước 12–14 của buổi stg ([12–14](session-stg-deploy.md#1214-root-gitops-argo-cd-và-root-gitops)), với `prd`; cần
tunnel mở.

```sh
aws/scripts/tf.sh prd gitops init
aws/scripts/tf.sh prd gitops plan
aws/scripts/tf.sh prd gitops apply
```

- **Mong đợi:** `init` in dòng cuối; `plan` in dòng `ok chart svp-cluster at <sha> …` và dòng `Plan: …`; `apply` in `Apply complete! …`
  cùng output `bootstrap_revision`.
- **Kiểm:** hai commit phải khớp hai khoá đã kiểm ở bước 4 của [Cổng promote prd](session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền):
  `<sha>` của dòng `ok chart svp-cluster at <sha>` (bước 13) là `revision` (commit repo code của chart), output `bootstrap_revision`
  (bước 14) là `gitopsRevision` (commit `svp-gitops`).
- **Bẫy:** plan của root gitops dừng khi khoá `gitopsRevision` vắng (`require_pinned_revision = true`): cổng promote chưa xong.

## Bước 15: chờ Argo CD đồng bộ

Loại: `lõi`. Lệnh `kubectl` tay vào prd ghi profile và context:

```sh
aws/scripts/bootstrap.sh prd wait
```

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io
```

- **Mong đợi:** mọi dòng `ok`/`FAIL` của `bootstrap.sh prd wait` (hạn 45 phút); các Application `Synced` `Healthy`.
- **Bẫy:** cảnh báo `PublicUptimeBudgetBurn` (SLO `public-uptime`, hai mức cùng tên: `page` và `ticket`) cháy sau khi dựng cluster mới là
  do probe lỗi lúc dựng (probe chạy trước các service, thứ tự ở `argocd/apps/components.json` của svp-gitops): chờ, không điều tra. Khi
  ba đích đã xanh, page hết sau chừng 30 phút, ticket theo cửa sổ 6 giờ; cửa sổ của hai mức ở
  `deploy/observability/prometheus/rules/slo-generated.yaml` của svp-backend, cách đọc ở
  [`public-uptime-budget-burn.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/public-uptime-budget-burn.md).

## Chạy tay một root (không qua script)

Khi cần chạy `terraform` trần ở root env (đọc plan từng bước, kiểm một lỗi). Script `tf.sh` vẫn là đường chính của buổi: nó thêm kiểm
account, biến, mốc `timeline.tsv` và các kiểm mốc mà lệnh trần không có. Khối dưới **thay** bước 6–9 (init, khoá ký, plan và apply), không
chạy sau chúng: `cp` ghi đè `prd.auto.tfvars` mà `tfvars.sh env prd` đã chuẩn bị, và `export SVP_SESSION_DIR` mới tách `timeline.tsv` sang
thư mục buổi khác.

Kiểm account trước (cột `Account` phải bằng `$SVP_AWS_PRD_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`; khác thì dừng):

```sh
cd aws/envs/prd                                          # từ infra/, thư mục của terminal buổi
AWS_PROFILE=anhnv-prd aws --no-cli-pager sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_PRD_ACCOUNT_ID"
```

Dựng:

```sh
cp example.auto.tfvars.example prd.auto.tfvars          # rồi sửa bốn giá trị
AWS_PROFILE=anhnv-prd terraform init -reconfigure -backend-config=../../backend-prd.hcl -backend-config=key=aws/prd/terraform.tfstate
export SVP_SESSION_DIR="$(git rev-parse --show-toplevel)/.session/$(date -u +%Y%m%dT%H%M%SZ)"  # thư mục buổi đang dở
../../scripts/media-signing-key.sh prd new a     # plan reads slot a's public key from media-signing.auto.tfvars.json
AWS_PROFILE=anhnv-prd \
TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" \
TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false -var-file=prd.tfvars -out=prd.tfplan
AWS_PROFILE=anhnv-prd terraform show -no-color prd.tfplan > "$SVP_SESSION_DIR/prd-plan.txt"
```

Đọc `prd-plan.txt` ([Đọc plan an toàn](../reference/operations.md#đọc-plan-an-toàn)): chỉ tài nguyên của `aws/envs/prd`, không
`destroy` nào. Đúng thì apply:

```sh
AWS_PROFILE=anhnv-prd terraform apply -input=false prd.tfplan && rm prd.tfplan
cd ../../..                                              # về infra/ cho các lệnh sau
```

Sau `apply`: xác nhận email của topic `svp-prd-alarms`, mở tunnel (mục [Tunnel tới API](#tunnel-tới-api-sau-bước-9-trước-bước-11));
`AWS_PROFILE=anhnv-prd terraform -chdir=aws/envs/prd output -raw rds_master_user_secret_arn` cho script buổi.
Tiếp theo: ghi khoá ký của ô `a` vào entry
`svp/prd/media-signing` (`aws/scripts/media-signing-key.sh prd activate a` với cùng `SVP_SESSION_DIR`, bước 10), giá trị các secret khác
(`AWS_PROFILE=anhnv-prd make eks-secrets CONTEXT=svp-prd` ở repo code, bước 11), rồi apply root `aws/gitops/prd` khi tunnel đang mở.

## Gỡ

Gỡ toàn bộ nằm ở trang chủ buổi prd: [Kết thúc buổi](session-prd.md#kết-thúc-buổi). Tunnel giữ tới hết bước 22.

## Khi một bước đỏ

- **`FAIL no tunnel …`:** mở lại tunnel ([Tunnel tới API](#tunnel-tới-api-sau-bước-9-trước-bước-11)), chạy lại đúng bước đó.
- **Plan gitops dừng vì thiếu `gitopsRevision`:** cổng promote chưa merge; không dựng tiếp.
- **Apply bước 9 đỏ:** xem bẫy của [bước 9](#bước-9-apply-root-env).
- **`Error acquiring the state lock`** kèm Lock ID sau một lệnh `terraform` trần bị ngắt (mục [Chạy tay một
  root](#chạy-tay-một-root-không-qua-script)): [Khoá state kẹt](../reference/operations.md#khoá-state-kẹt).
- **Lỗi khác của script:** đọc dòng `FAIL`, dán cả dòng; theo trang tương ứng của
  [buổi stg](session-stg-deploy.md#khi-một-bước-đỏ).
