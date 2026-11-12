# Runbook: một buổi AWS stg

Một buổi dựng env stg trong account `svp-stg` (`aws/envs/stg`), cài Argo CD và root GitOps lên EKS bằng Terraform (`aws/gitops/stg`, mẫu
GitOps Bridge), đo (smoke, seed, k6 bậc 1, 2, 4, 8), rồi gỡ sạch trong cùng buổi và quét cả account stg lẫn account management. Thiết kế:
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
VPC origin tới ALB internal, ba web ACL, cert ACM, log CloudFront, DNS của buổi). Buổi prd theo [`session-prd.md`](session-prd.md),
dùng chung mọi mục chung của file này.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại và nhắc tới khi destroy hai root và hai lượt `sweep.sh` (stg, mgmt) đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`). Mỗi account một
profile và một biến account, script tự lấy theo env từ bảng `env_table` của `aws/scripts/lib.sh`:

| Env của script | Account | Profile | Biến account |
| --- | --- | --- | --- |
| `stg` | `svp-stg` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` |
| `prd` | `svp-prd` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` |
| `mgmt` | management (account sandbox cũ) | `anhnv-sso` | `SVP_AWS_MGMT_ACCOUNT_ID` |

Profile và region `ap-southeast-1` (`us-east-1` cho WAF, cert ACM và log chuẩn của CloudFront, Pricing Plan Manager và API Free Tier)
ghi sẵn trong từng lệnh của script. Script in mỗi bước một dòng
`ok`, `FAIL` (dừng), `note` hay `skip`, không in giá trị bí mật nào.

Xem trước toàn bộ lệnh của buổi, theo đúng thứ tự, không chạy gì (an toàn, không cần credential):

```sh
aws/scripts/session.sh --print stg
```

## Giới hạn

- **Cả buổi 4 giờ**, từ `check-account.sh` (mốc `session-start`) tới hai lượt `sweep.sh` sạch. **Quá 3 giờ mà chưa đo xong thì bỏ phần đo
  còn lại, sang gỡ**: `measure.sh` tự bỏ bậc k6 nào sẽ kết thúc sau mốc 3 giờ (dòng `skip`).
- Chi phí, trần $5 một buổi 4 giờ: ước tính của ADR-0034 §12 cộng MSK và ElastiCache (H_k ~$0,144 mỗi giờ, O_k ~$0,06, ADR-0053 §16), cộng
  phần ADR-0055 và ADR-0056 thêm vào stg (nhóm node hệ thống on-demand, bastion SSM, KMS key, log control plane, flow log, CloudWatch alarm),
  cộng phần edge (ALB, phí theo giờ của ba web ACL, log; bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13); buổi đầu đo số thật ở Cost
  Explorer (mục **Kết thúc buổi**). Quên destroy 24 giờ tốn gấp ~6 lần một buổi; budget `svp-stg-monthly` của
  account stg và budget tổng của org ở management gửi email ở 50 %, 80 %, 100 %.
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
   tới API), `kubectl`, `jq`, `dig`, `nc`, `make`; `.env` của repo code đã có
   (`make -C ../backend env`; `tf.sh stg gitops plan` lấy chat Telegram `SVP_ALERT_TELEGRAM_CHAT_ID` từ đó, rỗng là chỉ commit status).
4. File backend của account stg, `aws/backend-stg.hcl` (git bỏ qua; chỉ bucket, region, KMS key, không `key`), ghi từ output của baseline:

   ```sh
   AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw backend_hcl > aws/backend-stg.hcl
   ```

5. `aws/envs/stg/stg.auto.tfvars` (git bỏ qua) sinh bằng khối lệnh dưới, chỉ đọc output của baseline; thay `<domain>`, `<email>` (hộp
   thư nhận alarm):

   ```sh
   zone=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
   cat > aws/envs/stg/stg.auto.tfvars <<EOF
   hosted_zone_id = "$zone"
   domain         = "stg.aws.<domain>"
   alarm_email    = "<email>"
   EOF
   ```

   `domain` là tên zone của account stg (web ở đỉnh, API ở `api.<domain>`); precondition của root từ chối tên ngoài zone đó ngay lúc plan.
   Endpoint công khai của API tắt, nên file không có IP của máy. File có sẵn mà còn dòng `eks_public_access_cidrs` hay `acme_email` (root
   không khai báo hai biến này: Terraform chỉ cảnh báo `Value for undeclared variable`) hay thiếu `alarm_email` (plan dừng ở `No value for
   required variable`): xoá hai dòng đó, thêm dòng `alarm_email` trong editor, rồi đếm (không in giá trị nào):

   ```sh
   sed -i '' -E '/^(eks_public_access_cidrs|acme_email)[[:space:]]*=/d' aws/envs/stg/stg.auto.tfvars
   grep -c -E '^(hosted_zone_id|domain|alarm_email) ' aws/envs/stg/stg.auto.tfvars     # 3
   ```

6. **Nền bảo mật của org đã áp** tới ít nhất bước (3) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu) (`aws/bootstrap`,
   `aws/org` tạo account `svp-log-archive`, `aws/log-archive`): root env ghi flow log VPC vào bucket `svp-flowlogs-<log>-ap-southeast-1` và log
   WAF vào `aws-waf-logs-svp-<log>-us-east-1` của account đó, nên cần id account đó trong biến `SVP_AWS_LOG_ACCOUNT_ID` (output
   `log_archive_account_id` của `aws/org`; mục **Mở terminal của buổi**). Thiếu biến thì `tf.sh` dừng với `FAIL set SVP_AWS_LOG_ACCOUNT_ID …`;
   bucket chưa có thì `apply` đỏ ở flow log hay logging của web ACL.
7. **Edge đã áp lần đầu** theo [`edge-setup.md`](edge-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (3): delivery destination
   `svp-cloudfront-stg` của account Log Archive (root env tạo delivery log của CloudFront tới nó; thiếu thì `apply` đỏ ở
   `aws_cloudwatch_log_delivery`), `CAA` ở zone, zone prd ký và có `DS` ở DNS cha (phép kiểm edge đọc cờ `ad`). Một lần, không nằm trong buổi.
8. Mac cắm sạc, tắt Low Power Mode (đo k6 và chờ dài).

## Mở terminal của buổi

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                                             # cho lượt sweep.sh mgmt cuối buổi
export SVP_AWS_STG_ACCOUNT_ID=<12 số của account svp-stg>                       # đọc trên trang SSO; không ghi vào file nào
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_AWS_LOG_ACCOUNT_ID=<12 số của account svp-log-archive>               # bucket flow log, log WAF của root env
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"               # số đo của buổi; .session/ git bỏ qua
```

Hai profile dùng chung một phiên SSO khi cùng `sso_session` trong `~/.aws/config`, khi đó một lần `aws sso login` là đủ. Biến account không
nằm trong file commit nào, kể cả `.envrc`; script đặt `TF_VAR_account_id` từ biến của env và `TF_VAR_log_archive_account_id` từ
`SVP_AWS_LOG_ACCOUNT_ID` ngay trong lệnh `terraform` của root env.

Mọi bước sau chạy trong **cùng terminal này** (cùng các biến). Thư mục buổi chứa: `timeline.tsv` (mốc UTC: `session-start`,
`env-apply-start`, `env-apply-end`, `secrets-written`, `gitops-apply-start`, `gitops-apply-end`, `observability-healthy`, `glitchtip-init`,
`svp-root-healthy`, `edge-healthy`, `smoke-ok`, `seed-ok`, `k6-<n>-start`/`-end`, `pre-destroy-*`, `gitops-destroy-*`, `env-destroy-*`),
`cluster-values.json` (mode 600), `eks-secrets.log`, `svp-cluster-chart/`, các file text của plan, `k6-levels.tsv`, `k6-<n>/`.

**Mở lại terminal giữa buổi** (terminal đóng, máy khởi động lại): đặt lại các biến, với `SVP_SESSION_DIR` là **thư mục của buổi đang dở**,
không phải thư mục mới. `measure.sh` đọc `cluster-values.json` của nó và tính mốc 3 giờ từ `session-start` của nó; `tf.sh` đọc các mốc gỡ
(`pre-destroy-done`, `gitops-destroy-end`) trong `timeline.tsv` của nó.

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
export SVP_AWS_STG_ACCOUNT_ID=<12 số> SVP_AWS_MGMT_ACCOUNT_ID=<12 số> SVP_AWS_LOG_ACCOUNT_ID=<12 số>
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
| 12 | `aws/scripts/pre-destroy.sh stg` | 30 phút | mọi dòng `ok`/`FAIL`/`note` |
| 13 | `aws/scripts/tf.sh stg gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` |
| 14 | `aws/scripts/tf.sh stg gitops destroy` | 10 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` |
| 15 | `aws/scripts/tf.sh stg env plan --teardown` | 1 phút | dòng `skip` (stg không có bảo vệ cần nhấc) |
| 16 | `aws/scripts/tf.sh stg env apply --teardown` | 1 phút | dòng `skip` |
| 17 | `aws/scripts/tf.sh stg env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan |
| 18 | `aws/scripts/tf.sh stg env destroy` | 50 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster MSK, replication group ElastiCache |
| 19 | `aws/scripts/sweep.sh stg` | 5 phút | toàn bộ output |
| 20 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output |

Bước tay chen giữa các bước script: xác nhận email của alarm sau bước 5 (mục 3–5), tunnel tới API sau bước 5 và trước bước 6 (mục
**Tunnel tới API**, giữ chạy tới hết bước 14), phép kiểm của bước 11, đọc finding bảo mật sau bước 11 và trước bước 12 (mục **Finding bảo
mật của buổi**).

Dự trù: apply root env xong ~T+70 phút (MSK là phần dài nhất), mọi Application Healthy ~T+1 giờ 55, đo tới muộn nhất T+3 giờ, gỡ và quét
xong trước T+4 giờ khi gỡ đúng số giả định của ADR-0053 §16; buổi stg đầu tiên đo hai mốc đó và ghi vào phụ lục của ADR.
Một bước đỏ: đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được). Không đi tiếp qua một bước đỏ, trừ
bước 11 (đo): đo hỏng thì vẫn sang bước 12. Bước 15, 16 không làm gì ở stg (không có `teardown.tfvars`); chúng nằm trong bảng để stg và prd
chạy cùng một chuỗi bước.

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
(bảng dưới). Muốn bỏ buổi thì sang bước 12 (`pre-destroy.sh` tự ghi context `svp-stg`, nên chạy được cả khi apply đỏ sau khi cluster EKS
đã có), hay bước 17 với `--no-cluster` khi apply đỏ trước khi tạo cluster EKS (điều kiện ở bước
17).

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
context không bao giờ tới cluster kia). Mở ở **một terminal riêng** từ gốc repo, giữ chạy tới hết bước 14 (Ctrl-C để đóng):

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
chỉ kiểm chúng có, không ghi, không đọc mật khẩu Kafka, Valkey của `.env` (mật khẩu của stack local). Nguồn của mọi Secret trên EKS có trước
Argo CD. Tìm: `ok entries svp/stg/* written (kafka-admin, kafka-users, valkey-users by the apply of aws/envs/stg)` và mốc `secrets-written`.
Đỏ: dán ~30 dòng cuối của `$SVP_SESSION_DIR/eks-secrets.log` (script nêu tên biến thiếu, không in giá trị).

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

sửa xong chạy lại (chạy lại được). Muốn bỏ buổi ở đây: sang bước 12; `pre-destroy.sh` chạy được cả khi Argo CD chưa được cài.

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

Trong lúc giữ tải, đọc phía server ở Grafana (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs port-forward --address 127.0.0.1
service/kps-grafana 3000:80`, đăng nhập `admin` + `SVP_GRAFANA_ADMIN_PASSWORD` của `.env`, dashboard SLO): p95/p99 của gateway theo route.
Các phép kiểm chỉ chứng minh được trên AWS ở mục "Kiểm chứng sau" của ADR-0034 và ADR-0048: làm trong lúc chờ bậc k6, ghi kết quả từng phép
kiểm (đạt hay không, output chính) vào một file trong `$SVP_SESSION_DIR`, để sau buổi điền cột Kết quả của bảng đó. Dán lại: `cat
$SVP_SESSION_DIR/k6-levels.tsv`, dòng `ok highest level …`, và với mỗi bậc `jq -c . $SVP_SESSION_DIR/k6-<n>/summaries/pod-*.json | head`.

Commit status `argocd/stg` (Argo CD Notifications, ADR-0032) phải có trên commit `svp-gitops` cluster vừa sync: đó là **bằng chứng stg** mà
`promote-prd` đòi trước khi promote commit đó lên prd. Đọc commit và status:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.sync.revision}{"\n"}'
gh api "repos/anhnvcoder/svp-gitops/commits/<sha trên>/statuses" --jq '.[] | select(.context == "argocd/stg") | "\(.state) \(.created_at)"' | head -n 1
```

Mong `success`; dán lại cả hai dòng.

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
limit theo IP dùng), nên phép này đọc trace: Grafana
(port-forward của bước 11) → Explore → data source Tempo → TraceQL, 15 phút gần nhất, hai truy vấn:

```text
{ span.client.address = "<IP vừa in>" }
{ span.client.address = "203.0.113.7" || span.client.address = "198.51.100.7" }
```

Mong truy vấn đầu có ít nhất ba trace ở thời điểm ba request, truy vấn sau không trace nào: CloudFront đè `CloudFront-Viewer-Address` viewer tự
gửi, gateway không đọc `X-Forwarded-For`. Truy vấn sau có trace: dừng buổi, dán output cho AI (mục "Xem lại khi" của ADR-0061).

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

(g) Plan lần hai `No changes`: phép (c) của mục trên (prd: bước 11 của `session-prd.md`). (h) Sau destroy, `sweep.sh stg` sạch: bước 19.

#### Kafka và Valkey managed

Phép kiểm (a)–(e) của mục "Xác nhận" của
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md#xác-nhận); (b) là smoke của
`measure.sh` (service ghi, đọc Kafka qua SASL/SCRAM-SHA-512 trên TLS), (f) là hai lượt `sweep.sh` cuối buổi. Lệnh và output có thời điểm UTC
vào phụ lục, một dòng kết luận mỗi env vào "Xác nhận". Buổi prd chạy đúng các lệnh này với `anhnv-prd`, `svp-prd`.

Mọi lệnh chạm Kafka, Valkey đi qua CLI vận hành (ADR-0053 §13): `svp-kafka` (đăng nhập `svp-admin`), `svp-valkey` (đăng nhập `svp-ops`) trong
Deployment `svp-data/svp-ops`, không `kubectl run`, không công cụ trên máy. Thử quyền của một user thường: `SVP_AS_USER=<user>`, mật khẩu là
dòng đầu của stdin, lấy từ Secret của chính client đó (`svp/<service>-env`), không qua đối số, không in ra.

(a) MSK `ACTIVE` với cấu hình của ADR-0053 §2, ElastiCache `available`; phút dựng là hai dòng `Creation complete after …` của bước 5, phút gỡ
là hai dòng `Destruction complete after …` của bước 18; plan lần hai `No changes` là phép (c) của mục trên:

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

(e) Lag hiện trên dashboard: trong lúc giữ tải, Grafana (port-forward ở trên) dashboard "SVP — Kafka and pipeline", panel "Consumer lag by
group (max over partitions)" có đường của bốn group `video-service`, `engagement-service`, `feed-service`, `media-worker` (receiver
`kafkametrics` của Collector, user `svp-otelcol`). Đối chiếu với broker:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka consumer-groups --describe --all-groups
```

Mong cột `LAG` của mỗi group cùng cỡ với panel. Panel trống: dán lỗi của receiver
(`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/otel-collector --tail=50 | grep -i kafka`) cho AI.

### Finding bảo mật của buổi (sau bước 11, trước bước 12)

Chỉ đọc, profile `anhnv-security-ro` của account Security Tooling, khi tài nguyên của buổi **còn sống**: tài nguyên bị xoá thì finding control
của nó chuyển `NOT_AVAILABLE` và `ARCHIVED` (Security Hub CSPM User Guide, "Generating and updating control findings"), nên lượt đọc định kỳ
của `security-alert.md` không bao giờ thấy tài nguyên chỉ sống trong buổi. Buổi dừng sớm rồi đi thẳng tới gỡ: vẫn đọc mục này trước bước 12
(đường `--no-cluster` của mục **15–18**: trước `plan --destroy`).

Mục này cần bước (4), (5) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu): profile `anhnv-security-ro` và Security
Hub ở `svp-security`. Org mới áp tới bước (3) (đủ cho buổi, điều kiện 6) thì chưa có gì để đọc: bỏ qua mục này. Kiểm:
`aws configure list-profiles | grep -x anhnv-security-ro` không in gì là chưa có.

```sh
ACC="${SVP_AWS_STG_ACCOUNT_ID:?not set}"    # buổi prd: ACC="${SVP_AWS_PRD_ACCOUNT_ID:?not set}"
A="\"AwsAccountId\":[{\"Value\":\"$ACC\",\"Comparison\":\"EQUALS\"}],\"RecordState\":[{\"Value\":\"ACTIVE\",\"Comparison\":\"EQUALS\"}]"
# Control FAILED của account (không bao giờ tới email); bản đủ, có id tài nguyên, giữ trong thư mục buổi
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

### 12. Gỡ trong cluster trước destroy

```sh
aws/scripts/pre-destroy.sh stg
```

Tunnel còn mở. Gỡ những gì Kubernetes tạo trong account mà Terraform không biết, **khi controller tạo ra chúng còn chạy**, mỗi lần chờ có
hạn: target của Envoy trong target group edge (`TargetGroupBinding`), volume EBS của PVC, node của Karpenter. Chỉ cần apply đã tạo cluster:
script tự chạy `aws eks update-kubeconfig --name svp-stg --alias svp-stg`, không đọc file nào của bước 6, nên chạy được cả khi bước 6 chưa
chạy hay từ thư mục buổi mới. `FAIL kubeconfig context …` là account không có cluster `svp-stg`: sang bước 17 với
`--no-cluster`.

1. ApplicationSet `svp-bootstrap` (nó dựng lại `svp-root`), `svp-root` và `svp-apps` (auto-sync prune + self-heal, không finalizer): xoá
   finalizer và `automated` của hai Application, rồi xoá riêng ba cái (child ở yên); tắt auto-sync của mọi Application còn lại (để
   `svp-cluster` không dựng lại Gateway).
2. Application workload theo sync wave từ cao xuống (finalizer của mỗi cái xoá thứ nó triển khai), trừ `svp-cluster` và controller nền
   tảng (cả `karpenter`); rồi Gateway `svp-edge/svp`, rồi xoá tường minh TargetGroupBinding `envoy-gateway-system/svp-envoy` (chart
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
bước 1, 5 và phần Application của bước 2 bỏ qua. Cluster chưa có CRD của Karpenter (dòng `note no Karpenter on svp-stg`): bước 4 không xoá
gì. Các phép chờ của bước 2–4 (Service `LoadBalancer`, ELBv2, PVC, volume EBS, instance của Karpenter) vẫn chạy, rồi ghi mốc
`pre-destroy-done` như thường.

Tìm: mỗi bước `ok`, cuối cùng `ok ready for: aws/scripts/tf.sh stg gitops plan --destroy` và mốc `pre-destroy-done` (thiếu mốc này thì
`tf.sh stg gitops plan --destroy` từ chối). Script ghi mốc `pre-destroy-start` ngay sau khi kiểm account, trước mọi bước khác. `FAIL` nêu thứ
còn lại và lệnh xem; sửa rồi chạy lại script (mỗi bước tìm thứ còn lại). Bước 4 đỏ vì NodeClaim còn: đọc log của Karpenter
(`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --tail=50`); đỏ vì instance còn mà hết NodeClaim:
`sweep.sh stg` in lệnh tắt nó. Bước 2 đỏ ở `svp-envoy`: dòng `FAIL` nêu lệnh xem finalizer, status của nó và log của LBC.
**Hết giờ của buổi mà bước 2, 3 hay 4 vẫn đỏ sau khi đã chạy lại**
(dòng `note` cuối sau `FAIL` nhắc lối này): sang bước 13 với `--leftovers`.

### 13–14. Gỡ root gitops

```sh
aws/scripts/tf.sh stg gitops plan --destroy
aws/scripts/tf.sh stg gitops destroy
```

Root gitops gỡ **trước** root env (provider của nó cần cluster). `plan --destroy` ghi `aws/gitops/stg/stg.destroy.tfplan` và bản text vào
`$SVP_SESSION_DIR/stg-gitops-destroy-plan.txt`; từ chối khi thư mục buổi chưa có mốc `pre-destroy-done`. Đọc file text: chỉ tài nguyên của
`aws/gitops/stg`, `0 to add, 0 to change`. `destroy` chỉ áp file đó (`terraform apply` file đó: không plan lại tại chỗ, không hỏi lại), ghi
mốc `gitops-destroy-end`. Root gitops chưa init trong bản checkout này (bỏ buổi trước bước 7): `aws/scripts/tf.sh stg gitops init` trước;
state trống thì plan là `No changes` và destroy chỉ ghi mốc.

Root gitops gỡ qua tunnel: đóng tunnel được sau bước 14. Hết giờ của buổi mà bước 12 vẫn đỏ ở bước 2, 3 hay 4 của nó sau khi đã chạy lại:
lối thoát có kiểm, để cluster không tính tiền tiếp.

```sh
aws/scripts/tf.sh stg gitops plan --destroy --leftovers
```

Chỉ nhận khi `timeline.tsv` của buổi có mốc `pre-destroy-start` (bước 12 đã chạy trong thư mục buổi này) mà chưa có `pre-destroy-done`;
thiếu `pre-destroy-start` thì từ chối và bảo chạy bước 12 trước, đã có `pre-destroy-done` thì từ chối (không cần cờ này). Dòng `note
--leftovers: …` nhắc thứ Kubernetes tạo có thể còn (volume EBS của PVC, instance EC2 của Karpenter, load balancer của Load Balancer
Controller), rồi ghi
mốc `pre-destroy-skipped`. Tiếp: bước 14, rồi các bước sau (destroy có thể kẹt vì những thứ đó: mục **Destroy kẹt**); thứ `sweep.sh` liệt
kê xoá bằng lệnh nó in, rồi chạy lại `sweep.sh` tới khi sạch.

### 15–18. Gỡ root env

```sh
aws/scripts/tf.sh stg env plan --teardown
aws/scripts/tf.sh stg env apply --teardown
aws/scripts/tf.sh stg env plan --destroy
aws/scripts/tf.sh stg env destroy
```

Bước 15, 16 in `skip`: stg không có file nhấc bảo vệ (prd có, `session-prd.md`). `plan --destroy` từ chối khi thư mục buổi chưa có mốc
`gitops-destroy-end`; như bước 4 cho apply, ghi `aws/envs/stg/stg.destroy.tfplan` và bản text `stg-env-destroy-plan.txt`. **Đọc file text đó
trước bước 18**: chỉ tài nguyên của `aws/envs/stg`, `0 to add, 0 to change`; không có bucket `svp-tfstate`, không có `aws_route53_zone` (của
baseline `aws/accounts/stg`, root khác). Thấy thứ khác: dừng, dán plan cho AI. `destroy` chỉ áp file đó, rồi xoá file. Kẹt: mục **Destroy
kẹt**, rồi `plan --destroy` lại (file plan cũ không áp lại được sau một apply dở) và `destroy`.

Destroy gỡ edge theo tham chiếu trong code: bản ghi DNS và delivery log, rồi ba distribution (provider tắt từng cái, chờ `Deployed`, rồi xoá:
mỗi cái vài phút tới ~15 phút, phần dài nhất của edge), rồi VPC origin (AWS từ chối xoá khi distribution còn dùng nó), rồi listener, ALB,
target group, security group, cert ACM. Sau VPC origin, CloudFront tự gỡ ENI của nó trong subnet edge và security group
`CloudFront-VPCOrigins-Service-SG` (ngoài state); chưa gỡ xong thì subnet edge hay VPC báo `DependencyViolation`: mục **Destroy kẹt**.

Apply đỏ trước khi tạo cluster EKS (chưa gì chạy trên cluster, root gitops chưa bao giờ apply): đọc mục **Finding bảo mật của buổi**
(VPC, NACL, RDS… đã tạo vẫn có control), bỏ bước 12–14, `aws/scripts/tf.sh stg env plan --destroy --no-cluster`. Script tự kiểm điều đó trước khi plan: thư mục buổi không có `cluster-values.json`
**và** `terraform state list` của `aws/envs/stg` (script tự chạy, profile `anhnv-stg`) không có `aws_eks_cluster`; không thì từ chối
(`FAIL --no-cluster refused: …`). State còn cluster: chạy bước 12 trong thư mục buổi hiện tại (không cần bước 6), bước 13, 14, rồi `plan
--destroy` không `--no-cluster`.

### 19–20. Quét sót

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

Edge thêm các loại: cert ACM tag `Project=svp` (region nhà và `us-east-1`), VPC origin CloudFront, security group
`CloudFront-VPCOrigins-Service-SG` trong VPC của lab (loại riêng: xoá tay chỉ khi không còn VPC origin), delivery, delivery source và delivery
destination của CloudWatch Logs (`us-east-1`), topic SNS `svp-*`; alarm, log group, topic SNS, KMS key và alias ở `us-east-1` (cái mang tag
`Stack=baseline` của baseline prd là `kept`). Distribution được nhận theo comment `svp-` hay origin `svp-*`; ALB, target group và web
ACL của edge theo bộ lọc ELBv2, WAF có sẵn.

Được giữ, in thành dòng riêng, không đếm: tài nguyên tag `Stack=baseline` ở account stg (bucket state, KMS key state, zone `stg.aws.<domain>`
với `NS`, `SOA`, `CAA` ở đỉnh) và ở account prd (thêm, ở `us-east-1`: key KMS DNSSEC, hai alarm DNSSEC, log group query log, topic
`svp-prd-dns-alarms` và key của nó)
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
| `DependencyViolation` khi xoá subnet, security group hay VPC | ENI còn gắn: ENI phụ của VPC CNI (`aws-K8S-<instance>`, `available` sau khi node mất), hay ENI của load balancer mà bước 12 chưa gỡ | `sweep.sh stg` liệt kê ENI theo VPC; ENI `available`: xoá ENI; ENI của load balancer: xoá load balancer (ENI tự mất), rồi destroy lại |
| `DependencyViolation` khi xoá subnet edge hay VPC, sau khi VPC origin đã xoá | ENI của CloudFront trong subnet edge hay security group `CloudFront-VPCOrigins-Service-SG` chưa được dịch vụ gỡ (ngoài state; tài liệu VPC origins không nói sau bao lâu) | đọc lại `sweep.sh stg` mỗi 5 phút tới khi không còn ENI trong subnet edge, rồi destroy lại; còn security group khi không còn VPC origin nào: xoá nó (lệnh ở **Lệnh xoá tay theo loại**); không xoá ENI của dịch vụ bằng tay |
| `CannotDeleteEntityWhileInUse` khi xoá VPC origin | distribution còn dùng nó (destroy dở ở distribution) | destroy lại sau khi distribution đã xoá (Terraform chờ tiếp) |
| ALB `svp-<env>-edge` báo deletion protection | prd: chưa áp `teardown.tfvars` (`edge_alb_deletion_protection = false`) | bước 15, 16, rồi destroy lại; state mất: tắt bằng tay (lệnh ở **Lệnh xoá tay theo loại**) |
| `ResourceInUseException` khi xoá cert ACM | distribution hay listener ALB còn dùng nó | destroy lại sau khi distribution, listener đã xoá |
| Destroy đỏ ở `aws_cloudfront_distribution`, hay `delete-distribution` bị từ chối, vì distribution còn gói flat-rate | gói không nằm trong state (destroy dở, state mất, gói tạo ở console) nên Terraform không huỷ nó trước; hay gói vừa huỷ còn đang đồng bộ (provider huỷ gói rồi trả về ngay, không chờ) | huỷ gói theo mục CloudFront của **Lệnh xoá tay theo loại**, chờ `list-subscriptions` không còn ARN đó, rồi destroy lại |
| Destroy chờ lâu hay quá hạn ở `aws_cloudfront_distribution` | Terraform phải tắt distribution và chờ `Deployed` (vài phút tới ~15 phút) trước khi xoá | destroy lại (Terraform chờ tiếp); vẫn kẹt thì tắt và xoá tay (lệnh dưới) |
| `BucketNotEmpty` | stg đặt `media_force_destroy = true` nên không nên gặp; object ghi giữa lúc destroy | destroy lại; còn thì xoá tay (lệnh dưới) |
| RDS báo deletion protection | `rds_deletion_protection` của `stg.tfvars` phải `false` (prd: `teardown.tfvars`) | sửa biến, `tf.sh stg env plan`, `apply`, rồi destroy lại |
| Node group `system` xoá lâu | node drain | chờ tới hạn bước 18 |
| `DependencyViolation` khi xoá subnet hay security group node, sau `--leftovers` | instance của Karpenter còn chạy (ENI của nó trong subnet private) | `sweep.sh stg` liệt kê nó với lệnh `terminate-instances`; chờ instance `terminated`, rồi destroy lại |
| `DeleteConflict` khi xoá role `svp-stg-karpenter-node` | instance profile do Karpenter tạo (ngoài state) còn giữ role | lệnh `delete:` của dòng `IAM instance profiles of Karpenter` trong `sweep.sh stg`, rồi destroy lại |
| `DependencyViolation` khi xoá subnet database hay security group của MSK, ElastiCache | ENI của broker MSK hay node ElastiCache còn trong subnet: cluster, replication group đang xoá (destroy quá hạn của provider trong khi AWS vẫn gỡ) | chờ `sweep.sh stg` không còn dòng `MSK clusters`, `ElastiCache replication groups` (đọc lại mỗi 5 phút), rồi destroy lại; không xoá ENI của dịch vụ managed bằng tay |
| Destroy đỏ ở `aws_msk_configuration` (`BadRequestException`, configuration đang được dùng) | cluster còn `DELETING` | như dòng trên: chờ cluster mất, destroy lại |
| Destroy root gitops kẹt ở namespace `Terminating` | Application còn finalizer mà Argo CD đã gỡ (sau `--leftovers`) | `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd patch applications.argoproj.io <tên> --type merge -p '{"metadata":{"finalizers":null}}'` từng cái còn lại, rồi destroy lại |

## Lệnh xoá tay theo loại

`sweep.sh` in lệnh xoá dưới từng tài nguyên sót. Mục này cho loại mà một lệnh không đủ, và cho thu hồi rule security group. Mọi lệnh ghi;
người học chạy sau khi `check-account.sh stg` đúng account, thay `<…>` bằng id `sweep.sh` in ra. Ưu tiên destroy lại cho thứ Terraform quản
(VPC, NAT, EIP, EKS, RDS, MSK, ElastiCache, bucket, gói, CloudFront, VPC origin, ALB, cert ACM, web ACL); lệnh tay cho thứ ngoài state
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

1. Thứ tự gỡ, mỗi bước xong mới sang bước sau: destroy root `aws/gitops/stg` rồi `aws/envs/stg` (bước 13–18); `sweep.sh stg`; `sweep.sh mgmt`.
   Hai lượt cùng exit 0 (dán output cho AI). AI nhắc tới khi người học xác nhận đã chạy cả hai destroy và hai lượt sweep. Phép kiểm (e) của
   ADR-0052 (output vào phụ lục của nó, kết luận vào "Xác nhận"): sau destroy, gói của account rỗng (mong `[]`), cùng lượt `sweep.sh stg` sạch:

   ```sh
   AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

   Phép kiểm (f) của ADR-0053 là cùng hai lượt sweep sạch: không còn dòng MSK, ElastiCache, `AmazonMSK_*` nào; KMS key của root env chỉ ở
   `pending deletion`. Phép kiểm `pre-destroy.sh` của ADR-0056: cùng lượt đó không còn instance, launch template, instance profile, hàng đợi
   SQS hay rule EventBridge nào của Karpenter.
2. Cái ở lại giữa các buổi: ở account stg là baseline (`Stack=baseline`: bucket state, KMS key state, zone `stg.aws.<domain>` với `CAA`) và
   baseline bảo mật (`Stack=security-baseline`: CMK EBS `alias/svp-ebs`; recorder Config, rule `svp-security-*` không phải tài nguyên `sweep.sh`
   liệt kê); ở account prd là hai baseline của nó, gồm zone `aws.<domain>` với `CAA`, bản ghi `NS` uỷ quyền `stg.aws.<domain>`, DNSSEC, query
   log và topic alarm DNSSEC (`sweep.sh` in chúng là `kept`); ở account Log Archive, bucket log CloudFront và delivery destination;
   management chỉ còn `Stack=bootstrap|org|security-baseline|security`, không hosted zone. `destroy` của hai root env không đụng zone
   nào (zone thuộc root `aws/accounts/<env>`) và không đụng baseline bảo mật (root `aws/baseline`).
3. Giữ `$SVP_SESSION_DIR` (máy local, không commit): `timeline.tsv`, `k6-levels.tsv`, `k6-<n>/` là số đo cho cột Kết quả của ADR-0034
   "Kiểm chứng sau" và roadmap; `controls-failed.tsv` là danh sách control FAILED của tài nguyên buổi, đầu vào của việc sửa trong Terraform.
4. Sau 24 giờ: Cost Explorer theo dịch vụ (account stg, hay management cho cả org), so với ước lượng (ADR-0034 §12 cộng MSK, ElastiCache
   của ADR-0053 §16, cộng phần của mục **Giới hạn**, ±50 %); số thật thay ước lượng ở mục đó.
