# Runbook: một buổi AWS stg

Một buổi dựng env stg trên AWS (`aws/envs/stg`), cài GitOps lên EKS, đo (smoke, seed, k6 bậc 1, 2, 4, 8), rồi gỡ sạch trong cùng buổi.
Thiết kế: [ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §13 (tài nguyên ngoài
state), §14 (buổi AWS).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại và nhắc tới khi `tf.sh stg destroy` và `sweep.sh` đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`), profile `anhnv-sso` và region
`ap-southeast-1` ghi sẵn trong từng lệnh của script. Script in mỗi bước một dòng `ok`, `FAIL` (dừng), `note` hay `skip`, không in giá trị
bí mật nào.

Xem trước toàn bộ lệnh của buổi, theo đúng thứ tự, không chạy gì (an toàn, không cần credential):

```sh
aws/scripts/session.sh --print stg
```

## Giới hạn

- **Cả buổi 4 giờ**, từ `check-account.sh` (mốc `session-start`) tới `sweep.sh` sạch. **Quá 3 giờ mà chưa đo xong thì bỏ phần đo còn
  lại, sang gỡ**: `measure.sh` tự bỏ bậc k6 nào sẽ kết thúc sau mốc 3 giờ (dòng `skip`).
- Chi phí ước tính ~$2,2–2,4 một buổi 4 giờ với node Spot, trần $5 (ADR-0034 §12). Quên destroy 24 giờ ≈ $9–12; budget `svp-monthly`
  gửi email ở 50 %, 80 %, 100 %.
- Chứng chỉ: buổi đo dùng ACME **production** của Let's Encrypt (`platforms/eks/svp-cluster.yaml` của `svp-gitops`): chứng chỉ staging
  không được `eks-smoke` lẫn pod k6 của `run.sh` tin. Giới hạn của Let's Encrypt (letsencrypt.org/docs/rate-limits, đọc 2026-10-31): 5
  chứng chỉ mỗi bộ tên y hệt mỗi 7 ngày (nạp lại 1 mỗi 34 giờ, không xin nâng được), 50 mỗi registered domain mỗi 7 ngày. Mỗi buổi xin hai
  bộ tên, nên tối đa ~5 buổi mỗi tuần với cùng `domain`. Staging chỉ khi muốn thử riêng issuer, trong một buổi không đo.

## Điều kiện trước buổi

1. Hosted zone `aws.<domain>` của `aws/bootstrap` đã uỷ quyền và lan truyền ([`aws/bootstrap/README.md`](../../aws/bootstrap/README.md),
   bước 5). Bước tay này một lần mỗi account, không nằm trong buổi; `check-dns.sh` đỏ thì quay lại README đó, không bắt đầu buổi.
2. Code đã merge: repo code ở `main` có mốc 1 (lối vào S3 `container`, Postgres ngoài, edge EKS, render theo nền tảng, target `eks-*`);
   `svp-gitops` ở `main` có lớp `platforms/eks`; repo này có `aws/envs/stg` và script buổi. Kiểm:

   ```sh
   git -C ../backend switch main && git -C ../backend pull --ff-only
   make -C ../backend help | grep -c '^  eks-'      # 6
   git -C ../gitops fetch origin                    # gitops.sh đọc refs/remotes/origin/main như lần fetch cuối
   git -C ../gitops log -1 --format='%H %s' origin/main
   ```

   `bootstrap-argocd.sh` tự kiểm lại: repo code ở `main`, sạch, bằng `origin/main`; nó fetch `svp-gitops` và lấy `GITOPS_REV` là SHA đủ 40
   hex của `origin/main` vừa fetch (cluster ở yên commit đó suốt buổi).
3. Trên máy: Terraform 1.15 (`terraform version`), AWS CLI v2, `kubectl`, `helm`, `jq`, `dig`, `make`; `.env` của repo code đã có
   (`make -C ../backend env`); `aws/backend.hcl` (từ output `backend_hcl` của `aws/bootstrap`); `aws/envs/stg/stg.auto.tfvars` (git bỏ qua) sinh bằng khối lệnh dưới, chỉ đọc output của bootstrap; thay `<domain>`, `<email>`:

   ```sh
   zone=$(AWS_PROFILE=anhnv-sso terraform -chdir=aws/bootstrap output -raw zone_id)
   ip=$(curl -s https://checkip.amazonaws.com)
   cat > aws/envs/stg/stg.auto.tfvars <<EOF
   hosted_zone_id          = "$zone"
   domain                  = "stg.aws.<domain>"
   acme_email              = "<email>"
   eks_public_access_cidrs = ["$ip/32"]
   EOF
   ```

   Đổi mạng giữa buổi (IP khác) thì `kubectl` không vào được endpoint EKS: sửa `eks_public_access_cidrs`, rồi `aws/scripts/tf.sh stg plan`,
   `aws/scripts/tf.sh stg apply`.
4. Mac cắm sạc, tắt Low Power Mode (đo k6 và chờ dài).

## Mở terminal của buổi

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login
export SVP_AWS_ACCOUNT_ID="$TF_VAR_account_id"                                # direnv nạp biến này khi cd infra, nếu .envrc có nó
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"             # số đo của buổi; .session/ git bỏ qua
```

Không có `TF_VAR_account_id` trong `.envrc` thì gõ 12 số của account sandbox (đọc trên trang SSO) thay cho dòng `SVP_AWS_ACCOUNT_ID`:
`export SVP_AWS_ACCOUNT_ID=<12 số>`; không ghi vào file nào.

Mọi bước sau chạy trong **cùng terminal này** (cùng hai biến). Thư mục buổi chứa: `timeline.tsv` (mốc UTC: `session-start`,
`apply-start`, `apply-end`, `argocd-healthy`, `smoke-ok`, `seed-ok`, `k6-<n>-start`/`-end`, `pre-destroy-*`, `destroy-start`,
`destroy-end`), `cluster-values.json` (mode 600, có email ACME), `eks-gitops-up.log`, `k6-levels.tsv`, `k6-<n>/`.

**Mở lại terminal giữa buổi** (terminal đóng, máy khởi động lại): đặt lại hai biến, với `SVP_SESSION_DIR` là **thư mục của buổi đang
dở**, không phải thư mục mới. `measure.sh` đọc `cluster-values.json` của nó và tính mốc 3 giờ từ `session-start` của nó, `tf.sh stg
destroy` đòi mốc `pre-destroy-done` trong `timeline.tsv` của nó.

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login
export SVP_AWS_ACCOUNT_ID="$TF_VAR_account_id"                                 # hay gõ 12 số của account sandbox nếu .envrc không có biến này
ls -1d .session/*/ | tail -n 3                                                 # thư mục mới nhất là buổi đang dở
export SVP_SESSION_DIR="$PWD/.session/<thư mục đó>"
tail -n 5 "$SVP_SESSION_DIR/timeline.tsv"                                      # mốc cuối: bước nào đã xong
```

Rồi chạy tiếp từ bước sau mốc cuối (hay chạy lại bước đang dở).

## Thứ tự

| # | Lệnh | Hạn | Dán lại cho AI |
| --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh` | 2 phút | dòng `ok account …` (account, ARN) |
| 2 | `aws/scripts/check-dns.sh` | 2 phút | ba dòng `ok` hay dòng `FAIL` |
| 3 | `aws/scripts/tf.sh stg init` | 5 phút | dòng cuối |
| 4 | `aws/scripts/tf.sh stg plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan |
| 5 | `aws/scripts/tf.sh stg apply` | 35 phút | dòng `Apply complete! …` và hai dòng `mark` |
| 6 | `aws/scripts/bootstrap-argocd.sh stg` | 45 phút | ~20 dòng cuối |
| 7 | `aws/scripts/measure.sh stg` | tới mốc 3 giờ | `k6-levels.tsv`, dòng `ok highest level …` |
| 8 | `aws/scripts/pre-destroy.sh stg` | 30 phút | mọi dòng `ok`/`FAIL`/`note` |
| 9 | `aws/scripts/tf.sh stg destroy` | 30 phút | dòng `Destroy complete! …` |
| 10 | `aws/scripts/sweep.sh` | 5 phút | toàn bộ output |

Dự trù: apply xong ~T+40 phút, mọi Application Healthy ~T+1 giờ 25, đo tới muộn nhất T+3 giờ, gỡ và quét xong trước T+4 giờ. Một bước đỏ:
đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được). Không đi tiếp qua một bước đỏ, trừ bước 7 (đo): đo
hỏng thì vẫn sang bước 8.

### 1. Kiểm account

```sh
aws/scripts/check-account.sh
```

Tìm: `ok    account <12 số>, arn:aws:sts::<12 số>:assumed-role/…` với đúng account sandbox và role SSO của người học. `FAIL … not
SVP_AWS_ACCOUNT_ID` là profile trỏ account khác: dừng, không chạy gì nữa. Mọi script chạm account (trừ `check-dns.sh`) tự kiểm lại điều này
trước lệnh đầu tiên của nó, nên `tf.sh` không bao giờ chạy trên account khác.

### 2. Kiểm DNS

```sh
aws/scripts/check-dns.sh
```

Đọc name server của zone từ output `name_servers` của `aws/bootstrap` (không gọi API AWS nào khác), hỏi `NS aws.<domain>` ở `1.1.1.1` và
`8.8.8.8`. Tìm: `ok hosted zone …`, rồi `ok resolver 1.1.1.1 …`, `ok resolver 8.8.8.8 …`. `FAIL … returns no NS` hay `returns NS … not the
hosted zone's`: uỷ quyền chưa lan hay sai (DNS-01 của Let's Encrypt và ExternalDNS sẽ hỏng): sửa theo `aws/bootstrap/README.md` bước 5,
**không bắt đầu buổi**.

### 3–5. Terraform: init, plan lưu file, đọc, apply file đó

```sh
aws/scripts/tf.sh stg init
aws/scripts/tf.sh stg plan
aws/scripts/tf.sh stg apply
```

`plan` ghi `aws/envs/stg/stg.tfplan` (nhị phân, git bỏ qua) và ngay sau đó bản text của nó vào `$SVP_SESSION_DIR/stg-plan.txt` (thư mục buổi, git
bỏ qua: plan có tên miền và IP thật nên không vào cây repo); `ok` cuối của `plan` nêu đường dẫn file text. Ghi lại bản text từ plan hiện có:
`aws/scripts/tf.sh stg show`. **Đọc file text đó trước khi apply**: lần đầu mỗi buổi chỉ `to add`, `0 to change, 0 to
destroy`; có `destroy` hay `change` là state còn tài nguyên của buổi trước (destroy dở): dừng, dán plan cho AI. `apply` chỉ nhận file plan
đó (không plan lại tại chỗ), rồi xoá nó. Thời gian: EKS ~10–15 phút, RDS ~10 phút, CloudFront ~5 phút, song song. `apply` đỏ giữa chừng:
đọc lỗi, `plan` lại, `apply` lại; muốn bỏ buổi thì sang bước 8 (không cần bước 6: `pre-destroy.sh` tự ghi context `svp-stg` và đọc
`hosted_zone_id` từ `stg.auto.tfvars`, nên chạy được cả khi apply đỏ sau khi cluster EKS đã có, lúc output `cluster_values` chưa được
lưu), hay bước 9 với `--no-cluster` khi apply đỏ trước khi tạo cluster EKS (điều kiện ở bước 9).

### 6. Cài GitOps lên EKS

```sh
aws/scripts/bootstrap-argocd.sh stg
```

Theo thứ tự: kiểm hai bản clone (repo code ở `main` = `origin/main`, sạch; `svp-gitops` fetch, `GITOPS_REV` = SHA của `origin/main`),
`aws eks update-kubeconfig --alias svp-stg`, ghi `cluster-values.json`, đọc **mật khẩu** master của RDS (trường `password` của secret mà
RDS giữ, username luôn `postgres`) vào môi trường của đúng lệnh `make` (không ra file, không in), rồi `make -C ../backend eks-gitops-up
CONTEXT=svp-stg CLUSTER_VALUES=<file> GITOPS_REV=<sha>`: kiểm bảy bản phát hành của `envs/stg/images/`, tạo namespace và Secret nguồn, cài
Argo CD, root `svp-root` ghim SHA, chờ mọi Application Synced và Healthy, khởi tạo GlitchTip. Script không cài Argo CD bằng `helm` của
chính nó. Tìm: `ok every Application Synced and Healthy on svp-stg at svp-gitops <sha>` và mốc `argocd-healthy`. Đỏ: dán ~40 dòng cuối của
`$SVP_SESSION_DIR/eks-gitops-up.log` (lỗi của `gitops.sh` in trạng thái từng Application chưa Healthy); sửa xong chạy lại (lệnh chạy lại
được trên cùng cluster). Muốn bỏ buổi ở đây (ví dụ kiểm bản phát hành đỏ vì attestation quá 48 giờ): sang bước 8; `pre-destroy.sh` chạy
được cả khi Argo CD chưa được cài.

### 7. Đo

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
không phải `fail`, Job để nguyên; `AWS_PROFILE=anhnv-sso aws sso login` rồi `measure.sh stg --from <n>`, script xoá Job đó trước khi
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

Trong lúc giữ tải, đọc phía server ở Grafana (`AWS_PROFILE=anhnv-sso kubectl --context svp-stg -n svp-obs port-forward --address 127.0.0.1
service/kps-grafana 3000:80`, đăng nhập `admin` + `SVP_GRAFANA_ADMIN_PASSWORD` của `.env`, dashboard SLO): p95/p99 của gateway theo route. Các phép kiểm chỉ chứng minh được trên AWS ở mục "Kiểm chứng sau" của ADR-0034:
làm trong lúc chờ bậc k6, ghi kết quả từng phép kiểm (đạt hay không, output chính) vào một file trong `$SVP_SESSION_DIR`, để sau buổi
điền cột Kết quả của bảng đó. Dán lại: `cat $SVP_SESSION_DIR/k6-levels.tsv`, dòng `ok highest level …`, và với
mỗi bậc `jq -c . $SVP_SESSION_DIR/k6-<n>/summaries/pod-*.json | head`.

### 8. Gỡ trong cluster trước destroy

```sh
aws/scripts/pre-destroy.sh stg
```

Gỡ những gì Kubernetes tạo trong account mà Terraform không biết, **khi controller tạo ra chúng còn chạy**, mỗi lần chờ có hạn. Chỉ cần
apply đã tạo cluster: script tự chạy `aws eks update-kubeconfig --name svp-stg --alias svp-stg` và đọc id zone lab từ `hosted_zone_id`
của `aws/envs/stg/stg.auto.tfvars` (giá trị mà output `cluster_values` đưa cho cluster), không đọc file nào của bước 6, nên chạy được cả
khi bước 6 chưa chạy hay từ thư mục buổi mới. `FAIL aws eks update-kubeconfig …` là account không có cluster `svp-stg`: sang bước 9 với
`--no-cluster`.

1. Root `svp-root` (auto-sync prune + self-heal, không finalizer): xoá finalizer và `automated`, rồi xoá riêng nó (child ở yên); tắt
   auto-sync của mọi Application còn lại (để `svp-cluster` không dựng lại Gateway).
2. Application workload theo sync wave từ cao xuống (finalizer của mỗi cái xoá thứ nó triển khai), trừ `svp-cluster` và controller nền
   tảng; rồi Gateway `svp-edge/svp`. Chờ hết Service `LoadBalancer`, TargetGroupBinding, NLB và target group của `svp-stg` trong ELBv2, bản
   ghi của ExternalDNS trong zone lab, trong khi LBC, ExternalDNS, Envoy Gateway còn chạy.
3. Mọi PVC ở mọi namespace (sinh từ `volumeClaimTemplates`, Argo CD không prune) khi EBS CSI còn chạy và namespace, StorageClass `gp3` của
   `svp-cluster` còn đó; chờ hết PVC, PV của `ebs.csi.aws.com`, volume EBS do driver tạo.
4. `svp-cluster` và Application nền tảng, theo wave; quá hạn chỉ ghi `note` (không gì của chúng tính tiền ngoài cluster).

Cluster chưa có Argo CD (`make eks-gitops-up` dừng trước khi cài nó, dòng `note no Argo CD on svp-stg`): không có Application nào để xoá,
bước 1, 4 và phần Application của bước 2 bỏ qua; các phép chờ của bước 2 và 3 (Service `LoadBalancer`, ELBv2, bản ghi DNS, PVC, volume
EBS) vẫn chạy, rồi ghi mốc `pre-destroy-done` như thường.

Tìm: mỗi bước `ok`, cuối cùng `ok ready for: aws/scripts/tf.sh stg destroy` và mốc `pre-destroy-done` (thiếu mốc này thì `tf.sh stg destroy`
từ chối). `FAIL` nêu thứ còn lại và lệnh xem; sửa rồi chạy lại script (mỗi bước tìm thứ còn lại). Hết giờ mà bước 2 hay 3 vẫn đỏ: vẫn sang
bước 9, rồi xoá tay phần `sweep.sh` liệt kê.

### 9. Destroy

```sh
aws/scripts/tf.sh stg destroy
```

Gõ `yes` khi Terraform hỏi (đọc trước: chỉ tài nguyên của `aws/envs/stg`). Kẹt: mục **Destroy kẹt** dưới đây, rồi chạy lại lệnh này.
Apply đỏ trước khi tạo cluster EKS (chưa gì chạy trên cluster): bỏ bước 8, `aws/scripts/tf.sh stg destroy --no-cluster`. Script tự kiểm
điều đó trước khi destroy: thư mục buổi không có `cluster-values.json` **và** `AWS_PROFILE=anhnv-sso terraform -chdir=aws/envs/stg state
list` (script tự chạy) không có `aws_eks_cluster`; không thì từ chối (`FAIL --no-cluster refused: …`). State còn cluster (apply đỏ sau
khi cluster đã có, hay terminal mở lại với thư mục buổi mới): chạy bước 8 trong thư mục buổi hiện tại (không cần bước 6), rồi lệnh ở đầu
mục này, không `--no-cluster`.

### 10. Quét sót

```sh
aws/scripts/sweep.sh
```

Chỉ đọc, chạy được cả khi state mất hay destroy dở: liệt kê mọi tài nguyên tag `Project=svp` hay tag Kubernetes đặt
(`kubernetes.io/cluster/svp-*`, `elbv2.k8s.aws/cluster`, `ebs.csi.aws.com/cluster`, `cluster.k8s.amazonaws.com/name`) hay mang tên `svp-*`:
EKS, EC2, EBS và snapshot, VPC, NAT, EIP, ENI, security group, ELBv2 và target group, RDS (instance, snapshot, backup tự động giữ lại), S3,
CloudFront (distribution, OAC, response headers policy), log group, Secrets Manager (cả secret đang chờ xoá), KMS, bản ghi của zone lab
ngoài NS/SOA ở đỉnh. Tài nguyên của `aws/bootstrap` (bucket state, hosted zone) in thành dòng `kept`. Tìm: `ok nothing left but
aws/bootstrap` (exit 0). Có dòng `FAIL <loại>: N left`: xoá tay bằng lệnh ở mục dưới, rồi chạy lại tới khi sạch. **Buổi chỉ xong khi
`sweep.sh` exit 0.**

## Destroy kẹt

| Triệu chứng | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `DependencyViolation` khi xoá subnet, security group hay VPC | ENI còn gắn: ENI phụ của VPC CNI (`aws-K8S-<instance>`, `available` sau khi node mất) hay ENI của NLB (`ELB net/k8s-…`) mà bước 8 chưa gỡ | `sweep.sh` liệt kê ENI theo VPC; ENI `available`: xoá ENI; ENI của NLB: xoá NLB (ENI tự mất), rồi destroy lại |
| Security group `k8s-…` của LBC không xoá được | security group node còn rule tham chiếu nó (LBC thêm rule cho NLB) | thu hồi các rule tham chiếu (lệnh dưới), xoá security group, destroy lại |
| Destroy chờ lâu hay quá hạn ở `aws_cloudfront_distribution` | Terraform phải tắt distribution và chờ `Deployed` (vài phút tới ~15 phút) trước khi xoá | chạy lại destroy (Terraform chờ tiếp); vẫn kẹt thì tắt và xoá tay (lệnh dưới) |
| `BucketNotEmpty` | stg đặt `media_force_destroy = true` nên không nên gặp; object ghi giữa lúc destroy | destroy lại; còn thì `aws s3 rb --force` (lệnh dưới) |
| RDS báo deletion protection | `rds_deletion_protection` của `stg.tfvars` phải `false` | sửa biến, `tf.sh stg plan`, `apply`, rồi destroy |
| Node group xoá lâu | Spot, node drain | chờ tới hạn bước 9 |

## Lệnh xoá tay theo loại

Mọi lệnh ghi; người học chạy sau khi `check-account.sh` đúng account, thay `<…>` bằng id `sweep.sh` in ra. Ưu tiên chạy lại
`tf.sh stg destroy` cho thứ Terraform quản (VPC, NAT, EIP, EKS, RDS, bucket, CloudFront); lệnh tay cho thứ ngoài state hay khi state mất.

```sh
# Volume, snapshot EBS
AWS_PROFILE=anhnv-sso aws ec2 delete-volume --volume-id <vol-…> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws ec2 delete-snapshot --snapshot-id <snap-…> --region ap-southeast-1
# ENI available
AWS_PROFILE=anhnv-sso aws ec2 delete-network-interface --network-interface-id <eni-…> --region ap-southeast-1
# Security group: rule nơi khác tham chiếu nó, thu hồi từng rule, rồi xoá
AWS_PROFILE=anhnv-sso aws ec2 describe-security-group-rules --region ap-southeast-1 --output text \
  --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='<sg-…>'].[GroupId,SecurityGroupRuleId,IsEgress]"
AWS_PROFILE=anhnv-sso aws ec2 revoke-security-group-ingress --group-id <GroupId> --security-group-rule-ids <sgr-…> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws ec2 delete-security-group --group-id <sg-…> --region ap-southeast-1
# NLB, target group
AWS_PROFILE=anhnv-sso aws elbv2 delete-load-balancer --load-balancer-arn <arn> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws elbv2 delete-target-group --target-group-arn <arn> --region ap-southeast-1
# NAT, EIP (khi state mất)
AWS_PROFILE=anhnv-sso aws ec2 delete-nat-gateway --nat-gateway-id <nat-…> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws ec2 release-address --allocation-id <eipalloc-…> --region ap-southeast-1
# RDS (khi state mất), snapshot, backup tự động giữ lại
AWS_PROFILE=anhnv-sso aws rds delete-db-instance --db-instance-identifier <svp-stg-…> --skip-final-snapshot --delete-automated-backups --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws rds delete-db-snapshot --db-snapshot-identifier <id> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws rds delete-db-instance-automated-backup --db-instance-automated-backups-arn <arn> --region ap-southeast-1
# Bucket (khi state mất): xoá mọi object rồi bucket
AWS_PROFILE=anhnv-sso aws s3 rb s3://<svp-stg-…> --force --region ap-southeast-1
# Log group, KMS key
AWS_PROFILE=anhnv-sso aws logs delete-log-group --log-group-name <name> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws kms schedule-key-deletion --key-id <key-id> --pending-window-in-days 7 --region ap-southeast-1
```

CloudFront: tắt, chờ `Deployed`, rồi xoá (OAC và response headers policy xoá sau distribution, cũng bằng `ETag`):

```sh
AWS_PROFILE=anhnv-sso aws cloudfront get-distribution-config --id <E…> --region ap-southeast-1 --output json > /tmp/svp-cf.json
jq '.DistributionConfig | .Enabled = false' /tmp/svp-cf.json > /tmp/svp-cf-off.json
AWS_PROFILE=anhnv-sso aws cloudfront update-distribution --id <E…> --if-match "$(jq -r .ETag /tmp/svp-cf.json)" \
  --distribution-config file:///tmp/svp-cf-off.json --region ap-southeast-1 >/dev/null
AWS_PROFILE=anhnv-sso aws cloudfront wait distribution-deployed --id <E…> --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws cloudfront delete-distribution --id <E…> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-sso aws cloudfront get-distribution --id <E…> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-sso aws cloudfront delete-origin-access-control --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-sso aws cloudfront get-origin-access-control --id <id> --query ETag --output text --region ap-southeast-1)"
AWS_PROFILE=anhnv-sso aws cloudfront delete-response-headers-policy --id <id> --region ap-southeast-1 \
  --if-match "$(AWS_PROFILE=anhnv-sso aws cloudfront get-response-headers-policy --id <id> --query ETag --output text --region ap-southeast-1)"
```

Bản ghi sót của zone lab (A, TXT của ExternalDNS; TXT `_acme-challenge` khi DNS-01 lỗi): không tính tiền nhưng chặn việc xoá zone sau
này và có thể trỏ tên tới IP người khác nhận lại. Dựng lô xoá từ chính bản ghi, đọc lại, rồi gửi:

```sh
zone=aws.<domain>; zone_id=<Z… của output zone_id của aws/bootstrap>
AWS_PROFILE=anhnv-sso aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --region ap-southeast-1 --output json |
  jq --arg apex "$zone." '{Changes: [.ResourceRecordSets[] | select((.Name == $apex and (.Type == "NS" or .Type == "SOA")) | not)
    | {Action: "DELETE", ResourceRecordSet: .}]}' > /tmp/svp-records.json
jq -r '.Changes[].ResourceRecordSet | "\(.Name) \(.Type)"' /tmp/svp-records.json      # chỉ bản ghi sót, không NS/SOA ở đỉnh
AWS_PROFILE=anhnv-sso aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch file:///tmp/svp-records.json --region ap-southeast-1
```

**Secret Secrets Manager đang chờ xoá** (dòng `scheduled for deletion since …`): vẫn giữ tên tới hết thời gian chờ (7–30 ngày), nên
**chặn tạo lại secret cùng tên** ở buổi sau. Secret master của RDS mang tên sinh ngẫu nhiên (`rds!db-<uuid>`), không chặn buổi sau, nhưng
`sweep.sh` vẫn đếm nó tới khi mất. Xử lý một trong hai:

```sh
# Xoá hẳn ngay, không chờ (không khôi phục được)
AWS_PROFILE=anhnv-sso aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery --region ap-southeast-1
# Hay lấy lại để dùng tiếp (rồi xoá bằng Terraform hay lệnh trên)
AWS_PROFILE=anhnv-sso aws secretsmanager restore-secret --secret-id <name> --region ap-southeast-1
```

## Kết thúc buổi

1. `sweep.sh` exit 0 (dán output cho AI). AI nhắc tới khi người học xác nhận đã chạy cả `tf.sh stg destroy` và `sweep.sh`.
2. Giữ `$SVP_SESSION_DIR` (máy local, không commit): `timeline.tsv`, `k6-levels.tsv`, `k6-<n>/` là số đo cho cột Kết quả của ADR-0034
   "Kiểm chứng sau" và roadmap.
3. Sau 24 giờ: Cost Explorer theo dịch vụ, so với ước lượng (ADR-0034 §12, ±50 %).
