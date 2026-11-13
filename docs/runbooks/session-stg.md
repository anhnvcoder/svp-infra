# Runbook: một buổi AWS stg

Một buổi dựng env stg trong account `svp-stg` (`aws/envs/stg`), cài Argo CD và root GitOps lên EKS bằng Terraform (`aws/gitops/stg`, mẫu
GitOps Bridge), đo (smoke, seed, k6 bậc 1, 2, 4, 8), diễn tập khôi phục (backup on-demand và copy sang account `svp-backup`, PITR của RDS,
một object S3 từ AWS Backup), rồi gỡ sạch trong cùng buổi và quét cả account stg lẫn account management. Thiết kế:
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §13 (tài nguyên ngoài state), §14 (buổi AWS);
[ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §1–§2 (account, state), §5 (secret), §6 (bootstrap
EKS), §9 (kết thúc buổi); [ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md) (zone của mỗi env);
[ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md) (gói CloudFront flat-rate Free, web ACL WAF);
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) (Kafka là Amazon MSK, Valkey là
ElastiCache, dựng cùng apply với EKS, mật khẩu do Terraform sinh); [ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) (stg chạy cùng
cấu hình, xác thực, mã hoá và giám sát với prd, kể cả API qua tunnel SSM); [ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md) (Karpenter trên nhóm
node hệ thống, Envoy và Kyverno HA); [ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md) (PostgreSQL 17, `verify-full`);
[ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) (CloudWatch alarm tới email qua SNS);
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) (edge: CloudFront trước web, API, media,
VPC origin tới ALB internal, ba web ACL, cert ACM, log CloudFront, DNS của buổi);
[ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) (image kéo từ ECR của account, pull-through
cache làm nóng mỗi buổi, Inspector); [ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md)
(metric vào AMP, log vào CloudWatch Logs, trace vào X-Ray, luật trên AMP tới SNS, dashboard trên Amazon Managed Grafana, canary hỏi AMP);
[ADR-0064](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0064-interface-endpoints.md) (API AWS qua endpoint interface có private
DNS); [ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md) (transcode bằng AWS Elemental
MediaConvert: queue, role, rule EventBridge, SQS và DLQ của root env, endpoint `mediaconvert`);
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) (backup và DR: Backup policy, vault copy ở account
`svp-backup`, mục tiêu RTO/RPO, diễn tập, xoá recovery point cuối buổi).
Buổi prd theo [`session-prd.md`](session-prd.md), dùng chung mọi mục chung của file này.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại và nhắc tới khi destroy hai root và hai lượt `sweep.sh` (stg, mgmt) đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`). Mỗi account một
profile và một biến account, script tự lấy theo env từ bảng `env_table` của `aws/scripts/lib.sh`:

| Env của script | Account | Profile | Biến account |
| --- | --- | --- | --- |
| `stg` | `svp-stg` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` |
| `prd` | `svp-prd` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` |
| `mgmt` | management (account sandbox cũ) | `anhnv-sso` | `SVP_AWS_MGMT_ACCOUNT_ID` |

Account `svp-backup` (vault `svp-stg-copy`, `svp-prd-copy` giữ bản copy) không phải env của script: script chỉ cần 12 số của nó trong
`SVP_AWS_BACKUP_ACCOUNT_ID` (ARN vault đích, key RDS của root env), lệnh tay đọc bản copy bằng profile chỉ đọc `anhnv-backup-ro`.

Profile và region `ap-southeast-1` (`us-east-1` cho WAF, cert ACM và log chuẩn của CloudFront, Pricing Plan Manager và API Free Tier)
ghi sẵn trong từng lệnh của script. Script in mỗi bước một dòng
`ok`, `FAIL` (dừng), `note` hay `skip`, không in giá trị bí mật nào.

Xem trước toàn bộ lệnh của buổi, theo đúng thứ tự, không chạy gì (an toàn, không cần credential):

```sh
aws/scripts/session.sh --print stg
```

## Giới hạn

- **Cả buổi 4 giờ**, từ `check-account.sh` (mốc `session-start`) tới hai lượt `sweep.sh` sạch. **Quá 3 giờ mà chưa đo xong thì bỏ phần đo
  còn lại, sang gỡ**: `measure.sh` tự bỏ bậc k6 nào sẽ kết thúc sau mốc 3 giờ (dòng `skip`). Diễn tập khôi phục (bước 12–14) chạy sau đo,
  không có mốc tự bỏ: mỗi lần chờ của `restore-drill.sh` có hạn riêng (đầu script), instance PITR sống tới khi kiểm xong (mục tiêu RTO ≤ 60
  phút). Hết giờ thì bỏ diễn tập chưa chạy, sang bước 15; bước 20 (`cleanup`) không bao giờ bỏ: thiếu nó, `tf.sh` từ chối destroy root env.
- Chi phí một buổi 4 giờ: ước tính của ADR-0034 §12 cộng MSK và ElastiCache (H_k ~$0,144 mỗi giờ, O_k ~$0,06, ADR-0053 §16), cộng
  phần ADR-0055 và ADR-0056 thêm vào stg (nhóm node hệ thống on-demand, bastion SSM, KMS key, log control plane, flow log, CloudWatch alarm),
  cộng phần edge (ALB, phí theo giờ của ba web ACL, log; bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13), cộng phần nền tảng managed (endpoint
  interface, mẫu AMP, log, span, Inspector mỗi digest bên thứ ba mới, AMG ở buổi đầu tháng: bảng tổng mỗi buổi và lúc không buổi ở
  [ADR-0063 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md#12-chi-phí-hợp-đồng-cluster-và-adr-cũ)
  và phụ lục của nó), cộng phần transcode (job MediaConvert của buổi, endpoint `mediaconvert`, SQS, request S3:
  [ADR-0066 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí) và mục "Chi phí" của
  phụ lục), cộng phần backup (instance `svp-stg-pitr` của diễn tập, key `uploads`, hai alarm backup, request và restore S3:
  [ADR-0067 §13](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#13-chi-phí) và bảng "Mỗi buổi" ở mục "Chi phí"
  của phụ lục; bản copy ở `svp-backup` tính theo retention, ngoài buổi); buổi đầu đo số thật ở Cost Explorer (mục **Kết thúc buổi**). Quên
  destroy 24 giờ tốn gấp ~6 lần một buổi; budget
  `svp-stg-monthly` của account stg và budget tổng của org ở management gửi email ở 50 %, 80 %, 100 %.
- MSK và ElastiCache dựng, gỡ lâu: tài liệu AWS không ghi thời gian, ADR-0053 §16 giả định MSK dựng ≤ 45, gỡ ≤ 30 phút, ElastiCache ≤ 20,
  ≤ 15 phút, song song với EKS trong apply của root env (buổi dài thêm ~30 phút apply, ~20 phút destroy); buổi stg đo số thật (phép kiểm (a)
  ở bước 11).
- Distribution media của stg và web ACL `svp-stg-media` nằm trong gói flat-rate Free ($0 mỗi tháng, 1 triệu request và 100 GB, không tính
  phí vượt; ADR-0052 §1). Vài phút trước khi gói có hiệu lực và sau khi huỷ lúc destroy tính pay-as-you-go. Distribution `svp-stg-web`,
  `svp-stg-api` và web ACL của chúng (ATP, Bot Control) là pay-as-you-go như prd. Web ACL sót lại tính phí theo giờ, nên `sweep.sh` bắt nó.
- Cert của ba tên là cert ACM (DNS validation trong zone `stg.aws.<domain>`, tự gia hạn); Envoy dùng cert
  của CA nội bộ cert-manager, chỉ ALB edge và Job k6 nói chuyện với nó.

## Điều kiện trước buổi

1. **Account stg đã có baseline**: root `aws/org` đã tạo account `svp-stg` và gán permission set `SvpAdmin`; profile `anhnv-stg` đã tạo bằng
   `aws configure sso`; baseline `aws/accounts/stg` đã apply (bucket state, KMS key `alias/svp-tfstate`, zone `stg.aws.<domain>`, budget). Zone đó là zone con của zone
   `aws.<domain>` của account prd: được uỷ quyền bằng bản ghi `NS` của `delegated_subdomains` ở `aws/accounts/prd`, còn `aws.<domain>` bằng bốn
   bản ghi `NS` `aws` ở DNS cha của domain ([`aws/accounts/README.md`](../../aws/accounts/README.md), mục 5). Bước tay này một lần, không
   nằm trong buổi; `check-dns.sh` đỏ thì quay lại README đó, không bắt đầu buổi. Không gỡ baseline stg giữa các buổi: zone stg dựng lại có
   name server mới, phải `apply` lại `aws/accounts/prd` mới phân giải được.
   Account mới còn phải được AWS xác minh trước khi tạo tài nguyên CloudFront, và quota EC2 đủ cho node của env (đoạn quota dưới): chưa
   xác minh thì `apply` đỏ
   ở `aws_cloudfront_distribution` với `AccessDenied: Your account must be verified before you can add new CloudFront resources`, khi EKS, RDS
   đã chạy và tính tiền. Mở case AWS Support từ account stg (Account and billing, kèm dòng lỗi và RequestID nếu có) và chờ xác nhận trước
   buổi đầu.
   Distribution media đăng ký gói CloudFront flat-rate Free: account đang dùng AWS Free Tier không đăng ký được, và mỗi account tối đa 3 gói
   Free, không tăng được. Mỗi buổi, trước bước 3, đọc gói của account và loại account (chỉ đọc; phép kiểm (a) của ADR-0052):

   ```sh
   AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   AWS_PROFILE=anhnv-stg aws freetier get-account-plan-state --region us-east-1 --query accountPlanType --output text
   ```

   Mong `[]` và `PAID`; dán lại cả hai. Còn gói (sót của buổi trước, hay của lần thử ở console): nó giữ một suất và distribution của nó,
   huỷ theo mục **Lệnh xoá tay theo loại** (CloudFront) rồi đọc lại. `FREE`: account còn ở AWS Free Tier, apply sẽ đỏ ở gói: không bắt đầu
   buổi, dán output cho AI.

   Quota vCPU (chỉ đọc): on-demand chuẩn (`L-1216C47A`) cho nhóm node hệ thống tới `system_node_max_size` (2 × số AZ node `m7g.large`,
   2 vCPU mỗi node) cộng bastion `t4g.nano` (2 vCPU); Spot chuẩn (`L-34B43A08`) cho `limits.cpu` của NodePool (`envs/stg/svp-cluster.yaml`
   của `svp-gitops`, số ở ADR-0056 §2):

   ```sh
   AWS_PROFILE=anhnv-stg aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-southeast-1 --query 'Quota.Value'
   AWS_PROFILE=anhnv-stg aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 --region ap-southeast-1 --query 'Quota.Value'
   ```

   Cần quota on-demand ≥ 10 (4 node × 2 cộng 2) và quota Spot ≥ `limits.cpu`; thiếu thì xin tăng và chờ trước buổi.
2. Code đã merge: repo code ở `main` có `make eks-secrets`, `make eks-glitchtip-init`; `svp-gitops` ở `main` có `argocd/root`,
   `argocd/bootstrap.json`, lớp `platforms/eks`; repo này có `aws/envs/stg`, `aws/gitops/stg` và script buổi. Kiểm:

   ```sh
   git -C ../backend switch main && git -C ../backend pull --ff-only
   make -C ../backend help | grep -E '^  eks-(secrets|glitchtip-init)'      # hai dòng
   git -C ../gitops fetch origin
   git -C ../gitops show origin/main:envs/stg/charts.yaml | grep '^revision:'
   ```

   `bootstrap.sh stg secrets` tự kiểm lại: repo code ở `main`, sạch, bằng `origin/main` (entry và key của `make eks-secrets` đọc từ chart của
   nó). `tf.sh stg gitops plan` fetch hai bản clone, giải nén chart `svp-cluster` ở `revision` của `envs/stg/charts.yaml` vào thư mục buổi.
3. Trên máy: Terraform 1.15 (`terraform version`), AWS CLI v2 và Session Manager plugin (`session-manager-plugin --version`, cho tunnel
   tới API), `kubectl`, `jq`, `dig`, `nc`, `make`, `cosign` (kiểm chữ ký bản ECR), `curl` có `--aws-sigv4` (7.75 trở lên; bản của macOS có:
   `curl --version`), Docker (`image-list.sh` của repo code render chart như `make helm-check`); `.env` của repo code đã có
   (`make -C ../backend env`; `tf.sh stg gitops plan` lấy chat Telegram `SVP_ALERT_TELEGRAM_CHAT_ID` từ đó, rỗng là chỉ commit status).
4. File backend của account stg, `aws/backend-stg.hcl` (git bỏ qua; chỉ bucket, region, KMS key, không `key`), ghi từ output của baseline:

   ```sh
   AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw backend_hcl > aws/backend-stg.hcl
   ```

5. `aws/envs/stg/stg.auto.tfvars` (git bỏ qua) sinh bằng khối lệnh dưới, chỉ đọc output của baseline; thay `<domain>`, `<email>` (hộp
   thư nhận alarm). `grafana_workspace_id` là id của workspace AMG `svp-stg` (nhãn đầu của output `grafana_url`; AMG không có data source tìm
   theo tên):

   ```sh
   zone=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
   ws=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw grafana_url | sed -E 's#^https://(g-[0-9a-z]+)\..*#\1#')
   cat > aws/envs/stg/stg.auto.tfvars <<EOF
   hosted_zone_id       = "$zone"
   domain               = "stg.aws.<domain>"
   alarm_email          = "<email>"
   grafana_workspace_id = "$ws"
   EOF
   ```

   `domain` là tên zone của account stg (web ở đỉnh, API ở `api.<domain>`); precondition của root từ chối tên ngoài zone đó ngay lúc plan.
   Endpoint công khai của API tắt, nên file không có IP của máy. File có sẵn mà còn dòng `eks_public_access_cidrs` hay `acme_email` (root
   không khai báo hai biến này: Terraform chỉ cảnh báo `Value for undeclared variable`) hay thiếu `alarm_email`, `grafana_workspace_id` (plan
   dừng ở `No value for required variable`): xoá hai dòng đó, thêm dòng thiếu (`grafana_workspace_id` theo bước (9) của
   [`platform-setup.md`](platform-setup.md#bước-9-grafana-managed)), rồi đếm (không in giá trị nào):

   ```sh
   sed -i '' -E '/^(eks_public_access_cidrs|acme_email)[[:space:]]*=/d' aws/envs/stg/stg.auto.tfvars
   grep -c -E '^(hosted_zone_id|domain|alarm_email|grafana_workspace_id) ' aws/envs/stg/stg.auto.tfvars     # 4
   ```

6. **Nền bảo mật của org đã áp** tới ít nhất bước (3) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu) (`aws/bootstrap`,
   `aws/org` tạo account `svp-log-archive`, `aws/log-archive`): root env ghi flow log VPC vào bucket `svp-flowlogs-<log>-ap-southeast-1` và log
   WAF vào `aws-waf-logs-svp-<log>-us-east-1` của account đó, nên cần id account đó trong biến `SVP_AWS_LOG_ACCOUNT_ID` (output
   `log_archive_account_id` của `aws/org`; mục **Mở terminal của buổi**). Thiếu biến thì `tf.sh` dừng với `FAIL set SVP_AWS_LOG_ACCOUNT_ID …`;
   bucket chưa có thì `apply` đỏ ở flow log hay logging của web ACL.
7. **Edge đã áp lần đầu** theo [`edge-setup.md`](edge-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (3): delivery destination
   `svp-cloudfront-stg` của account Log Archive (root env tạo delivery log của CloudFront tới nó; thiếu thì `apply` đỏ ở
   `aws_cloudwatch_log_delivery`), `CAA` ở zone, zone prd ký và có `DS` ở DNS cha (phép kiểm edge đọc cờ `ad`). Một lần, không nằm trong buổi.
8. **Nền tảng managed đã áp** theo [`platform-setup.md`](platform-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (9): registry, pull-through cache có
   credential, workspace AMP, log group `/svp/stg/otel`, AMG của `aws/accounts/stg` (root env đọc chúng bằng data source; thiếu thì `plan` dừng
   ở data source hay precondition), quota chu kỳ luật AMP 15 s đã duyệt (thiếu thì luật không lên AMP), secret CI đã đặt. Một lần, không
   nằm trong buổi.
9. **Chart có nền tảng managed**: `revision` của `envs/stg/charts.yaml` (lệnh của điều 2) là commit của repo code có Collector theo nền tảng và
   value `canaryPrometheus` (chart cũ bỏ qua values eks mới: không metric, log, trace vào dịch vụ managed, image kéo thẳng upstream, canary hỏi
   Prometheus không còn trả lời). Kiểm (hai dòng `ok`):

   ```sh
   rev=$(git -C ../gitops show origin/main:envs/stg/charts.yaml | sed -n 's/^revision: *//p')
   git -C ../backend fetch origin
   git -C ../backend cat-file -e "$rev:deploy/observability/otelcol/k8s-eks.yaml" && echo ok
   git -C ../backend show "$rev:deploy/helm/svp-service/values.yaml" | grep -q '^canaryPrometheus:' && echo ok
   ```

10. **Backup đã áp** theo [`backup-setup.md`](backup-setup.md#thứ-tự-áp-lần-đầu): account `svp-backup` và biến
    `SVP_AWS_BACKUP_ACCOUNT_ID` (thiếu biến thì `tf.sh stg env …` dừng với `FAIL set SVP_AWS_BACKUP_ACCOUNT_ID …`), Backup policy
    `svp-backup-stg` gắn OU `NonProd` (plan `svp-stg` của account), vault `svp-stg-copy` ở `svp-backup`, vault `svp-stg` cùng role
    `svp-stg-backup` và opt-in ở `aws/accounts/stg`, profile `anhnv-backup-ro`. Thiếu một phần thì bước 12 dừng ở phần đó (`FAIL no backup plan
    svp-stg …`, `opt-in …`), hay copy job lỗi. Một lần, không nằm trong buổi.
11. Mac cắm sạc, tắt Low Power Mode (đo k6 và chờ dài).

## Mở terminal của buổi

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                                             # cho lượt sweep.sh mgmt cuối buổi
export SVP_AWS_STG_ACCOUNT_ID=<12 số của account svp-stg>                       # đọc trên trang SSO; không ghi vào file nào
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_AWS_LOG_ACCOUNT_ID=<12 số của account svp-log-archive>               # bucket flow log, log WAF của root env
export SVP_AWS_BACKUP_ACCOUNT_ID=<12 số của account svp-backup>                 # copy vaults; root env shares RDS key
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"               # số đo của buổi; .session/ git bỏ qua
```

Các profile dùng chung một phiên SSO khi cùng `sso_session` trong `~/.aws/config` (cả `anhnv-backup-ro` của bước 12), khi đó một lần `aws sso
login` là đủ. Biến account không nằm trong file commit nào, kể cả `.envrc`; script đặt `TF_VAR_account_id` từ biến của env,
`TF_VAR_log_archive_account_id` từ `SVP_AWS_LOG_ACCOUNT_ID` và `TF_VAR_backup_account_id` từ `SVP_AWS_BACKUP_ACCOUNT_ID` ngay trong lệnh
`terraform` của root env; `restore-drill.sh` dựng ARN vault `svp-stg-copy` từ `SVP_AWS_BACKUP_ACCOUNT_ID`.

Mọi bước sau chạy trong **cùng terminal này** (cùng các biến). Thư mục buổi chứa: `timeline.tsv` (mốc UTC: `session-start`,
`env-apply-start`, `env-apply-end`, `secrets-written`, `gitops-apply-start`, `gitops-apply-end`, `observability-healthy`, `glitchtip-init`,
`svp-root-healthy`, `edge-healthy`, `smoke-ok`, `seed-ok`, `k6-<n>-start`/`-end`, `backup-undrained`, `backup-drained`, `pre-destroy-*`,
`gitops-destroy-*`, `env-destroy-*`), `cluster-values.json` (mode 600), `eks-secrets.log`, `svp-cluster-chart/`, các file text của plan,
`k6-levels.tsv`, `k6-<n>/`, `restore-drill.tsv`, `restore-drill-points.tsv` và các file mẫu `restore-drill-*` của diễn tập.

**Mở lại terminal giữa buổi** (terminal đóng, máy khởi động lại): đặt lại các biến, với `SVP_SESSION_DIR` là **thư mục của buổi đang dở**,
không phải thư mục mới. `measure.sh` đọc `cluster-values.json` của nó và tính mốc 3 giờ từ `session-start` của nó; `tf.sh` đọc các mốc gỡ
(`pre-destroy-done`, `gitops-destroy-end`) trong `timeline.tsv` của nó.

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
export SVP_AWS_STG_ACCOUNT_ID=<12 số> SVP_AWS_MGMT_ACCOUNT_ID=<12 số> SVP_AWS_LOG_ACCOUNT_ID=<12 số> SVP_AWS_BACKUP_ACCOUNT_ID=<12 số>
ls -1d .session/*/ | tail -n 3                                                 # thư mục mới nhất là buổi đang dở
export SVP_SESSION_DIR="$PWD/.session/<thư mục đó>"
tail -n 5 "$SVP_SESSION_DIR/timeline.tsv"                                      # mốc cuối: bước nào đã xong
```

Rồi chạy tiếp từ bước sau mốc cuối (hay chạy lại bước đang dở).

## Thứ tự

| # | Lệnh | Hạn | Dán lại cho AI |
| --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh stg` | 2 phút | dòng `ok account …` (account, ARN) |
| 2 | `aws/scripts/check-dns.sh stg` | 2 phút | ba dòng `ok` hay dòng `FAIL` |
| 3 | `aws/scripts/tf.sh stg env init` | 5 phút | dòng cuối |
| 4 | `aws/scripts/tf.sh stg env plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan |
| 5 | `aws/scripts/tf.sh stg env apply` | 65 phút | dòng `Apply complete! …`, hai dòng `mark` và hai dòng `Creation complete after …` của `module.msk.aws_msk_cluster.this`, `module.elasticache.aws_elasticache_replication_group.this` |
| 6 | `aws/scripts/bootstrap.sh stg secrets` | 5 phút | mọi dòng `ok`/`FAIL` |
| 7 | `aws/scripts/tf.sh stg gitops init` | 2 phút | dòng cuối |
| 8 | `aws/scripts/tf.sh stg gitops plan` | 5 phút | dòng `ok chart svp-cluster at …`, dòng `Plan: …` và đường dẫn file text của plan |
| 9 | `aws/scripts/tf.sh stg gitops apply` | 15 phút | dòng `Apply complete! …`, output `bootstrap_revision` |
| 10 | `aws/scripts/bootstrap.sh stg wait` | 45 phút | mọi dòng `ok`/`FAIL` |
| 11 | `aws/scripts/measure.sh stg` | tới mốc 3 giờ | `k6-levels.tsv`, dòng `ok highest level …` |
| 12 | `aws/scripts/restore-drill.sh stg backup` | 60 phút | mọi dòng `ok`/`FAIL`, dòng `PASS backup …` |
| 13 | `aws/scripts/restore-drill.sh stg rds` | 75 phút | mọi dòng `ok`/`FAIL`, dòng `PASS rds …` hay `FAIL rds …` |
| 14 | `aws/scripts/restore-drill.sh stg s3` | 30 phút | mọi dòng `ok`/`FAIL`, dòng `PASS s3 …` hay `FAIL s3 …` |
| 15 | `aws/scripts/pre-destroy.sh stg` | 30 phút | mọi dòng `ok`/`FAIL`/`note` |
| 16 | `aws/scripts/tf.sh stg gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` |
| 17 | `aws/scripts/tf.sh stg gitops destroy` | 10 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` |
| 18 | `aws/scripts/tf.sh stg env plan --teardown` | 1 phút | dòng `skip` (stg không có bảo vệ cần nhấc) |
| 19 | `aws/scripts/tf.sh stg env apply --teardown` | 1 phút | dòng `skip` |
| 20 | `aws/scripts/restore-drill.sh stg cleanup` | 30 phút | mọi dòng `ok`/`FAIL`/`skip`, mốc `backup-drained` |
| 21 | `aws/scripts/tf.sh stg env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan |
| 22 | `aws/scripts/tf.sh stg env destroy` | 50 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster MSK, replication group ElastiCache |
| 23 | `aws/scripts/sweep.sh stg` | 5 phút | toàn bộ output |
| 24 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output |

Bước tay chen giữa các bước script: xác nhận email của alarm sau bước 5 (mục 3–5), tunnel tới API sau bước 5 và trước bước 6 (mục
**Tunnel tới API**, giữ chạy tới hết bước 17), làm nóng cache sau bước 6 và trước bước 7 (mục **Làm nóng cache**), phép kiểm của bước 11 (cả
mục **Phép kiểm nền tảng managed** và **Phép kiểm transcode**, clip của nó sinh trong lúc chờ bước 5),
đọc bản copy ở `svp-backup` sau bước 12 (mục **12–14**), đọc finding bảo mật sau bước 14 và trước bước 15 (mục **Finding bảo mật của
buổi**), chạy lại truy vấn dữ liệu sau bước 24 (mục **Kết thúc buổi**).

Dự trù: apply root env xong ~T+70 phút (MSK là phần dài nhất), mọi Application Healthy ~T+1 giờ 55, đo tới muộn nhất T+3 giờ, gỡ và quét
xong trước T+4 giờ khi gỡ đúng số giả định của ADR-0053 §16; buổi stg đầu tiên đo hai mốc đó và ghi vào phụ lục của ADR. Hạn của bước 12–14,
20 là ước (AWS không công bố thời gian của job backup, copy hay restore); buổi stg đầu đo số thật (`t0`, `t1` của `restore-drill.tsv`, mốc
`backup-drained`) và ghi vào phụ lục ADR-0067.
Một bước đỏ: đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được). Không đi tiếp qua một bước đỏ, trừ
bước 11 (đo): đo hỏng thì vẫn sang bước 12; và bước 13, 14 khi dòng kết quả là `FAIL` của phép đo (mục **12–14**): đó là số đo, sang bước kế.
Bước 18, 19 không làm gì ở stg (không có `teardown.tfvars`); chúng nằm trong bảng để stg và prd chạy cùng một chuỗi bước.

### 1. Kiểm account

```sh
aws/scripts/check-account.sh stg
```

Tìm: `ok    account <12 số> of stg, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_SvpAdmin_…` với đúng account `svp-stg`. `FAIL … not
SVP_AWS_STG_ACCOUNT_ID` là profile `anhnv-stg` trỏ account khác: dừng, không chạy gì nữa. Mọi script chạm account (trừ `check-dns.sh`) tự
kiểm lại điều này trước lệnh đầu tiên của nó, nên `tf.sh` không bao giờ chạy trên account khác. Cùng lệnh với `prd`, `mgmt` kiểm account của
env đó trước một lệnh ghi bằng tay.

### 2. Kiểm DNS

```sh
aws/scripts/check-dns.sh stg
```

Đọc name server của zone `stg.aws.<domain>` (tên là `zone_name` của `aws/accounts/stg/stg.auto.tfvars`) từ output `name_servers` của
`aws/accounts/stg` (không gọi API AWS nào khác), hỏi `NS stg.aws.<domain>` ở `1.1.1.1` và `8.8.8.8`. Tìm: `ok hosted zone …`, rồi `ok resolver
1.1.1.1 …`, `ok resolver 8.8.8.8 …`. `FAIL … returns no NS` hay `returns NS … not the hosted zone's`: uỷ quyền chưa lan hay sai (validation
DNS của cert ACM và ba tên của buổi sẽ hỏng). Lời của script là một câu chung: uỷ quyền zone con nằm ở `delegated_subdomains` của
`aws/accounts/prd`, zone gốc ở bản ghi `NS` `aws` của DNS cha. Zone stg đi qua cả hai nấc, nên kiểm theo `aws/accounts/README.md` (mục 5) cả
hai: sửa nấc sai, **không bắt đầu buổi**.

### 3–5. Root env: init, plan lưu file, đọc, apply file đó

```sh
aws/scripts/tf.sh stg env init
aws/scripts/tf.sh stg env plan
aws/scripts/tf.sh stg env apply
```

`init` luôn chạy `terraform init -reconfigure -backend-config=../../backend-stg.hcl -backend-config=key=aws/stg/terraform.tfstate`: file
backend của account stg cộng key của chính root này. `-reconfigure` bỏ cấu hình backend cũ mà `.terraform` còn giữ (lần init đầu ở account
mới, `.terraform` vẫn trỏ bucket của management) và **không bao giờ migrate state**: state cũ `aws/stg/terraform.tfstate` ở bucket management
đã được chứng minh rỗng khi dựng baseline, buổi này bắt đầu từ state trống ở bucket của account stg.

`plan` ghi `aws/envs/stg/stg.tfplan` (nhị phân, git bỏ qua) và ngay sau đó bản text của nó vào `$SVP_SESSION_DIR/stg-env-plan.txt` (thư mục
buổi, git bỏ qua: plan có tên miền và IP thật nên không vào cây repo); `ok` cuối của `plan` nêu đường dẫn file text. Ghi lại bản text từ plan
hiện có: `aws/scripts/tf.sh stg env show`. **Đọc file text đó trước khi apply**: lần đầu mỗi buổi chỉ `to add`, `0 to change, 0 to destroy`; có
`destroy` hay `change` là state còn tài nguyên của buổi trước (destroy dở): dừng, dán plan cho AI. Plan có ba web ACL
`module.waf["web"]`, `["api"]`, `["media"]` (`aws_wafv2_web_acl.this`, provider `us-east-1`); `module.edge`: ALB `svp-stg-edge` với
`internal = true` ở subnet edge, listener HTTPS 443, target group `svp-stg-envoy`, VPC origin `svp-stg-edge`, distribution `svp-stg-web`,
`svp-stg-api`, cert ACM (`us-east-1` cho distribution, region nhà cho ALB), bản ghi A, AAAA và validation, delivery log `us-east-1`;
distribution `svp-stg-media` (`media.<domain>`) với gói `module.media.aws_pricingplanmanager_subscription.media[0]` `plan_tier = "FREE"`
(phép kiểm (b) của ADR-0052). Plan có cluster `module.msk.aws_msk_cluster.this` (`kafka_version = "4.1.x.kraft"`,
`kafka.t3.small`, 2 broker), tám secret `AmazonMSK_svp-stg-*`, replication group `module.elasticache.aws_elasticache_replication_group.this`
(`engine = "valkey"`, `engine_version = "9.1"`) và bốn `aws_elasticache_user`; mật khẩu của chúng là đối số write-only, plan chỉ in
`(write-only attribute)`, không giá trị. Plan cũng có: node group `system` của `module.eks` (không node group nào khác), submodule
`module.eks.module.karpenter` (hàng đợi SQS `svp-stg-karpenter`, rule EventBridge, role `svp-stg-karpenter`, `svp-stg-karpenter-node`, Pod
Identity association), bastion `module.ssm_bastion`, KMS key của `module.rds`, `module.msk`, `module.alarms` và của Secrets EKS, topic SNS
`svp-stg-alarms` với một subscription `email`, các `aws_cloudwatch_metric_alarm` của `module.rds`, `module.msk`, `module.elasticache` (bảng
alarm của ADR-0058 §2), target và policy autoscaling storage của MSK, log group slow-log của Valkey. `apply` chỉ nhận file plan đó (không plan lại tại chỗ), rồi xoá nó. Thời gian: EKS ~10–15 phút,
RDS ~10 phút, ba distribution CloudFront và cert ACM (DNS validation) ~5–15 phút, MSK ≤ 45 phút, ElastiCache ≤ 20 phút (giả định của
ADR-0053 §16), song song; gói Free chờ tới `ACTIVE` (vài
phút tới hơn nửa giờ). Ghi lại hai dòng `Creation complete after …` của cluster MSK và replication group ElastiCache trong output (phút
dựng, phép kiểm (a) của ADR-0053). Root này cũng tạo các entry `svp/stg/*` của Secrets Manager: `kafka-admin`, `kafka-users`, `valkey-users`
có giá trị ngay trong apply này (Terraform sinh mật khẩu, ghi cùng một giá trị vào secret `AmazonMSK_*`, user ElastiCache và entry; không
vào plan hay state), các entry khác còn rỗng tới bước 6. `apply` đỏ giữa chừng: đọc lỗi, `plan` lại, `apply` lại. Ngoại lệ là khi output của
lượt đỏ đã có `Creation complete` hay `Modifications complete` của một tài nguyên mang mật khẩu: `aws_secretsmanager_secret_version` hay
`aws_elasticache_user` dưới `module.msk` (nhóm Kafka) hay `module.elasticache` (nhóm Valkey). Mật khẩu là write-only: phần đã ghi giữ mật
khẩu của lượt đỏ, `plan` lại không thấy lệch (in `No changes` cho chúng), còn phần chưa ghi nhận mật khẩu mới của lượt sau, nên user và
entry lệch nhau (`WRONGPASS` ở phép kiểm (d) của ADR-0053 ở bước 11, MSK từ chối đăng nhập). Khi đó tăng version của nhóm đó trước khi
`plan` lại, đúng cách của mục [Đổi một secret của env đang chạy](#đổi-một-secret-của-env-đang-chạy) (`msk_password_version`,
`valkey_password_version` trong `stg.auto.tfvars`): apply với version mới ghi lại mọi mật khẩu của nhóm từ cùng một giá trị; rồi đi tiếp
bước 6 (`bootstrap.sh stg secrets`, lệnh kết thúc lượt xoay đó). Lỗi nằm ở chính access string của user ElastiCache thì không apply lại
(bảng dưới). Muốn bỏ buổi thì sang bước 15 (`pre-destroy.sh` tự ghi context `svp-stg`, nên chạy được cả khi apply đỏ sau khi cluster EKS
đã có), hay bước 20 rồi 21 với `--no-cluster` khi apply đỏ trước khi tạo cluster EKS (điều kiện ở mục
18–22).

**Xác nhận email của alarm** (mỗi buổi, sau apply): SNS gửi thư "AWS Notification - Subscription Confirmation" tới `alarm_email`; mở link
"Confirm subscription" trong thư. Chưa xác nhận thì không alarm nào tới email. Đọc lại (ARN của topic tính từ biến account của buổi):

```sh
AWS_PROFILE=anhnv-stg aws sns list-subscriptions-by-topic --region ap-southeast-1 \
  --topic-arn "arn:aws:sns:ap-southeast-1:$SVP_AWS_STG_ACCOUNT_ID:svp-stg-alarms" --query 'Subscriptions[].SubscriptionArn' --output text |
  sed -E 's/^arn:.*/confirmed/'
```

Mong `confirmed` (lệnh thay ARN bằng chữ đó, để output dán lại không có account); `PendingConfirmation` là chưa mở link (thư có thể ở mục
spam). Subscription chưa xác nhận ở lại account sau destroy tới khi AWS tự xoá nó (README của `aws/modules/alarms`).

Lỗi apply đã biết, không sửa bằng `plan` lại:

| Lỗi | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `AccessDenied: Your account must be verified before you can add new CloudFront resources` ở `aws_cloudfront_distribution` | account chưa được AWS xác minh cho CloudFront | gỡ buổi như trên, rồi case AWS Support của điều kiện 1 |
| lỗi ở `module.elasticache.aws_elasticache_user.this[…]` về `access_string` (ElastiCache không nhận một luật của chuỗi) | access string của ADR-0053 §9 chưa qua phép kiểm (a) của buổi stg; `plan` lại, version mới đều gửi lại đúng chuỗi đó | không apply lại; gỡ buổi như trên, dán lỗi cho AI: sửa chuỗi bằng PR (ADR-0053 §9, module `elasticache`, aclfile local cùng chuỗi), rồi buổi mới |
| lỗi ở `aws_cloudwatch_log_delivery` của `module.edge` hay `module.media` nêu delivery destination `svp-cloudfront-stg` | destination chưa có hay policy của nó chưa cho account stg: bước (1) của `edge-setup.md` chưa áp | gỡ buổi như trên, áp bước (1) của [`edge-setup.md`](edge-setup.md#bước-1-log-cloudfront-và-quyền-đọc), rồi buổi mới |
| `ServiceQuotaExceededException` ở `aws_pricingplanmanager_subscription.media` (câu của mô hình API: "You have reached the maximum number of subscriptions allowed for your account"; câu lúc chạy có thể khác, nhận theo tên lỗi) | account đã dùng hết 3 gói Free; tài liệu AWS không nói gói đã huỷ có bị đếm hay không (ADR-0052, Hệ quả) | không apply lại; gỡ buổi như trên, rồi mở case AWS Support từ account đó kèm dòng lỗi và RequestID |

### Tunnel tới API (sau bước 5, trước bước 6)

Endpoint công khai của API tắt ở cả hai env (ADR-0055 §2): máy tới endpoint private qua phiên port forwarding của Session Manager tới bastion
`t4g.nano` trong subnet private (module `ssm-bastion`), cổng local `127.0.0.1:6444` (prd `6443`, cột `tunnel` của `env_table`: một lệnh nhầm
context không bao giờ tới cluster kia). Mở ở **một terminal riêng** từ gốc repo, giữ chạy tới hết bước 17 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/envs/stg output -raw api_tunnel_command)"
```

Lệnh của output có sẵn profile `anhnv-stg` và `--region`. Mọi script cần API (`bootstrap.sh stg wait`, `tf.sh stg gitops
plan|apply|plan --destroy|destroy`, `measure.sh stg`, `pre-destroy.sh stg`) kiểm `127.0.0.1:6444` trước lệnh đầu tới API và dừng với
`FAIL no tunnel …` khi tunnel chưa mở hay đã rớt (phiên SSM hết hạn): mở lại tunnel rồi chạy lại đúng bước đó. Context `svp-stg` do
`bootstrap.sh stg secrets` (và `pre-destroy.sh stg`) ghi: server `https://127.0.0.1:6444`, TLS server name là host của endpoint private.
Root `aws/gitops/stg` đi qua cùng tunnel (`api_server_url` của `aws/gitops/stg/stg.tfvars`). Mọi lệnh `kubectl` tay của file này chạy khi
tunnel mở.

### 6. Giá trị secret

```sh
aws/scripts/bootstrap.sh stg secrets
```

Theo thứ tự: kiểm account; repo code ở `main` = `origin/main`, sạch; `aws eks update-kubeconfig --alias svp-stg`; ghi `cluster-values.json`;
đọc **mật khẩu** master của RDS (trường `password` của secret mà RDS giữ, username luôn `postgres`) vào môi trường của đúng lệnh `make`
(không ra file, không in), rồi `make -C ../backend eks-secrets CONTEXT=svp-stg` với `AWS_PROFILE=anhnv-stg`: ghi các entry `svp/stg/*` từ
`.env` (mỗi entry một `put-secret-value --secret-string file://…`, giá trị không qua đối số hay output); `glitchtip-runtime` ba key rỗng chỉ
khi chưa có giá trị. Ba entry của Kafka và Valkey (`kafka-admin`, `kafka-users`, `valkey-users`) Terraform đã ghi ở bước 5: `make eks-secrets`
chỉ kiểm chúng có, không ghi, không đọc mật khẩu Kafka, Valkey của `.env` (mật khẩu của stack local). Rồi token của Grafana Operator: tìm
service account `svp-grafana-operator` của workspace AMG (id từ `grafanaUrl` của `cluster-values.json`), xoá mọi token cũ của nó (quota 100 token
mỗi workspace, kể cả token hết hạn), tạo token sống 24 giờ và ghi thẳng vào entry `svp/stg/grafana-operator` qua pipe (token không qua đối số,
file hay output). Nguồn của mọi Secret trên EKS có trước Argo CD. Tìm: `ok a token of svp-grafana-operator valid 24 h in entry
svp/stg/grafana-operator (not shown)`, `ok entries svp/stg/* written (kafka-admin, kafka-users, valkey-users by the apply of aws/envs/stg); next:
aws/scripts/ecr-warm.sh stg <image list>, …` và mốc `secrets-written`. Đỏ: dán ~30 dòng cuối của `$SVP_SESSION_DIR/eks-secrets.log` (script
nêu tên biến thiếu, không in giá trị), hay dòng `FAIL` của phần Grafana (thiếu `grafanaUrl`, thiếu service account: `aws/accounts/stg` chưa có
bước (5) của [`platform-setup.md`](platform-setup.md#bước-5-awsaccountsenv)).

### Làm nóng cache (sau bước 6, trước bước 7)

Mọi image của cluster ghim digest, mà ECR không kéo được theo digest một image pull-through cache chưa từng thấy
([ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §7). Nên trước khi Argo CD cài gì,
`ecr-warm.sh` kéo **theo tag** qua cache mọi image bên thứ ba của bản render eks của env, rồi kiểm digest ghim có ở ECR. Danh sách do
`deploy/ci/image-list.sh` của repo code in, mỗi dòng `<ref upstream>:<tag>@<digest>` (không image phát hành của lab: chúng vào ECR qua CI). Lập
danh sách không chạm AWS, làm được từ đầu buổi (render các chart ở `revision` của env như `make helm-check`, ~1–2 phút, cần mạng và Docker):

```sh
(cd ../backend && deploy/ci/image-list.sh ../gitops stg) >"$SVP_SESSION_DIR/images-stg.txt"
wc -l <"$SVP_SESSION_DIR/images-stg.txt"
aws/scripts/ecr-warm.sh stg "$SVP_SESSION_DIR/images-stg.txt"
```

Script đọc hết danh sách trước lệnh đầu tiên (dòng sai dạng, image không thuộc năm tiền tố cache thì dừng, nêu dòng), kiểm account, rồi mỗi image
một `aws ecr batch-get-image` theo tag qua repo cache và so digest (đi hết danh sách, rồi mới dừng nếu có image đỏ). Tìm: mỗi image một dòng
`ok`, dòng cuối `ok every image of … in the cache of stg at its pinned digest; next: …`, mốc `ecr-warm-start`, `ecr-warmed` trong
`timeline.tsv`. Dòng `FAIL` nêu image, tag, digest ghim và digest ECR trả: tag upstream đã dời (cache làm mới một tag tối đa mỗi ngày một lần;
Renovate mở PR đổi digest ghim) hay credential của cache sai (dòng GHCR, Docker Hub:
[`platform-setup.md`](platform-setup.md#xoay-credential)); dán mọi dòng `FAIL`. PR đổi digest bên thứ ba merge giữa
buổi thì lập lại danh sách và chạy lại script trước khi Argo CD sync bản đó. Xem trước lệnh, không chạy gì: `aws/scripts/ecr-warm.sh --print stg
<file>` (`session.sh --print` không gồm bước này).

### 7–9. Root gitops: Argo CD và root GitOps

```sh
aws/scripts/tf.sh stg gitops init
aws/scripts/tf.sh stg gitops plan
aws/scripts/tf.sh stg gitops apply
```

Root `aws/gitops/stg` ([README](../../aws/gitops/README.md)) đọc root env qua `terraform_remote_state`, cài theo thứ tự namespace (nhãn Pod
Security) → Argo CD (chart, version, values từ `svp-gitops` ở commit bootstrap) → AppProject → cluster Secret `in-cluster` (metadata của
cluster, `cluster_values`, chat Telegram) → ApplicationSet `svp-bootstrap` tạo Application `svp-root`. `init` như bước 3 với key
`aws/gitops/stg/terraform.tfstate`. `plan` trước hết fetch hai bản clone, giải nén chart `svp-cluster` của repo code ở `revision` của
`envs/stg/charts.yaml` (`origin/main` của `svp-gitops`) bằng `git archive` vào `$SVP_SESSION_DIR/svp-cluster-chart/` (`TF_VAR_svp_cluster_chart`),
lấy `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (`TF_VAR_telegram_chat_id`), rồi plan; dòng `ok chart svp-cluster at <sha>` nêu commit.
Đọc file text `stg-gitops-plan.txt`: chỉ thêm namespace, ba `helm_release`, Secret `in-cluster`. `apply` như bước 5. Plan cần mạng tới GitHub
(raw file, REST API của `svp-gitops`).

### 10. Chờ Argo CD

```sh
aws/scripts/bootstrap.sh stg wait
```

Chờ Application `svp-observability` Healthy (GlitchTip chạy), chạy `make -C ../backend eks-glitchtip-init CONTEXT=svp-stg` (DSN và token của
GlitchTip vào entry `glitchtip-runtime`, dựng lại ba ExternalSecret; Secret `svp/sentry` đổi nên Reloader restart service đọc DSN), rồi chờ `svp-root` Synced và Healthy (Argo CD
báo Healthy khi mọi Application nó tạo Healthy), rồi chờ target group `svp-stg-envoy` của ALB edge có một target `healthy` (pod Envoy do
`TargetGroupBinding` `svp-envoy` đăng ký, health check cổng 19003): smoke của bước 11 đi qua CloudFront và ALB đó. Mỗi lần chờ tối đa 30
phút. Tìm: `ok every Application Synced and Healthy on svp-stg`, mốc `svp-root-healthy`, rồi `ok the edge's target group has a healthy
target; next: …` và mốc `edge-healthy`. `FAIL no healthy target in …` nêu trạng thái từng target: đọc
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system describe targetgroupbinding svp-envoy`. Đỏ: dán dòng `FAIL` (có trạng
thái sync, health) và

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io
```

sửa xong chạy lại (chạy lại được). Muốn bỏ buổi ở đây: sang bước 15; `pre-destroy.sh` chạy được cả khi Argo CD chưa được cài.

### 11. Đo

```sh
aws/scripts/measure.sh stg
```

1. `make eks-smoke CONTEXT=svp-stg DOMAIN=<domain>`: luồng đầu-cuối qua `https://api.<domain>`, tức CloudFront `svp-stg-api`, VPC origin, ALB
   edge, Envoy (cert ACM).
2. `make eks-seed`: ≥ 30 video `READY` trong `GET /feed/explore` (k6 profile `cloud` đọc chúng).
3. k6 (`deploy/k6/cloud/run.sh` của repo code) bậc **1, 2, 4, 8 pod**, mỗi pod một phần tải của thiết kế 20 pod, lên 2 phút, giữ 10 phút;
   **trước mỗi bậc `make eks-rl-reset CONTEXT=svp-stg`** (pod bậc sau có thể nhận lại IP của pod bậc trước, burst đăng ký theo IP sẽ cạn;
   **LOCAL LAB ONLY**: xoá khoá `svp:gw:rl:register:*` ở db 10 của ElastiCache, qua `svp-valkey` của Deployment `svp-ops`). Bậc đầu tiên trượt (threshold, iteration bị bỏ, 429,
   pod thiếu summary) kết thúc thang đo. Job `svp-k6` (namespace `svp-load`) đi thẳng tới ClusterIP của Service `svp-envoy`, không qua
   CloudFront, WAF (tải từ vài IP NAT sẽ chạm luật rate-based của WAF): mỗi pod đặt `CloudFront-Viewer-Address` là `<IP pod>:0`, nên mỗi
   pod một bucket rate limit; pod tin CA nội bộ của Envoy, `run.sh` đọc khoá `ca.crt` của Secret `svp-edge/svp-edge-tls` (không đọc khoá
   riêng). Mỗi bậc ghi `k6-<n>/`: `nodes.tsv` (số node Ready theo thời gian), `top-nodes.tsv`,
   `top-pods.tsv` (`kubectl top` mỗi lần chờ), `summaries/` (summary của từng pod), `logs.txt`, `node-events.json`.

Exit: `0` khi thang đo đã chạy tới cuối (một bậc trượt là kết quả, không phải lỗi script; dòng `FAIL level <n>` nêu lý do), `1` khi smoke,
seed hay công cụ của một bậc hỏng (cả khi hết hạn chờ mà lần đọc Job cuối cùng lỗi, như phiên SSO hết hạn hay mất mạng: bậc ghi `error`,
không phải `fail`, Job để nguyên; `AWS_PROFILE=anhnv-stg aws sso login --region us-east-1` rồi `measure.sh stg --from <n>`, script xoá Job đó trước khi
chạy lại bậc), `3` khi một node của lúc bắt đầu bậc mất hay `NotReady` giữa bậc (**Spot bị thu hồi**, dòng `note
node(s) …`): bậc đó ghi `interrupted`, **không tính là hệ thống trượt**. Còn thời gian (dưới mốc 3 giờ) thì chạy lại từ bậc đó, không
smoke, không seed:

```sh
aws/scripts/measure.sh stg --from <n>
```

Sau smoke, một phép tay: bucket `media` không liệt kê được ẩn danh khi gọi thẳng endpoint vùng của S3, không qua CloudFront (smoke chỉ thử
phép liệt kê qua gốc của CloudFront, không suy được tên bucket). Mong `403`; `200` là bucket liệt kê được, dừng buổi và báo lại:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://$(jq -r .mediaBucket "$SVP_SESSION_DIR/cluster-values.json").s3.$(jq -r .region "$SVP_SESSION_DIR/cluster-values.json").amazonaws.com/?list-type=2"
```

Dán lại mã in ra (ghi vào hàng tương ứng của mục "Kiểm chứng sau" của ADR-0034).

Trong lúc giữ tải, đọc phía server ở Amazon Managed Grafana (`AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw
grafana_url`, mở trên trình duyệt, đăng nhập bằng IAM Identity Center với user của nhóm nền tảng; dashboard "SVP — SLO"): p95/p99 của gateway
theo route. Grafana của eks là AMG: Grafana trong cluster không chạy, trace không có data source Tempo (mục Phép kiểm edge (d)).
Các phép kiểm chỉ chứng minh được trên AWS ở mục "Kiểm chứng sau" của ADR-0034 và ADR-0048: làm trong lúc chờ bậc k6, ghi kết quả từng phép
kiểm (đạt hay không, output chính) vào một file trong `$SVP_SESSION_DIR`, để sau buổi điền cột Kết quả của bảng đó. Dán lại: `cat
$SVP_SESSION_DIR/k6-levels.tsv`, dòng `ok highest level …`, và với mỗi bậc `jq -c . $SVP_SESSION_DIR/k6-<n>/summaries/pod-*.json | head`.

Commit status `argocd/stg` (Argo CD Notifications, ADR-0032) phải có trên commit `svp-gitops` cluster vừa sync: đó là **bằng chứng stg** mà
`promote-prd` đòi trước khi promote commit đó lên prd. Đọc commit (ghi vào `stg-ref.txt` của thư mục buổi), status của nó và
commit đó nằm trên `main` của `svp-gitops`, trước bước 15 (cluster còn):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.sync.revision}{"\n"}' |
  tee "$SVP_SESSION_DIR/stg-ref.txt"
gh api "repos/anhnvcoder/svp-gitops/commits/$(cat "$SVP_SESSION_DIR/stg-ref.txt")/statuses" --jq '.[] | select(.context == "argocd/stg") | "\(.state) \(.created_at)"' | head -n 1
git -C ../gitops fetch origin && git -C ../gitops merge-base --is-ancestor "$(cat "$SVP_SESSION_DIR/stg-ref.txt")" origin/main && echo on-main
```

Mong 40 hex, `success` và `on-main`; dán lại ba dòng. Commit trong `stg-ref.txt` là `stg_ref` của buổi prd (mục **Cổng promote prd** của
[`session-prd.md`](session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền)) khi buổi này qua mục **Phép kiểm transcode**.

#### Nền tảng EKS, TLS Postgres và alarm

Phép kiểm buổi stg của mục "Xác nhận" của ADR-0055…0058, làm trong lúc chờ bậc k6 (tunnel mở). Lệnh và output có thời điểm UTC vào một
file của `$SVP_SESSION_DIR`, một dòng kết luận mỗi phép vào "Xác nhận" của ADR tương ứng. Buổi prd chạy đúng các lệnh này với `anhnv-prd`,
`--context svp-prd`, tên `svp-prd`.

(a) Node: nhóm hệ thống on-demand mỗi AZ một node, node Karpenter cho pod còn lại (stg `spot`, ADR-0056 §2), NodeClaim khớp node:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes \
  -L topology.kubernetes.io/zone,eks.amazonaws.com/nodegroup,karpenter.sh/nodepool,karpenter.sh/capacity-type
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system get deploy karpenter
AWS_PROFILE=anhnv-stg kubectl --context svp-stg describe nodes -l eks.amazonaws.com/nodegroup=system | grep -A 8 'Allocated resources'
```

Mong: hai node `nodegroup=system` ở hai zone, không giá trị ở cột `nodepool`; mọi node khác có `nodepool=default`, `capacity-type=spot`, mỗi
cái một NodeClaim `Ready`; Deployment `karpenter` `2/2`. Request của nhóm hệ thống (khối `Allocated resources`) so với bảng tính ở phụ lục
§3 của ADR-0056 (mục "Xem lại khi": quá 80 % allocatable). Dán cả bốn output.

(b) Interruption đi qua hàng đợi: tắt một instance Karpenter; EventBridge chuyển sự kiện đổi trạng thái vào SQS `svp-stg-karpenter`, Karpenter
đọc nó, drain node và dựng node thay:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get node -l karpenter.sh/nodepool=default \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.providerID}{"\n"}{end}'
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws ec2 terminate-instances --instance-ids <i-… của một dòng trên> --region ap-southeast-1 \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --since=10m | grep -i -E 'interruption|disrupt' | head -n 5
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh -w                                     # NodeClaim mới Ready, Ctrl-C
```

Mong `shutting-down`, một dòng log của Karpenter nêu NodeClaim của instance đó, rồi một NodeClaim mới `Ready` (ghi thời gian từ lệnh tắt
tới đó). Không dòng log nào: dán log và số tin còn trong hàng đợi cho AI:

```sh
AWS_PROFILE=anhnv-stg aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages --region ap-southeast-1 \
  --queue-url "$(AWS_PROFILE=anhnv-stg aws sqs get-queue-url --queue-name svp-stg-karpenter --region ap-southeast-1 --query QueueUrl --output text)"
```

(c) Envoy và Kyverno HA, trải zone (ADR-0056 §4–§6): Envoy hai replica có HPA và PDB, Kyverno ba replica có PDB, pod nằm trên node của
nhiều zone (cột `NODE` so với cột zone của (a)):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system get hpa,pdb
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=svp -o wide
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pdb
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide
```

Mong HPA từ `2` tới `4`, PDB của Envoy `MIN AVAILABLE 1`, PDB của Kyverno `MAX UNAVAILABLE 1`; hai pod Envoy trên node ở hai zone khác nhau,
ba pod Kyverno trên node của cả hai zone (stg có hai AZ). Hai pod Envoy chung một zone khi zone kia còn chỗ: dán output cho AI.

(d) TLS Postgres (ADR-0057): chuỗi kết nối của service đi `verify-full` tới địa chỉ RDS, và RDS ghi mỗi kết nối là TLS (`log_connections`
của parameter group, log `postgresql` export ra CloudWatch Logs). Lệnh đầu chỉ in host và phần sau `?` của URL (không có user, mật khẩu);
lệnh sau đọc các dòng `connection authorized` của 30 phút gần nhất, trừ user nội bộ `rdsadmin` của RDS (nối qua socket local, không TLS):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret user-service-env -o jsonpath='{.data.DATABASE_URL}' | base64 --decode |
  sed -E 's#^[^@]*@([^/]*)/[^?]*#\1 #'; echo
AWS_PROFILE=anhnv-stg aws logs filter-log-events --log-group-name /aws/rds/instance/svp-stg/postgresql --region ap-southeast-1 \
  --start-time "$(( ($(date +%s) - 1800) * 1000 ))" --filter-pattern '"connection authorized" -rdsadmin' --max-items 10 --query 'events[].message' --output text
AWS_PROFILE=anhnv-stg aws rds describe-db-instances --db-instance-identifier svp-stg --region ap-southeast-1 --output text \
  --query 'DBInstances[0].[DBInstanceClass,EngineVersion,CACertificateIdentifier,StorageEncrypted,MaxAllocatedStorage]'
```

Mong: dòng đầu là `<địa chỉ RDS>:5432 ?sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt…`; mọi dòng log có `SSL enabled (protocol=TLSv1.3`
(hay `TLSv1.2`); `db.t4g.small`, `17.<minor RDS chọn>`, `rds-ca-rsa2048-g1`, `True`, trần storage của `stg.tfvars`. Pod của service
`Running` cùng các dòng đó chứng minh client kiểm được cert theo tên: với `verify-full`, tên sai thì client không nối được. Dòng log câu lệnh
chậm (`duration:` từ 1 s, ADR-0057 §6) không được kèm dòng `Parameters:`; mong `0`:

```sh
AWS_PROFILE=anhnv-stg aws logs filter-log-events --log-group-name /aws/rds/instance/svp-stg/postgresql --region ap-southeast-1 \
  --start-time "$(( ($(date +%s) - 3600) * 1000 ))" --filter-pattern '"Parameters:"' --query 'length(events)' --output text
```

(e) Log control plane, mã hoá Secret, endpoint, autoscaling storage MSK, slow-log Valkey (ADR-0055 §2, ADR-0056 §7, ADR-0058 §4, §5):

```sh
AWS_PROFILE=anhnv-stg aws eks describe-cluster --name svp-stg --region ap-southeast-1 --output json \
  --query 'cluster.[logging.clusterLogging[?enabled].types[], encryptionConfig[].resources[], resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess]]'
AWS_PROFILE=anhnv-stg aws application-autoscaling describe-scaling-policies --service-namespace kafka --region ap-southeast-1 --output text \
  --query 'ScalingPolicies[].[PolicyName,TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,TargetTrackingScalingPolicyConfiguration.TargetValue]'
AWS_PROFILE=anhnv-stg aws elasticache describe-replication-groups --replication-group-id svp-stg --region ap-southeast-1 --output text \
  --query 'ReplicationGroups[0].LogDeliveryConfigurations[].[LogType,DestinationType,LogFormat,Status]'
AWS_PROFILE=anhnv-stg aws logs describe-log-streams --log-group-name /aws/elasticache/svp-stg/slow-log --region ap-southeast-1 --max-items 1 \
  --query 'logStreams[].logStreamName' --output text
```

Mong năm loại log `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`; `secrets`; `false`, `true`; một policy
`KafkaBrokerStorageUtilization` ở mức của ADR-0058 §4 (API từ chối `kafka.t3.small` thì apply đã đỏ ở bước 5: dán lỗi cho AI);
`slow-log cloudwatch-logs json active`; một log stream (chưa có lệnh chậm nào thì rỗng: ghi lại, không là trượt).

(f) Alarm tới email (ADR-0058 §1): mọi alarm của bảng ở `OK` hay `INSUFFICIENT_DATA`, rồi ép một alarm `page` sang `ALARM`; email tới có URL
runbook; CloudWatch đưa alarm về trạng thái thật ở lần đánh giá kế (chu kỳ 60 s) và gửi thư `OK`:

```sh
AWS_PROFILE=anhnv-stg aws cloudwatch describe-alarms --alarm-name-prefix svp-stg- --region ap-southeast-1 --output text \
  --query 'MetricAlarms[].[AlarmName,StateValue]'
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws cloudwatch set-alarm-state --alarm-name svp-stg-rds-storage-low --state-value ALARM \
  --state-reason 'session test of the alarm path' --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws cloudwatch describe-alarm-history --alarm-name svp-stg-rds-storage-low --history-item-type StateUpdate \
  --max-items 3 --region ap-southeast-1 --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
```

Mong một dòng mỗi alarm của bảng ADR-0058 §2 (`svp-stg-<alarm>`), không dòng nào `ALARM`; vài phút sau hai thư tới `alarm_email`: `ALARM:
"svp-stg-rds-storage-low"` có URL `…/docs/runbooks/rds-storage-low.md` trong phần mô tả, rồi `OK`; lịch sử có hai lần đổi trạng thái. Không
thư nào: đọc lại subscription (mục 3–5); subscription đã xác nhận mà vẫn không thư: dán output cho AI (key policy của CMK, README của
`aws/modules/alarms`).

#### Gói Free và CORS của media

Hai phép tay sau smoke, (c) và (d) của ADR-0052; lệnh và output có thời điểm UTC vào phụ lục, một dòng kết luận vào mục "Xác nhận" của
[ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md#xác-nhận). Buổi prd chạy đúng các
lệnh này với `anhnv-prd`, `prd`.

(c) Gói đã có hiệu lực trên đúng hai tài nguyên, rồi plan lần hai không còn gì để đổi:

```sh
AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].arn' --output text
AWS_PROFILE=anhnv-stg aws pricing-plan-manager get-subscription --arn <arn trên> --region us-east-1 --query '[subscription.status,subscription.planTier]' --output text
AWS_PROFILE=anhnv-stg aws pricing-plan-manager get-subscription --arn <arn trên> --region us-east-1 --query 'subscription.resourceArns' --output json
aws/scripts/tf.sh stg env plan
```

Mong một ARN; `ACTIVE FREE`; hai ARN là distribution media (`arn:aws:cloudfront::<12 số>:distribution/<E…>`) và web ACL
(`arn:aws:wafv2:us-east-1:<12 số>:global/webacl/svp-stg-media/<id>`): AWS nhận giá trị enum, số luật của web ACL và alias `media.<domain>`.
Plan lần hai (sau apply, `aws/envs/stg`) phải cho `No changes`: dòng `ok plan text in …: No changes.` (AWS không đổi gì trên distribution khi
gói có hiệu lực, `price_class` khớp). Nó ghi đè `stg-env-plan.txt` của bước 4 và để lại `stg.tfplan` không thay đổi gì, không cần apply. Có
`change`: không apply, dán file text cho AI. `PENDING_APPROVAL`, `SYNC_IN_PROGRESS`: đọc lại sau vài phút; `FAILED`: dán output cho AI.

(d) CloudFront trả header CORS của policy managed `Managed-SimpleCORS` cho playlist của một video đã seed:

```sh
values=$SVP_SESSION_DIR/cluster-values.json
key=$(AWS_PROFILE=anhnv-stg aws s3api list-objects-v2 --bucket "$(jq -r .mediaBucket "$values")" --prefix media/ --region ap-southeast-1 \
  --query "Contents[?ends_with(Key, 'master.m3u8')].Key | [0]" --output text)
curl -sI -H "Origin: https://$(jq -r .domain "$values")" "https://$(jq -r .mediaDomain "$values")/$key" | grep -i -E '^(HTTP|access-control-allow-origin)'
```

Mong `HTTP/2 200` và `access-control-allow-origin: *`; rồi mở `https://<domain>` trên trình duyệt, đăng nhập và phát một video của feed.
Thiếu header hay video không phát: dán output và lỗi ở console của trình duyệt cho AI.

#### Phép kiểm edge

Phép kiểm của mục "Xác nhận" của
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md#xác-nhận), sau smoke; lệnh và output có
thời điểm UTC vào một file của `$SVP_SESSION_DIR`, một dòng kết luận mỗi env vào "Xác nhận". Buổi prd chạy đúng các lệnh này với `anhnv-prd`,
`$SVP_AWS_PRD_ACCOUNT_ID`, tên `svp-prd`. `curl -4` đi IPv4, để IP so ở (d) là một địa chỉ. Tên của buổi đọc từ `cluster-values.json`:

```sh
values=$SVP_SESSION_DIR/cluster-values.json
d=$(jq -r .domain "$values"); m=$(jq -r .mediaDomain "$values")
api="https://api.$d/public/videos/00000000-0000-4000-8000-000000000000"     # route công khai, không token; id không có nên 404
```

(a) Header, cert ACM đúng tên, TLS ≥ 1.2 của ba tên (`key` là playlist mà phép (d) của mục Gói Free vừa đọc):

```sh
for u in "https://$d/" "$api" "https://$m/$key"; do
  echo "== $u"
  curl -4 -sI "$u" | grep -i -E '^(HTTP|strict-transport-security|x-content-type-options|x-frame-options|referrer-policy|content-security-policy)'
done
for h in "$d" "api.$d" "$m"; do
  echo "== $h"
  openssl s_client -connect "$h:443" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -text |
    grep -E 'subject=|issuer=|DNS:'
  curl -4 -s -o /dev/null --tlsv1.0 --tls-max 1.1 "https://$h/"; echo "TLS 1.1: exit $?"
done
```

Mong: web và api có `strict-transport-security: max-age=63072000; includeSubDomains`, `x-content-type-options: nosniff`, `x-frame-options:
DENY`, `referrer-policy: strict-origin-when-cross-origin` (ở web, header nào web đã tự đặt thì giữ giá trị của web); api thêm `content-security-policy: default-src 'none'; frame-ancestors 'none'` và
`HTTP/2 404`. Media của stg (gói Free, `Managed-SimpleCORS`) chỉ có `HTTP/2 200`, không HSTS, nosniff (khác biệt stg/prd của ADR-0061); media
của prd (policy `svp-prd-media`) có HSTS và nosniff. Mỗi tên: `subject` là đúng tên đó, `issuer` của Amazon, đúng một `DNS:` là tên đó; `TLS
1.1: exit` khác 0 (CloudFront từ chối dưới TLS 1.2).

(b) ALB edge không có tên công khai: scheme `internal`, tên DNS chỉ ra IP private trong CIDR của VPC:

```sh
lb=$(AWS_PROFILE=anhnv-stg aws elbv2 describe-load-balancers --names svp-stg-edge --region ap-southeast-1 \
  --query 'LoadBalancers[0].[Scheme,DNSName]' --output text); echo "$lb"
dig +short "$(cut -f 2 <<<"$lb")" @1.1.1.1
```

Mong `internal internal-svp-stg-edge-….elb.amazonaws.com` và mỗi dòng của `dig` là một IP `10.…`.

(c) Mẫu thử WAF (chuỗi `${jndi:…}` của luật `Log4JRCE` trong `AWSManagedRulesKnownBadInputsRuleSet`; nháy đơn giữ nguyên chuỗi):

```sh
for u in "https://$d/" "$api"; do
  curl -4 -s -o /dev/null -w "%{http_code} $u\n" -H 'X-Svp-Probe: ${jndi:ldap://example.com/}' "$u"
done
```

Mong `403` ở cả hai.

(d) IP người xem tới gateway: ba request, một thường, một tự đặt `CloudFront-Viewer-Address`, một tự đặt `X-Forwarded-For`:

```sh
ip=$(curl -4 -s https://checkip.amazonaws.com); echo "$ip"
curl -4 -s -o /dev/null -w '%{http_code}\n' "$api"
curl -4 -s -o /dev/null -w '%{http_code}\n' -H 'CloudFront-Viewer-Address: 203.0.113.7:4242' "$api"
curl -4 -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-For: 198.51.100.7' "$api"
```

Mong ba dòng `404`. Access log của gateway không ghi IP; gateway ghi IP client vào thuộc tính `client.address` của span (cùng giá trị rate
limit theo IP dùng), nên phép này đọc span ở log group `aws/spans` (Transaction Search của X-Ray) bằng CloudWatch Logs Insights, 15 phút gần
nhất, hai truy vấn (hai phút sau ba request, để span đã tới). Hàm `insights` nằm ở khối biến và hàm dùng chung của mục
[Phép kiểm nền tảng managed](#phép-kiểm-nền-tảng-managed): chạy khối đó trước, một lần trong terminal (buổi prd với `E=prd`):

```sh
for f in "= \"$ip\"" 'in ["203.0.113.7", "198.51.100.7"]'; do
  echo "== client.address $f"
  insights aws/spans "$(( $(date +%s) - 900 ))" "$(date +%s)" \
    "filter \`attributes.client.address\` $f | stats count(*) as spans, count_distinct(traceId) as traces" || echo "query failed"
done
```

Mong truy vấn đầu có ít nhất ba trace ở thời điểm ba request, truy vấn sau không dòng nào (không trace nào): CloudFront đè
`CloudFront-Viewer-Address` viewer tự gửi, gateway không đọc `X-Forwarded-For`. Truy vấn sau có trace: dừng buổi, dán output cho AI (mục "Xem
lại khi" của ADR-0061). Truy vấn đầu cũng rỗng: span chưa tới X-Ray (mục Phép kiểm nền tảng managed (c)), dán output. Dòng `query failed`
là truy vấn hỏng, không phải kết quả rỗng: dán dòng lỗi ngay trên nó (lỗi của `aws`, như phiên SSO hết hạn, hay dòng `insights:`).

(e) Log mới ở bucket log CloudFront và bucket log WAF của account Log Archive (năm phút sau các request trên; profile `anhnv-log-ro` của bước
(4) của [`org-security-setup.md`](org-security-setup.md#bước-4-awsorg-đủ)):

```sh
L=$SVP_AWS_LOG_ACCOUNT_ID A=$SVP_AWS_STG_ACCOUNT_ID
AWS_PROFILE=anhnv-log-ro aws s3 ls "s3://svp-cloudfront-$L-us-east-1/AWSLogs/$A/CloudFront/" --recursive --region us-east-1 |
  tail -n 3 | sed "s/$A/<account>/g"
AWS_PROFILE=anhnv-log-ro aws s3 ls "s3://aws-waf-logs-svp-$L-us-east-1/AWSLogs/$A/WAFLogs/" --recursive --region us-east-1 |
  tail -n 3 | sed "s/$A/<account>/g"
```

Mong ở mỗi bucket object có thời điểm của buổi: log CloudFront (Parquet) của `svp-stg-web`, `svp-stg-api` (media của stg trong gói Free không có
access log; prd có cả media), log WAF của các web ACL. WAF giao file mỗi năm phút: bucket WAF rỗng sau năm phút nữa là lỗi, dán output cho AI.

CloudFront giao log chậm hơn: thường trong một giờ sau request, nhưng chỉ giao đều khoảng bốn giờ sau khi bật log (buổi tạo lại distribution và
delivery), có phần trễ tới 24 giờ
([CloudFront: Standard logging reference](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logs-reference.html)),
nên bucket CloudFront rỗng trong buổi chưa phải lỗi. Khi đó kiểm delivery của account env trỏ đúng đích:

```sh
AWS_PROFILE=anhnv-stg aws logs describe-deliveries --region us-east-1 \
  --query 'deliveries[].[deliverySourceName,deliveryDestinationArn]' --output text | sed "s/$L/<log>/g"
```

Mong mỗi distribution có log (`svp-stg-web`, `svp-stg-api`; prd thêm `svp-prd-media`) một dòng tới
`arn:aws:logs:us-east-1:<log>:delivery-destination:svp-cloudfront-stg`. Thiếu dòng hay đích khác là lỗi cấu hình: dán output cho AI. Đủ dòng:
ghi `chờ giao` cùng thời điểm UTC của request cuối vào file phép kiểm, đi tiếp buổi, chạy lại khối `aws s3 ls` trên cuối buổi và sau buổi (chỉ
đọc bucket của Log Archive, không cần env còn dựng). Có object thì ghi kết luận; bốn giờ sau request cuối vẫn rỗng thì dán cả hai output cho AI.

(f) DNSSEC của zone prd và `CAA` của zone env:

```sh
dig +dnssec SOA aws.<domain> @1.1.1.1 | grep -E '^;; (flags|->>HEADER)'
dig +short CAA "$d" @1.1.1.1 | sort
```

Mong `status: NOERROR` và cờ `ad`; tám dòng `0 issue`, `0 issuewild` cho bốn CA của Amazon. Không cờ `ad`: [`edge-setup.md`](edge-setup.md),
bước (3).

(g) Plan lần hai `No changes`: phép (c) của mục trên (prd: bước 11 của `session-prd.md`). (h) Sau destroy, `sweep.sh stg` sạch: bước 23.

#### Kafka và Valkey managed

Phép kiểm (a)–(e) của mục "Xác nhận" của
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md#xác-nhận); (b) là smoke của
`measure.sh` (service ghi, đọc Kafka qua SASL/SCRAM-SHA-512 trên TLS), (f) là hai lượt `sweep.sh` cuối buổi. Lệnh và output có thời điểm UTC
vào phụ lục, một dòng kết luận mỗi env vào "Xác nhận". Buổi prd chạy đúng các lệnh này với `anhnv-prd`, `svp-prd`.

Mọi lệnh chạm Kafka, Valkey đi qua CLI vận hành (ADR-0053 §13): `svp-kafka` (đăng nhập `svp-admin`), `svp-valkey` (đăng nhập `svp-ops`) trong
Deployment `svp-data/svp-ops`, không `kubectl run`, không công cụ trên máy. Thử quyền của một user thường: `SVP_AS_USER=<user>`, mật khẩu là
dòng đầu của stdin, lấy từ Secret của chính client đó (`svp/<service>-env`), không qua đối số, không in ra.

(a) MSK `ACTIVE` với cấu hình của ADR-0053 §2, ElastiCache `available`; phút dựng là hai dòng `Creation complete after …` của bước 5, phút gỡ
là hai dòng `Destruction complete after …` của bước 22; plan lần hai `No changes` là phép (c) của mục trên:

```sh
AWS_PROFILE=anhnv-stg aws kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --output text \
  --query 'ClusterInfoList[].[State,Provisioned.CurrentBrokerSoftwareInfo.KafkaVersion,Provisioned.BrokerNodeGroupInfo.InstanceType,Provisioned.NumberOfBrokerNodes]'
AWS_PROFILE=anhnv-stg aws kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --output text \
  --query 'ClusterInfoList[].Provisioned.[ClientAuthentication.Sasl.Scram.Enabled,ClientAuthentication.Sasl.Iam.Enabled,EncryptionInfo.EncryptionInTransit.ClientBroker]'
AWS_PROFILE=anhnv-stg aws elasticache describe-replication-groups --replication-group-id svp-stg --region ap-southeast-1 --output text \
  --query 'ReplicationGroups[].[Status,TransitEncryptionMode,AtRestEncryptionEnabled,length(MemberClusters)]'
AWS_PROFILE=anhnv-stg aws elasticache describe-users --region ap-southeast-1 --output text \
  --query "Users[?starts_with(UserId, 'svp-stg-')].[UserName,Status,AccessString]"
```

Mong `ACTIVE`, `4.1.x.kraft`, `kafka.t3.small`, `2`; `True`, `False`, `TLS`; `available`, `required`, `True`, `1`; bốn user `active` với
access string đúng nguyên văn ADR-0053 §9 (ElastiCache viết lại một chuỗi là mục "Xem lại khi" của ADR: dán cho AI). Dán lại cả bốn output.

(c) Topic, ACL, và một service bị từ chối trên topic không có ACL của nó. Topic thử `svp-acl-check` tạo bằng `svp-admin` rồi xoá ngay:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --list --exclude-internal
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka acls --list --principal User:svp-feed-service
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --create --topic svp-acl-check --partitions 1
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret feed-service-env -o jsonpath='{.data.KAFKA_SASL_PASSWORD}' | base64 --decode)
printf '%s\nprobe\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c kafka -- \
  env SVP_AS_USER=svp-feed-service /opt/svp/bin/svp-kafka console-producer --topic svp-acl-check --producer-property max.block.ms=15000 2>&1 |
  grep -m 1 -oE '(TopicAuthorization|SaslAuthentication)Exception[^\[]*(\[[^]]*\])?'
unset pw
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --delete --topic svp-acl-check
```

Mong tám topic (`video.lifecycle.v1`, `media.transcodes.v1`, `user.follows.v1`, `engagement.views.v1` và bốn topic `.dlq` của chúng); ACL của
`svp-feed-service` chỉ Read trên `user.follows.v1`, `video.lifecycle.v1`, Write trên `user.follows.v1.dlq`, `video.lifecycle.v1.dlq`, Read trên
group `feed-service`; dòng `TopicAuthorizationException: Not authorized to access topics: [svp-acl-check]`. `SaslAuthenticationException` là
mật khẩu của Secret không khớp secret `AmazonMSK_svp-stg-svp-feed-service` (MSK đồng bộ tới 10 phút sau apply): đọc lại sau 10 phút, còn thì dán cho AI.

(d) ACL Valkey chặn db và tiền tố khoá của service khác (mật khẩu là phần giữa `:` và `@` của `REDIS_URL` trong Secret của service):

```sh
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret feed-service-env -o jsonpath='{.data.REDIS_URL}' | base64 --decode |
  sed -E 's#^rediss://[^:]+:([A-Za-z0-9]+)@.*#\1#')
printf '%s\nSELECT 10\nSELECT 14\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c valkey -- \
  env SVP_AS_USER=svp-feed-service /opt/svp/bin/svp-valkey
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret gateway-env -o jsonpath='{.data.REDIS_URL}' | base64 --decode |
  sed -E 's#^rediss://[^:]+:([A-Za-z0-9]+)@.*#\1#')
printf '%s\nGET svp:feed:explore:check\nGET svp:gw:check\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c valkey -- \
  env SVP_AS_USER=svp-gateway /opt/svp/bin/svp-valkey -n 10
unset pw
```

Mong, theo thứ tự: một dòng `NOPERM …` (`svp-feed-service` không vào db 10) rồi `OK` (db 14 của nó); một dòng `NOPERM …` (`svp-gateway` không
đọc `svp:feed:*`) rồi một dòng trống (khoá `svp:gw:check` không có, đọc được). `WRONGPASS` hay lỗi TLS: dán cho AI.

(e) Lag hiện trên dashboard: trong lúc giữ tải, AMG (bước 11) dashboard "SVP — Kafka and pipeline", panel "Consumer lag by
group (max over partitions)" có đường của bốn group `video-service`, `engagement-service`, `feed-service`, `media-worker` (receiver
`kafkametrics` của Collector, user `svp-otelcol`). Đối chiếu với broker:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka consumer-groups --describe --all-groups
```

Mong cột `LAG` của mỗi group cùng cỡ với panel. Panel trống: dán lỗi của receiver
(`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/otel-collector --tail=50 | grep -i kafka`) cho AI.

#### Phép kiểm nền tảng managed

Phép kiểm buổi của mục "Xác nhận" của ADR-0062 (registry), ADR-0063 (observability), ADR-0064 (endpoint): image kéo từ ECR, mạng riêng,
telemetry, cảnh báo, canary, dữ liệu còn sau destroy. Làm trong bước 11, tunnel mở; lệnh và output có thời điểm UTC vào một file của
`$SVP_SESSION_DIR`, một dòng kết luận mỗi phép vào "Xác nhận" của ADR tương ứng. Buổi prd chạy (a), (b), (c), (e) và phần luật của (d) với
`anhnv-prd`, `--context svp-prd`, `svp-prd` (mục cùng tên của [`session-prd.md`](session-prd.md#phép-kiểm-nền-tảng-managed)).

Biến và hàm dùng chung, một lần trong terminal của buổi (mở lại terminal thì chạy lại khối này). `amp_get` gọi API Prometheus của workspace AMP
bằng `curl --aws-sigv4`: credential tạm của profile đi từ `aws configure export-credentials` qua `jq` vào `curl --config -`, đều qua pipe, không
qua đối số, file hay output. Workspace, log group lấy từ root `aws/accounts/stg`, nên các hàm chạy được cả khi env đã gỡ:

```sh
E=stg                                                       # buổi prd: E=prd
values=$SVP_SESSION_DIR/cluster-values.json
ecr=$(jq -r .ecrRegistry "$values")                         # chỉ (a), (b): cần cluster của buổi
ws=$(AWS_PROFILE="anhnv-$E" terraform -chdir="aws/accounts/$E" output -raw amp_workspace_id)
amp="https://aps-workspaces.ap-southeast-1.amazonaws.com/workspaces/$ws/"
# amp_get PATH [tuỳ chọn curl…]: GET tới API Prometheus của workspace, ký SigV4
amp_get() {
  local p=$1; shift
  AWS_PROFILE="anhnv-$E" aws configure export-credentials --format process --region ap-southeast-1 |
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
  id=$(AWS_PROFILE="anhnv-$E" aws logs start-query --log-group-names "$1" --start-time "$2" --end-time "$3" --query-string "$4" \
    --region ap-southeast-1 --query queryId --output text) || return 1
  while :; do
    st=$(AWS_PROFILE="anhnv-$E" aws logs get-query-results --query-id "$id" --region ap-southeast-1 --query status --output text) ||
      return 1
    case $st in
      Complete) break ;;
      Scheduled | Running) ;;
      *) echo "insights: query $id ended $st" >&2; return 1 ;;
    esac
    [ $((n += 1)) -lt 150 ] || { echo "insights: query $id still $st after 300 s" >&2; return 1; }
    sleep 2
  done
  AWS_PROFILE="anhnv-$E" aws logs get-query-results --query-id "$id" --region ap-southeast-1 --query 'results[][].[field,value]' --output text
}
```

(a) Image (ADR-0062): pod kéo image từ ECR của account (policy `svp-registry-mirror` đổi tham chiếu lúc tạo pod, IVP `svp-images` xác minh ở
ECR bằng Pod Identity của Kyverno); host image theo namespace:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get pods -A -o json |
  jq -r '.items[] | .metadata.namespace as $n | ((.spec.initContainers // [])[], .spec.containers[]) | "\($n) \(.image | split("/")[0])"' |
  sort | uniq -c | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/g"
```

Mong mọi namespace chỉ có host `<account>.dkr.ecr.ap-southeast-1.amazonaws.com`, trừ `kube-system` (Kyverno không nhận request của namespace
này: Karpenter, Load Balancer Controller, add-on EKS kéo upstream hay ECR của AWS), `kyverno` (policy loại trừ) và `argocd` (Terraform cài trước
khi policy có; pod tạo trước policy kéo upstream tới lần tạo lại). Namespace khác có host `ghcr.io`, `docker.io`, `quay.io`, `registry.k8s.io`,
`public.ecr.aws`: dán output. Chữ ký và attestation đi theo bản ECR (đăng nhập ECR vào một `DOCKER_CONFIG` tạm, mật khẩu qua stdin):

```sh
img=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods -o json |
  jq -r '[.items[].spec.containers[].image | select(contains("/svp-backend/gateway@"))][0]')
echo "$img" | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/"
export DOCKER_CONFIG=$(mktemp -d)
AWS_PROFILE=anhnv-stg aws ecr get-login-password --region ap-southeast-1 | cosign login "$ecr" -u AWS --password-stdin
ident=(--certificate-oidc-issuer https://token.actions.githubusercontent.com
  --certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
cosign verify "${ident[@]}" "$img" >/dev/null 2>&1 && echo "signature verified"
for t in vuln slsaprovenance1; do cosign verify-attestation --type "$t" "${ident[@]}" "$img" >/dev/null 2>&1 && echo "$t verified"; done
rm -rf "$DOCKER_CONFIG"; unset DOCKER_CONFIG
```

Mong `<account>.dkr.ecr…/svp-backend/gateway@sha256:…` rồi ba dòng `verified`. Thiếu dòng: chạy lại lệnh đó không có `>/dev/null 2>&1`,
dán lỗi. Inspector quét repo cache (image bên thứ ba vừa làm nóng; vài phút sau khi image vào cache), không quét repo phát hành:

```sh
AWS_PROFILE=anhnv-stg aws inspector2 list-coverage --region ap-southeast-1 --output text \
  --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_ECR_CONTAINER_IMAGE"}]}' \
  --query 'coveredResources[].scanStatus.statusCode' | tr '\t' '\n' | sort | uniq -c
AWS_PROFILE=anhnv-stg aws inspector2 list-findings --region ap-southeast-1 --max-results 10 --output text \
  --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_ECR_CONTAINER_IMAGE"}],"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' \
  --sort-criteria field=SEVERITY,sortOrder=DESC --query 'findings[].[severity,resources[0].details.awsEcrContainerImage.repositoryName,title]'
```

Mong phần lớn image `ACTIVE` (đang được quét liên tục); ít nhất một finding, repo của nó bắt đầu bằng `ghcr/`, `docker-hub/`, `quay/`, `k8s/` hay
`ecr-public/`, không repo `svp-backend/`, `svp-frontend/`. Rỗng: đọc lại cuối bước 11; vẫn rỗng thì dán cả hai output. Finding cũng vào
Security Hub của `svp-security` (`ProductName` Inspector), không gửi email.

(b) Mạng riêng (ADR-0064): endpoint interface có private DNS ở subnet private (stg một AZ), tên API AWS phân giải ra IP trong VPC từ một pod,
Kyverno và External Secrets vẫn gọi được API qua đó:

```sh
jq -r .vpcCidr "$values"
AWS_PROFILE=anhnv-stg aws ec2 describe-vpc-endpoints --region ap-southeast-1 --output text \
  --filters "Name=vpc-id,Values=$(jq -r .vpcId "$values")" Name=vpc-endpoint-type,Values=Interface \
  --query 'VpcEndpoints[].[ServiceName,State,PrivateDnsEnabled,length(SubnetIds)]' | sort
for n in sts secretsmanager logs api.ecr "$ecr" aps-workspaces aps xray ssm ec2 elasticloadbalancing sqs eks-auth; do
  case $n in *.amazonaws.com) h=$n ;; eks-auth) h=eks-auth.ap-southeast-1.api.aws ;; *) h=$n.ap-southeast-1.amazonaws.com ;; esac
  printf '%s ' "$h" | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/"
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c valkey -- nslookup "$h" 2>/dev/null |
    awk '/^Address/ && !/:53$/ { printf "%s ", $NF } END { print "" }'
done
```

Mong: CIDR của VPC; 15 dòng của ADR-0064 §1 (`com.amazonaws.ap-southeast-1.sts`, `eks-auth`, `secretsmanager`, `logs`, `ssm`, `ssmmessages`,
`ec2messages`, `ecr.api`, `ecr.dkr`, `ec2`, `elasticloadbalancing`, `aps-workspaces`, `aps`, `xray`, `sqs`) cộng `guardduty-data`, mỗi dòng
`available True 1` (prd `3`); mỗi tên in ít nhất một IP trong CIDR đó, không IP công khai (`nslookup` của BusyBox trong container `valkey` của
`svp-ops`). Tên ra IP công khai: private DNS của endpoint đó chưa bật hay endpoint thiếu: dán output. Rồi Kyverno, External Secrets và Pod
Identity:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pods
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n external-secrets get pods
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get externalsecrets.external-secrets.io -A -o json |
  jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
    | "\(.metadata.namespace)/\(.metadata.name)"] as $bad | "\(.items | length) ExternalSecrets, not Ready: \($bad | if length == 0 then "none" else join(" ") end)"'
AWS_PROFILE=anhnv-stg aws eks list-pod-identity-associations --cluster-name svp-stg --region ap-southeast-1 \
  --query 'associations[].[namespace,serviceAccount]' --output text | sort
```

Mong mọi pod `Running` và `READY` đủ; dòng `<N> ExternalSecrets, not Ready: none`; association có năm danh tính của
module `eks` (`svp-obs/otel-collector`, `svp-obs/kps-prometheus`, `svp-obs/ack-prometheusservice-controller`,
`kyverno/kyverno-admission-controller`, `argo-rollouts/argo-rollouts`) cạnh các danh tính có sẵn. ExternalSecret không Ready hay pod Kyverno
không Ready: NetworkPolicy chưa mở 443 tới CIDR của VPC (value `awsEndpointCidrs`); dán output và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n external-secrets logs deploy/external-secrets --tail=30`.

(c) Telemetry (ADR-0063): metric ở AMP (agent và Collector), log ở `/svp/stg/otel`, span ở `aws/spans`, series service graph do Collector
sinh; trong lúc k6 giữ tải:

```sh
promql 'count by (job) (up{cluster="svp-stg"})'
promql 'count by (service_name) ({__name__=~"svp_.+"})'
promql 'sum by (client, server) (traces_service_graph_request_total)'
insights /svp/stg/otel "$(( $(date +%s) - 900 ))" "$(date +%s)" 'stats count(*) as records'
insights aws/spans "$(( $(date +%s) - 900 ))" "$(date +%s)" 'stats count(*) as spans, count_distinct(traceId) as traces'
```

Mong: mỗi job mà agent scrape một dòng (cluster `svp-stg`); mỗi service của lab đang nhận tải một dòng (metric OTLP của Collector, tên như trên
Prometheus); cặp `client`, `server` của các lời gọi gateway → service; `records`, `spans`, `traces` lớn hơn 0. Rỗng: dán output và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/otel-collector --tail=50` (lỗi SigV4, 403, timeout tới endpoint).
Trễ remote write của agent (số đo cho ADR-0063 §8, giây; tiêu chí ≤ 30):

```sh
promql 'max(max_over_time((prometheus_remote_storage_highest_timestamp_in_seconds - ignoring(remote_name, url) group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds)[30m:30s]))'
```

Trên AMG (bước 11): **Explore** → data source `prometheus` → `up{cluster="svp-stg"}` có kết quả (metric qua AMG); **Dashboards**: năm dashboard
"SVP — …" của repo code, mỗi cái khung 1 giờ gần nhất, ghi tên mọi panel "No data". Panel của "SVP — Web vitals (RUM)" chỉ có dữ liệu khi
trình duyệt mở web (phép (d) của mục Gói Free); hai panel Tempo (TraceQL, service map) không có trên eks. Grafana Operator đã đồng bộ:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs get \
  grafanas.grafana.integreatly.org,grafanadatasources.grafana.integreatly.org,grafanadashboards.grafana.integreatly.org -o json |
  jq -r '.items[] | "\(.kind) \(.metadata.name) \(.status.stage // "") \([.status.conditions[]? | "\(.type)=\(.status)"] | join(","))"'
```

Mong một `Grafana` (`stage` hoàn tất), hai `GrafanaDatasource`, năm `GrafanaDashboard`, mọi điều kiện `…=True`. Dán danh sách panel trống
theo dashboard (rỗng là đạt).

(d) Cảnh báo và canary (ADR-0063 §5, §8). Luật của chart ở AMP, chu kỳ 15 s (quota của bước (8) của
[`platform-setup.md`](platform-setup.md#bước-8-quota-chu-kỳ-luật-amp)), Alertmanager của AMP gửi SNS:

```sh
AWS_PROFILE=anhnv-stg aws amp list-rule-groups-namespaces --workspace-id "$ws" --region ap-southeast-1 \
  --query 'ruleGroupsNamespaces[].[name,status.statusCode]' --output text
AWS_PROFILE=anhnv-stg aws amp describe-alert-manager-definition --workspace-id "$ws" --region ap-southeast-1 \
  --query 'alertManagerDefinition.status.statusCode' --output text
amp_get api/v1/rules | jq -r '.data.groups[] | "\(.name) \(.interval) \(.rules | length)"'
```

Mong hai namespace `svp-alerts`, `slo-generated` `ACTIVE`; `ACTIVE`; mỗi nhóm luật một dòng chu kỳ `15`. Namespace `CREATION_FAILED` (chu kỳ dưới
quota) hay thiếu: dán output và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs describe rulegroupsnamespaces.prometheusservice.services.k8s.aws`.

Canary thật của gateway và một cảnh báo `page` dùng chung một revision mới: một PR ở `svp-gitops` thêm vào `envs/stg/gateway.yaml` một annotation
của pod template (cùng image, revision mới, nên Argo Rollouts chạy canary; cách diễn tập canary của lab), mở và chờ check xanh **trước buổi**,
chưa merge:

```yaml
podAnnotations:
  svp-session-canary: "<UTC của buổi, vd 2026-11-20T03:00Z>"
```

Đường lỗi trước: một policy inline tạm chặn `aps:QueryMetrics` của role Pod Identity `svp-stg-argo-rollouts` (IAM xét policy ở mỗi request, nên
credential đang có của controller bị chặn ngay; không sửa code), rồi merge PR. AnalysisRun nền lỗi ba lần liên tiếp thì Rollout bị abort,
Application `gateway` thành Degraded, và sau 10 phút luật `ArgoCDApplicationDegraded` (`page`) cháy:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws iam put-role-policy --role-name svp-stg-argo-rollouts --policy-name svp-session-deny-query --region us-east-1 \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"aps:QueryMetrics","Resource":"*"}]}'
date -u +%Y-%m-%dT%H:%M:%SZ | tee "$SVP_SESSION_DIR/canary-deny-start"
```

Merge PR, rồi đọc mỗi phút (Argo CD sync trong vài phút; AnalysisRun nền đo từ giây 60 của canary):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout gateway -o jsonpath='{.status.phase} {.status.abort} {.status.message}{"\n"}'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io --sort-by=.metadata.creationTimestamp -o json |
  jq -r '.items[-2:][] | "\(.metadata.name) \(.status.phase) \([.status.metricResults[]? | "\(.name): \(.measurements[-1] | "\(.phase) \(.value // "") \(.message // "")")"] | join("; "))"'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get httproute api -o jsonpath='{.spec.rules[0].backendRefs[*].weight}{"\n"}'
```

Mong: AnalysisRun mới nhất `gateway-…` `Error`, measurement `Error` nêu `AccessDenied` hay `403`; Rollout `Degraded true` với message
`RolloutAborted…`; trọng số `100 0` (canary không được promote, bản stable nhận mọi request). Rồi chờ cảnh báo (khoảng 12 phút sau abort: `for`
10 phút, `rule_query_offset` 60 s, chu kỳ đánh giá):

```sh
amp_get api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.labels.name // "-") \(.labels.severity) \(.state) \(.activeAt)"'
```

Mong dòng `ArgoCDApplicationDegraded gateway page firing` (Application cha có thể có dòng của mình); vài phút sau một thư SNS của topic
`svp-stg-alarms` tới `alarm_email` mang `ArgoCDApplicationDegraded`, `severity` `page` và `runbook_url`
`…/docs/runbooks/argocd-application-degraded.md`. Dán dòng `firing`, tiêu đề và giờ nhận thư, nguyên văn phần thân (che account). Không thư:
đọc lại subscription (mục 3–5), rồi dán output của `amp_get api/v1/alerts`.

Trả lại, rồi canary đi tiếp **trong lúc k6 giữ tải** (canary cần ít nhất 30 response không 4xx mỗi phút: chờ mốc `k6-<n>-start` của một bậc
trong `timeline.tsv` cộng 2 phút lên tải; còn ≥ 6 phút giữ tải):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws iam delete-role-policy --role-name svp-stg-argo-rollouts --policy-name svp-session-deny-query --region us-east-1
AWS_PROFILE=anhnv-stg aws iam list-role-policies --role-name svp-stg-argo-rollouts --region us-east-1 --query PolicyNames --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp patch rollout gateway --subresource=status --type=merge -p '{"status":{"abort":false}}'
```

Dòng `list-role-policies` không còn `svp-session-deny-query`. Lệnh `patch` là "retry" của Argo Rollouts (gỡ cờ abort): canary chạy lại từ 25 %,
khoảng 3–4 phút. Đọc lại bằng khối đọc ở trên, rồi giá trị mọi lần đo của hai AnalysisRun mới nhất:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io --sort-by=.metadata.creationTimestamp -o json |
  jq -r '.items[-2:][] | "\(.metadata.name) \(.status.phase) \([.status.metricResults[]? | "\(.name)=\([.measurements[].value] | join(","))"] | join("; "))"'
```

Mong Rollout `Healthy` (cờ abort `false`), trọng số `100 0` sau khi promote xong, hai AnalysisRun (nền và `…-gate`) `Successful`, mọi
giá trị ≥ 0 (không `-1`: số đo thật từ AMP). `Inconclusive` với `-1`: canary thiếu tải hay mẫu tới AMP trễ (trễ remote write ở (c));
`Error` sau khi gỡ policy: chờ một phút rồi retry lại; còn thì dán output. Annotation ở lại trong `envs/stg/gateway.yaml` (không đổi gì
ngoài pod template); bỏ nó là một revision mới, tức một canary nữa.

Hai AnalysisRun thủ công, cùng metric `canary-5xx-ratio` của template `gateway-canary-gate` đọc từ cluster: một cái điều kiện thất bại luôn đúng
(`result[0] >= -1`, mong `Failed`), một cái trỏ workspace không có (mong `Error`); không Rollout nào dùng chúng:

```sh
tpl=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysistemplate gateway-canary-gate -o json)
jq '{apiVersion: "argoproj.io/v1alpha1", kind: "AnalysisRun",
  metadata: {generateName: "session-check-failed-", namespace: "svp", labels: {"svp-session-check": "true"}},
  spec: {metrics: [.spec.metrics[0] | del(.successCondition) | .failureCondition = "result[0] >= -1"]}}' <<<"$tpl" |
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg create -f -
jq '{apiVersion: "argoproj.io/v1alpha1", kind: "AnalysisRun",
  metadata: {generateName: "session-check-error-", namespace: "svp", labels: {"svp-session-check": "true"}},
  spec: {metrics: [.spec.metrics[0] | .provider.prometheus.address |= sub("ws-[0-9a-f-]+"; "ws-00000000-0000-0000-0000-000000000000")]}}' <<<"$tpl" |
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg create -f -
```

Một phút sau, đọc rồi xoá:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io -l svp-session-check=true -o json |
  jq -r '.items[] | "\(.metadata.name) \(.status.phase) \(.status.metricResults[0].measurements[-1] | "\(.phase) \(.value // "") \(.message // "")")"'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp delete analysisruns.argoproj.io -l svp-session-check=true
```

Mong `session-check-failed-… Failed Failed <số ≥ -1>` và `session-check-error-… Error Error … 404` (hay thông điệp không tìm thấy workspace).

(e) Dữ liệu còn sau destroy (ADR-0063, "Xác nhận"): metric, log và trace của buổi nằm ở account, không ở cluster. Ghi lại **trước bước 15**,
sau khi k6 xong, một khoảng thời gian tuyệt đối trong buổi và một trace của khoảng đó; rồi chạy lại đúng các truy vấn sau bước 24 (cùng ngày)
và ở buổi kế. Kết quả nằm ở `.session/persist-stg/` (git bỏ qua, không commit; giữ qua các buổi, như thư mục buổi). `end` cách lúc ghi ít nhất 10
phút, để mẫu, log, span đến trễ đã tới:

```sh
d=.session/persist-$E; mkdir -p "$d"
printf 'start=%s\nend=%s\n' '<UTC đầu khoảng, sau mốc svp-root-healthy, vd 2026-11-20T03:30:00Z>' '<UTC cuối khoảng>' >"$d/window.env"
. "$d/window.env"
insights aws/spans "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$start" +%s)" "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$end" +%s)" \
  'stats count(*) as spans by traceId | sort spans desc | limit 1'
printf 'trace=%s\n' '<traceId vừa in>' >>"$d/window.env"
# persist: đúng các truy vấn được so; đọc khoảng và trace từ window.env
persist() {
  local s e
  . "$d/window.env"
  s=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$start" +%s); e=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$end" +%s)
  echo "== $start $end"
  echo "== series per job"; promql "count by (job) (count_over_time(up{cluster=\"svp-$E\"}[$((e - s))s]))" "$e"
  echo "== samples per job"; promql "sum by (job) (count_over_time(up{cluster=\"svp-$E\"}[$((e - s))s]))" "$e"
  echo "== log records"; insights "/svp/$E/otel" "$s" "$e" 'stats count(*) as records' || echo "query failed"
  echo "== spans of trace $trace"
  insights aws/spans "$s" "$e" "filter traceId = \"$trace\" | stats count(*) as spans" || echo "query failed"
}
persist | tee "$d/before.txt"
```

Mong mỗi phần có dòng (series, số mẫu mỗi job, `records`, `spans` lớn hơn 0), không dòng `query failed`. Dán `window.env` (không có giá trị bí
mật) và `before.txt`. Sau bước 24 cùng ngày (mục **Kết thúc buổi**) và ở buổi kế (trước bước 1, terminal có biến và hàm của khối dùng chung,
`E`, `d` như trên):

```sh
persist | tee "$d/after-destroy.txt"; diff "$d/before.txt" "$d/after-destroy.txt" && echo same      # buổi kế: next-session.txt
```

Tiêu chí: `same`, tức metric bằng hệt (cùng series, cùng số), log và trace còn đủ. Khác: dán `diff`; ghi chênh lệch vào "Xác nhận". Buổi kế
còn trong retention của workspace AMP, nhưng log ứng dụng và `aws/spans` giữ ngắn hơn (`log_retention_days`, `span_retention_days` ở `locals` của
`aws/accounts/<env>`, ADR-0063 §10): quá hạn đó thì hai phần log, trace rỗng là đúng retention, ghi "ngoài retention", chỉ so metric.
Dòng `query failed` là truy vấn hỏng, không phải dữ liệu mất: lỗi nằm trên terminal (stderr không vào file); sửa nguyên nhân (như
`AWS_PROFILE=anhnv-$E aws sso login --region us-east-1` khi phiên SSO hết hạn) rồi chạy lại `persist`.

(f) Quét sót: `sweep.sh stg` và `sweep.sh mgmt` sạch ở bước 23–24, cùng các loại mới (endpoint interface, rule groups namespace của AMP) và
dòng `kept` của registry, observability.

#### Phép kiểm transcode

Phép kiểm buổi của mục "Xác nhận" của
[ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#xác-nhận): `media-worker` chạy
lệnh con `mediaconvert` và video đi qua MediaConvert, header của output qua CloudFront, FF-9 của threat model, lớp cắt đầu vào, hàng đợi sự
kiện rỗng, và đường MediaConvert của phép đo hai đường. Làm trong lúc bậc k6 đầu tiên (1 pod) giữ tải, tunnel mở: k6 chỉ gọi
`POST /videos`, không tải file, nên không job nào khác chen vào số đo. Lệnh và output có thời điểm UTC vào một file của `$SVP_SESSION_DIR`, một
dòng kết luận mỗi phép vào "Xác nhận" của ADR-0066, số thô của (b) vào bảng "Kết quả" ở phụ lục của nó. Buổi prd chạy (a) và (f) với
`anhnv-prd`, `--context svp-prd`, tên `svp-prd` ([`session-prd.md`](session-prd.md#phép-kiểm-transcode)). Chi phí của mục này nằm trong phần
chi phí của transcode ở [ADR-0066 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí).

Ba clip sinh trên máy một lần, trong lúc chờ bước 5 (vài phút CPU): clip tham chiếu 60 s và 200 s (lệnh của mục "Phép đo hai đường:
phương pháp" ở [phụ lục ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md#phép-đo-hai-đường-phương-pháp)),
và một bản 200 s không edit list mà header MP4 khai 60 s, cho (e). Script Python chỉ ghi lại trường thời lượng của ba hộp `mvhd`, `tkhd`,
`mdhd` (version 0, như ffmpeg ghi); mẫu của luồng giữ nguyên 200 s:

```sh
c=$SVP_SESSION_DIR
for t in 60 200; do
  ffmpeg -f lavfi -i testsrc2=size=1080x1920:rate=30 -f lavfi -i sine=frequency=440 -t "$t" -c:v libx264 -pix_fmt yuv420p -c:a aac "$c/clip-${t}s.mp4"
done
ffmpeg -f lavfi -i testsrc2=size=1080x1920:rate=30 -f lavfi -i sine=frequency=440 -t 200 -c:v libx264 -pix_fmt yuv420p -c:a aac \
  -use_editlist 0 "$c/clip-200s-noedit.mp4"
python3 - "$c/clip-200s-noedit.mp4" "$c/clip-200s-says-60s.mp4" 60 <<'EOF'
import struct, sys
src, dst, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
b = bytearray(open(src, 'rb').read())
movie = 0
def walk(off, end):
    global movie
    while off < end:
        size, kind = struct.unpack_from('>I4s', b, off)
        if size < 8:
            sys.exit('box size %d at %d: not a plain MP4' % (size, off))
        if kind in (b'moov', b'trak', b'mdia'):
            walk(off + 8, off + size)
        elif kind in (b'mvhd', b'tkhd', b'mdhd'):
            if b[off + 8] != 0:
                sys.exit(kind.decode() + ': only version 0 is patched')
            if kind == b'tkhd':
                struct.pack_into('>I', b, off + 28, int(secs * movie))
            else:
                scale = struct.unpack_from('>I', b, off + 20)[0]
                movie = scale if kind == b'mvhd' else movie
                struct.pack_into('>I', b, off + 24, int(secs * scale))
        off += size
walk(0, len(b))
open(dst, 'wb').write(b)
EOF
ffprobe -v error -show_entries format=duration -of csv=p=0 "$c/clip-200s-says-60s.mp4"
ffmpeg -v error -i "$c/clip-200s-says-60s.mp4" -map 0:v -f null - -stats 2>&1 | tail -n 1
```

Mong dòng đầu ~`60` (header khai 60 s) và dòng sau có `time=00:03:20` (giải mã thật 200 s). Khác: dán hai dòng cho AI, không dùng file đó.

Biến và hàm dùng chung, một lần trong terminal của buổi (mở lại terminal thì chạy lại khối này). Bản ghi job
(`transcode-jobs/<video_id>/<version>.json` của bucket media) là nguồn duy nhất của kết quả mỗi version: job của version hay lý do hỏng
trước khi có job (`docs/explanation/transcode.md` của repo code):

```sh
values=$SVP_SESSION_DIR/cluster-values.json
media=$(jq -r .mediaBucket "$values"); dom=$(jq -r .domain "$values"); cdn=https://$(jq -r .mediaDomain "$values")
record_key() {          # job record key of video $1
  AWS_PROFILE=anhnv-stg aws s3api list-objects-v2 --bucket "$media" --prefix "transcode-jobs/$1/" --region ap-southeast-1 \
    --query 'Contents[0].Key' --output text
}
last_key() {            # newest job record: the video just uploaded
  AWS_PROFILE=anhnv-stg aws s3api list-objects-v2 --bucket "$media" --prefix transcode-jobs/ --region ap-southeast-1 \
    --query 'sort_by(Contents, &LastModified)[-1].Key' --output text
}
show() { AWS_PROFILE=anhnv-stg aws s3 cp "s3://$media/$1" - --region ap-southeast-1; }
```

(a) Smoke đi qua MediaConvert: Deployment `media-worker` chạy lệnh con `mediaconvert`, và job trong bản ghi của mỗi video smoke, seed của
`measure.sh` là `COMPLETE` trên queue `svp-stg`. Một video có thể có thêm job lạc: `CreateJob` mất response, bridge thử lại và tạo job thứ
hai; job đó chạy tới `COMPLETE` hay `ERROR` nhưng không có tên trong bản ghi, nên không quyết kết quả. Khối dưới chép mọi bản ghi về thư mục
buổi, rồi đếm mỗi bản ghi theo trạng thái job của nó (`record-job`) hay lý do của nó (`reason`), và mỗi job khác của cùng video (`orphan-job`):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get deploy media-worker \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="media-worker")].args}{"\n"}'
AWS_PROFILE=anhnv-stg aws mediaconvert list-jobs --queue svp-stg --region ap-southeast-1 --output json > "$SVP_SESSION_DIR/mediaconvert-jobs.json"
AWS_PROFILE=anhnv-stg aws s3 sync "s3://$media/transcode-jobs/" "$SVP_SESSION_DIR/transcode-jobs/" --region ap-southeast-1 --only-show-errors
find "$SVP_SESSION_DIR/transcode-jobs" -name '*.json' -exec jq -c '{video: (input_filename | split("/")[-2]), job: .job_id, reason}' {} + |
  jq -rs --slurpfile all "$SVP_SESSION_DIR/mediaconvert-jobs.json" '($all[0].Jobs | map({key: .Id, value: .Status}) | from_entries) as $st
    | map(.job | select(.)) as $own | map(.video) as $videos
    | (.[] | if .reason then "reason \(.reason)" else "record-job \($st[.job] // "MISSING")" end),
      ($all[0].Jobs[] | select((.UserMetadata.video_id | IN($videos[])) and (.Id | IN($own[]) | not)) | "orphan-job \(.Status)")' |
  sort | uniq -c
```

Mong `["mediaconvert"]`, rồi dòng `record-job COMPLETE` với số đếm bằng số video smoke và seed đã `READY`, không dòng `record-job` nào khác,
không dòng `reason`. Dòng `orphan-job <trạng thái>` được chấp nhận (job lạc, như trên); ghi số của nó vào dòng kết luận. `record-job` khác
`COMPLETE` (`MISSING`: job của bản ghi không có trên queue) hay có dòng `reason`: dán bảng đếm và output của
`jq -c '.Jobs[] | select(.Status != "COMPLETE") | {Id, Status, ErrorCode, ErrorMessage, UserMetadata}' "$SVP_SESSION_DIR/mediaconvert-jobs.json"`
cho AI.

(b) Phép đo hai đường, đường MediaConvert: script đo thời gian tới `READY` (`deploy/compose/transcode-timing.sh`) qua
`make eks-transcode-timing` của repo code, 5 lần clip 60 s, rồi `GetJob` của 5 job (job ID ở bản ghi job) cho phút output theo loại:

```sh
AWS_PROFILE=anhnv-stg make -C ../backend eks-transcode-timing CONTEXT=svp-stg DOMAIN="$dom" CLIP="$SVP_SESSION_DIR/clip-60s.mp4" N=5 |
  tee "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt"
grep -E '^[0-9a-f-]{36} [0-9]+$' "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt" | cut -d ' ' -f 1 | while read -r id; do
  job=$(show "$(record_key "$id")" | jq -r .job_id)
  AWS_PROFILE=anhnv-stg aws mediaconvert get-job --id "$job" --region ap-southeast-1 --output json \
    --query 'Job.{id: Id, status: Status, timing: Timing, outputs: OutputGroupDetails[].OutputDetails[].[DurationInMs, VideoDetails.WidthInPx, VideoDetails.HeightInPx]}'
done | tee "$SVP_SESSION_DIR/transcode-timing-jobs.json"
```

Mong năm dòng `<video_id> <giây>`, dòng `p50=<giây> max=<giây>` và năm JSON `COMPLETE`. Dán nguyên `transcode-timing-mediaconvert.txt` và
`transcode-timing-jobs.json` (output thô, AI tính chi phí theo công thức ở mục "Chi phí mỗi phút video" của phụ lục). Đường ffmpeg trên
compose chạy ngoài buổi, một lần, theo cùng mục của phụ lục; tổng MediaConvert của ngày buổi ở Cost Explorer đọc ở mục **Kết thúc buổi**.

(c) Header của output qua CloudFront: master, playlist rendition, một segment và thumbnail của một video vừa đo, đọc qua `media.<domain>`:

```sh
id=$(grep -E -m 1 '^[0-9a-f-]{36} [0-9]+$' "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt" | cut -d ' ' -f 1)
key=$(AWS_PROFILE=anhnv-stg aws s3api list-objects-v2 --bucket "$media" --prefix "media/$id/" --region ap-southeast-1 \
  --query "Contents[?ends_with(Key, 'master.m3u8')].Key | [0]" --output text)
dir=${key%/master.m3u8}
var=$(curl -s "$cdn/$key" | grep -v -e '^#' -e '^[[:space:]]*$' | head -n 1 | tr -d '\r')
seg=$(curl -s "$cdn/$dir/$var" | grep -v -e '^#' -e '^[[:space:]]*$' | head -n 1 | tr -d '\r')
for k in "$key" "$dir/$var" "$dir/${var%/*}/$seg" "$dir/${var%/*}/thumbnail.jpg"; do
  echo "$k"; curl -sI "$cdn/$k" | grep -i -E '^(HTTP|cache-control|content-type)'
done
```

Mong bốn khối, mỗi khối `HTTP/2 200` và `cache-control` đúng hằng `CacheControl` của `services/media-worker/internal/worker/worker.go`
(`max-age=31536000, immutable`, như `serve` ghi), `content-type` theo đuôi như `serve`: `application/vnd.apple.mpegurl` cho hai playlist,
`video/mp2t` cho segment, `image/jpeg` cho thumbnail. Biến thể trong master có dạng `<attempt>/index_<rendition>.m3u8`. Thiếu header hay
khác giá trị: dán output cho AI.

(d) FF-9: clip 200 s thành `FAILED` với lý do `DURATION_EXCEEDED`, và không job nào của video đó trên queue:

```sh
AWS_PROFILE=anhnv-stg make -C ../backend eks-transcode-timing CONTEXT=svp-stg DOMAIN="$dom" CLIP="$SVP_SESSION_DIR/clip-200s.mp4" N=1
key=$(last_key); echo "$key"; show "$key"
AWS_PROFILE=anhnv-stg aws mediaconvert list-jobs --queue svp-stg --region ap-southeast-1 --output json \
  --query "Jobs[?UserMetadata.video_id=='$(cut -d / -f 2 <<<"$key")'].[Id,Status]"
```

Mong: `make` dừng ở `FAIL  video v went FAILED instead of READY`; key `transcode-jobs/<video_id>/<version>.json`, nội dung
`{"reason":"DURATION_EXCEEDED"}`; `[]`. Video `READY`, lý do khác hay có job: dán cả ba output cho AI (FF-9 không giữ được).

(e) Lớp cắt: file khai 60 s mà dài thật 200 s không ra output quá 3 phút:

```sh
AWS_PROFILE=anhnv-stg make -C ../backend eks-transcode-timing CONTEXT=svp-stg DOMAIN="$dom" CLIP="$SVP_SESSION_DIR/clip-200s-says-60s.mp4" N=1
key=$(last_key); echo "$key"; show "$key"
job=$(show "$key" | jq -r '.job_id // empty')
[ -z "$job" ] || AWS_PROFILE=anhnv-stg aws mediaconvert get-job --id "$job" --region ap-southeast-1 --output json \
  --query 'Job.[Status,ErrorCode,OutputGroupDetails[].OutputDetails[].DurationInMs]'
```

Đạt khi không output nào dài quá 180 000 ms. Ghi trường hợp gặp: video `READY`, bản ghi có `job_id`, job `COMPLETE` với mọi `DurationInMs`
quanh 60 000 (cắt tại thời lượng Probe báo: lớp cắt chạy); hay `FAILED` với bản ghi `{"reason":"INVALID_INPUT"}` hoặc job `ERROR` (không
output); hay `{"reason":"DURATION_EXCEEDED"}` (Probe không tin header, lớp cắt không được thử tới). Có output trên 180 000 ms: trần chi phí
hỏng, dừng mục này và dán output cho AI.

(f) Hàng đợi sự kiện rỗng, alarm DLQ không báo, bridge không bỏ message nào. Chạy sau cùng, khi mọi job của mục này đã xong:

```sh
for q in svp-stg-transcode-events svp-stg-transcode-events-dlq; do
  url=$(AWS_PROFILE=anhnv-stg aws sqs get-queue-url --queue-name "$q" --region ap-southeast-1 --query QueueUrl --output text)
  echo "$q $(AWS_PROFILE=anhnv-stg aws sqs get-queue-attributes --queue-url "$url" --region ap-southeast-1 --output text \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]')"
done
AWS_PROFILE=anhnv-stg aws cloudwatch describe-alarms --alarm-names svp-stg-transcode-events-dlq --region ap-southeast-1 --output text \
  --query 'MetricAlarms[].[AlarmName,StateValue]'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp logs deploy/media-worker --since=3h |
  grep -c -E 'transcode event (ignored|interrupted)|transcode result undecided'
```

Mong hai dòng kết thúc bằng hai số `0` (hàng đợi nguồn còn số khác 0 thì đọc lại sau một phút), alarm `OK` hay `INSUFFICIENT_DATA`, và `0`.
DLQ có message hay alarm `ALARM`: theo runbook
[`transcode-events-dlq.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/transcode-events-dlq.md) của repo code, dán
output cho AI. Rồi chạy lại ba lệnh cuối của (a) (`list-jobs`, `s3 sync`, bảng đếm). Mong `record-job` chỉ `COMPLETE` (thêm `ERROR` khi (e)
gặp job `ERROR`), `reason` chỉ `DURATION_EXCEEDED` của (d) và lý do (e) đã ghi; `orphan-job` như ở (a); khác: dán bảng đếm cho AI.
`mediaconvert-jobs.json` khi đó giữ mọi job của buổi cùng thời lượng từng output, đầu vào đối chiếu chi phí ở mục **Kết thúc buổi**.

### 12–14. Diễn tập khôi phục

```sh
aws/scripts/restore-drill.sh stg backup
aws/scripts/restore-drill.sh stg rds
aws/scripts/restore-drill.sh stg s3
```

Chạy sau bước 11 và các phép kiểm của nó, khi không còn tải: k6 đã xong, không client nào ghi (Diễn tập PITR chỉ so nội dung tại các mẫu).
Tunnel còn mở: bước 13 đọc dữ liệu qua `svp-pg` trong pod `svp-ops`. Mục tiêu RTO/RPO, cách đo và giới hạn của kết luận:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §2, §9, §10; hạn của từng lần chờ ở đầu
`restore-drill.sh`. Mỗi lệnh con ghi mốc `backup-undrained` sau kiểm account, trước lệnh ghi đầu tiên, nên sau nó `tf.sh` chỉ destroy root env khi bước 20 đã
chạy lại. Xem trước lệnh của một lệnh con, không chạy gì: `aws/scripts/restore-drill.sh --print stg backup` (hay `rds`, `s3`, `cleanup`).

Kết quả mỗi lần chạy thêm một dòng vào `restore-drill.tsv` (cột `kind t0 t1 rto_s rpo_s check note`, giờ UTC). Dán lại bảng sau bước 14:

```sh
column -t -s "$(printf '\t')" "$SVP_SESSION_DIR/restore-drill.tsv"
```

Số đo (RTO, RPO, thời gian của từng bước) vào phụ lục ADR-0067 sau buổi.

**Bước 12, `backup`.** Kiểm cấu hình mà lịch hằng ngày dựa vào: plan `svp-stg` do Backup policy `svp-backup-stg` sinh trong account, selection
`svp-stg-tagged` của nó, opt-in RDS và S3 của account. Rồi job on-demand cho instance `svp-stg` và hai bucket vào vault `svp-stg` bằng role
`svp-stg-backup` (retention là của rule `daily`), chờ xong; copy từng recovery point sang vault `svp-stg-copy` của `svp-backup` (retention bản
copy của plan), chờ xong; ghi `restore-drill-points.tsv` (**Điểm của buổi**, bước 14 và bước 20 đọc nó). Tìm `ok plan svp-stg: …`,
`ok selection svp-stg-tagged: …`, `ok opt-in of RDS and S3 on …`, ba dòng `ok backup job … completed` và ba dòng `ok copy job … completed`,
rồi `PASS  backup: …`. Dòng `FAIL`:

| Dòng `FAIL` | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `no backup plan svp-stg in the account of stg` | policy `svp-backup-stg` chưa gắn OU `NonProd`, hay AWS chưa sinh plan trong account | kiểm theo bước (7) của [`backup-setup.md`](backup-setup.md#bước-7-kiểm-sau-áp); chưa có thì bỏ diễn tập, sang bước 15 |
| `plan svp-stg is not the policy's` hay `selection svp-stg-tagged is not the policy's` | plan trong account khác Backup policy của `aws/org` | dán dòng đó cho AI; không sửa plan ở account (plan của policy là bất biến) |
| `opt-in of the account of stg …` | `aws/accounts/stg` chưa áp phần backup | áp theo bước (6) của `backup-setup.md`, rồi chạy lại bước 12 |
| `backup job … ended …: no recovery point` hay `copy job … is FAILED` | job lỗi | đọc `StatusMessage` (lệnh dưới), dán cho AI; lỗi quyền ở copy job thường là vault access policy của `svp-stg-copy` hay key policy |
| `backup jobs still running after …` | job chưa xong khi hết hạn chờ | đọc job bằng lệnh script in ra; xong thì chạy lại bước 12 (lượt mới tạo job mới; recovery point của job cũ không có copy job, nên bước 20 giữ nó và `FAIL … has no completed copy … kept`: chọn copy lại hay xoá theo lệnh in ra) |

```sh
AWS_PROFILE=anhnv-stg aws backup describe-backup-job --backup-job-id <id> --region ap-southeast-1 --query '[State,StatusMessage]' --output text
AWS_PROFILE=anhnv-stg aws backup describe-copy-job --copy-job-id <id> --region ap-southeast-1 \
  --query 'CopyJob.[State,StatusMessage]' --output text
```

**Đọc bản copy** (sau bước 12, chỉ đọc, profile `anhnv-backup-ro` của account `svp-backup`): recovery point của buổi trong `svp-stg-copy`, mã
hoá bằng key của chính vault đó (dùng được sau khi key RDS bị xoá cuối buổi, và cả khi key vault env, sống giữa các buổi, bị xoá khi gỡ
lab). Lệnh không in ARN nào (ARN mang id account):

```sh
k=$(AWS_PROFILE=anhnv-backup-ro aws backup describe-backup-vault --backup-vault-name svp-stg-copy --region ap-southeast-1 \
  --query EncryptionKeyArn --output text)
AWS_PROFILE=anhnv-backup-ro aws backup list-recovery-points-by-backup-vault --backup-vault-name svp-stg-copy --region ap-southeast-1 \
  --by-created-after "$(head -n 1 "$SVP_SESSION_DIR/timeline.tsv" | cut -f 1)" --output json |
  jq -r --arg k "$k" '.RecoveryPoints[] | [.ResourceType, .Status, .CreationDate, .CalculatedLifecycle.DeleteAt,
    (if .EncryptionKeyArn == $k then "vault-key" else "other-key" end)] | @tsv'
```

Mong ba dòng (`RDS` và hai `S3`), mỗi dòng `COMPLETED`, `DeleteAt` cách `CreationDate` đúng retention bản copy của stg (ADR-0067 §4) và
`vault-key`. Thiếu dòng hay `other-key`: dán output cho AI. Lỗi `AccessDenied` hay profile không có: profile `anhnv-backup-ro` chưa tạo hay
permission set chưa gán (bước (1), (2) của `backup-setup.md`).

**Bước 13, `rds`.** **Diễn tập PITR** của ADR-0067 §9: mẫu S1 (**Kiểm dữ liệu** trên `svp-stg` qua `svp-pg`), T_r là lúc S1 xong làm tròn lên
giây kế; chờ `LatestRestorableTime` ≥ T_r; mẫu S2 trên nguồn; restore `--restore-time` T_r ra `svp-stg-pitr` (cùng subnet group, security
group, parameter group, lớp; một AZ); chờ `available`; mẫu R trên bản khôi phục; so; rồi xoá `svp-stg-pitr` và chờ nó mất, kể cả khi FAIL. Tìm
`ok sample S1 of svp-stg; T_r …`, `ok sample S2 equals S1`, dòng `PASS  rds: RTO … s, RPO … s; R equals S1 on the tables checked`, rồi
`ok svp-stg-pitr deleted`. Dòng kết quả `FAIL rds` là số đo (sang bước 14), trừ dòng đầu của bảng:

| Dòng | Nghĩa | Cách xử lý |
| --- | --- | --- |
| `source changed during window` | có ghi giữa S1 và S2 (còn tải, job, consumer): không restore gì | chờ hết ghi, chạy lại bước 13 |
| `restore differs from sample S1` | R khác S1; chưa chứng minh restore sai: ghi giữa lúc S1 xong và T_r không để dấu ở S1, S2 | dán phần `diff` script in và log của ba service quanh T_r (lệnh dưới) cho AI |
| `RTO over 3600 s`, `RPO over 300 s` | vượt mục tiêu của ADR-0067 §2 | ghi lại; số đo vào phụ lục |
| `… is left from an earlier drill` | `svp-stg-pitr` còn từ lần trước | chạy lệnh xoá script in, chờ nó mất, chạy lại bước 13 |
| `LatestRestorableTime of svp-stg is still before T_r` | RDS chưa đẩy log giao dịch tới T_r trong hạn chờ | đọc bằng lệnh script in, chạy lại bước 13 |
| `could not read svp-stg-pitr` hay `svp-stg-pitr is still …` | xoá instance khôi phục chưa xong hay lỗi | chạy lệnh `delete-db-instance` script in; `sweep.sh stg` của bước 23 cũng bắt nó |

```sh
for s in video-service engagement-service feed-service; do
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp logs "deploy/$s" --since-time=<T_r trừ 2 phút, RFC 3339> --timestamps | head -n 100
done
```

**Bước 14, `s3`.** **Diễn tập object S3** của ADR-0067 §10: recovery point là dòng của bucket media trong `restore-drill-points.tsv`; key là
key `.m3u8` đầu tiên theo thứ tự từ điển dưới `media/` có trước recovery point đó; tải, ghi độ dài và SHA-256; xoá key (delete marker);
restore item-level đúng key đó vào chính bucket bằng role `svp-stg-backup`; tải lại, so độ dài và SHA-256 (ETag không so: AWS Backup không
giữ ETag). Tìm `ok s3://svp-stg-media-…/<key>: N bytes, SHA-256 …; deleting it`, rồi `PASS  s3: RTO … s, RPO … s; …`. `rpo_s` là tuổi của
recovery point đã dùng, chỉ ghi lại: RPO của S3 là giới hạn cấu hình (ADR-0067 §2). Dòng `FAIL`:

- `no line of arn:aws:s3:::… in …restore-drill-points.tsv`: bước 12 chưa xong cho bucket media; chạy bước 12, rồi bước 14.
- `no .m3u8 under media/ … older than its recovery point`: bucket media chưa có video nào trước lúc backup (smoke, seed của bước 11 chưa
  chạy); không diễn tập được ở buổi này, ghi lại.
- `restore job … ended …` hay `… after … s`: key vẫn bị xoá, version cũ còn (bucket có versioning). Khôi phục bằng cách xoá delete marker
  (lệnh dưới; key là key script in), dán `StatusMessage` của job cho AI.

```sh
aws/scripts/check-account.sh stg
b="svp-stg-media-$SVP_AWS_STG_ACCOUNT_ID-ap-southeast-1"
AWS_PROFILE=anhnv-stg aws backup describe-restore-job --restore-job-id <id> --region ap-southeast-1 --query '[Status,StatusMessage]' --output text
AWS_PROFILE=anhnv-stg aws s3api list-object-versions --bucket "$b" --prefix <key> --region ap-southeast-1 \
  --query 'DeleteMarkers[?IsLatest].VersionId' --output text
AWS_PROFILE=anhnv-stg aws s3api delete-object --bucket "$b" --key <key> --version-id <VersionId của delete marker> --region ap-southeast-1
```

### Finding bảo mật của buổi (sau bước 14, trước bước 15)

Chỉ đọc, profile `anhnv-security-ro` của account Security Tooling, khi tài nguyên của buổi **còn sống**: tài nguyên bị xoá thì finding control
của nó chuyển `NOT_AVAILABLE` và `ARCHIVED` (Security Hub CSPM User Guide, "Generating and updating control findings"), nên lượt đọc định kỳ
của `security-alert.md` không bao giờ thấy tài nguyên chỉ sống trong buổi. Buổi dừng sớm rồi đi thẳng tới gỡ: vẫn đọc mục này trước bước 15
(đường `--no-cluster` của mục **18–22**: trước `plan --destroy`).

Mục này cần bước (4), (5) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu): profile `anhnv-security-ro` và Security
Hub ở `svp-security`. Org mới áp tới bước (3) (đủ cho buổi, điều kiện 6) thì chưa có gì để đọc: bỏ qua mục này. Kiểm:
`aws configure list-profiles | grep -x anhnv-security-ro` không in gì là chưa có.

```sh
ACC="${SVP_AWS_STG_ACCOUNT_ID:?not set}"    # prd session: ACC="${SVP_AWS_PRD_ACCOUNT_ID:?not set}"
A="\"AwsAccountId\":[{\"Value\":\"$ACC\",\"Comparison\":\"EQUALS\"}],\"RecordState\":[{\"Value\":\"ACTIVE\",\"Comparison\":\"EQUALS\"}]"
# FAILED controls of the account (never emailed); the full list with resource ids stays in the session directory
AWS_PROFILE=anhnv-security-ro aws securityhub get-findings --region ap-southeast-1 --output text \
  --filters "{$A,\"ComplianceStatus\":[{\"Value\":\"FAILED\",\"Comparison\":\"EQUALS\"}],\"WorkflowStatus\":[{\"Value\":\"NEW\",\"Comparison\":\"EQUALS\"}]}" \
  --query 'Findings[].[Compliance.SecurityControlId,Severity.Label,Resources[0].Type,Resources[0].Id]' \
  | sort | tee "$SVP_SESSION_DIR/controls-failed.tsv" | cut -f 1-3 | uniq -c | sort -rn
# Finding GuardDuty, Access Analyzer mới hay cập nhật từ đầu buổi, mọi mức
AWS_PROFILE=anhnv-security-ro aws securityhub get-findings --region ap-southeast-1 --output text \
  --filters "{$A,\"UpdatedAt\":[{\"Start\":\"$(head -n 1 "$SVP_SESSION_DIR/timeline.tsv" | cut -f 1)\",\"End\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}],
    \"ProductName\":[{\"Value\":\"GuardDuty\",\"Comparison\":\"EQUALS\"},{\"Value\":\"IAM Access Analyzer\",\"Comparison\":\"EQUALS\"}]}" \
  --query 'Findings[].[ProductName,Severity.Label,Types[0],Title]' | sort | uniq -c | sort -rn
```

Dán toàn bộ output của cả hai lệnh, cùng `controls-failed.tsv` khi AI hỏi tới tài nguyên. Lệnh đầu gồm cả control FAILED của baseline (đã có
trong danh sách ban đầu, mục 7a của [`org-security-setup.md`](org-security-setup.md#7a-dịch-vụ-bật)) lẫn của tài nguyên buổi. Mỗi control FAILED,
của tài nguyên buổi cũng như tài nguyên lâu dài, xử lý theo mục "Đọc bảng Security Hub định kỳ" của runbook
[`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md#đọc-bảng-security-hub-định-kỳ):
buổi sau tạo lại tài nguyên từ cùng code, nên lỗi không sửa trong Terraform sẽ quay lại. Của lệnh thứ hai, chỉ mức HIGH, CRITICAL tới email
(cả finding phát sinh trong lúc gỡ); mức thấp hơn (ngoài `[SAMPLE]`) đối chiếu thời điểm với `timeline.tsv` (diễn tập, đo) rồi xử lý theo
cùng runbook.

### 15. Gỡ trong cluster trước destroy

```sh
aws/scripts/pre-destroy.sh stg
```

Tunnel còn mở. Gỡ những gì Kubernetes tạo trong account mà Terraform không biết, **khi controller tạo ra chúng còn chạy**, mỗi lần chờ có
hạn: target của Envoy trong target group edge (`TargetGroupBinding`), volume EBS của PVC, node của Karpenter. Chỉ cần apply đã tạo cluster:
script tự chạy `aws eks update-kubeconfig --name svp-stg --alias svp-stg`, không đọc file nào của bước 6, nên chạy được cả khi bước 6 chưa
chạy hay từ thư mục buổi mới. `FAIL kubeconfig context …` là account không có cluster `svp-stg`: sang bước 20, rồi 21 với
`--no-cluster`.

1. ApplicationSet `svp-bootstrap` (nó dựng lại `svp-root`), `svp-root` và `svp-apps` (auto-sync prune + self-heal, không finalizer): xoá
   finalizer và `automated` của hai Application, rồi xoá riêng ba cái (child ở yên); tắt auto-sync của mọi Application còn lại (để
   `svp-cluster` không dựng lại Gateway).
2. Trước hết luật và Alertmanager của AMP: xoá mọi `RuleGroupsNamespace`, `AlertManagerDefinition` của ACK khi controller ACK còn chạy (nó
   xoá chúng ở AMP, chờ tối đa 5 phút); không pod ACK nào Ready hay quá hạn thì gỡ finalizer của chúng và in dòng `note left in AMP: …` kèm
   lệnh xoá ở AMP (người học chạy sau bước 24; `sweep.sh stg` cũng liệt kê rule groups namespace còn lại). Mốc `pre-destroy-amp-rules`. Rồi
   Application workload theo sync wave từ cao xuống (finalizer của mỗi cái xoá thứ nó triển khai), trừ `svp-cluster` và controller nền
   tảng (cả `karpenter`); rồi, khi `media-worker` đã gỡ (không job mới), huỷ mọi job `SUBMITTED`, `PROGRESSING` của queue MediaConvert
   `svp-stg` và chờ tới khi không còn job nào dở (job dở chặn xoá queue và ghi vào bucket `media` mà destroy làm rỗng), in số job đã huỷ
   (`ok no MediaConvert queue …` khi account không có queue đó); rồi Gateway `svp-edge/svp`,
   rồi xoá tường minh TargetGroupBinding `envoy-gateway-system/svp-envoy` (chart
   `svp-cluster` render nó, không mất theo Gateway): LBC gỡ target của Envoy khỏi target group edge rồi mới thả nó, chờ có hạn. Chờ hết
   Service `LoadBalancer`, TargetGroupBinding, load balancer và target group mang tag `elbv2.k8s.aws/cluster=svp-stg` trong ELBv2 (của
   controller; ALB và target group edge của Terraform không mang tag này), trong khi LBC, Envoy Gateway còn chạy. Bản ghi DNS của buổi thuộc
   root env, gỡ cùng destroy của nó.
3. Mọi PVC ở mọi namespace (sinh từ `volumeClaimTemplates`, Argo CD không prune) khi EBS CSI còn chạy và namespace, StorageClass `gp3` của
   `svp-cluster` còn đó; chờ hết PVC, PV của `ebs.csi.aws.com`, volume EBS do driver tạo.
4. Mọi NodePool rồi mọi EC2NodeClass, khi Karpenter còn chạy (`svp-cluster`, chart render chúng, không sync lại từ bước 1); chờ tới khi hết
   NodeClaim và hết instance EC2 mang tag `karpenter.sh/nodepool` của cluster, giới hạn 15 phút (ADR-0056 §9: `terminationGracePeriod`
   10 phút của NodePool là trần drain một node, quá trần Karpenter tắt instance dù PDB còn chặn, cộng thời gian tắt instance). Mốc
   `pre-destroy-nodes`.
5. `svp-cluster` và Application nền tảng, theo wave; quá hạn chỉ ghi `note` (không gì của chúng tính tiền ngoài cluster).

Cluster chưa có Argo CD (root gitops chưa apply hay dừng trước Argo CD, dòng `note no Argo CD on svp-stg`): không có Application nào để xoá,
bước 1, 5 và phần Application của bước 2 bỏ qua; phần huỷ job MediaConvert của bước 2 vẫn chạy.
Cluster chưa có CRD của Karpenter (dòng `note no Karpenter on svp-stg`): bước 4 không xoá
gì. Các phép chờ của bước 2–4 (Service `LoadBalancer`, ELBv2, PVC, volume EBS, instance của Karpenter) vẫn chạy, rồi ghi mốc
`pre-destroy-done` như thường.

Tìm: mỗi bước `ok`, cuối cùng `ok ready for: aws/scripts/tf.sh stg gitops plan --destroy` và mốc `pre-destroy-done` (thiếu mốc này thì
`tf.sh stg gitops plan --destroy` từ chối). Script ghi mốc `pre-destroy-start` ngay sau khi kiểm account, trước mọi bước khác. `FAIL` nêu thứ
còn lại và lệnh xem; sửa rồi chạy lại script (mỗi bước tìm thứ còn lại). Bước 4 đỏ vì NodeClaim còn: đọc log của Karpenter
(`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --tail=50`); đỏ vì instance còn mà hết NodeClaim:
`sweep.sh stg` in lệnh tắt nó. Bước 2 đỏ ở `svp-envoy`: dòng `FAIL` nêu lệnh xem finalizer, status của nó và log của LBC.
Bước 2 đỏ ở job MediaConvert: dòng `FAIL` nêu lời gọi lỗi (quyền, throttle) hay job còn dở sau hạn chờ;
sửa rồi chạy lại script, hay huỷ tay theo mục **Lệnh xoá tay theo loại**.
**Hết giờ của buổi mà bước 2, 3 hay 4 vẫn đỏ sau khi đã chạy lại**
(dòng `note` cuối sau `FAIL` nhắc lối này): sang bước 16 với `--leftovers`.

### 16–17. Gỡ root gitops

```sh
aws/scripts/tf.sh stg gitops plan --destroy
aws/scripts/tf.sh stg gitops destroy
```

Root gitops gỡ **trước** root env (provider của nó cần cluster). `plan --destroy` ghi `aws/gitops/stg/stg.destroy.tfplan` và bản text vào
`$SVP_SESSION_DIR/stg-gitops-destroy-plan.txt`; từ chối khi thư mục buổi chưa có mốc `pre-destroy-done`. Đọc file text: chỉ tài nguyên của
`aws/gitops/stg`, `0 to add, 0 to change`. `destroy` chỉ áp file đó (`terraform apply` file đó: không plan lại tại chỗ, không hỏi lại), ghi
mốc `gitops-destroy-end`. Root gitops chưa init trong bản checkout này (bỏ buổi trước bước 7): `aws/scripts/tf.sh stg gitops init` trước;
state trống thì plan là `No changes` và destroy chỉ ghi mốc.

Root gitops gỡ qua tunnel: đóng tunnel được sau bước 17. Hết giờ của buổi mà bước 15 vẫn đỏ ở bước 2, 3 hay 4 của nó sau khi đã chạy lại:
lối thoát có kiểm, để cluster không tính tiền tiếp.

```sh
aws/scripts/tf.sh stg gitops plan --destroy --leftovers
```

Chỉ nhận khi `timeline.tsv` của buổi có mốc `pre-destroy-start` (bước 15 đã chạy trong thư mục buổi này) mà chưa có `pre-destroy-done`;
thiếu `pre-destroy-start` thì từ chối và bảo chạy bước 15 trước, đã có `pre-destroy-done` thì từ chối (không cần cờ này). Dòng `note
--leftovers: …` nhắc thứ Kubernetes tạo có thể còn (volume EBS của PVC, instance EC2 của Karpenter, load balancer của Load Balancer
Controller), rồi ghi
mốc `pre-destroy-skipped`. Tiếp: bước 17, rồi các bước sau (destroy có thể kẹt vì những thứ đó: mục **Destroy kẹt**); thứ `sweep.sh` liệt
kê xoá bằng lệnh nó in, rồi chạy lại `sweep.sh` tới khi sạch.

### 18–22. Gỡ root env

```sh
aws/scripts/tf.sh stg env plan --teardown
aws/scripts/tf.sh stg env apply --teardown
aws/scripts/restore-drill.sh stg cleanup
aws/scripts/tf.sh stg env plan --destroy
aws/scripts/tf.sh stg env destroy
```

Bước 18, 19 in `skip`: stg không có file nhấc bảo vệ (prd có, `session-prd.md`). Bước 20 xoá backup của buổi (mục dưới). `plan --destroy`
từ chối khi thư mục buổi chưa có mốc `gitops-destroy-end`, hay khi trong `timeline.tsv` mốc cuối trong bốn mốc `backup-undrained`,
`env-apply-end`, `env-teardown-applied`, `backup-drained` không phải `backup-drained` (`FAIL the backups of stg are not drained …`: chạy bước
20, rồi bước 21 lại); `destroy` cũng kiểm lại điều đó. Như bước 4 cho apply, `plan --destroy` ghi `aws/envs/stg/stg.destroy.tfplan` và bản
text `stg-env-destroy-plan.txt`. **Đọc file text đó trước bước 22**: chỉ tài nguyên của `aws/envs/stg`, `0 to add, 0 to change`; không có
bucket `svp-tfstate`, không có `aws_route53_zone` (của baseline `aws/accounts/stg`, root khác). Thấy thứ khác: dừng, dán plan cho AI.
`destroy` chỉ áp file đó, rồi xoá file. Kẹt: mục **Destroy kẹt**, rồi `plan --destroy` lại (file plan cũ không áp lại được sau một apply
dở) và `destroy`.

Destroy gỡ edge theo tham chiếu trong code: bản ghi DNS và delivery log, rồi ba distribution (provider tắt từng cái, chờ `Deployed`, rồi xoá:
mỗi cái vài phút tới ~15 phút, phần dài nhất của edge), rồi VPC origin (AWS từ chối xoá khi distribution còn dùng nó), rồi listener, ALB,
target group, security group, cert ACM. Sau VPC origin, CloudFront tự gỡ ENI của nó trong subnet edge và security group
`CloudFront-VPCOrigins-Service-SG` (ngoài state); chưa gỡ xong thì subnet edge hay VPC báo `DependencyViolation`: mục **Destroy kẹt**.

Apply đỏ trước khi tạo cluster EKS (chưa gì chạy trên cluster, root gitops chưa bao giờ apply): đọc mục **Finding bảo mật của buổi**
(VPC, NACL, RDS… đã tạo vẫn có control), bỏ bước 12–17, chạy bước 20 (apply đã gắn tag `Backup` và ghi `backup-undrained`), rồi
`aws/scripts/tf.sh stg env plan --destroy --no-cluster`. Script tự kiểm điều đó trước khi plan: thư mục buổi không có `cluster-values.json`
**và** `terraform state list` của `aws/envs/stg` (script tự chạy, profile `anhnv-stg`) không có `aws_eks_cluster`; không thì từ chối
(`FAIL --no-cluster refused: …`). State còn cluster: chạy bước 15 trong thư mục buổi hiện tại (không cần bước 6), bước 16, 17, 20, rồi `plan
--destroy` không `--no-cluster`.

#### Bước 20: xoá backup của buổi

`restore-drill.sh stg cleanup` (**Xoá cuối buổi** của ADR-0067 §11) chạy sau lần ghi Terraform cuối vào root env (mọi apply gắn lại tag
`Backup`) và ngay trước `plan --destroy`, theo thứ tự: xoá `svp-stg-pitr` nếu còn; gỡ tag `Backup` khỏi instance `svp-stg` và hai bucket (lịch
không chọn chúng nữa); chờ mọi job backup, copy, restore của account kết thúc (có hạn); với mỗi recovery point của vault `svp-stg`: có copy job
`COMPLETED` tới `svp-stg-copy` thì xoá, không có thì giữ và in hai lệnh; cả bốn xong thì ghi mốc `backup-drained`. Vault `svp-stg` ở lại
(`aws/accounts/stg`), bản copy ở lại tới hết retention. Key RDS, key `uploads` chỉ vào `PendingDeletion` ở destroy sau bước này, khi bản copy
đã mã hoá bằng key của `svp-backup`. Tìm `ok no svp-stg-pitr left`, `ok tag Backup removed …` (hay `skip` khi tài nguyên không còn), `ok no
backup, copy or restore job running`, mỗi recovery point một dòng `ok recovery point … deleted: its copy is in svp-stg-copy`, mốc
`backup-drained`, rồi `ok backups of stg drained: next, …`. Không cờ nào bỏ qua bước này; hai trường hợp đỏ:

- **Job kẹt** (`FAIL jobs still running after … s, nothing deleted`, kèm danh sách `kind id state resource`): không gì bị xoá. Backup job dừng
  được (lệnh dưới); copy job và restore job không dừng được, chỉ chờ (đọc lại trạng thái). Rồi chạy lại bước 20.
- **Recovery point chưa có bản copy** (`FAIL recovery point … has no completed copy in svp-stg-copy, kept`, rồi `… kept, backup-drained not
  recorded`): copy job của nó lỗi hay chưa từng chạy (job theo lịch khi env sống qua 18:00 UTC mà copy lỗi). Chọn một trong hai lệnh script in
  dưới mỗi recovery point: copy lại (`start-copy-job`, đúng retention của plan; chạy lại bước 20 khi copy job `COMPLETED`) hay chấp nhận mất
  bản đó (`delete-recovery-point`, ghi lại vào ghi chú của buổi); rồi chạy lại bước 20.

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws backup describe-backup-job --backup-job-id <id> --region ap-southeast-1 --query '[State,PercentDone]' --output text
AWS_PROFILE=anhnv-stg aws backup stop-backup-job --backup-job-id <id> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws backup describe-copy-job --copy-job-id <id> --region ap-southeast-1 --query 'CopyJob.State' --output text
AWS_PROFILE=anhnv-stg aws backup describe-restore-job --restore-job-id <id> --region ap-southeast-1 --query Status --output text
```

Bỏ cả buổi khi apply đỏ: bước 20 vẫn chạy trước `plan --destroy` (kể cả `--no-cluster`), vì `env apply` ghi `backup-undrained` trước khi
tạo gì; khi chưa có instance hay bucket, nó in `skip` cho phần đó.

### 23–24. Quét sót

```sh
aws/scripts/sweep.sh stg
aws/scripts/sweep.sh mgmt
```

Chỉ đọc, chạy được cả khi state mất hay destroy dở; mỗi lượt với profile của account đó. Liệt kê mọi tài nguyên tag `Project=svp` hay tag
Kubernetes đặt (`kubernetes.io/cluster/svp-*`, `elbv2.k8s.aws/cluster`, `ebs.csi.aws.com/cluster`, `cluster.k8s.amazonaws.com/name`,
`karpenter.sh/nodepool`, `karpenter.k8s.aws/cluster`) hay mang tên `svp-*`: EKS, EC2 (cả instance của Karpenter), launch template (Karpenter tạo
một cái cho mỗi EC2NodeClass), instance profile của Karpenter (ngoài state, path `/karpenter/<region>/svp-…`; còn thì IAM không xoá được role
node), hàng đợi SQS và rule EventBridge `Karpenter*` của nó, CloudWatch alarm `svp-*` (cả alarm target tracking mà autoscaling storage của
MSK tạo), EBS và snapshot, VPC, NAT, EIP, ENI, security group, ELBv2 và target group, RDS (instance, snapshot, backup tự động giữ
lại), MSK (cluster, rồi configuration), ElastiCache (replication group, rồi user group, user, subnet group, parameter group; user `default`
và nhóm `default.*` của AWS không tính), S3, gói CloudFront flat-rate (loại `CloudFront pricing plan subscriptions`, `us-east-1`, đọc trước
distribution), CloudFront (distribution, OAC, response headers policy), web ACL WAF của CloudFront (`us-east-1`), log group (cả log group
EKS, RDS tự tạo ngoài state và log broker `/aws/msk/svp-*`), Secrets Manager (cả secret đang chờ xoá và secret SCRAM `AmazonMSK_svp-*`), KMS
key, bản ghi của zone của account ngoài `NS`, `SOA`, `CAA` ở đỉnh và ngoài mọi `NS` dưới đỉnh (uỷ quyền zone con của baseline). Mỗi loại in theo thứ
tự AWS cho xoá (cluster trước configuration, replication group trước user group, user group trước user).

Nền tảng managed thêm các loại: endpoint interface `svp-<env>-<dịch vụ>` và security group `svp-<env>-endpoints` (của root env, sót là
lỗi); rule groups namespace của AMP (ACK tạo mỗi buổi, `pre-destroy.sh` xoá; sót là ruler còn đánh giá và tính tiền); workspace AMP, workspace
Grafana, repo ECR, rule pull-through cache cùng repo do cache tạo (không tag), IAM OIDC provider và role `svp-ci-*` của root
`aws/accounts/<env>`: in là `kept` khi account giữ `Stack=baseline`.

Transcode thêm các loại: queue MediaConvert `svp-<env>` (queue `Default` của account không tính); hàng đợi SQS
`svp-<env>-transcode-events` và `-dlq` (loại SQS có sẵn); rule EventBridge `svp-<env>-mediaconvert-job-state`: loại `EventBridge rule targets`
(chỉ rule còn đích) in trước loại `EventBridge rules`, rule `svp-*` mang tag `Stack` được giữ (rule `svp-security-*` của `aws/baseline`) là
`kept`; role `svp-<env>-mediaconvert` (`us-east-1`): loại `IAM inline policies of MediaConvert roles` in trước `IAM roles of MediaConvert`;
alarm `svp-<env>-transcode-events-dlq` và endpoint interface `svp-<env>-mediaconvert` (loại alarm, endpoint có sẵn).
Sót là lỗi: mọi thứ đó ở root env.

Backup thêm các loại (ADR-0067, **Quét backup**): job backup, copy, restore chưa kết thúc (`AWS Backup … jobs not ended`; backup job dừng
được, copy và restore job thì chờ rồi quét lại); recovery point trong mọi vault `svp-*` (luôn là sót: bước 20 xoá recovery point của buổi;
snapshot RDS `awsbackup:*` là recovery point, loại `RDS snapshots` không đếm nó lần nữa); vault lock rồi vault `svp-*` không mang `Stack` được
giữ (vault `svp-<env>` của `aws/accounts/<env>` mang `Stack=baseline`, là `kept`); plan cục bộ `svp-probe*` (plan `svp-stg`, `svp-prd` của
Backup policy không tính: account không xoá được chúng); role `svp-*-backup` (`us-east-1`; role `svp-<env>-backup` của `aws/accounts/<env>`
là `kept`), in sau policy inline và managed policy gắn vào nó. Instance `svp-<env>-pitr` của diễn tập nằm trong loại `RDS instances`; snapshot
tự động của instance vừa xoá nằm trong loại `RDS automated snapshots` (RDS tự gỡ sau vài phút: quét lại). Bản copy ở account `svp-backup`
không thuộc lượt quét nào: nó sống theo retention.

Edge thêm các loại: cert ACM tag `Project=svp` (region nhà và `us-east-1`), VPC origin CloudFront, security group
`CloudFront-VPCOrigins-Service-SG` trong VPC của lab (loại riêng: xoá tay chỉ khi không còn VPC origin), delivery, delivery source và delivery
destination của CloudWatch Logs (`us-east-1`), topic SNS `svp-*`; alarm, log group, topic SNS, KMS key và alias ở `us-east-1` (cái mang tag
`Stack=baseline` của baseline prd là `kept`). Distribution được nhận theo comment `svp-` hay origin `svp-*`; ALB, target group và web
ACL của edge theo bộ lọc ELBv2, WAF có sẵn.

Được giữ, in thành dòng riêng, không đếm: tài nguyên tag `Stack=baseline` ở account stg (bucket state, KMS key state, zone `stg.aws.<domain>`
với `NS`, `SOA`, `CAA` ở đỉnh; registry ECR, AMP, AMG, OIDC provider, role CI; vault `svp-stg`, role `svp-stg-backup` và key của vault) và ở
account prd (thêm, ở `us-east-1`: key KMS DNSSEC,
hai alarm DNSSEC, log group query log, topic `svp-prd-dns-alarms` và key của nó)
và `Stack=bootstrap|org` ở management (bucket state, bucket và KMS key của trail; management không có hosted zone) là `kept`, gói đã có
lịch huỷ (`scheduledChange.changeType` `CANCELLATION`, chỉ gói trả phí; gói Free huỷ ngay) cũng là `kept`; KMS key ở trạng thái `PendingDeletion` (key của root env sau destroy: RDS, MSK, alarm, Secrets của EKS; tối thiểu 7 ngày) là `pending deletion`. Tìm: `ok nothing left
in account … but what it keeps` (exit 0) ở **cả hai lượt**. Có dòng `FAIL <loại>: N left`: dưới mỗi tài nguyên sót là dòng `delete:` với lệnh
xoá đủ profile và region (hay trỏ mục dưới khi một lệnh không đủ); chạy, rồi chạy lại lượt đó tới khi sạch. **Buổi chỉ xong khi hai lượt cùng
exit 0.**

## Destroy kẹt

"Destroy lại" ở bảng dưới là `aws/scripts/tf.sh stg env plan --destroy` (plan mới từ state hiện tại), đọc file text, rồi
`aws/scripts/tf.sh stg env destroy`; với root gitops cũng vậy, thay `env` bằng `gitops` (thêm `--leftovers` nếu lần trước đã dùng nó).

| Triệu chứng | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `FAIL the backups of stg are not drained …` ở `plan --destroy` hay `destroy` | một apply hay diễn tập chạy sau `cleanup` cuối (mốc cuối không phải `backup-drained`) | bước 20, rồi `plan --destroy` lại |
| `DependencyViolation` khi xoá subnet, security group hay VPC | ENI còn gắn: ENI phụ của VPC CNI (`aws-K8S-<instance>`, `available` sau khi node mất), hay ENI của load balancer mà bước 15 chưa gỡ | `sweep.sh stg` liệt kê ENI theo VPC; ENI `available`: xoá ENI; ENI của load balancer: xoá load balancer (ENI tự mất), rồi destroy lại |
| `DependencyViolation` khi xoá subnet edge hay VPC, sau khi VPC origin đã xoá | ENI của CloudFront trong subnet edge hay security group `CloudFront-VPCOrigins-Service-SG` chưa được dịch vụ gỡ (ngoài state; tài liệu VPC origins không nói sau bao lâu) | đọc lại `sweep.sh stg` mỗi 5 phút tới khi không còn ENI trong subnet edge, rồi destroy lại; còn security group khi không còn VPC origin nào: xoá nó (lệnh ở **Lệnh xoá tay theo loại**); không xoá ENI của dịch vụ bằng tay |
| `CannotDeleteEntityWhileInUse` khi xoá VPC origin | distribution còn dùng nó (destroy dở ở distribution) | destroy lại sau khi distribution đã xoá (Terraform chờ tiếp) |
| ALB `svp-<env>-edge` báo deletion protection | prd: chưa áp `teardown.tfvars` (`edge_alb_deletion_protection = false`) | bước 18, 19, 20, rồi destroy lại; state mất: tắt bằng tay (lệnh ở **Lệnh xoá tay theo loại**) |
| `ResourceInUseException` khi xoá cert ACM | distribution hay listener ALB còn dùng nó | destroy lại sau khi distribution, listener đã xoá |
| Destroy đỏ ở `aws_cloudfront_distribution`, hay `delete-distribution` bị từ chối, vì distribution còn gói flat-rate | gói không nằm trong state (destroy dở, state mất, gói tạo ở console) nên Terraform không huỷ nó trước; hay gói vừa huỷ còn đang đồng bộ (provider huỷ gói rồi trả về ngay, không chờ) | huỷ gói theo mục CloudFront của **Lệnh xoá tay theo loại**, chờ `list-subscriptions` không còn ARN đó, rồi destroy lại |
| Destroy chờ lâu hay quá hạn ở `aws_cloudfront_distribution` | Terraform phải tắt distribution và chờ `Deployed` (vài phút tới ~15 phút) trước khi xoá | destroy lại (Terraform chờ tiếp); vẫn kẹt thì tắt và xoá tay (lệnh dưới) |
| `BucketNotEmpty` | stg đặt `media_force_destroy = true` nên không nên gặp; object ghi giữa lúc destroy | destroy lại; còn thì xoá tay (lệnh dưới) |
| RDS báo deletion protection | `rds_deletion_protection` của `stg.tfvars` phải `false` (prd: `teardown.tfvars`) | sửa biến, `tf.sh stg env plan`, `apply`, bước 20, rồi destroy lại |
| Node group `system` xoá lâu | node drain | chờ tới hạn bước 22 |
| Destroy đỏ ở `aws_media_convert_queue` (`ConflictException`, queue còn job) | job `SUBMITTED`, `PROGRESSING` còn trên queue: bước 15 bị bỏ (`--leftovers`) hay job tạo sau nó | huỷ job theo mục MediaConvert của **Lệnh xoá tay theo loại**, rồi destroy lại |
| `DependencyViolation` khi xoá subnet hay security group node, sau `--leftovers` | instance của Karpenter còn chạy (ENI của nó trong subnet private) | `sweep.sh stg` liệt kê nó với lệnh `terminate-instances`; chờ instance `terminated`, rồi destroy lại |
| `DeleteConflict` khi xoá role `svp-stg-karpenter-node` | instance profile do Karpenter tạo (ngoài state) còn giữ role | lệnh `delete:` của dòng `IAM instance profiles of Karpenter` trong `sweep.sh stg`, rồi destroy lại |
| `DependencyViolation` khi xoá subnet database hay security group của MSK, ElastiCache | ENI của broker MSK hay node ElastiCache còn trong subnet: cluster, replication group đang xoá (destroy quá hạn của provider trong khi AWS vẫn gỡ) | chờ `sweep.sh stg` không còn dòng `MSK clusters`, `ElastiCache replication groups` (đọc lại mỗi 5 phút), rồi destroy lại; không xoá ENI của dịch vụ managed bằng tay |
| Destroy đỏ ở `aws_msk_configuration` (`BadRequestException`, configuration đang được dùng) | cluster còn `DELETING` | như dòng trên: chờ cluster mất, destroy lại |
| Destroy root gitops kẹt ở namespace `Terminating` | Application còn finalizer mà Argo CD đã gỡ (sau `--leftovers`) | `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd patch applications.argoproj.io <tên> --type merge -p '{"metadata":{"finalizers":null}}'` từng cái còn lại, rồi destroy lại |

## Lệnh xoá tay theo loại

`sweep.sh` in lệnh xoá dưới từng tài nguyên sót. Mục này cho loại mà một lệnh không đủ, và cho thu hồi rule security group. Mọi lệnh ghi;
người học chạy sau khi `check-account.sh stg` đúng account, thay `<…>` bằng id `sweep.sh` in ra. Ưu tiên destroy lại cho thứ Terraform quản
(VPC, NAT, EIP, EKS, RDS, MSK, ElastiCache, bucket, gói, CloudFront, VPC origin, ALB, cert ACM, web ACL,
queue MediaConvert); lệnh tay cho thứ ngoài state
hay khi state mất. Tài nguyên sót ở management (lượt `sweep.sh
mgmt`): cùng lệnh với `AWS_PROFILE=anhnv-sso`.

Security group: rule nơi khác tham chiếu nó, thu hồi từng rule, rồi xoá:

```sh
AWS_PROFILE=anhnv-stg aws ec2 describe-security-group-rules --region ap-southeast-1 --output text \
  --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='<sg-…>'].[GroupId,SecurityGroupRuleId,IsEgress]"
AWS_PROFILE=anhnv-stg aws ec2 revoke-security-group-ingress --group-id <GroupId> --security-group-rule-ids <sgr-…> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws ec2 delete-security-group --group-id <sg-…> --region ap-southeast-1
```

Bucket (khi state mất): bucket không versioning xoá mọi object rồi bucket bằng một lệnh; bucket có versioning (`media` của prd) phải xoá mọi
version và delete marker trước (từng lô 1 000, lặp tới khi rỗng):

```sh
AWS_PROFILE=anhnv-stg aws s3 rb s3://<svp-stg-…> --force --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws s3api list-object-versions --bucket <svp-…> --max-items 1000 --region ap-southeast-1 --output json |
  jq '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}' > /tmp/svp-versions.json
AWS_PROFILE=anhnv-stg aws s3api delete-objects --bucket <svp-…> --delete file:///tmp/svp-versions.json --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws s3api delete-bucket --bucket <svp-…> --region ap-southeast-1
```

CloudFront, theo thứ tự: huỷ gói flat-rate trước (AWS không tắt gói khỏi distribution, không xoá distribution còn gói), rồi tắt distribution, chờ
`Deployed`, xoá; OAC và response headers policy tự viết (khi `sweep.sh` liệt kê) xoá sau distribution, cũng bằng `ETag`; web ACL sau cùng
(khối dưới). Huỷ gói: `--if-match` là `eTag` của `get-subscription`:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status,resourceArns]' --output json
AWS_PROFILE=anhnv-stg aws pricing-plan-manager get-subscription --arn <arn> --region us-east-1 --query eTag --output text
AWS_PROFILE=anhnv-stg aws pricing-plan-manager cancel-subscription --arn <arn> --if-match <eTag trên> --region us-east-1 --query '[subscription.status,subscription.scheduledChange.changeType]' --output text
AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].arn' --output text
```

Lệnh cuối không còn in ARN đó thì gói đã gỡ (gói Free huỷ ngay; `get-subscription` của ARN đã gỡ trả lỗi, không phải rỗng). Còn in: chờ một
phút rồi đọc lại; **không tắt, không xoá distribution khi gói còn**. Gói có `scheduledChange.changeType` `CANCELLATION` (gói trả phí, huỷ
theo lịch) chỉ gỡ ở `effectiveDate` của nó; tới đó distribution ở yên. Rồi distribution:

```sh
AWS_PROFILE=anhnv-stg aws cloudfront get-distribution-config --id <E…> --region ap-southeast-1 --output json > /tmp/svp-cf.json
jq '.DistributionConfig | .Enabled = false' /tmp/svp-cf.json > /tmp/svp-cf-off.json
AWS_PROFILE=anhnv-stg aws cloudfront update-distribution --id <E…> --if-match "$(jq -r .ETag /tmp/svp-cf.json)" \
  --distribution-config file:///tmp/svp-cf-off.json --region ap-southeast-1 >/dev/null
AWS_PROFILE=anhnv-stg aws cloudfront wait distribution-deployed --id <E…> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws cloudfront delete-distribution --id <E…> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws cloudfront get-distribution --id <E…> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws cloudfront delete-origin-access-control --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws cloudfront get-origin-access-control --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws cloudfront delete-response-headers-policy --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws cloudfront get-response-headers-policy --id <id> --query ETag --output text --region ap-southeast-1)"
```

VPC origin (sau mọi distribution dùng nó; `--if-match` là `ETag` của `get-vpc-origin`), rồi, khi `sweep.sh` không còn liệt kê VPC origin
nào, security group `CloudFront-VPCOrigins-Service-SG` mà CloudFront để lại (thu hồi rule tham chiếu nó trước như khối security group ở trên):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws cloudfront delete-vpc-origin --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-stg aws cloudfront get-vpc-origin --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-stg aws cloudfront list-vpc-origins --region ap-southeast-1 --query 'VpcOriginList.Items[].[Id,Name,Status]' --output text
AWS_PROFILE=anhnv-stg aws ec2 delete-security-group --group-id <sg-…> --region ap-southeast-1
```

ALB edge của prd còn deletion protection (state mất, chưa áp `teardown.tfvars`): kiểm account prd, tắt rồi xoá bằng lệnh `delete:` của
`sweep.sh prd`:

```sh
aws/scripts/check-account.sh prd
AWS_PROFILE=anhnv-prd aws elbv2 modify-load-balancer-attributes --load-balancer-arn <arn> --region ap-southeast-1 \
  --attributes Key=deletion_protection.enabled,Value=false --query 'Attributes[?Key==`deletion_protection.enabled`].Value' --output text
```

Web ACL WAF của CloudFront (cả hai env; prd với `AWS_PROFILE=anhnv-prd`, `check-account.sh prd`, tên `svp-prd-…`): scope `CLOUDFRONT` nằm ở
`us-east-1`; xoá sau khi gói đã huỷ và distribution không còn dùng nó, bằng lock token hiện tại. Web ACL sót lại sau khi gói huỷ tính
pay-as-you-go theo giờ:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws wafv2 get-web-acl --scope CLOUDFRONT --name <svp-stg-…> --id <id> --region us-east-1 --query LockToken --output text
AWS_PROFILE=anhnv-stg aws wafv2 delete-web-acl --scope CLOUDFRONT --name <svp-stg-…> --id <id> --lock-token <token> --region us-east-1
```

MSK (khi state mất), theo thứ tự: cluster (gỡ ENI của broker trong subnet database), chờ nó biến mất khỏi danh sách, rồi configuration
(AWS từ chối xoá configuration khi cluster còn dùng nó), rồi secret SCRAM và KMS key của module (mục dưới):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws kafka delete-cluster --cluster-arn <arn cluster> --region ap-southeast-1 --query State --output text
AWS_PROFILE=anhnv-stg aws kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --query 'ClusterInfoList[].[ClusterName,State]' --output text
AWS_PROFILE=anhnv-stg aws kafka delete-configuration --arn <arn configuration> --region ap-southeast-1 --query State --output text
```

Lệnh thứ ba in `svp-stg DELETING` trong lúc gỡ (≤ 30 phút, giả định của ADR-0053 §16); đọc lại tới khi không in gì, rồi lệnh cuối.

ElastiCache (khi state mất), theo thứ tự AWS cho xoá: replication group (chờ xoá xong), user group, từng user `svp-stg-*` (không bao giờ
`default`), subnet group, parameter group:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws elasticache delete-replication-group --replication-group-id svp-stg --region ap-southeast-1 --query ReplicationGroup.Status --output text
AWS_PROFILE=anhnv-stg aws elasticache wait replication-group-deleted --replication-group-id svp-stg --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws elasticache delete-user-group --user-group-id svp-stg --region ap-southeast-1 --query Status --output text
AWS_PROFILE=anhnv-stg aws elasticache describe-user-groups --region ap-southeast-1 --query "UserGroups[?UserGroupId=='svp-stg'].Status" --output text
AWS_PROFILE=anhnv-stg aws elasticache delete-user --user-id <svp-stg-…> --region ap-southeast-1 --query Status --output text
AWS_PROFILE=anhnv-stg aws elasticache delete-cache-subnet-group --cache-subnet-group-name svp-stg --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws elasticache delete-cache-parameter-group --cache-parameter-group-name <svp-stg-valkey9> --region ap-southeast-1
```

User group `deleting` chặn xoá user của nó: đọc lại (lệnh thứ năm) tới khi không in gì, rồi xoá từng user `sweep.sh` liệt kê.

Secret SCRAM `AmazonMSK_svp-stg-*` (module tạo với `recovery_window_in_days = 0`, nên chỉ sót khi state mất) xoá bằng lệnh `delete:` của
`sweep.sh` (`--force-delete-without-recovery`). KMS key của module MSK (alias `alias/svp-stg-msk-scram`) mà `sweep.sh` in `Enabled` (không
phải `pending deletion`): lên lịch xoá, sớm nhất 7 ngày, rồi xoá alias của nó. Key ở `PendingDeletion` không tính tiền, `sweep.sh` không đếm
nó; alias thì vẫn giữ tên tới khi bị xoá, nên buổi sau tạo lại alias đó lỗi `AlreadyExists` tới hết 7 ngày: `sweep.sh` đếm alias còn trỏ key
`PendingDeletion` (mục `KMS aliases on keys pending deletion`, lệnh `delete:` là lệnh thứ hai dưới đây):

```sh
AWS_PROFILE=anhnv-stg aws kms schedule-key-deletion --key-id <key id> --pending-window-in-days 7 --region ap-southeast-1 --query KeyState --output text
AWS_PROFILE=anhnv-stg aws kms delete-alias --alias-name alias/svp-stg-msk-scram --region ap-southeast-1
```

Bản ghi sót của zone `stg.aws.<domain>` (alias A, AAAA của ba tên và CNAME validation ACM của root env khi state mất): không tính tiền
nhưng chặn việc xoá zone sau này, và apply của buổi sau đỏ khi tạo lại bản ghi cùng tên. Dựng lô xoá từ chính bản ghi, đọc lại, rồi gửi:

```sh
zone=stg.aws.<domain>; zone_id=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
AWS_PROFILE=anhnv-stg aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --region ap-southeast-1 --output json |
  jq --arg apex "$zone." '{Changes: [.ResourceRecordSets[]
    | select(((.Name == $apex and (.Type == "SOA" or .Type == "CAA")) or (.Type == "NS" and (.Name == $apex or (.Name | endswith("." + $apex))))) | not)
    | {Action: "DELETE", ResourceRecordSet: .}]}' > /tmp/svp-records.json
jq -r '.Changes[].ResourceRecordSet | "\(.Name) \(.Type)"' /tmp/svp-records.json      # chỉ bản ghi sót, không NS/SOA/CAA ở đỉnh, không NS uỷ quyền bên dưới
AWS_PROFILE=anhnv-stg aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch file:///tmp/svp-records.json --region ap-southeast-1
```

Bản ghi `NS` dưới đỉnh là uỷ quyền do baseline tạo (ở zone prd: `stg.aws.<domain>.`) và `CAA` ở đỉnh, phải giữ: khối trên bỏ qua chúng.
Ở zone prd dùng cùng
khối với `AWS_PROFILE=anhnv-prd`, `zone=aws.<domain>`, `aws/accounts/prd`. Management không có zone nên lượt `mgmt` không có bản ghi nào để xoá.

MediaConvert (khi state mất, hay queue còn job): huỷ mọi job dở của queue `svp-stg`, đọc lại tới khi hai lệnh `list-jobs` không in gì,
rồi xoá queue. Phần còn lại của transcode xoá bằng lệnh `delete:` của `sweep.sh stg`, theo thứ tự nó in: hai hàng đợi SQS, đích rồi rule
EventBridge `svp-stg-mediaconvert-job-state`, alarm, policy inline rồi role `svp-stg-mediaconvert` (IAM ở `us-east-1`):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws mediaconvert list-jobs --queue svp-stg --status SUBMITTED --region ap-southeast-1 --query 'Jobs[].Id' --output text
AWS_PROFILE=anhnv-stg aws mediaconvert list-jobs --queue svp-stg --status PROGRESSING --region ap-southeast-1 --query 'Jobs[].Id' --output text
AWS_PROFILE=anhnv-stg aws mediaconvert cancel-job --id <id> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws mediaconvert delete-queue --name svp-stg --region ap-southeast-1
```

AWS Backup plans (loại `AWS Backup plans` của `sweep.sh`): chỉ plan cục bộ `svp-probe*` của thử sandbox ở management (lượt `sweep.sh mgmt`,
`AWS_PROFILE=anhnv-sso`, `check-account.sh mgmt`). AWS từ chối xoá plan còn selection: xoá từng selection, rồi plan. Không xoá plan
`svp-stg`, `svp-prd`: Backup policy của `aws/org` sinh chúng, account không xoá được.

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws backup list-backup-selections --backup-plan-id <BackupPlanId> --region ap-southeast-1 \
  --query 'BackupSelectionsList[].[SelectionId,SelectionName]' --output text
AWS_PROFILE=anhnv-sso aws backup delete-backup-selection --backup-plan-id <BackupPlanId> --selection-id <SelectionId> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws backup delete-backup-plan --backup-plan-id <BackupPlanId> --region ap-southeast-1 --query DeletionDate --output text
```

Loại AWS Backup khác có lệnh `delete:` đủ dưới mỗi dòng của `sweep.sh`, theo thứ tự nó in: job (dừng backup job; copy, restore job thì chờ),
recovery point, vault lock (governance: account gỡ được), vault, policy rồi role `svp-*-backup`. Vault không xoá được khi còn recovery point
hay copy job đang ghi vào nó: xoá recovery point trước, chờ job xong.

Luật và Alertmanager của AMP sót (dòng `note left in AMP: …` của `pre-destroy.sh`, hay `AMP rule groups namespaces` của `sweep.sh`): xoá bằng
lệnh dòng đó in, rồi đọc lại tới khi rỗng; workspace thì giữ (`kept`):

```sh
aws/scripts/check-account.sh stg
ws=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw amp_workspace_id)
AWS_PROFILE=anhnv-stg aws amp delete-rule-groups-namespace --workspace-id "$ws" --name <tên> --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws amp delete-alert-manager-definition --workspace-id "$ws" --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws amp list-rule-groups-namespaces --workspace-id "$ws" --region ap-southeast-1 --query 'ruleGroupsNamespaces[].name' --output text
```

Policy tạm `svp-session-deny-query` của phép kiểm canary (mục Phép kiểm nền tảng managed (d)) còn trên role `svp-stg-argo-rollouts`: gỡ trước
destroy của root env (lệnh `delete-role-policy` của mục đó): Terraform không biết policy này, nên destroy có thể đỏ ở role đó (`DeleteConflict`).

Role CI `svp-ci-*` hay IAM OIDC provider mà `sweep.sh` in là sót (không `kept`: account không còn giữ `Stack=baseline`, tức `aws/accounts/<env>` đã
gỡ dở): Terraform của root đó là đường chính (mục "Gỡ baseline" của [README `aws/accounts`](../../aws/accounts/README.md#gỡ-baseline-có-chủ-đích));
khi state mất, gỡ mọi policy inline của role rồi xoá role:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws iam list-role-policies --role-name <svp-ci-…> --region us-east-1 --query PolicyNames --output text
AWS_PROFILE=anhnv-stg aws iam delete-role-policy --role-name <svp-ci-…> --policy-name <từng tên trên> --region us-east-1
AWS_PROFILE=anhnv-stg aws iam delete-role --role-name <svp-ci-…> --region us-east-1
```

**Secret Secrets Manager đang chờ xoá** (dòng `scheduled for deletion since …`): vẫn giữ tên tới hết thời gian chờ (7–30 ngày), nên
**chặn tạo lại secret cùng tên** ở buổi sau (entry `svp/stg/*` do Terraform tạo với `recovery_window_in_days = 0` nên xoá ngay; dòng này là
secret tạo cách khác). Secret master của RDS mang tên sinh ngẫu nhiên (`rds!db-<uuid>`), không chặn buổi sau, nhưng `sweep.sh` vẫn đếm nó tới
khi mất. Lệnh `delete:` của `sweep.sh` xoá hẳn ngay (không khôi phục được); muốn lấy lại để dùng tiếp:

```sh
AWS_PROFILE=anhnv-stg aws secretsmanager restore-secret --secret-id <name> --region ap-southeast-1
```

## Đổi một secret của env đang chạy

Hai nguồn, hai đường: mật khẩu Kafka và Valkey do Terraform sinh (entry `kafka-admin`, `kafka-users`, `valkey-users`); mọi entry khác từ
`.env` của repo code. Cả hai kết thúc bằng cùng một lệnh, `bootstrap.sh stg secrets`, chạy `make eks-secrets` (đọc lại mật khẩu master RDS
như bước 6), làm trọn một lượt xoay theo thứ tự của `make k8s-secrets` trên k3d, người học không sync, không restart tay:

1. ghi lại các entry từ `.env` (trừ ba entry của Terraform và `glitchtip-runtime`, đã có giá trị);
2. dựng lại (force-sync) các ExternalSecret của `svp-data` (`kafka-admin`, `svp-ops`, `pg-*`) từ entry;
3. một sync của Application `svp-data`, chờ đúng lượt đó `Succeeded`: Job `pg-bootstrap` đặt mật khẩu mới trong Postgres, Job `kafka-init`
   đăng nhập MSK bằng `svp-admin` với mật khẩu của entry (thử lại ít nhất 10 phút) và đặt lại topic, ACL;
4. dựng lại mọi ExternalSecret còn lại (`svp/<service>-env` có `KAFKA_SASL_PASSWORD`, `REDIS_URL`; `keda/keda-kafka`; `svp-obs/otelcol-kafka`);
   Reloader restart workload có Secret đổi (Rollout `gateway`, `web` không có revision mới nên không thành canary).

**Mật khẩu từ `.env`** (Postgres của service, khoá API…): sửa `.env` của repo code, rồi `aws/scripts/bootstrap.sh stg secrets`.

**Mật khẩu Kafka hay Valkey** (ADR-0053 §12): tăng version write-only của nhóm đó trong `aws/envs/stg/stg.auto.tfvars` (git bỏ qua; giữ giá
trị mới tới hết buổi và các buổi sau: apply với version khác lại sinh mật khẩu mới), plan, đọc, apply, rồi một lượt như trên. Mỗi version đổi
mọi user của nhóm cùng lúc (một entry chung). Đọc version đang có (không có dòng của nhóm: version là 1, mặc định của biến), rồi sửa
trong editor đúng dòng đó thành số lớn hơn (`msk_password_version` cho Kafka, `valkey_password_version` cho Valkey); file chưa có dòng của
nhóm thì thêm một dòng `msk_password_version = 2` (hay `valkey_password_version = 2`). Không nối thêm dòng cùng tên: Terraform từ chối file
có một biến hai lần (`Attribute redefined`) ngay ở plan:

```sh
grep -E '^(msk|valkey)_password_version' aws/envs/stg/stg.auto.tfvars
aws/scripts/tf.sh stg env plan
aws/scripts/tf.sh stg env apply
aws/scripts/bootstrap.sh stg secrets
```

Plan chỉ đổi phiên bản của secret, `aws_secretsmanager_secret_version` (tám secret `AmazonMSK_*` và hai entry `kafka-*`, hay entry
`valkey-users`), và với Valkey bốn `aws_elasticache_user` tại chỗ; thấy cluster MSK, replication group, user group hay chính secret bị
`replace`, `destroy`: dừng, dán plan cho AI. Kafka: chờ 10 phút giữa
`apply` và `bootstrap.sh` (MSK đồng bộ secret SCRAM tới broker trong tối đa 10 phút; Job `kafka-init` của bước 3 là chốt, nó chỉ xanh khi
broker nhận mật khẩu mới). Valkey: ElastiCache đổi mật khẩu của user ngay khi apply xong, nên chạy `bootstrap.sh` ngay; tới khi Reloader
restart xong, kết nối mới của pod còn mật khẩu cũ bị từ chối (kết nối đang mở vẫn chạy): ADR-0053 chấp nhận khoảng này.

Tìm trong output và `$SVP_SESSION_DIR/eks-secrets.log`, theo thứ tự:

- `ok    entries of svp/stg/ written: … kafka-admin kafka-users valkey-users left to the infrastructure repository`;
- `ok    ExternalSecrets of the server built again from their source: …`;
- `ok    init Jobs of svp-data done (sync of Application svp-data Succeeded): the servers take the new passwords`;
- `ok    ExternalSecrets of the clients built again from their source: …`;
- `ok    Reloader restarts each workload whose Secret changed …`.

Một dòng `FAIL` thì không bước nào sau nó chạy:

- `FAIL  cluster svp-stg is not ready for a change of credentials: <lý do>`: cluster chưa có Reloader chạy, không gì bị ghi; sync Application
  `svp-apps` tới revision có nó;
- `FAIL  sync of Application argocd/svp-data …`: xem Job lỗi (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data get jobs`,
  `… logs job/kafka-init`); Job `kafka-init` lỗi đăng nhập ngay sau khi đổi mật khẩu Kafka là MSK chưa đồng bộ: chờ rồi chạy lại. Secret của
  client chưa đổi.

Sửa nguyên nhân rồi chạy lại đúng `aws/scripts/bootstrap.sh stg secrets`: lượt nào cũng làm đủ các bước, gồm Job init còn thiếu của lượt
trước. Theo dõi restart:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get pods -A -w
```

Không sửa entry hay Secret bằng tay, không ghi mật khẩu Kafka, Valkey vào entry bằng `put-secret-value`: Terraform là nơi duy nhất ghi ba entry
đó cùng secret SCRAM và user ElastiCache, ghi tay làm hai bên lệch. Chi tiết: `docs/reference/eks.md` của repo code, mục "Đổi secret của env
đang chạy".

## Kết thúc buổi

1. Thứ tự gỡ, mỗi bước xong mới sang bước sau: destroy root `aws/gitops/stg`, xoá backup của buổi, rồi destroy `aws/envs/stg` (bước
   16–22); `sweep.sh stg`; `sweep.sh mgmt`.
   Hai lượt cùng exit 0 (dán output cho AI). AI nhắc tới khi người học xác nhận đã chạy cả hai destroy và hai lượt sweep. Phép kiểm (e) của
   ADR-0052 (output vào phụ lục của nó, kết luận vào "Xác nhận"): sau destroy, gói của account rỗng (mong `[]`), cùng lượt `sweep.sh stg` sạch:

   ```sh
   AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

   Phép kiểm (f) của ADR-0053 là cùng hai lượt sweep sạch: không còn dòng MSK, ElastiCache, `AmazonMSK_*` nào; KMS key của root env chỉ ở
   `pending deletion`. Phép kiểm `pre-destroy.sh` của ADR-0056: cùng lượt đó không còn instance, launch template, instance profile, hàng đợi
   SQS hay rule EventBridge nào của Karpenter. Phép kiểm gỡ của ADR-0066: cùng lượt đó không còn queue `svp-stg`, role
   `svp-stg-mediaconvert`, hàng đợi `svp-stg-transcode-events*`, rule `svp-stg-mediaconvert-job-state`, endpoint `svp-stg-mediaconvert`. Phép
   kiểm gỡ của ADR-0067: cùng lượt đó không còn recovery point, job AWS Backup chưa kết thúc hay instance `svp-stg-pitr`; vault `svp-stg`, role
   `svp-stg-backup` là `kept`; bản copy của buổi vẫn ở `svp-stg-copy` (lệnh **Đọc bản copy** của mục **12–14**, mong cùng ba dòng). Ngày sau
   buổi, tổng MediaConvert của ngày buổi ở Cost Explorer (lệnh ở mục "Chi phí mỗi phút video" của
   [phụ lục ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md#chi-phí-mỗi-phút-video)),
   đối chiếu với tổng tính theo output của mọi job trong `mediaconvert-jobs.json` (lượt cuối của mục **Phép kiểm transcode** (f)) mà video có
   bản ghi ở `$SVP_SESSION_DIR/transcode-jobs/`, job lạc gồm; dán output.
   Rồi chạy lại truy vấn dữ liệu đã ghi trước bước 15 (mục Phép kiểm nền tảng managed (e), `after-destroy.txt`), cùng ngày; dán `diff`.
   Buổi đầu có span của account: retention của `aws/spans` theo bước (10) của
   [`platform-setup.md`](platform-setup.md#bước-10-retention-của-awsspans).
2. Cái ở lại giữa các buổi: ở account stg là baseline (`Stack=baseline`: bucket state, KMS key state, zone `stg.aws.<domain>` với `CAA`;
   registry ECR cùng repo phát hành, rule và repo của pull-through cache, OIDC provider, role CI; workspace AMP, log group `/svp/stg/otel`,
   Transaction Search của X-Ray cùng `aws/spans`, workspace AMG, hai key KMS của chúng; vault `svp-stg` rỗng, key `alias/svp-stg-backup`,
   role `svp-stg-backup`, opt-in của AWS Backup) và
   baseline bảo mật (`Stack=security-baseline`: CMK EBS `alias/svp-ebs`; recorder Config, rule `svp-security-*` không phải tài nguyên `sweep.sh`
   liệt kê); ở account prd là hai baseline của nó, gồm zone `aws.<domain>` với `CAA`, bản ghi `NS` uỷ quyền `stg.aws.<domain>`, DNSSEC, query
   log và topic alarm DNSSEC (`sweep.sh` in chúng là `kept`); ở account Log Archive, bucket log CloudFront và delivery destination; ở account
   `svp-backup`, vault `svp-stg-copy` với bản copy của buổi tới hết retention (root `aws/backup`); plan `svp-stg` của Backup policy;
   management chỉ còn `Stack=bootstrap|org|security-baseline|security`, không hosted zone. `destroy` của hai root env không đụng zone
   nào (zone thuộc root `aws/accounts/<env>`) và không đụng baseline bảo mật (root `aws/baseline`).
3. Giữ `$SVP_SESSION_DIR` (máy local, không commit): `timeline.tsv`, `k6-levels.tsv`, `k6-<n>/` là số đo cho cột Kết quả của ADR-0034
   "Kiểm chứng sau" và roadmap; `restore-drill.tsv` là số đo RTO/RPO cho phụ lục ADR-0067; `controls-failed.tsv` là danh sách control
   FAILED của tài nguyên buổi, đầu vào của việc sửa trong Terraform.
4. Sau 24 giờ: Cost Explorer theo dịch vụ (account stg, hay management cho cả org), so với ước lượng (ADR-0034 §12 cộng MSK, ElastiCache
   của ADR-0053 §16, cộng phần của mục **Giới hạn**, ±50 %); số thật thay ước lượng ở mục đó.
