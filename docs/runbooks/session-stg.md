# Runbook: một buổi AWS stg

← [github-setup, bước 7 trở đi](github-setup.md#thứ-tự-trên-một-account-mới) · [Mục lục](README.md) · [Dựng env](session-stg-deploy.md) →

> **Tóm tắt**
>
> - **Làm gì:** dựng env stg trong account `svp-stg` (`aws/envs/stg`), cài Argo CD và root GitOps lên EKS bằng Terraform
>   (`aws/gitops/stg`, mẫu GitOps Bridge), chạy phép kiểm `lõi` (smoke, phát video, commit status, migration của release, xác thực qua
>   CloudFront, image phát hành ở ECR, đường cảnh báo và uptime, service mesh, bảo vệ của account: agent GuardDuty, flow log, log WAF,
>   quét malware, finding GuardDuty), rồi gỡ sạch trong cùng buổi và quét cả account stg lẫn account management. Phép kiểm `chuẩn
>   ngành` (seed, k6 bậc 1, 2, 4, 8, dashboard, diễn tập khôi phục, kiểm sâu nền tảng managed…) chọn bật từng buổi: mục
>   [Phép kiểm lõi và chuẩn ngành](#phép-kiểm-lõi-và-chuẩn-ngành).
> - **Khi nào và bao lâu:** mỗi buổi cloud của stg, một lượt từ `check-account.sh` tới hai lượt `sweep.sh` sạch; tối đa 4 giờ
>   ([Giới hạn](#giới-hạn)).
> - **Phí trong lúc chạy:** ước tính một buổi 4 giờ và các khoản của nó ở [Giới hạn](#giới-hạn); quên destroy 24 giờ tốn gấp ~6 lần
>   một buổi. Số thật đo ở Cost Explorer ([Kết thúc buổi](#kết-thúc-buổi)).

Buổi prd theo [`session-prd.md`](session-prd.md), dùng chung mọi mục chung của trang này. Trang này là trang chủ của buổi: điều kiện,
terminal, giới hạn, cờ chi phí, bảng bước, phép kiểm bước 16, cách gỡ kẹt và xoá tay, kết thúc buổi. Các pha còn lại ở bốn trang riêng
(bảng [Thứ tự](#thứ-tự)). Thiết kế: [ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §13 (tài
nguyên ngoài state), §14 (buổi AWS); [ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §1–§2
(account, state), §5 (secret), §6 (bootstrap EKS), §9 (kết thúc buổi);
[ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md) (zone của mỗi env);
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) (Kafka là Amazon MSK, Valkey là
ElastiCache, dựng cùng apply với EKS, mật khẩu do Terraform sinh);
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) (backup và DR: Backup policy, vault copy ở
account `svp-backup`, mục tiêu RTO/RPO, diễn tập, xoá recovery point cuối buổi);
[ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md) (cờ chi phí theo account: AMG, Inspector
ECR, Security Hub CSPM, AWS Config);
[ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) (giá trị rẻ nhất của cờ, phép
kiểm `lõi` và `chuẩn ngành`).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại và nhắc tới khi destroy hai root và hai lượt `sweep.sh` (stg, mgmt) đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`). Mỗi
account một profile và một biến account, script tự lấy theo env từ bảng `env_table` của `aws/scripts/lib.sh`:

| Env của script | Account | Profile | Biến account |
| --- | --- | --- | --- |
| `stg` | `svp-stg` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` |
| `prd` | `svp-prd` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` |
| `mgmt` | management (account sandbox cũ) | `anhnv-sso` | `SVP_AWS_MGMT_ACCOUNT_ID` |

Account `svp-backup` (vault `svp-stg-copy`, `svp-prd-copy` giữ bản copy) không phải env của script: script chỉ cần 12 số của nó trong
`SVP_AWS_BACKUP_ACCOUNT_ID` (ARN vault đích, key RDS của root env), lệnh tay đọc bản copy bằng profile chỉ đọc `anhnv-backup-ro`.

Profile và region `ap-southeast-1` (`us-east-1` cho WAF, cert ACM và log chuẩn của CloudFront, Pricing Plan Manager và API Free Tier)
ghi sẵn trong từng lệnh của script. Script in mỗi bước một dòng `ok`, `FAIL` (dừng), `note` hay `skip`, không in giá trị bí mật nào.

Xem trước toàn bộ lệnh của buổi, theo đúng thứ tự, không chạy gì (an toàn, không cần credential):

```sh
aws/scripts/session.sh --print stg
```

## Điều kiện trước

Kiểm đủ mười một điều kiện trước bước 1. Điều kiện 1, 6–8, 10 là việc một lần của tổ chức, không nằm trong buổi.

- [ ] **1. Account stg đã có baseline.** Root `aws/org` đã tạo account `svp-stg` và gán permission set `SvpAdmin`; profile `anhnv-stg` đã
  ghi bằng `aws/scripts/sso-profiles.sh write` ([`org-security-setup.md`, 4c](org-security-setup.md#4c-profile-của-account-thành-viên));
  baseline `aws/accounts/stg` đã apply (bucket state, KMS key `alias/svp-tfstate`, zone `stg.aws.<domain>`, budget).
  - **Việc tay:** zone đó là zone con của zone `aws.<domain>` của account prd: được uỷ quyền bằng bản ghi `NS` của `delegated_subdomains` ở
    `aws/accounts/prd`, còn `aws.<domain>` bằng bốn bản ghi `NS` `aws` ở DNS cha của domain ([`accounts-setup.md`, bước
    (5)](accounts-setup.md#bước-5-uỷ-quyền-zone-của-env)). Bước tay này một lần, không nằm trong buổi. Account mới còn phải được AWS xác
    minh trước khi tạo tài nguyên CloudFront, và quota EC2 đủ cho node của env: chưa xác minh thì `apply` đỏ ở `aws_cloudfront_distribution`
    với `AccessDenied: Your account must be verified before you can add new CloudFront resources`, khi EKS, RDS đã chạy và tính tiền. Mở
    case AWS Support từ account stg (Account and billing, kèm dòng lỗi và RequestID nếu có) và chờ xác nhận trước buổi đầu.
  - **Bẫy:** `check-dns.sh` đỏ thì quay lại `accounts-setup.md`, không bắt đầu buổi. Không gỡ baseline stg giữa các buổi: zone stg dựng
    lại có name server mới, phải `apply` lại `aws/accounts/prd` mới phân giải được.
  - **Kiểm:** distribution media đăng ký gói CloudFront flat-rate Free: account đang dùng AWS Free Tier không đăng ký được, và mỗi
    account tối đa 3 gói Free, không tăng được. Mỗi buổi, trước bước 3, đọc gói của account và loại account (chỉ đọc; phép kiểm (a) của
    ADR-0052), và quota vCPU (chỉ đọc), bằng hai script ở terminal của buổi (mục [Mở terminal](#mở-terminal)):

    ```sh
    aws/scripts/preflight.sh freetier stg
    aws/scripts/preflight.sh quotas stg
    ```

  - **Mong đợi:** `freetier` in `ok    no CloudFront flat-rate plan in stg` và `ok    account plan of stg is PAID`; dán lại cả hai.
    Account thành viên của tổ chức không có gói riêng: vào tổ chức là gói Free tự lên gói trả phí ([AWS: Free Tier
    plans](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html), đọc 2026-11-19), API `GetAccountPlanState`
    trả `ResourceNotFoundException`, script in `ok    account plan of stg is PAID (member of an organization, no account plan)`: cũng đạt.
    `quotas` đọc mỗi quota một dòng `ok    <mã> <tên>: <giá trị> (min|max <cần>)`: on-demand chuẩn (`L-1216C47A`) cho nhóm node hệ thống
    tới `system_node_max_size` (2 × số AZ node `m7g.large`, 2 vCPU mỗi node) cộng bastion `t4g.nano` (2 vCPU), Spot chuẩn (`L-34B43A08`)
    cho `limits.cpu` của NodePool (`envs/stg/svp-cluster.yaml` của `svp-gitops`, số ở ADR-0056 §2), và quota chu kỳ luật AMP: quota mặc
    định đạt, dòng `ok    <mã> AMP rule evaluation interval (seconds): 30.0 (max 30)`. Số cần ở `quota_table` của script.
  - **Bẫy:** `FAIL  N CloudFront plan(s) left in stg …`: gói sót của buổi trước hay của lần thử ở console giữ một suất và distribution của
    nó: huỷ theo mục [Lệnh xoá tay theo loại](#lệnh-xoá-tay-theo-loại) (CloudFront) rồi chạy lại. `FAIL  account plan of stg is FREE`:
    account còn ở AWS Free Tier, apply sẽ đỏ ở gói: không bắt đầu buổi, dán output cho AI. `FAIL  <mã> …: needs min <cần>: run
    preflight.sh quotas stg request`: xin tăng bằng đúng lệnh đó (lệnh duy nhất của `preflight.sh` ghi) và chờ `APPROVED` trước buổi;
    chạy `quotas stg` lại tới khi hết `FAIL`.
- [ ] **2. Code đã merge.** Repo code ở `main` có `make eks-secrets`, `make eks-glitchtip-init`; `svp-gitops` ở `main` có `argocd/root`,
  `argocd/bootstrap.json`, lớp `platforms/eks`; repo này có `aws/envs/stg`, `aws/gitops/stg` và script buổi.
  - **Kiểm:**

    ```sh
    git -C ../backend switch main && git -C ../backend pull --ff-only
    make -C ../backend help | grep -E '^  eks-(secrets|glitchtip-init)'      # hai dòng
    git -C ../gitops fetch origin
    git -C ../gitops show origin/main:envs/stg/charts.yaml | grep '^revision:'
    ```

  - **Mong đợi:** `bootstrap.sh stg secrets` tự kiểm lại: repo code ở `main`, sạch, bằng `origin/main` (entry và key của `make
    eks-secrets` đọc từ chart của nó). `tf.sh stg gitops plan` fetch hai bản clone, giải nén chart `svp-cluster` ở `revision` của
    `envs/stg/charts.yaml` vào thư mục buổi.
- [ ] **3. Công cụ trên máy.** Terraform 1.15 (`terraform version`), AWS CLI v2 và Session Manager plugin (`session-manager-plugin
  --version`, cho tunnel tới API), `kubectl`, `jq`, `dig`, `nc`, `make`, `cosign` (kiểm chữ ký bản ECR), `curl` có `--aws-sigv4`
  (7.75 trở lên; bản của macOS có: `curl --version`), Docker (`image-list.sh` của repo code render chart như `make helm-check`);
  `.env` của repo code đã có (`make -C ../backend env`; `tf.sh stg gitops plan` lấy chat Telegram `SVP_ALERT_TELEGRAM_CHAT_ID` từ
  đó, rỗng là chỉ commit status).
- [ ] **4. File backend của account stg.** `aws/backend-stg.hcl` (git bỏ qua; chỉ bucket, region, KMS key, không `key`), ghi từ output của
  baseline:

  ```sh
  aws/scripts/tfvars.sh backend stg
  ```

  - **Mong đợi:** `ok    aws/backend-stg.hcl: output backend_hcl of aws/accounts/stg written (… lines, mode 600)`; không in giá trị.
  - **Bẫy:** baseline chưa apply hay output không có bucket thì `FAIL` và file giữ nguyên.
- [ ] **5. `stg.auto.tfvars`.** `aws/envs/stg/stg.auto.tfvars` (git bỏ qua) ghi bằng script, chỉ đọc output của baseline. File không có id
  workspace AMG: khi cờ `managed_grafana` khác `off`, root env đọc nó từ tham số SSM `/svp/stg/grafana-workspace-id` (`session`: bước
  3–5 của buổi tạo cùng workspace); với `off` root env không đọc gì về Grafana:

  ```sh
  aws/scripts/tfvars.sh env stg
  ```

  - **Mong đợi:** `ok` có `3 of hosted_zone_id, domain, alarm_email`. Script ghi `hosted_zone_id` từ output `zone_id` của
    `aws/accounts/stg`; `domain` (tên zone stg, `stg.aws.<domain>`) và `alarm_email` (hộp thư nhận alarm) giữ nếu file đã có. Nó cũng
    xoá các dòng `eks_public_access_cidrs`, `acme_email`, `grafana_workspace_id` (root không khai báo ba biến này: Terraform chỉ cảnh
    báo `Value for undeclared variable`) và chỉ đổi dòng của biến, không đổi dòng khác. `domain` là tên zone của account stg (web ở
    đỉnh, API ở `api.<domain>`); precondition của root từ chối tên ngoài zone đó ngay lúc plan. Endpoint công khai của API tắt, nên file
    không có IP của máy.
  - **Script hỏi:** `domain` và `alarm_email` chưa có trong file thì hỏi ở terminal (giá trị cá nhân, không in lại): nhập tên zone stg
    và hộp thư nhận alarm.
  - **Bẫy:** file có sẵn thiếu `alarm_email` mà chạy ngoài terminal thật thì `FAIL … stdin is not a terminal`: chạy lại trong terminal.
- [ ] **6. Nền bảo mật của org đã áp** tới ít nhất bước (3) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu)
  (`aws/bootstrap`, `aws/org` tạo account `svp-log-archive`, `aws/log-archive`): root env ghi flow log VPC vào bucket
  `svp-flowlogs-<log>-ap-southeast-1` và log WAF vào `aws-waf-logs-svp-<log>-us-east-1` của account đó, nên cần id account đó trong biến
  `SVP_AWS_LOG_ACCOUNT_ID` (output `log_archive_account_id` của `aws/org`; mục [Mở terminal](#mở-terminal)).
  - **Bẫy:** thiếu biến thì `tf.sh` dừng với `FAIL set SVP_AWS_LOG_ACCOUNT_ID …`; bucket chưa có thì `apply` đỏ ở flow log hay logging
    của web ACL.
- [ ] **7. Edge đã áp lần đầu** theo [`edge-setup.md`](edge-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (3): delivery destination
  `svp-cloudfront-stg` của account Log Archive (root env tạo delivery log của CloudFront tới nó), `CAA` ở zone, zone prd ký và có `DS` ở
  DNS cha (phép kiểm edge đọc cờ `ad`). Một lần, không nằm trong buổi.
  - **Bẫy:** thiếu delivery destination thì `apply` đỏ ở `aws_cloudwatch_log_delivery`.
- [ ] **8. Nền tảng managed đã áp** theo [`platform-setup.md`](platform-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (9): registry, pull-through
  cache có credential, workspace AMP, log group `/svp/stg/otel` của `aws/accounts/stg` (root env đọc chúng bằng data source; AMG theo cờ
  `managed_grafana`, mục [Cờ chi phí của buổi](#cờ-chi-phí-của-buổi)), quota EC2 đã duyệt, secret CI đã đặt. Một lần, không trong buổi.
  - **Bẫy:** thiếu một phần thì `plan` dừng ở data source hay precondition. Luật AMP chạy 30 s (quota mặc định), không cần case Support.
- [ ] **9. Chart có nền tảng managed.** `revision` của `envs/stg/charts.yaml` (lệnh của điều kiện 2) là commit của repo code có Collector
  theo nền tảng, value `canaryPrometheus` và `rules.amp.interval`.
  - **Kiểm** (ba dòng `ok`):

    ```sh
    rev=$(git -C ../gitops show origin/main:envs/stg/charts.yaml | sed -n 's/^revision: *//p')
    git -C ../backend fetch origin
    git -C ../backend cat-file -e "$rev:deploy/observability/otelcol/k8s-eks.yaml" && echo ok
    git -C ../backend show "$rev:deploy/helm/svp-service/values.yaml" | grep -q '^canaryPrometheus:' && echo ok
    git -C ../backend show "$rev:deploy/helm/svp-observability/values.yaml" | grep -q '^ *interval: 15s' && echo ok
    ```

  - **Bẫy:** chart cũ bỏ qua values eks mới: không metric, log, trace vào dịch vụ managed, image kéo thẳng upstream, canary hỏi
    Prometheus không còn trả lời; chart chưa có `rules.amp.interval` thì luật ra 15 s, dưới quota, namespace `CREATION_FAILED`.
- [ ] **10. Backup đã áp** theo [`backup-setup.md`](backup-setup.md#thứ-tự-áp-lần-đầu): account `svp-backup` và biến
  `SVP_AWS_BACKUP_ACCOUNT_ID`, Backup policy `svp-backup-stg` gắn OU `NonProd` (plan `svp-stg` của account), vault `svp-stg-copy` ở
  `svp-backup`, vault `svp-stg` cùng role `svp-stg-backup` và opt-in ở `aws/accounts/stg`, profile `anhnv-backup-ro`. Một lần, không nằm
  trong buổi.
  - **Bẫy:** thiếu biến thì `tf.sh stg env …` dừng với `FAIL set SVP_AWS_BACKUP_ACCOUNT_ID …`. Thiếu một phần còn lại thì bước 17 dừng ở
    phần đó (`FAIL no backup plan svp-stg …`, `opt-in …`), hay copy job lỗi.
- [ ] **11. Máy.** Mac cắm sạc, tắt Low Power Mode (đo k6 và chờ dài).

## Mở terminal

Mở một terminal, chạy khối dưới. Mọi bước sau chạy trong **cùng terminal này** (cùng các biến); trang pha của buổi trỏ về mục này thay
vì chép lại.

```sh
cd infra
AWS_PROFILE=anhnv-sso aws --no-cli-pager sso login --region us-east-1   # one login per sso_session
printf 'mgmt …%s\n' "${SVP_AWS_MGMT_ACCOUNT_ID: -4}"                      # from .envrc (direnv), 4 last digits only
eval "$(aws/scripts/accounts.sh)"                                               # sets five member-account variables
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"               # số đo của buổi; .session/ git bỏ qua
aws/scripts/sso-profiles.sh check                                               # all eight profiles sign in
```

- **Mong đợi:** `accounts.sh` đọc tổ chức bằng `anhnv-sso` và đặt `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_PRD_ACCOUNT_ID`,
  `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID` (bucket flow log, log WAF, copy vault, key RDS dùng
  ba biến sau): năm dòng `ok    SVP_AWS_<…>_ACCOUNT_ID: account svp-<tên>, ACTIVE` (không in id). `sso-profiles.sh check` in tám dòng `ok
  account <12 số> of <tên>, arn:…`; dán các dòng `FAIL`.
- **Bẫy:** `FAIL  no account svp-<tên> in the organization` hay `FAIL  profile anhnv-sso is account …` (`SVP_AWS_MGMT_ACCOUNT_ID` sai) thì
  stdout rỗng, `eval` không đặt gì: sửa rồi chạy lại.
- **Việc tay (phiên SSO):** mọi profile của lab dùng chung một `sso_session` (của `anhnv-sso`), nên một lần `aws sso login` là đủ cho cả
  tám, kể cả `anhnv-stg` và `anhnv-backup-ro` của bước 17; không login từng profile. Phiên hết hạn giữa buổi thì lệnh `aws` hay script báo
  `Token has expired` hay `The SSO session associated with this profile has expired`, và `check_account` của script dừng ở `FAIL  aws sts
  get-caller-identity with profile <tên> (expired SSO session? …)`. Login lại bằng lệnh đầu của khối trên: lệnh mở trình duyệt, bạn duyệt
  thiết bị bằng tay (MFA; không có API), rồi chạy lại đúng lệnh đang dở. Một bước đã `FAIL` vì phiên hết hạn không để lại gì dở: các
  script chạy lại an toàn, và `measure.sh` nói rõ cách chạy tiếp (`--from <n>`).

Biến account nằm trong `.envrc` ở thư mục chứa các clone, ngoài mọi repo (direnv nạp, xem
[`operations.md`](../reference/operations.md#biến-account-và-direnv)); không file commit nào chứa ID; script đặt `TF_VAR_account_id` từ
biến của env, `TF_VAR_log_archive_account_id` từ `SVP_AWS_LOG_ACCOUNT_ID` và `TF_VAR_backup_account_id` từ `SVP_AWS_BACKUP_ACCOUNT_ID`
ngay trong lệnh `terraform` của root env; `restore-drill.sh` dựng ARN vault `svp-stg-copy` từ `SVP_AWS_BACKUP_ACCOUNT_ID`. File đó cũng
đặt mặc định `AWS_PROFILE`, `AWS_REGION` cho lệnh tay ở root management
([`operations.md`](../reference/operations.md#biến-account-và-direnv)).

Thư mục buổi chứa: `timeline.tsv` (mốc UTC: `session-start`, `env-apply-start`, `env-apply-end`, `secrets-written`, `gitops-apply-start`,
`gitops-apply-end`, `observability-healthy`, `glitchtip-init`, `svp-root-healthy`, `edge-healthy`, `smoke-ok`, `seed-ok`,
`k6-<n>-start`/`-end`, `backup-undrained`, `backup-drained`, `pre-destroy-*`, `gitops-destroy-*`, `env-destroy-*`, `account-open-applied`,
`account-close-applied`), `cluster-values.json` (mode 600), `eks-secrets.log`, `svp-cluster-chart/`, các file text của plan,
`k6-levels.tsv`, `k6-<n>/`, `restore-drill.tsv`, `restore-drill-points.tsv` và các file mẫu `restore-drill-*` của diễn tập.

**Mở lại terminal giữa buổi** (terminal đóng, máy khởi động lại): nạp lại biến (direnv đã nạp biến account khi vào repo), với
`SVP_SESSION_DIR` là **thư mục của buổi đang dở**, không phải thư mục mới. `measure.sh` đọc `cluster-values.json` của nó và tính mốc 3
giờ từ `session-start` của nó; `tf.sh` đọc các mốc gỡ (`pre-destroy-done`, `gitops-destroy-end`) trong `timeline.tsv` của nó.

```sh
cd infra
AWS_PROFILE=anhnv-sso aws --no-cli-pager sso login --region us-east-1
eval "$(aws/scripts/accounts.sh)"
ls -1d .session/*/ | tail -n 3                                                 # thư mục mới nhất là buổi đang dở
export SVP_SESSION_DIR="$PWD/.session/<thư mục đó>"
tail -n 5 "$SVP_SESSION_DIR/timeline.tsv"                                      # mốc cuối: bước nào đã xong
```

Rồi chạy tiếp từ bước sau mốc cuối (hay chạy lại bước đang dở).

### Hàm dùng chung của phép đo

Các trang phép kiểm của bước 16 dùng chung biến `E`, `ws`, `amp`, `ecr` và ba hàm `amp_get`, `promql`, `insights`. Chạy khối dưới một lần
sau bước 15, tunnel mở (mở lại terminal thì chạy lại). Credential tạm đi từ `aws configure export-credentials` qua pipe tới `curl`, không
qua đối số, file hay output; workspace, log group lấy từ root `aws/accounts/stg`, nên hàm chạy được cả khi env đã gỡ:

```sh
E=stg                                                       # buổi prd: E=prd
values=$SVP_SESSION_DIR/cluster-values.json
ecr=$(jq -r .ecrRegistry "$values")                         # chỉ (a), (b) của Nền tảng managed: cần cluster
ws=$(AWS_PROFILE="anhnv-$E" terraform -chdir="aws/accounts/$E" output -raw amp_workspace_id)
amp="https://aps-workspaces.ap-southeast-1.amazonaws.com/workspaces/$ws/"
# amp_get PATH [tuỳ chọn curl…]: GET tới API Prometheus của workspace, ký SigV4
amp_get() {
  local p=$1; shift
  AWS_PROFILE="anhnv-$E" aws --no-cli-pager configure export-credentials --format process --region ap-southeast-1 |
    jq -r '"user = \"\(.AccessKeyId):\(.SecretAccessKey)\"", "header = \"x-amz-security-token: \(.SessionToken)\""' |
    curl -sS --fail-with-body --config - --aws-sigv4 aws:amz:ap-southeast-1:aps -G "$amp$p" "$@"
}
# promql QUERY [THỜI ĐIỂM, giây Unix]: truy vấn tức thời; mỗi series một dòng, nhãn rồi giá trị
promql() {
  if [ -n "${2:-}" ]; then amp_get api/v1/query --data-urlencode "query=$1" --data-urlencode "time=$2"
  else amp_get api/v1/query --data-urlencode "query=$1"; fi |
    jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1])"' | sort
}
# insights LOG-GROUP TỪ TỚI QUERY: Logs Insights trong [TỪ, TỚI] (giây Unix); in trường, giá trị
# Lỗi API, trạng thái khác Complete, chờ quá 300 s: báo ở stderr, trả 1
insights() {
  local id st n=0
  id=$(AWS_PROFILE="anhnv-$E" aws --no-cli-pager logs start-query --log-group-names "$1" --start-time "$2" --end-time "$3" --query-string "$4" \
    --region ap-southeast-1 --query queryId --output text) || return 1
  while :; do
    st=$(AWS_PROFILE="anhnv-$E" aws --no-cli-pager logs get-query-results --query-id "$id" --region ap-southeast-1 --query status --output text) ||
      return 1
    case $st in
      Complete) break ;;
      Scheduled | Running) ;;
      *) echo "insights: query $id ended $st" >&2; return 1 ;;
    esac
    [ $((n += 1)) -lt 150 ] || { echo "insights: query $id still $st after 300 s" >&2; return 1; }
    sleep 2
  done
  AWS_PROFILE="anhnv-$E" aws --no-cli-pager logs get-query-results --query-id "$id" --region ap-southeast-1 --query 'results[][].[field,value]' --output text
}
```

## Giới hạn

- **Cả buổi 4 giờ**, từ `check-account.sh` (mốc `session-start`) tới hai lượt `sweep.sh` sạch. **Quá 3 giờ mà chưa đo xong thì bỏ phần
  đo còn lại, sang gỡ**: `measure.sh` tự bỏ bậc k6 nào sẽ kết thúc sau mốc 3 giờ (dòng `skip`). Diễn tập khôi phục (bước 17–19) chạy sau
  đo, không có mốc tự bỏ: mỗi lần chờ của `restore-drill.sh` có hạn riêng (đầu script), instance PITR sống tới khi kiểm xong (mục tiêu
  RTO ≤ 60 phút). Hết giờ thì bỏ diễn tập chưa chạy, sang bước 20; bước 25 (`cleanup`) không bao giờ bỏ: thiếu nó, `tf.sh` từ chối
  destroy root env.
- Chi phí một buổi 4 giờ: ước tính của ADR-0034 §12 cộng MSK và ElastiCache (H_k ~$0,144 mỗi giờ, O_k ~$0,06, ADR-0053 §16), cộng
  phần ADR-0055 và ADR-0056 thêm vào stg (nhóm node hệ thống on-demand, bastion SSM, KMS key, log control plane, flow log,
  CloudWatch alarm), cộng phần edge (ALB, phí theo giờ của ba web ACL, log; bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13), cộng
  phần nền tảng managed (endpoint interface, mẫu AMP, log, span: bảng tổng mỗi buổi và lúc không buổi ở [ADR-0063
  §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md#12-chi-phí-hợp-đồng-cluster-và-adr-cũ)
  và phụ lục của nó; AMG, Inspector, Security Hub, Config theo cờ của mục [Cờ chi phí của buổi](#cờ-chi-phí-của-buổi): bảng tháng
  không buổi và mỗi buổi ở [phụ lục
  ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#bảng-tháng-không-buổi)),
  cộng phần transcode (job MediaConvert của buổi, endpoint `mediaconvert`, SQS, request S3: [ADR-0066
  §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí) và mục "Chi phí"
  của phụ lục), cộng phần backup (instance `svp-stg-pitr` của diễn tập, key `uploads`, hai alarm backup, request và restore S3:
  [ADR-0067 §13](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#13-chi-phí) và bảng "Mỗi buổi" ở
  mục "Chi phí" của phụ lục; bản copy ở `svp-backup` tính theo retention, ngoài buổi); buổi đầu đo số thật ở Cost Explorer (mục
  [Kết thúc buổi](#kết-thúc-buổi)). Quên destroy 24 giờ tốn gấp ~6 lần một buổi; budget `svp-stg-monthly` của account stg và
  budget tổng của org ở management gửi email ở 50 %, 80 %, 100 %.
- MSK và ElastiCache dựng, gỡ lâu: tài liệu AWS không ghi thời gian, ADR-0053 §16 giả định MSK dựng ≤ 45, gỡ ≤ 30 phút, ElastiCache ≤
  20, ≤ 15 phút, song song với EKS trong apply của root env (buổi dài thêm ~30 phút apply, ~20 phút destroy); buổi stg đo số thật (phép
  kiểm (a) ở bước 16).
- Distribution media của stg và web ACL `svp-stg-media` nằm trong gói flat-rate Free ($0 mỗi tháng, 1 triệu request và 100 GB, không
  tính phí vượt; ADR-0052 §1). Vài phút trước khi gói có hiệu lực và sau khi huỷ lúc destroy tính pay-as-you-go. Distribution
  `svp-stg-web`, `svp-stg-api` và web ACL của chúng (ATP, Bot Control) là pay-as-you-go như prd. Web ACL sót lại tính phí theo giờ, nên
  `sweep.sh` bắt nó.
- Cert của ba tên là cert ACM (DNS validation trong zone `stg.aws.<domain>`, tự gia hạn); Envoy dùng cert của CA nội bộ cert-manager,
  chỉ ALB edge và Job k6 nói chuyện với nó.

## Cờ chi phí của buổi

Dịch vụ tốn tiền mà hệ thống không cần để chạy có cờ theo account trong file commit
[`aws/paid-features.json`](../../aws/paid-features.json); thiết kế và chi phí ở
[ADR-0071](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md); giá trị của file (rẻ nhất mà validation
cho phép ở mọi account, stg và prd như nhau, prd đổi về giá trị production chỉ cho buổi prd) ở
[ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md). Đọc cờ của stg trước bước
3 (không gọi AWS; khoá vắng là `always`). Giá trị của file là đường mặc định của buổi; phép kiểm `chuẩn ngành` cần giá trị khác thì đổi
cờ giữa hai buổi (mục [Phép kiểm lõi và chuẩn ngành](#phép-kiểm-lõi-và-chuẩn-ngành)):

```sh
jq -r '.stg // {} | to_entries[] | "\(.key) \(.value)"' aws/paid-features.json
```

Cờ đổi bước nào, phép kiểm nào của buổi:

| Cờ | Giá trị của file (mặc định) | Giá trị chọn bật | Phần của buổi đổi theo cờ |
| --- | --- | --- | --- |
| `managed_grafana` | `off`: không workspace AMG, không tham số SSM, `grafanaUrl` rỗng, không entry `svp/stg/grafana-operator`, không dashboard | `session`: bước 3–5 tạo workspace `svp-stg` và tham số SSM của nó, bước 28–29 xoá; `always`: workspace sống giữa các buổi | `off`, `always`: bước 3–5, 28–29 in `ok no session feature …`, không chạy gì; `off`: bước 11 in `skip managed_grafana of stg is off …` (không token); `session`, `always`: token Grafana Operator ở bước 11 và phép kiểm dashboard; `sweep.sh stg` coi workspace, tham số còn lại là sót khi cờ khác `always` |
| `inspector_ecr` | `off`: quét cơ bản khi push, không Inspector | `always`: Inspector quét liên tục repo cache | đoạn Inspector của [Nền tảng managed (a)](session-stg-check-managed.md#nền-tảng-managed-a-image-từ-ecr) |
| `security_hub` | `off`: không control; finding GuardDuty HIGH, CRITICAL tới email qua rule `svp-security-guardduty-findings` | `always` (cần `config_recording` `always` cùng account): control FSBP, CIS và finding ở Security Hub | [Finding bảo mật của buổi](session-stg-drills.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20), [Control Security Hub của buổi](session-stg-drills.md#control-security-hub-của-buổi) |
| `config_recording` | `off`: không recorder | `always`: recorder ghi ở hai region | không phép kiểm nào của buổi đọc Config; đi cùng `security_hub` `always` |

Không đổi cờ giữa buổi: đổi cờ theo [`paid-features.md`](paid-features.md), giữa hai buổi.

## Phép kiểm lõi và chuẩn ngành

Mỗi mục bước và phép kiểm của runbook mở bằng một dòng `Loại:`
([ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §6). `lõi` là phép chứng
minh upload, transcode, feed, phát, xác thực, triển khai qua Argo CD (cả commit status `argocd/stg` mà promote cần, Job migration của
release, image phát hành có ở ECR) và đường cảnh báo (luật ở AMP, Alertmanager tới topic SNS của env, email alarm đã xác nhận, probe
uptime và cảnh báo của chúng); bước tạo, kiểm, gỡ env; và phép đọc an toàn không tốn tiền (finding GuardDuty, trạng thái mesh, flow log,
log WAF, tag quét malware). Mọi phép khác là `chuẩn ngành`: dòng `Loại:` của nó nêu cờ cần bật và phần thêm vào buổi (thời gian, chi
phí, có nguồn).

**Đường mặc định của buổi chỉ chạy `lõi`**, với cờ của file: bước 1–15; ở bước 16 `measure.sh stg --smoke` (mục
[Smoke](session-stg-check-release.md#smoke)) thay cho `measure.sh stg`, rồi các mục `lõi` của bước 16; bỏ bước 17–19; finding bảo mật;
bước 20–31. Buổi muốn chạy thêm phép `chuẩn ngành` chọn trước buổi, đổi cờ nó cần theo [`paid-features.md`](paid-features.md) giữa hai
buổi, rồi chạy mục đó ở chỗ của nó:

| Cờ của `stg` cần | Phép kiểm `chuẩn ngành` |
| --- | --- |
| không cần cờ | [Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6) (`measure.sh stg` của bảng Thứ tự), [Bucket media không liệt kê được](session-stg-check-security.md#bucket-media-không-liệt-kê-được), [Nền tảng EKS và TLS Postgres](session-stg-check-platform.md#nền-tảng-eks-và-tls-postgres), [Service mesh: danh tính lạ bị từ chối](session-stg-check-platform.md#service-mesh-danh-tính-lạ-bị-từ-chối) (tạo rồi xoá pod trong `svp`), [Vận hành pod](session-stg-check-platform.md#vận-hành-pod-timeout-grace-zone-dlq), [Gói Free của media](session-stg-check-edge-media.md#gói-free-của-media), [Phép kiểm edge](session-stg-check-edge-media.md#phép-kiểm-edge), [edge premium](session-stg-check-edge-media.md#phép-kiểm-edge-premium), [Transcode (b)–(e)](session-stg-check-edge-media.md#transcode-be-đo-hai-đường-header-ff-9-lớp-cắt), [Kafka và Valkey managed](session-stg-check-managed.md#kafka-và-valkey-managed), [managed (b)](session-stg-check-managed.md#nền-tảng-managed-b-mạng-riêng), [(e)](session-stg-check-managed.md#nền-tảng-managed-e-dữ-liệu-còn-sau-destroy), [managed (a)](session-stg-check-managed.md#nền-tảng-managed-a-image-từ-ecr) và [(c)](session-stg-check-managed.md#nền-tảng-managed-c-telemetry) (trừ đoạn Inspector, đoạn AMG: hai dòng dưới), [Chi phí theo namespace](session-stg-check-platform.md#chi-phí-theo-namespace) (trừ đoạn dashboard), [Diễn tập khôi phục](session-stg-drills.md#1719-diễn-tập-khôi-phục) (bước 17–19) |
| không cần cờ; cần thang k6 đang giữ tải hay đã chạy, hoặc thành phần ở `svp-gitops` | [Độ trễ mesh khi giữ tải](session-stg-check-platform.md#độ-trễ-mesh-khi-giữ-tải), [Chặn quá tải và pool khi giữ tải](session-stg-check-platform.md#chặn-quá-tải-và-pool-khi-giữ-tải), [Canary và cảnh báo `page`](session-stg-check-managed.md#nền-tảng-managed-d-canary-và-cảnh-báo-page); [Trải zone và chạy thử DLQ](session-stg-check-platform.md#trải-zone-và-chạy-thử-dlq) (`dlq-replay`, `zoneSpread`), [Canary gRPC theo request](session-stg-check-platform.md#canary-grpc-theo-request) (bản phát hành gRPC có canary dưới thang k6) |
| `managed_grafana` `session` | [Dashboard SLO khi giữ tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải); đoạn dashboard của [Chi phí theo namespace](session-stg-check-platform.md#chi-phí-theo-namespace); (e) của Kafka và Valkey; đoạn AMG của [managed (c)](session-stg-check-managed.md#nền-tảng-managed-c-telemetry) |
| `inspector_ecr` `always` | đoạn Inspector của [Nền tảng managed (a)](session-stg-check-managed.md#nền-tảng-managed-a-image-từ-ecr) |
| `security_hub` và `config_recording` `always` | [Control Security Hub của buổi](session-stg-drills.md#control-security-hub-của-buổi) |

## Thứ tự

Bảng dưới là thứ tự của cả buổi; script `session.sh --print stg` in đúng chuỗi lệnh này. Mỗi bước ở trang pha của nó (bảng pha dưới bảng
bước).

| # | Lệnh | Hạn | Dán lại cho AI | Loại |
| --- | --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh stg` | 2 phút | dòng `ok account …` (account, ARN) | `lõi` |
| 2 | `aws/scripts/check-dns.sh stg` | 2 phút | ba dòng `ok` hay dòng `FAIL` | `lõi` |
| 3 | `aws/scripts/tf.sh stg account init` | 2 phút | dòng cuối | `lõi` |
| 4 | `aws/scripts/tf.sh stg account plan --open` | 5 phút | dòng `Plan: N to add, …` và đường dẫn file text của plan | `lõi` |
| 5 | `aws/scripts/tf.sh stg account apply` | 10 phút | dòng `Apply complete! …`, mốc `account-open-applied` | `lõi` |
| 6 | `aws/scripts/tf.sh stg env init` | 5 phút | dòng cuối | `lõi` |
| 7 | `aws/scripts/media-signing-key.sh stg new a` | 1 phút | dòng `ok slot a: …` và mọi dòng `warn`/`note` | `lõi` |
| 8 | `aws/scripts/tf.sh stg env plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan | `lõi` |
| 9 | `aws/scripts/tf.sh stg env apply` | 65 phút | dòng `Apply complete! …`, hai dòng `mark` và hai dòng `Creation complete after …` của `module.msk.aws_msk_cluster.this`, `module.elasticache.aws_elasticache_replication_group.this` | `lõi` |
| 10 | `aws/scripts/media-signing-key.sh stg activate a` | 2 phút | dòng `ok entry …` (không có khoá) | `lõi` |
| 11 | `aws/scripts/bootstrap.sh stg secrets` | 5 phút | mọi dòng `ok`/`FAIL` | `lõi` |
| 12 | `aws/scripts/tf.sh stg gitops init` | 2 phút | dòng cuối | `lõi` |
| 13 | `aws/scripts/tf.sh stg gitops plan` | 5 phút | dòng `ok chart svp-cluster at …`, dòng `Plan: …` và đường dẫn file text của plan | `lõi` |
| 14 | `aws/scripts/tf.sh stg gitops apply` | 15 phút | dòng `Apply complete! …`, output `bootstrap_revision` | `lõi` |
| 15 | `aws/scripts/bootstrap.sh stg wait` | 45 phút | mọi dòng `ok`/`FAIL` | `lõi` |
| 16 | `aws/scripts/measure.sh stg` | tới mốc 3 giờ | `k6-levels.tsv`, dòng `ok highest level …` | `lõi`: `measure.sh stg --smoke` (mục 16); `chuẩn ngành`: cả `measure.sh stg` (seed, thang k6) |
| 17 | `aws/scripts/restore-drill.sh stg backup` | 60 phút | mọi dòng `ok`/`FAIL`, dòng `PASS backup …` | `chuẩn ngành` |
| 18 | `aws/scripts/restore-drill.sh stg rds` | 75 phút | mọi dòng `ok`/`FAIL`, dòng `PASS rds …` hay `FAIL rds …` | `chuẩn ngành` |
| 19 | `aws/scripts/restore-drill.sh stg s3` | 30 phút | mọi dòng `ok`/`FAIL`, dòng `PASS s3 …` hay `FAIL s3 …` | `chuẩn ngành` |
| 20 | `aws/scripts/pre-destroy.sh stg` | 30 phút | mọi dòng `ok`/`FAIL`/`note` | `lõi` |
| 21 | `aws/scripts/tf.sh stg gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` | `lõi` |
| 22 | `aws/scripts/tf.sh stg gitops destroy` | 10 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` | `lõi` |
| 23 | `aws/scripts/tf.sh stg env plan --teardown` | 1 phút | dòng `skip` (stg không có bảo vệ cần nhấc) | `lõi` |
| 24 | `aws/scripts/tf.sh stg env apply --teardown` | 1 phút | dòng `skip` | `lõi` |
| 25 | `aws/scripts/restore-drill.sh stg cleanup` | 30 phút | mọi dòng `ok`/`FAIL`/`skip`, mốc `backup-drained` | `lõi` |
| 26 | `aws/scripts/tf.sh stg env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan | `lõi` |
| 27 | `aws/scripts/tf.sh stg env destroy` | 50 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster MSK, replication group ElastiCache | `lõi` |
| 28 | `aws/scripts/tf.sh stg account plan --close` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan | `lõi` |
| 29 | `aws/scripts/tf.sh stg account apply` | 10 phút | dòng `Apply complete! …`, mốc `account-close-applied` | `lõi` |
| 30 | `aws/scripts/sweep.sh stg` | 5 phút | toàn bộ output | `lõi` |
| 31 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output | `lõi` |

Bước tay chen giữa các bước script: đọc [Cờ chi phí của buổi](#cờ-chi-phí-của-buổi) trước bước 3, xác nhận email của alarm sau bước 9
([Alarm tới email](session-stg-check-security.md#alarm-tới-email)), [Tunnel tới
API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11) sau bước 9 và trước bước 11, [Làm nóng
cache](session-stg-deploy.md#làm-nóng-cache-sau-bước-11-trước-bước-12) sau bước 11 và trước bước 12, sinh clip của [Transcode
(b)–(e)](session-stg-check-edge-media.md#phép-kiểm-transcode) trong lúc chờ bước 9, phép kiểm của bước 16 (năm trang
`session-stg-check-<nhóm>.md`, bảng dưới; giờ chạy của từng phép ở "Điều kiện trước" của trang), [đọc bản
copy](session-stg-drills.md#1719-diễn-tập-khôi-phục) sau bước 17, [finding bảo
mật](session-stg-drills.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20) trước bước 20, chạy lại truy vấn dữ liệu sau bước 31 ([Kết
thúc buổi](#kết-thúc-buổi), khi buổi đã ghi nó).

Dự trù: apply root env xong ~T+70 phút (MSK là phần dài nhất), mọi Application Healthy ~T+1 giờ 55, đo tới muộn nhất T+3 giờ, gỡ và quét
xong trước T+4 giờ khi gỡ đúng số giả định của ADR-0053 §16; buổi stg đầu tiên đo hai mốc đó và ghi vào phụ lục của ADR. Hạn của bước
17–19, 25 là ước (AWS không công bố thời gian của job backup, copy hay restore); buổi stg đầu đo số thật (`t0`, `t1` của
`restore-drill.tsv`, mốc `backup-drained`) và ghi vào phụ lục ADR-0067. Không đi tiếp qua một bước đỏ ([Khi một bước
đỏ](#khi-một-bước-đỏ)), trừ bước 16 (đo): đo hỏng thì vẫn sang bước 17; và bước 18, 19 khi dòng kết quả là `FAIL` của phép đo (mục
**17–19**): đó là số đo, sang bước kế. Bước 23, 24 không làm gì ở stg (không có `teardown.tfvars`); chúng nằm trong bảng để stg và prd
chạy cùng một chuỗi bước. Bước 3–5 và 28–29 chỉ làm việc khi cờ `managed_grafana` của env là `session` (mục **Cờ chi phí của buổi**). Với
giá trị của file (`off`) chúng in `ok no session feature …`, và ở prd cũng vậy: trước buổi prd khoá `prd` đã xoá khỏi file (điều kiện 12
của [`session-prd.md`](session-prd.md#điều-kiện-trước)) nên không cờ nào của prd là `session`.

Các trang của buổi, theo thứ tự làm:

| Pha | Trang | Bước |
| --- | --- | --- |
| Điều kiện, terminal, cờ, bảng bước | trang này | trước bước 1 |
| Dựng env, Argo CD, chờ healthy | [`session-stg-deploy.md`](session-stg-deploy.md) | 1–15, Tunnel tới API, Làm nóng cache |
| Đo: release (smoke, seed, thang k6, dashboard SLO, commit status, migration, xác thực qua CloudFront, image `dlq-replay`) | [`session-stg-check-release.md`](session-stg-check-release.md) | 16 |
| Đo: nền tảng (EKS, TLS Postgres, mesh, độ trễ mesh, chi phí theo namespace, vận hành pod, trải zone, chặn quá tải, canary gRPC) | [`session-stg-check-platform.md`](session-stg-check-platform.md) | 16 |
| Đo: bảo mật (bucket media, bảo vệ của account, alarm tới email) | [`session-stg-check-security.md`](session-stg-check-security.md) | 16 |
| Đo: edge và media (gói Free, phát video, edge, edge premium, uptime, transcode) | [`session-stg-check-edge-media.md`](session-stg-check-edge-media.md) | 16 |
| Đo: dịch vụ managed (Kafka và Valkey, nền tảng managed (a)–(e)) | [`session-stg-check-managed.md`](session-stg-check-managed.md) | 16 |
| Diễn tập khôi phục, finding bảo mật | [`session-stg-drills.md`](session-stg-drills.md) | 17–19, Finding bảo mật của buổi |
| Gỡ, quét sót | [`session-stg-teardown.md`](session-stg-teardown.md) | 20–31 |
| Gỡ kẹt, xoá tay, đổi secret, kết thúc | trang này | Destroy kẹt, Lệnh xoá tay theo loại, Đổi một secret, Kết thúc buổi |

### 16. Đo

Loại: `lõi`. Đường mặc định chạy `measure.sh stg --smoke` ([Smoke](session-stg-check-release.md#smoke)) rồi các mục `lõi` của năm trang
phép kiểm ở bảng trên; `measure.sh stg` của bảng Thứ tự (smoke, seed, thang k6 trong một lượt) chỉ chạy khi buổi bật thang đo
([Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6)). Ghi kết quả từng phép vào một file trong `$SVP_SESSION_DIR` để điền
cột Kết quả của mục "Kiểm chứng sau" của ADR-0034 và ADR-0048.

## Destroy kẹt

"Destroy lại" ở bảng dưới là `aws/scripts/tf.sh stg env plan --destroy` (plan mới từ state hiện tại), đọc file text, rồi
`aws/scripts/tf.sh stg env destroy`; với root gitops cũng vậy, thay `env` bằng `gitops` (thêm `--leftovers` nếu lần trước đã dùng nó).

| Triệu chứng | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `FAIL the backups of stg are not drained …` ở `plan --destroy` hay `destroy` | một apply hay diễn tập chạy sau `cleanup` cuối (mốc cuối không phải `backup-drained`) | bước 25, rồi `plan --destroy` lại |
| `DependencyViolation` khi xoá subnet, security group hay VPC | ENI còn gắn: ENI phụ của VPC CNI (`aws-K8S-<instance>`, `available` sau khi node mất), hay ENI của load balancer mà bước 20 chưa gỡ | `sweep.sh stg` liệt kê ENI theo VPC; ENI `available`: xoá ENI; ENI của load balancer: xoá load balancer (ENI tự mất), rồi destroy lại |
| `DependencyViolation` khi xoá subnet edge hay VPC, sau khi VPC origin đã xoá | ENI của CloudFront trong subnet edge hay security group `CloudFront-VPCOrigins-Service-SG` chưa được dịch vụ gỡ (ngoài state; tài liệu VPC origins không nói sau bao lâu) | đọc lại `sweep.sh stg` mỗi 5 phút tới khi không còn ENI trong subnet edge, rồi destroy lại; còn security group khi không còn VPC origin nào: xoá nó (lệnh ở **Lệnh xoá tay theo loại**); không xoá ENI của dịch vụ bằng tay |
| `CannotDeleteEntityWhileInUse` khi xoá VPC origin | distribution còn dùng nó (destroy dở ở distribution) | destroy lại sau khi distribution đã xoá (Terraform chờ tiếp) |
| ALB `svp-<env>-edge` báo deletion protection | prd: chưa áp `teardown.tfvars` (`edge_alb_deletion_protection = false`) | bước 23, 24, 25, rồi destroy lại; state mất: tắt bằng tay (lệnh ở **Lệnh xoá tay theo loại**) |
| `ResourceInUseException` khi xoá cert ACM | distribution hay listener ALB còn dùng nó | destroy lại sau khi distribution, listener đã xoá |
| Destroy đỏ ở `aws_cloudfront_distribution`, hay `delete-distribution` bị từ chối, vì distribution còn gói flat-rate | gói không nằm trong state (destroy dở, state mất, gói tạo ở console) nên Terraform không huỷ nó trước; hay gói vừa huỷ còn đang đồng bộ (provider huỷ gói rồi trả về ngay, không chờ) | huỷ gói theo mục CloudFront của **Lệnh xoá tay theo loại**, chờ `list-subscriptions` không còn ARN đó, rồi destroy lại |
| Destroy chờ lâu hay quá hạn ở `aws_cloudfront_distribution` | Terraform phải tắt distribution và chờ `Deployed` (vài phút tới ~15 phút) trước khi xoá | destroy lại (Terraform chờ tiếp); vẫn kẹt thì tắt và xoá tay (lệnh dưới) |
| `BucketNotEmpty` | stg đặt `media_force_destroy = true` nên không nên gặp; object ghi giữa lúc destroy | destroy lại; còn thì xoá tay (lệnh dưới) |
| RDS báo deletion protection | `rds_deletion_protection` của `stg.tfvars` phải `false` (prd: `teardown.tfvars`) | sửa biến, `tf.sh stg env plan`, `apply`, bước 25, rồi destroy lại |
| Node group `system` xoá lâu | node drain | chờ tới hạn bước 27 |
| Destroy đỏ ở `aws_media_convert_queue` (`ConflictException`, queue còn job) | job `SUBMITTED`, `PROGRESSING` còn trên queue: bước 20 bị bỏ (`--leftovers`) hay job tạo sau nó | huỷ job theo mục MediaConvert của **Lệnh xoá tay theo loại**, rồi destroy lại |
| `DependencyViolation` khi xoá subnet hay security group node, sau `--leftovers` | instance của Karpenter còn chạy (ENI của nó trong subnet private) | `sweep.sh stg` liệt kê nó với lệnh `terminate-instances`; chờ instance `terminated`, rồi destroy lại |
| `DeleteConflict` khi xoá role `svp-stg-karpenter-node` | instance profile do Karpenter tạo (ngoài state) còn giữ role | lệnh `delete:` của dòng `IAM instance profiles of Karpenter` trong `sweep.sh stg`, rồi destroy lại |
| `DependencyViolation` khi xoá subnet database hay security group của MSK, ElastiCache | ENI của broker MSK hay node ElastiCache còn trong subnet: cluster, replication group đang xoá (destroy quá hạn của provider trong khi AWS vẫn gỡ) | chờ `sweep.sh stg` không còn dòng `MSK clusters`, `ElastiCache replication groups` (đọc lại mỗi 5 phút), rồi destroy lại; không xoá ENI của dịch vụ managed bằng tay |
| Destroy đỏ ở `aws_msk_configuration` (`BadRequestException`, configuration đang được dùng) | cluster còn `DELETING` | như dòng trên: chờ cluster mất, destroy lại |
| Destroy root gitops kẹt ở namespace `Terminating` | Application còn finalizer mà Argo CD đã gỡ (sau `--leftovers`) | `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd patch applications.argoproj.io <tên> --type merge -p '{"metadata":{"finalizers":null}}'` từng cái còn lại, rồi destroy lại |

## Lệnh xoá tay theo loại

`sweep.sh` in lệnh xoá dưới từng tài nguyên sót. Mục này cho loại mà một lệnh không đủ, và cho thu hồi rule security group. Mọi lệnh ghi;
người học chạy sau khi `check-account.sh stg` đúng account, thay `<…>` bằng id `sweep.sh` in ra. Ưu tiên destroy lại cho thứ Terraform
quản (VPC, NAT, EIP, EKS, RDS, MSK, ElastiCache, bucket, gói, CloudFront, VPC origin, ALB, cert ACM, web ACL, queue MediaConvert); lệnh
tay cho thứ ngoài state hay khi state mất. Tài nguyên sót ở management (lượt `sweep.sh mgmt`): cùng lệnh với `AWS_PROFILE=anhnv-sso`.

Security group: rule nơi khác tham chiếu nó, thu hồi từng rule, rồi xoá:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 describe-security-group-rules --region ap-southeast-1 --output text \
  --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='<sg-…>'].[GroupId,SecurityGroupRuleId,IsEgress]"
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 revoke-security-group-ingress --group-id <GroupId> --security-group-rule-ids <sgr-…> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 delete-security-group --group-id <sg-…> --region ap-southeast-1
```

Bucket (khi state mất): bucket không versioning xoá mọi object rồi bucket bằng một lệnh; bucket có versioning (`media` của prd) phải xoá
mọi version và delete marker trước (từng lô 1 000, lặp tới khi rỗng):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3 rb s3://<svp-stg-…> --force --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-object-versions --bucket <svp-…> --max-items 1000 --region ap-southeast-1 --output json |
  jq '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}' > /tmp/svp-versions.json
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api delete-objects --bucket <svp-…> --delete file:///tmp/svp-versions.json --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api delete-bucket --bucket <svp-…> --region ap-southeast-1
```

CloudFront, theo thứ tự: huỷ gói flat-rate trước (AWS không tắt gói khỏi distribution, không xoá distribution còn gói), rồi tắt
distribution, chờ `Deployed`, xoá; OAC, response headers policy tự viết, key group media rồi public key của nó (khi `sweep.sh` liệt kê)
xoá sau distribution, cũng bằng `ETag`; web ACL sau cùng (khối dưới). Huỷ gói: `--if-match` là `eTag` của `get-subscription`:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status,resourceArns]' --output json
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager get-subscription --arn <arn> --region us-east-1 --query eTag --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager cancel-subscription --arn <arn> --if-match <eTag trên> --region us-east-1 --query '[subscription.status,subscription.scheduledChange.changeType]' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].arn' --output text
```

Lệnh cuối không còn in ARN đó thì gói đã gỡ (gói Free huỷ ngay; `get-subscription` của ARN đã gỡ trả lỗi, không phải rỗng). Còn in: chờ
một phút rồi đọc lại; **không tắt, không xoá distribution khi gói còn**. Gói có `scheduledChange.changeType` `CANCELLATION` (gói trả
phí, huỷ theo lịch) chỉ gỡ ở `effectiveDate` của nó; tới đó distribution ở yên. Rồi distribution:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-distribution-config --id <E…> --region ap-southeast-1 --output json > /tmp/svp-cf.json
jq '.DistributionConfig | .Enabled = false' /tmp/svp-cf.json > /tmp/svp-cf-off.json
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront update-distribution --id <E…> --if-match "$(jq -r .ETag /tmp/svp-cf.json)" \
  --distribution-config file:///tmp/svp-cf-off.json --region ap-southeast-1 >/dev/null
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront wait distribution-deployed --id <E…> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-distribution --id <E…> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-distribution --id <E…> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-origin-access-control --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-origin-access-control --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-response-headers-policy --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-response-headers-policy --id <id> --query ETag --output text --region ap-southeast-1)"
```

Key group `svp-stg-media` (sau distribution media, behavior mặc định của nó tin key group), rồi từng public key `svp-stg-media-*` (AWS
từ chối xoá public key còn trong key group); `--if-match` là `ETag` của `get-key-group`, `get-public-key`:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-key-group --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-key-group --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-public-key --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-public-key --id <id> --query ETag --output text --region ap-southeast-1)"
```

VPC origin (sau mọi distribution dùng nó; `--if-match` là `ETag` của `get-vpc-origin`), rồi, khi `sweep.sh` không còn liệt kê VPC origin
nào, security group `CloudFront-VPCOrigins-Service-SG` mà CloudFront để lại (thu hồi rule tham chiếu nó trước như khối security group ở
trên):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront delete-vpc-origin --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront get-vpc-origin --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudfront list-vpc-origins --region ap-southeast-1 --query 'VpcOriginList.Items[].[Id,Name,Status]' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 delete-security-group --group-id <sg-…> --region ap-southeast-1
```

ALB edge của prd còn deletion protection (state mất, chưa áp `teardown.tfvars`): kiểm account prd, tắt rồi xoá bằng lệnh `delete:` của
`sweep.sh prd`:

```sh
aws/scripts/check-account.sh prd
AWS_PROFILE=anhnv-prd aws --no-cli-pager elbv2 modify-load-balancer-attributes --load-balancer-arn <arn> --region ap-southeast-1 \
  --attributes Key=deletion_protection.enabled,Value=false --query 'Attributes[?Key==`deletion_protection.enabled`].Value' --output text
```

Web ACL WAF của CloudFront (cả hai env; prd với `AWS_PROFILE=anhnv-prd`, `check-account.sh prd`, tên `svp-prd-…`): scope `CLOUDFRONT`
nằm ở `us-east-1`; xoá sau khi gói đã huỷ và distribution không còn dùng nó, bằng lock token hiện tại. Web ACL sót lại sau khi gói huỷ
tính pay-as-you-go theo giờ:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager wafv2 get-web-acl --scope CLOUDFRONT --name <svp-stg-…> --id <id> --region us-east-1 --query LockToken --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager wafv2 delete-web-acl --scope CLOUDFRONT --name <svp-stg-…> --id <id> --lock-token <token> --region us-east-1
```

MSK (khi state mất), theo thứ tự: cluster (gỡ ENI của broker trong subnet database), chờ nó biến mất khỏi danh sách, rồi configuration
(AWS từ chối xoá configuration khi cluster còn dùng nó), rồi secret SCRAM và KMS key của module (mục dưới):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager kafka delete-cluster --cluster-arn <arn cluster> --region ap-southeast-1 --query State --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --query 'ClusterInfoList[].[ClusterName,State]' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager kafka delete-configuration --arn <arn configuration> --region ap-southeast-1 --query State --output text
```

Lệnh thứ ba in `svp-stg DELETING` trong lúc gỡ (≤ 30 phút, giả định của ADR-0053 §16); đọc lại tới khi không in gì, rồi lệnh cuối.

ElastiCache (khi state mất), theo thứ tự AWS cho xoá: replication group (chờ xoá xong), user group, từng user `svp-stg-*` (không bao giờ
`default`), subnet group, parameter group:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache delete-replication-group --replication-group-id svp-stg --region ap-southeast-1 --query ReplicationGroup.Status --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache wait replication-group-deleted --replication-group-id svp-stg --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache delete-user-group --user-group-id svp-stg --region ap-southeast-1 --query Status --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache describe-user-groups --region ap-southeast-1 --query "UserGroups[?UserGroupId=='svp-stg'].Status" --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache delete-user --user-id <svp-stg-…> --region ap-southeast-1 --query Status --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache delete-cache-subnet-group --cache-subnet-group-name svp-stg --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache delete-cache-parameter-group --cache-parameter-group-name <svp-stg-valkey9> --region ap-southeast-1
```

User group `deleting` chặn xoá user của nó: đọc lại (lệnh thứ năm) tới khi không in gì, rồi xoá từng user `sweep.sh` liệt kê.

Secret SCRAM `AmazonMSK_svp-stg-*` (module tạo với `recovery_window_in_days = 0`, nên chỉ sót khi state mất) xoá bằng lệnh `delete:` của
`sweep.sh` (`--force-delete-without-recovery`). KMS key của module MSK (alias `alias/svp-stg-msk-scram`) mà `sweep.sh` in `Enabled` (không
phải `pending deletion`): lên lịch xoá, sớm nhất 7 ngày, rồi xoá alias của nó. Key ở `PendingDeletion` không tính tiền, `sweep.sh` không
đếm nó; alias thì vẫn giữ tên tới khi bị xoá, nên buổi sau tạo lại alias đó lỗi `AlreadyExists` tới hết 7 ngày: `sweep.sh` đếm alias còn
trỏ key `PendingDeletion` (mục `KMS aliases on keys pending deletion`, lệnh `delete:` là lệnh thứ hai dưới đây):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager kms schedule-key-deletion --key-id <key id> --pending-window-in-days 7 --region ap-southeast-1 --query KeyState --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager kms delete-alias --alias-name alias/svp-stg-msk-scram --region ap-southeast-1
```

Bản ghi sót của zone `stg.aws.<domain>` (alias A, AAAA của ba tên và CNAME validation ACM của root env khi state mất): không tính tiền
nhưng chặn việc xoá zone sau này, và apply của buổi sau đỏ khi tạo lại bản ghi cùng tên. Dựng lô xoá từ chính bản ghi, đọc lại, rồi gửi:

```sh
zone=stg.aws.<domain>; zone_id=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
AWS_PROFILE=anhnv-stg aws --no-cli-pager route53 list-resource-record-sets --hosted-zone-id "$zone_id" --region ap-southeast-1 --output json |
  jq --arg apex "$zone." '{Changes: [.ResourceRecordSets[]
    | select(((.Name == $apex and (.Type == "SOA" or .Type == "CAA")) or (.Type == "NS" and (.Name == $apex or (.Name | endswith("." + $apex))))) | not)
    | {Action: "DELETE", ResourceRecordSet: .}]}' > /tmp/svp-records.json
jq -r '.Changes[].ResourceRecordSet | "\(.Name) \(.Type)"' /tmp/svp-records.json      # chỉ bản ghi sót, không NS/SOA/CAA ở đỉnh, không NS uỷ quyền bên dưới
AWS_PROFILE=anhnv-stg aws --no-cli-pager route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch file:///tmp/svp-records.json --region ap-southeast-1
```

Bản ghi `NS` dưới đỉnh là uỷ quyền do baseline tạo (ở zone prd: `stg.aws.<domain>.`) và `CAA` ở đỉnh, phải giữ: khối trên bỏ qua chúng.
Ở zone prd dùng cùng khối với `AWS_PROFILE=anhnv-prd`, `zone=aws.<domain>`, `aws/accounts/prd`. Management không có zone nên lượt `mgmt`
không có bản ghi nào để xoá.

MediaConvert (khi state mất, hay queue còn job): huỷ mọi job dở của queue `svp-stg`, đọc lại tới khi hai lệnh `list-jobs` không in gì,
rồi xoá queue. Phần còn lại của transcode xoá bằng lệnh `delete:` của `sweep.sh stg`, theo thứ tự nó in: hai hàng đợi SQS, đích rồi rule
EventBridge `svp-stg-mediaconvert-job-state`, alarm, policy inline rồi role `svp-stg-mediaconvert` (IAM ở `us-east-1`):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert list-jobs --queue svp-stg --status SUBMITTED --region ap-southeast-1 --query 'Jobs[].Id' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert list-jobs --queue svp-stg --status PROGRESSING --region ap-southeast-1 --query 'Jobs[].Id' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert cancel-job --id <id> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert delete-queue --name svp-stg --region ap-southeast-1
```

AWS Backup plans (loại `AWS Backup plans` của `sweep.sh`): chỉ plan cục bộ `svp-probe*` của thử sandbox ở management (lượt `sweep.sh
mgmt`, `AWS_PROFILE=anhnv-sso`, `check-account.sh mgmt`). AWS từ chối xoá plan còn selection: xoá từng selection, rồi plan. Không xoá
plan `svp-stg`, `svp-prd`: Backup policy của `aws/org` sinh chúng, account không xoá được.

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws --no-cli-pager backup list-backup-selections --backup-plan-id <BackupPlanId> --region ap-southeast-1 \
  --query 'BackupSelectionsList[].[SelectionId,SelectionName]' --output text
AWS_PROFILE=anhnv-sso aws --no-cli-pager backup delete-backup-selection --backup-plan-id <BackupPlanId> --selection-id <SelectionId> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws --no-cli-pager backup delete-backup-plan --backup-plan-id <BackupPlanId> --region ap-southeast-1 --query DeletionDate --output text
```

Loại AWS Backup khác có lệnh `delete:` đủ dưới mỗi dòng của `sweep.sh`, theo thứ tự nó in: job (dừng backup job; copy, restore job thì
chờ), recovery point, vault lock (governance: account gỡ được), vault, policy rồi role `svp-*-backup`. Vault không xoá được khi còn
recovery point hay copy job đang ghi vào nó: xoá recovery point trước, chờ job xong.

Luật và Alertmanager của AMP sót (dòng `note left in AMP: …` của `pre-destroy.sh`, hay `AMP rule groups namespaces` của `sweep.sh`): xoá
bằng lệnh dòng đó in, rồi đọc lại tới khi rỗng; workspace thì giữ (`kept`):

```sh
aws/scripts/check-account.sh stg
ws=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw amp_workspace_id)
AWS_PROFILE=anhnv-stg aws --no-cli-pager amp delete-rule-groups-namespace --workspace-id "$ws" --name <tên> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager amp delete-alert-manager-definition --workspace-id "$ws" --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager amp list-rule-groups-namespaces --workspace-id "$ws" --region ap-southeast-1 --query 'ruleGroupsNamespaces[].name' --output text
```

Policy tạm `svp-session-deny-query` của phép kiểm canary (mục Phép kiểm nền tảng managed (d)) còn trên role `svp-stg-argo-rollouts`: gỡ
trước destroy của root env (lệnh `delete-role-policy` của mục đó): Terraform không biết policy này, nên destroy có thể đỏ ở role đó
(`DeleteConflict`).

Role CI `svp-ci-*` hay IAM OIDC provider mà `sweep.sh` in là sót (không `kept`: account không còn giữ `Stack=baseline`, tức
`aws/accounts/<env>` đã gỡ dở): Terraform của root đó là đường chính (mục "Gỡ baseline" của
[`lab-teardown.md`](lab-teardown.md#awsaccountsenv)); khi state mất, gỡ mọi policy inline của role rồi xoá role:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam list-role-policies --role-name <svp-ci-…> --region us-east-1 --query PolicyNames --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam delete-role-policy --role-name <svp-ci-…> --policy-name <từng tên trên> --region us-east-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam delete-role --role-name <svp-ci-…> --region us-east-1
```

**Secret Secrets Manager đang chờ xoá** (dòng `scheduled for deletion since …`): vẫn giữ tên tới hết thời gian chờ (7–30 ngày), nên
**chặn tạo lại secret cùng tên** ở buổi sau (entry `svp/stg/*` do Terraform tạo với `recovery_window_in_days = 0` nên xoá ngay; dòng này
là secret tạo cách khác). Secret master của RDS mang tên sinh ngẫu nhiên (`rds!db-<uuid>`), không chặn buổi sau, nhưng `sweep.sh` vẫn
đếm nó tới khi mất. Lệnh `delete:` của `sweep.sh` xoá hẳn ngay (không khôi phục được); muốn lấy lại để dùng tiếp:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager secretsmanager restore-secret --secret-id <name> --region ap-southeast-1
```

## Đổi một secret của env đang chạy

Hai nguồn, hai đường: mật khẩu Kafka và Valkey do Terraform sinh (entry `kafka-admin`, `kafka-users`, `valkey-users`); mọi entry khác từ
`.env` của repo code. Cả hai kết thúc bằng cùng một lệnh, `bootstrap.sh stg secrets`, chạy `make eks-secrets` (đọc lại mật khẩu master
RDS như bước 11), làm trọn một lượt xoay theo thứ tự của `make k8s-secrets` trên k3d, người học không sync, không restart tay:

1. ghi lại các entry từ `.env` (trừ ba entry của Terraform và `glitchtip-runtime`, đã có giá trị);
2. dựng lại (force-sync) các ExternalSecret của `svp-data` (`kafka-admin`, `svp-ops`, `pg-*`) từ entry;
3. một sync của Application `svp-data`, chờ đúng lượt đó `Succeeded`: Job `pg-bootstrap` đặt mật khẩu mới trong Postgres, Job
   `kafka-init` đăng nhập MSK bằng `svp-admin` với mật khẩu của entry (thử lại ít nhất 10 phút) và đặt lại topic, ACL;
4. dựng lại mọi ExternalSecret còn lại (`svp/<service>-env` có `KAFKA_SASL_PASSWORD`, `REDIS_URL`; `keda/keda-kafka`;
   `svp-obs/otelcol-kafka`); Reloader restart workload có Secret đổi (Rollout `gateway`, `web` không có revision mới nên không thành
   canary).

**Mật khẩu từ `.env`** (Postgres của service, khoá API…): sửa `.env` của repo code, rồi `aws/scripts/bootstrap.sh stg secrets`.

**Mật khẩu Kafka hay Valkey** (ADR-0053 §12): tăng version write-only của nhóm đó trong `aws/envs/stg/stg.auto.tfvars` (git bỏ qua; giữ
giá trị mới tới hết buổi và các buổi sau: apply với version khác lại sinh mật khẩu mới), plan, đọc, apply, rồi một lượt như trên. Mỗi
version đổi mọi user của nhóm cùng lúc (một entry chung). `tfvars.sh bump` tăng đúng dòng `msk_password_version` (Kafka) hay
`valkey_password_version` (Valkey) thêm 1; file chưa có dòng của nhóm thì version đang dùng là mặc định của biến (1) và script ghi dòng
mới bằng mặc định cộng 1, không nối dòng thứ hai cùng tên (Terraform từ chối file có một biến hai lần, `Attribute redefined`, ngay ở
plan). Các dòng khác của file giữ nguyên:

```sh
aws/scripts/tfvars.sh bump stg msk            # or valkey
aws/scripts/tf.sh stg env plan
aws/scripts/tf.sh stg env apply
aws/scripts/bootstrap.sh stg secrets
```

`tfvars.sh bump` in `ok    aws/envs/stg/stg.auto.tfvars: msk_password_version from N to N+1 written (… lines, mode 600)`; `FAIL  … is not
a whole number: fix it by hand; file unchanged` là dòng bị sửa tay thành giá trị khác số, script không đoán.

Plan chỉ đổi phiên bản của secret, `aws_secretsmanager_secret_version` (mọi secret `AmazonMSK_*` và hai entry `kafka-*`, hay entry
`valkey-users`), và với Valkey bốn `aws_elasticache_user` tại chỗ; thấy cluster MSK, replication group, user group hay chính secret bị
`replace`, `destroy`: dừng, dán plan cho AI. Kafka: chờ 10 phút giữa `apply` và `bootstrap.sh` (MSK đồng bộ secret SCRAM tới broker
trong tối đa 10 phút; Job `kafka-init` của bước 3 là chốt, nó chỉ xanh khi broker nhận mật khẩu mới). Valkey: ElastiCache đổi mật khẩu
của user ngay khi apply xong, nên chạy `bootstrap.sh` ngay; tới khi Reloader restart xong, kết nối mới của pod còn mật khẩu cũ bị từ
chối (kết nối đang mở vẫn chạy): ADR-0053 chấp nhận khoảng này.

Tìm trong output và `$SVP_SESSION_DIR/eks-secrets.log`, theo thứ tự:

- `ok    entries of svp/stg/ written: … kafka-admin kafka-users valkey-users left to the infrastructure repository`;
- `ok    ExternalSecrets of the server built again from their source: …`;
- `ok    init Jobs of svp-data done (sync of Application svp-data Succeeded): the servers take the new passwords`;
- `ok    ExternalSecrets of the clients built again from their source: …`;
- `ok    Reloader restarts each workload whose Secret changed …`.

Một dòng `FAIL` thì không bước nào sau nó chạy:

- `FAIL  cluster svp-stg is not ready for a change of credentials: <lý do>`: cluster chưa có Reloader chạy, không gì bị ghi; sync
  Application `svp-apps` tới revision có nó;
- `FAIL  sync of Application argocd/svp-data …`: xem Job lỗi (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data get jobs`,
  `… logs job/kafka-init`); Job `kafka-init` lỗi đăng nhập ngay sau khi đổi mật khẩu Kafka là MSK chưa đồng bộ: chờ rồi chạy lại. Secret của
  client chưa đổi.

Sửa nguyên nhân rồi chạy lại đúng `aws/scripts/bootstrap.sh stg secrets`: lượt nào cũng làm đủ các bước, gồm Job init còn thiếu của lượt
trước. Theo dõi restart:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get pods -A -w
```

Không sửa entry hay Secret bằng tay, không ghi mật khẩu Kafka, Valkey vào entry bằng `put-secret-value`: Terraform là nơi duy nhất ghi
ba entry đó cùng secret SCRAM và user ElastiCache, ghi tay làm hai bên lệch. Chi tiết: `docs/reference/eks.md` của repo code, mục "Đổi
secret của env đang chạy".

## Kết thúc buổi

1. Thứ tự gỡ, mỗi bước xong mới sang bước sau: destroy root `aws/gitops/stg`, xoá backup của buổi, destroy `aws/envs/stg`, rồi đóng tính
   năng của buổi ở `aws/accounts/stg` (bước 21–29); `sweep.sh stg`; `sweep.sh mgmt`. Hai lượt cùng exit 0 (dán output cho AI). AI nhắc
   tới khi người học xác nhận đã chạy cả hai destroy và hai lượt sweep. Phép kiểm sau đây đọc kết quả của chính hai lượt sweep đó
   (`lõi`, cùng bước 30–31), trừ chỗ ghi `chuẩn ngành`. Phép kiểm (e) của ADR-0052 (output vào phụ lục của nó, kết luận vào "Xác nhận"):
   sau destroy, gói của account rỗng (mong `[]`), cùng lượt `sweep.sh stg` sạch:

   ```sh
   AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

   Phép kiểm (f) của ADR-0053 là cùng hai lượt sweep sạch: không còn dòng MSK, ElastiCache, `AmazonMSK_*` nào; KMS key của root
   env chỉ ở `pending deletion`. Phép kiểm `pre-destroy.sh` của ADR-0056: cùng lượt đó không còn instance, launch template,
   instance profile, hàng đợi SQS hay rule EventBridge nào của Karpenter. Phép kiểm gỡ của ADR-0066: cùng lượt đó không còn queue
   `svp-stg`, role `svp-stg-mediaconvert`, hàng đợi `svp-stg-transcode-events*`, rule `svp-stg-mediaconvert-job-state`, endpoint
   `svp-stg-mediaconvert`. Phép kiểm gỡ của ADR-0067: cùng lượt đó không còn recovery point, job AWS Backup chưa kết thúc hay
   instance `svp-stg-pitr`; vault `svp-stg`, role `svp-stg-backup` là `kept`; buổi đã chạy bước 17 (`chuẩn ngành`): bản copy của
   buổi vẫn ở `svp-stg-copy` (lệnh **Đọc bản copy** của mục [17–19](session-stg-drills.md#1719-diễn-tập-khôi-phục), mong cùng ba
   dòng). Phép kiểm gỡ của ADR-0073: cùng lượt đó không còn key group `svp-stg-media`, public key `svp-stg-media-*`, entry
   `svp/stg/media-signing`. Ngày sau buổi (`chuẩn ngành`, không cần cờ), tổng MediaConvert của ngày buổi ở Cost Explorer (lệnh ở
   mục "Chi phí mỗi phút video" của [phụ lục
   ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md#chi-phí-mỗi-phút-video)),
   đối chiếu với tổng tính theo output của mọi job trong `mediaconvert-jobs.json` (lượt cuối của mục [Phép kiểm
   transcode](session-stg-check-edge-media.md#transcode-f-hàng-đợi-rỗng) (f)) mà video có bản ghi ở
   `$SVP_SESSION_DIR/transcode-jobs/`, job lạc gồm; dán output. Buổi đã ghi truy vấn dữ liệu trước bước 20 (`chuẩn ngành`, mục
   [Nền tảng managed (e)](session-stg-check-managed.md#nền-tảng-managed-e-dữ-liệu-còn-sau-destroy)): chạy lại nó cùng ngày
   (`after-destroy.txt`); dán `diff`. Buổi đầu có span của account: retention của `aws/spans` theo bước (10) của
   [`platform-setup.md`](platform-setup.md#bước-10-retention-của-awsspans).
2. Cái ở lại giữa các buổi: ở account stg là baseline (`Stack=baseline`: bucket state, KMS key state, zone `stg.aws.<domain>` với `CAA`;
   registry ECR cùng repo phát hành, rule và repo của pull-through cache, OIDC provider, role CI; workspace AMP, log group
   `/svp/stg/otel`, Transaction Search của X-Ray cùng `aws/spans`, workspace AMG khi cờ `managed_grafana` là `always`, hai key KMS của
   chúng; vault `svp-stg` rỗng, key `alias/svp-stg-backup`, role `svp-stg-backup`, opt-in của AWS Backup) và baseline bảo mật
   (`Stack=security-baseline`: CMK EBS `alias/svp-ebs`; recorder Config khi cờ `config_recording` là `always`, rule `svp-security-*`,
   không phải tài nguyên `sweep.sh` liệt kê); ở account prd là hai baseline của nó, gồm zone `aws.<domain>` với `CAA`, bản ghi `NS` uỷ
   quyền `stg.aws.<domain>`, DNSSEC, query log và topic alarm DNSSEC (`sweep.sh` in chúng là `kept`); ở account Log Archive, bucket log
   CloudFront và delivery destination; ở account `svp-backup`, vault `svp-stg-copy` với bản copy của buổi tới hết retention (root
   `aws/backup`); plan `svp-stg` của Backup policy; management chỉ còn `Stack=bootstrap|org|security-baseline|security`, không hosted
   zone. `destroy` của hai root env không đụng zone nào (zone thuộc root `aws/accounts/<env>`) và không đụng baseline bảo mật (root
   `aws/baseline`).
3. Giữ `$SVP_SESSION_DIR` (máy local, không commit): `timeline.tsv`, `k6-levels.tsv`, `k6-<n>/` là số đo cho cột Kết quả của ADR-0034
   "Kiểm chứng sau" và roadmap; `restore-drill.tsv` là số đo RTO/RPO cho phụ lục ADR-0067; `controls-failed.tsv` là danh sách control
   FAILED của tài nguyên buổi, đầu vào của việc sửa trong Terraform.
4. Sau 24 giờ: Cost Explorer theo dịch vụ (account stg, hay management cho cả org), so với ước lượng (ADR-0034 §12 cộng MSK, ElastiCache
   của ADR-0053 §16, cộng phần của mục **Giới hạn**, ±50 %); số thật thay ước lượng ở mục đó.

## Gỡ

Gỡ sạch buổi ở [`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31). Destroy kẹt: mục [Destroy kẹt](#destroy-kẹt); tài
nguyên sót mà một lệnh không đủ: mục [Lệnh xoá tay theo loại](#lệnh-xoá-tay-theo-loại).

## Khi một bước đỏ

Đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được); không đi tiếp qua một bước đỏ, trừ các ngoại lệ ở
cuối mục [Thứ tự](#thứ-tự). Dán dòng `FAIL` và phần output quanh nó cho AI. Lỗi của từng bước nằm ở trang pha của nó, dưới nhãn **Bẫy**.
