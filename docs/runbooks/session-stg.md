# Runbook: một buổi AWS stg

Một buổi dựng env stg trong account `svp-stg` (`aws/envs/stg`), cài Argo CD và root GitOps lên EKS bằng Terraform (`aws/gitops/stg`, mẫu
GitOps Bridge), đo (smoke, seed, k6 bậc 1, 2, 4, 8), rồi gỡ sạch trong cùng buổi và quét cả account stg lẫn account management. Thiết kế:
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §13 (tài nguyên ngoài state), §14 (buổi AWS);
[ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §1–§2 (account, state, zone), §5 (secret), §6 (bootstrap
EKS), §9 (kết thúc buổi). Buổi prd theo [`session-prd.md`](session-prd.md), dùng chung mọi mục chung của file này.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại và nhắc tới khi destroy hai root và hai lượt `sweep.sh` (stg, mgmt) đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`). Mỗi account một
profile và một biến account, script tự lấy theo env từ bảng `env_table` của `aws/scripts/lib.sh`:

| Env của script | Account | Profile | Biến account |
| --- | --- | --- | --- |
| `stg` | `svp-stg` | `anhnv-stg` | `SVP_AWS_STG_ACCOUNT_ID` |
| `prd` | `svp-prd` | `anhnv-prd` | `SVP_AWS_PRD_ACCOUNT_ID` |
| `mgmt` | management (account sandbox cũ) | `anhnv-sso` | `SVP_AWS_MGMT_ACCOUNT_ID` |

Profile và region `ap-southeast-1` (`us-east-1` cho WAF của CloudFront) ghi sẵn trong từng lệnh của script. Script in mỗi bước một dòng
`ok`, `FAIL` (dừng), `note` hay `skip`, không in giá trị bí mật nào.

Xem trước toàn bộ lệnh của buổi, theo đúng thứ tự, không chạy gì (an toàn, không cần credential):

```sh
aws/scripts/session.sh --print stg
```

## Giới hạn

- **Cả buổi 4 giờ**, từ `check-account.sh` (mốc `session-start`) tới hai lượt `sweep.sh` sạch. **Quá 3 giờ mà chưa đo xong thì bỏ phần đo
  còn lại, sang gỡ**: `measure.sh` tự bỏ bậc k6 nào sẽ kết thúc sau mốc 3 giờ (dòng `skip`).
- Chi phí ước tính ~$2,2–2,4 một buổi 4 giờ với node Spot, trần $5 (ADR-0034 §12). Quên destroy 24 giờ ≈ $9–12; budget `svp-stg-monthly` của
  account stg và budget tổng của org ở management gửi email ở 50 %, 80 %, 100 %.
- Chứng chỉ: buổi đo dùng ACME **production** của Let's Encrypt (`platforms/eks/svp-cluster.yaml` của `svp-gitops`): chứng chỉ staging
  không được `eks-smoke` lẫn pod k6 của `run.sh` tin. Giới hạn của Let's Encrypt (letsencrypt.org/docs/rate-limits, đọc 2026-10-31): 5
  chứng chỉ mỗi bộ tên y hệt mỗi 7 ngày (nạp lại 1 mỗi 34 giờ, không xin nâng được), 50 mỗi registered domain mỗi 7 ngày. Mỗi buổi xin hai
  bộ tên, nên tối đa ~5 buổi mỗi tuần với cùng `domain`. Staging chỉ khi muốn thử riêng issuer, trong một buổi không đo.

## Điều kiện trước buổi

1. **Account stg đã có baseline**: root `aws/org` đã tạo account `svp-stg` và gán permission set `SvpAdmin`; profile `anhnv-stg` đã tạo bằng
   `aws configure sso`; baseline `aws/accounts/stg` đã apply (bucket state, KMS key `alias/svp-tfstate`, zone `stg.aws.<domain>`, budget) và
   zone đó đã được uỷ quyền bằng `delegated_subdomains` của `aws/bootstrap` ([`aws/accounts/README.md`](../../aws/accounts/README.md)). Bước
   tay này một lần mỗi account, không nằm trong buổi; `check-dns.sh` đỏ thì quay lại README đó, không bắt đầu buổi.
   Account mới còn phải được AWS xác minh trước khi tạo tài nguyên CloudFront, và quota EC2 đủ cho node của env: chưa xác minh thì `apply` đỏ
   ở `aws_cloudfront_distribution` với `AccessDenied: Your account must be verified before you can add new CloudFront resources`, khi EKS, RDS
   đã chạy và tính tiền. Mở case AWS Support từ account stg (Account and billing, kèm dòng lỗi và RequestID nếu có) và chờ xác nhận trước
   buổi đầu.
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
3. Trên máy: Terraform 1.15 (`terraform version`), AWS CLI v2, `kubectl`, `jq`, `dig`, `nc`, `make`; `.env` của repo code đã có
   (`make -C ../backend env`; `tf.sh stg gitops plan` lấy chat Telegram `SVP_ALERT_TELEGRAM_CHAT_ID` từ đó, rỗng là chỉ commit status).
4. File backend của account stg, `aws/backend-stg.hcl` (git bỏ qua; chỉ bucket, region, KMS key, không `key`), ghi từ output của baseline:

   ```sh
   AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw backend_hcl > aws/backend-stg.hcl
   ```

5. `aws/envs/stg/stg.auto.tfvars` (git bỏ qua) sinh bằng khối lệnh dưới, chỉ đọc output của baseline; thay `<domain>`, `<email>`:

   ```sh
   zone=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
   ip=$(curl -s https://checkip.amazonaws.com)
   cat > aws/envs/stg/stg.auto.tfvars <<EOF
   hosted_zone_id          = "$zone"
   domain                  = "stg.aws.<domain>"
   acme_email              = "<email>"
   eks_public_access_cidrs = ["$ip/32"]
   EOF
   ```

   `domain` là tên zone của account stg (web ở đỉnh, API ở `api.<domain>`); precondition của root từ chối tên ngoài zone đó ngay lúc plan.
   Đổi mạng giữa buổi (IP khác) thì `kubectl` không vào được endpoint EKS: sửa `eks_public_access_cidrs`, rồi `aws/scripts/tf.sh stg env plan`,
   `aws/scripts/tf.sh stg env apply`.
6. Mac cắm sạc, tắt Low Power Mode (đo k6 và chờ dài).

## Mở terminal của buổi

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                                             # cho lượt sweep.sh mgmt cuối buổi
export SVP_AWS_STG_ACCOUNT_ID=<12 số của account svp-stg>                       # đọc trên trang SSO; không ghi vào file nào
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"               # số đo của buổi; .session/ git bỏ qua
```

Hai profile dùng chung một phiên SSO khi cùng `sso_session` trong `~/.aws/config`, khi đó một lần `aws sso login` là đủ. Biến account không
nằm trong file commit nào, kể cả `.envrc`; script đặt `TF_VAR_account_id` từ biến của env ngay trong lệnh `terraform`.

Mọi bước sau chạy trong **cùng terminal này** (cùng các biến). Thư mục buổi chứa: `timeline.tsv` (mốc UTC: `session-start`,
`env-apply-start`, `env-apply-end`, `secrets-written`, `gitops-apply-start`, `gitops-apply-end`, `observability-healthy`, `glitchtip-init`,
`svp-root-healthy`, `smoke-ok`, `seed-ok`, `k6-<n>-start`/`-end`, `pre-destroy-*`, `gitops-destroy-*`, `env-destroy-*`),
`cluster-values.json` (mode 600, có email ACME), `eks-secrets.log`, `svp-cluster-chart/`, các file text của plan, `k6-levels.tsv`, `k6-<n>/`.

**Mở lại terminal giữa buổi** (terminal đóng, máy khởi động lại): đặt lại các biến, với `SVP_SESSION_DIR` là **thư mục của buổi đang dở**,
không phải thư mục mới. `measure.sh` đọc `cluster-values.json` của nó và tính mốc 3 giờ từ `session-start` của nó; `tf.sh` đọc các mốc gỡ
(`pre-destroy-done`, `gitops-destroy-end`) trong `timeline.tsv` của nó.

```sh
cd infra
AWS_PROFILE=anhnv-stg aws sso login --region us-east-1
export SVP_AWS_STG_ACCOUNT_ID=<12 số> SVP_AWS_MGMT_ACCOUNT_ID=<12 số>
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
| 5 | `aws/scripts/tf.sh stg env apply` | 35 phút | dòng `Apply complete! …` và hai dòng `mark` |
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
| 18 | `aws/scripts/tf.sh stg env destroy` | 30 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` |
| 19 | `aws/scripts/sweep.sh stg` | 5 phút | toàn bộ output |
| 20 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output |

Dự trù: apply root env xong ~T+40 phút, mọi Application Healthy ~T+1 giờ 25, đo tới muộn nhất T+3 giờ, gỡ và quét xong trước T+4 giờ.
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

Đọc name server của zone `stg.aws.<domain>` từ output `name_servers` của `aws/accounts/stg` (không gọi API AWS nào khác), hỏi `NS
stg.aws.<domain>` ở `1.1.1.1` và `8.8.8.8`. Tìm: `ok hosted zone …`, rồi `ok resolver 1.1.1.1 …`, `ok resolver 8.8.8.8 …`. `FAIL … returns no
NS` hay `returns NS … not the hosted zone's`: uỷ quyền chưa lan hay sai (DNS-01 của Let's Encrypt và ExternalDNS sẽ hỏng): sửa
`delegated_subdomains` của `aws/bootstrap` theo `aws/accounts/README.md`, **không bắt đầu buổi**.

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
`destroy` hay `change` là state còn tài nguyên của buổi trước (destroy dở): dừng, dán plan cho AI. `apply` chỉ nhận file plan đó (không plan
lại tại chỗ), rồi xoá nó. Thời gian: EKS ~10–15 phút, RDS ~10 phút, CloudFront ~5 phút, song song. Root này cũng tạo vỏ các entry
`svp/stg/*` của Secrets Manager (chưa có giá trị). `apply` đỏ giữa chừng: đọc lỗi, `plan` lại, `apply` lại; muốn bỏ buổi thì sang bước 12
(`pre-destroy.sh` tự ghi context `svp-stg` và đọc `hosted_zone_id` từ `stg.auto.tfvars`, nên chạy được cả khi apply đỏ sau khi cluster EKS đã
có), hay bước 17 với `--no-cluster` khi apply đỏ trước khi tạo cluster EKS (điều kiện ở bước 17).

### 6. Giá trị secret

```sh
aws/scripts/bootstrap.sh stg secrets
```

Theo thứ tự: kiểm account; repo code ở `main` = `origin/main`, sạch; `aws eks update-kubeconfig --alias svp-stg`; ghi `cluster-values.json`;
đọc **mật khẩu** master của RDS (trường `password` của secret mà RDS giữ, username luôn `postgres`) vào môi trường của đúng lệnh `make`
(không ra file, không in), rồi `make -C ../backend eks-secrets CONTEXT=svp-stg` với `AWS_PROFILE=anhnv-stg`: ghi mọi entry `svp/stg/*` từ
`.env` (mỗi entry một `put-secret-value --secret-string file://…`, giá trị không qua đối số hay output); `glitchtip-runtime` ba key rỗng chỉ
khi chưa có giá trị. Nguồn của mọi Secret trên EKS có trước Argo CD. Tìm: `ok entries svp/stg/* written` và mốc `secrets-written`. Đỏ: dán
~30 dòng cuối của `$SVP_SESSION_DIR/eks-secrets.log` (script nêu tên biến thiếu, không in giá trị).

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
GlitchTip vào entry `glitchtip-runtime`, force-sync ba ExternalSecret, restart service cần DSN), rồi chờ `svp-root` Synced và Healthy (Argo CD
báo Healthy khi mọi Application nó tạo Healthy). Mỗi lần chờ tối đa 30 phút. Tìm: `ok every Application Synced and Healthy on svp-stg` và
mốc `svp-root-healthy`. Đỏ: dán dòng `FAIL` (có trạng thái sync, health) và

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io
```

sửa xong chạy lại (chạy lại được). Muốn bỏ buổi ở đây: sang bước 12; `pre-destroy.sh` chạy được cả khi Argo CD chưa được cài.

### 11. Đo

```sh
aws/scripts/measure.sh stg
```

1. `make eks-smoke CONTEXT=svp-stg DOMAIN=<domain>`: luồng đầu-cuối qua `https://api.<domain>` (chứng chỉ công khai).
2. `make eks-seed`: ≥ 30 video `READY` trong `GET /feed/explore` (k6 profile `cloud` đọc chúng).
3. k6 (`deploy/k6/cloud/run.sh` của repo code) bậc **1, 2, 4, 8 pod**, mỗi pod một phần tải của thiết kế 20 pod, lên 2 phút, giữ 10 phút;
   **trước mỗi bậc `make eks-rl-reset CONTEXT=svp-stg`** (pod bậc sau có thể nhận lại IP của pod bậc trước, burst đăng ký theo IP sẽ cạn;
   **LOCAL LAB ONLY**: xoá khoá `svp:gw:rl:register:*` ở Valkey db 10 của cluster). Bậc đầu tiên trượt (threshold, iteration bị bỏ, 429,
   pod thiếu summary) kết thúc thang đo. Mỗi bậc ghi `k6-<n>/`: `nodes.tsv` (số node Ready theo thời gian), `top-nodes.tsv`,
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

### 12. Gỡ trong cluster trước destroy

```sh
aws/scripts/pre-destroy.sh stg
```

Gỡ những gì Kubernetes tạo trong account mà Terraform không biết, **khi controller tạo ra chúng còn chạy**, mỗi lần chờ có hạn. Chỉ cần
apply đã tạo cluster: script tự chạy `aws eks update-kubeconfig --name svp-stg --alias svp-stg` và đọc id zone của account từ `hosted_zone_id`
của `aws/envs/stg/stg.auto.tfvars` (giá trị mà output `cluster_values` đưa cho cluster), không đọc file nào của bước 6, nên chạy được cả khi
bước 6 chưa chạy hay từ thư mục buổi mới. `FAIL kubeconfig context …` là account không có cluster `svp-stg`: sang bước 17 với
`--no-cluster`.

1. ApplicationSet `svp-bootstrap` (nó dựng lại `svp-root`), `svp-root` và `svp-apps` (auto-sync prune + self-heal, không finalizer): xoá
   finalizer và `automated` của hai Application, rồi xoá riêng ba cái (child ở yên); tắt auto-sync của mọi Application còn lại (để
   `svp-cluster` không dựng lại Gateway).
2. Application workload theo sync wave từ cao xuống (finalizer của mỗi cái xoá thứ nó triển khai), trừ `svp-cluster` và controller nền
   tảng; rồi Gateway `svp-edge/svp`. Chờ hết Service `LoadBalancer`, TargetGroupBinding, NLB và target group của `svp-stg` trong ELBv2, bản
   ghi của ExternalDNS trong zone `stg.aws.<domain>`, trong khi LBC, ExternalDNS, Envoy Gateway còn chạy.
3. Mọi PVC ở mọi namespace (sinh từ `volumeClaimTemplates`, Argo CD không prune) khi EBS CSI còn chạy và namespace, StorageClass `gp3` của
   `svp-cluster` còn đó; chờ hết PVC, PV của `ebs.csi.aws.com`, volume EBS do driver tạo.
4. `svp-cluster` và Application nền tảng, theo wave; quá hạn chỉ ghi `note` (không gì của chúng tính tiền ngoài cluster).

Cluster chưa có Argo CD (root gitops chưa apply hay dừng trước Argo CD, dòng `note no Argo CD on svp-stg`): không có Application nào để xoá,
bước 1, 4 và phần Application của bước 2 bỏ qua; các phép chờ của bước 2 và 3 (Service `LoadBalancer`, ELBv2, bản ghi DNS, PVC, volume EBS)
vẫn chạy, rồi ghi mốc `pre-destroy-done` như thường.

Tìm: mỗi bước `ok`, cuối cùng `ok ready for: aws/scripts/tf.sh stg gitops plan --destroy` và mốc `pre-destroy-done` (thiếu mốc này thì
`tf.sh stg gitops plan --destroy` từ chối). Script ghi mốc `pre-destroy-start` ngay sau khi kiểm account, trước mọi bước khác. `FAIL` nêu thứ
còn lại và lệnh xem; sửa rồi chạy lại script (mỗi bước tìm thứ còn lại). **Hết giờ của buổi mà bước 2 hay 3 vẫn đỏ sau khi đã chạy lại**
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

Hết giờ của buổi mà bước 12 vẫn đỏ ở bước 2 hay 3 của nó sau khi đã chạy lại: lối thoát có kiểm, để cluster không tính tiền tiếp.

```sh
aws/scripts/tf.sh stg gitops plan --destroy --leftovers
```

Chỉ nhận khi `timeline.tsv` của buổi có mốc `pre-destroy-start` (bước 12 đã chạy trong thư mục buổi này) mà chưa có `pre-destroy-done`;
thiếu `pre-destroy-start` thì từ chối và bảo chạy bước 12 trước, đã có `pre-destroy-done` thì từ chối (không cần cờ này). Dòng `note
--leftovers: …` nhắc thứ Kubernetes tạo có thể còn (Load Balancer và target group, bản ghi DNS của ExternalDNS, volume EBS của PVC), rồi ghi
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

Apply đỏ trước khi tạo cluster EKS (chưa gì chạy trên cluster, root gitops chưa bao giờ apply): bỏ bước 12–14,
`aws/scripts/tf.sh stg env plan --destroy --no-cluster`. Script tự kiểm điều đó trước khi plan: thư mục buổi không có `cluster-values.json`
**và** `terraform state list` của `aws/envs/stg` (script tự chạy, profile `anhnv-stg`) không có `aws_eks_cluster`; không thì từ chối
(`FAIL --no-cluster refused: …`). State còn cluster: chạy bước 12 trong thư mục buổi hiện tại (không cần bước 6), bước 13, 14, rồi `plan
--destroy` không `--no-cluster`.

### 19–20. Quét sót

```sh
aws/scripts/sweep.sh stg
aws/scripts/sweep.sh mgmt
```

Chỉ đọc, chạy được cả khi state mất hay destroy dở; mỗi lượt với profile của account đó. Liệt kê mọi tài nguyên tag `Project=svp` hay tag
Kubernetes đặt (`kubernetes.io/cluster/svp-*`, `elbv2.k8s.aws/cluster`, `ebs.csi.aws.com/cluster`, `cluster.k8s.amazonaws.com/name`) hay mang
tên `svp-*`: EKS, EC2, EBS và snapshot, VPC, NAT, EIP, ENI, security group, ELBv2 và target group, RDS (instance, snapshot, backup tự động giữ
lại), S3, CloudFront (distribution, OAC, response headers policy), web ACL WAF của CloudFront (`us-east-1`), log group (cả log group EKS, RDS tự
tạo ngoài state), Secrets Manager (cả secret đang chờ xoá), KMS key, bản ghi của zone của account ngoài NS/SOA ở đỉnh.

Được giữ, in thành dòng riêng, không đếm: tài nguyên tag `Stack=baseline` ở account stg (bucket state, KMS key state, zone `stg.aws.<domain>`)
và `Stack=bootstrap|org` ở management (bucket state, zone lab cùng bản ghi `NS` uỷ quyền zone của stg, prd, bucket và KMS key của trail) là
`kept`; KMS key ở trạng thái `PendingDeletion` (key của root env sau destroy, tối thiểu 7 ngày) là `pending deletion`. Tìm: `ok nothing left
in account … but what it keeps` (exit 0) ở **cả hai lượt**. Có dòng `FAIL <loại>: N left`: dưới mỗi tài nguyên sót là dòng `delete:` với lệnh
xoá đủ profile và region (hay trỏ mục dưới khi một lệnh không đủ); chạy, rồi chạy lại lượt đó tới khi sạch. **Buổi chỉ xong khi hai lượt cùng
exit 0.**

## Destroy kẹt

"Destroy lại" ở bảng dưới là `aws/scripts/tf.sh stg env plan --destroy` (plan mới từ state hiện tại), đọc file text, rồi
`aws/scripts/tf.sh stg env destroy`; với root gitops cũng vậy, thay `env` bằng `gitops` (thêm `--leftovers` nếu lần trước đã dùng nó).

| Triệu chứng | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `DependencyViolation` khi xoá subnet, security group hay VPC | ENI còn gắn: ENI phụ của VPC CNI (`aws-K8S-<instance>`, `available` sau khi node mất) hay ENI của NLB (`ELB net/k8s-…`) mà bước 12 chưa gỡ | `sweep.sh stg` liệt kê ENI theo VPC; ENI `available`: xoá ENI; ENI của NLB: xoá NLB (ENI tự mất), rồi destroy lại |
| Security group `k8s-…` của LBC không xoá được | security group node còn rule tham chiếu nó (LBC thêm rule cho NLB) | thu hồi các rule tham chiếu (lệnh dưới), xoá security group, destroy lại |
| Destroy chờ lâu hay quá hạn ở `aws_cloudfront_distribution` | Terraform phải tắt distribution và chờ `Deployed` (vài phút tới ~15 phút) trước khi xoá | destroy lại (Terraform chờ tiếp); vẫn kẹt thì tắt và xoá tay (lệnh dưới) |
| `BucketNotEmpty` | stg đặt `media_force_destroy = true` nên không nên gặp; object ghi giữa lúc destroy | destroy lại; còn thì xoá tay (lệnh dưới) |
| RDS báo deletion protection | `rds_deletion_protection` của `stg.tfvars` phải `false` (prd: `teardown.tfvars`) | sửa biến, `tf.sh stg env plan`, `apply`, rồi destroy lại |
| Node group xoá lâu | Spot, node drain | chờ tới hạn bước 18 |
| Destroy root gitops kẹt ở namespace `Terminating` | Application còn finalizer mà Argo CD đã gỡ (sau `--leftovers`) | `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd patch applications.argoproj.io <tên> --type merge -p '{"metadata":{"finalizers":null}}'` từng cái còn lại, rồi destroy lại |

## Lệnh xoá tay theo loại

`sweep.sh` in lệnh xoá dưới từng tài nguyên sót. Mục này cho loại mà một lệnh không đủ, và cho thu hồi rule security group. Mọi lệnh ghi;
người học chạy sau khi `check-account.sh stg` đúng account, thay `<…>` bằng id `sweep.sh` in ra. Ưu tiên destroy lại cho thứ Terraform quản
(VPC, NAT, EIP, EKS, RDS, bucket, CloudFront); lệnh tay cho thứ ngoài state hay khi state mất. Tài nguyên sót ở management (lượt `sweep.sh
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

CloudFront: tắt, chờ `Deployed`, rồi xoá (OAC và response headers policy xoá sau distribution, cũng bằng `ETag`):

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

Bản ghi sót của zone `stg.aws.<domain>` (A, TXT của ExternalDNS; TXT `_acme-challenge` khi DNS-01 lỗi): không tính tiền nhưng chặn việc xoá zone
sau này và có thể trỏ tên tới IP người khác nhận lại. Dựng lô xoá từ chính bản ghi, đọc lại, rồi gửi:

```sh
zone=stg.aws.<domain>; zone_id=$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -raw zone_id)
AWS_PROFILE=anhnv-stg aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --region ap-southeast-1 --output json |
  jq --arg apex "$zone." '{Changes: [.ResourceRecordSets[] | select((.Name == $apex and (.Type == "NS" or .Type == "SOA")) | not)
    | {Action: "DELETE", ResourceRecordSet: .}]}' > /tmp/svp-records.json
jq -r '.Changes[].ResourceRecordSet | "\(.Name) \(.Type)"' /tmp/svp-records.json      # chỉ bản ghi sót, không NS/SOA ở đỉnh
AWS_PROFILE=anhnv-stg aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch file:///tmp/svp-records.json --region ap-southeast-1
```

Ở zone lab (lượt `mgmt`): cùng khối với `AWS_PROFILE=anhnv-sso`, `zone=aws.<domain>`, `zone_id` từ output `zone_id` của `aws/bootstrap`, và
thêm điều kiện bỏ bản ghi `NS` của `stg.aws.<domain>.`, `prd.aws.<domain>.` vào `select` (chúng là uỷ quyền của baseline, phải giữ).

**Secret Secrets Manager đang chờ xoá** (dòng `scheduled for deletion since …`): vẫn giữ tên tới hết thời gian chờ (7–30 ngày), nên
**chặn tạo lại secret cùng tên** ở buổi sau (entry `svp/stg/*` do Terraform tạo với `recovery_window_in_days = 0` nên xoá ngay; dòng này là
secret tạo cách khác). Secret master của RDS mang tên sinh ngẫu nhiên (`rds!db-<uuid>`), không chặn buổi sau, nhưng `sweep.sh` vẫn đếm nó tới
khi mất. Lệnh `delete:` của `sweep.sh` xoá hẳn ngay (không khôi phục được); muốn lấy lại để dùng tiếp:

```sh
AWS_PROFILE=anhnv-stg aws secretsmanager restore-secret --secret-id <name> --region ap-southeast-1
```

## Đổi một secret của env đang chạy

Sửa `.env` của repo code, rồi theo đúng thứ tự (cùng thứ tự với `make k8s-secrets` trên k3d):

1. Một lệnh làm bốn việc đầu: mật khẩu admin Kafka mới vào broker đang chạy trước, ghi lại mọi entry `svp/stg/*` (trừ `glitchtip-runtime`,
   đã có giá trị), force-sync mọi ExternalSecret, rồi chỉ khi mật khẩu admin Kafka đổi thì rolling restart StatefulSet `redpanda` (từng
   broker một, chờ Ready rồi sang broker sau): broker và sidecar đọc mật khẩu đó từ environment lúc khởi động, giữ mật khẩu cũ thì probe
   nhận 401, broker NotReady và sync ở bước 2 không chạy được hook PostSync. Script đọc lại mật khẩu master RDS và chạy `make eks-secrets`
   như bước 6:

   ```sh
   aws/scripts/bootstrap.sh stg secrets
   ```

   Tìm `ok statefulset/redpanda restarted one broker at a time` (mật khẩu admin Kafka đổi) hay `skip  restart of Redpanda's brokers` (không
   đổi) trong `$SVP_SESSION_DIR/eks-secrets.log`.

2. Sync Application `svp-data` (Job init đặt mật khẩu mới trong Postgres, Kafka) và chờ đúng lượt sync đó xong, gồm hook PostSync
   `pg-bootstrap`, `redpanda-init`: restart trước khi Job đặt mật khẩu mới thì pod mới đăng nhập bằng mật khẩu hệ thống chưa có:

   ```sh
   before=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io svp-data -o jsonpath='{.status.operationState.startedAt}')
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd patch applications.argoproj.io svp-data --type merge -p '{"operation":{"sync":{}}}'
   until s=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io svp-data \
       -o jsonpath='{.status.operationState.startedAt} {.status.operationState.phase}') &&
     [ "${s% *}" != "$before" ] && case "${s#* }" in Succeeded) true ;; Failed | Error) echo "STOP sync $s"; true ;; *) false ;; esac
   do sleep 5; done; echo "sync: $s"
   ```

   Dòng cuối phải là `sync: <thời điểm mới> Succeeded`. In `STOP` thì không sang bước 3: xem Job lỗi
   (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data get jobs`), sửa rồi chạy lại bước 2.

3. Restart workload có Secret đổi: Deployment bằng `rollout restart`; Rollout `gateway`, `web` bằng `spec.restartAt` (không tạo revision,
   nên không thành canary):

   ```sh
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n <namespace> rollout restart deployment/<tên>
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp patch rollout <tên> --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
   ```

Đổi thứ tự (Secret đổi trước hệ thống dùng nó) làm service mất đăng nhập tới khi bước 2, 3 chạy. Chi tiết: `docs/reference/eks.md` của repo
code, mục "Đổi secret của env đang chạy".

## Kết thúc buổi

1. Thứ tự gỡ, mỗi bước xong mới sang bước sau: destroy root `aws/gitops/stg` rồi `aws/envs/stg` (bước 13–18); `sweep.sh stg`; `sweep.sh mgmt`.
   Hai lượt cùng exit 0 (dán output cho AI). AI nhắc tới khi người học xác nhận đã chạy cả hai destroy và hai lượt sweep.
2. Giữ `$SVP_SESSION_DIR` (máy local, không commit): `timeline.tsv`, `k6-levels.tsv`, `k6-<n>/` là số đo cho cột Kết quả của ADR-0034
   "Kiểm chứng sau" và roadmap.
3. Sau 24 giờ: Cost Explorer theo dịch vụ (account stg, hay management cho cả org), so với ước lượng (ADR-0034 §12, ±50 %).
