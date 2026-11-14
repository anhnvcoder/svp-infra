# Runbook: một buổi AWS prd

Một buổi dựng env prd trong account `svp-prd` (`aws/envs/prd`, mức production: NAT mỗi AZ, RDS Multi-AZ, MSK ba broker trên ba AZ,
ElastiCache primary và replica Multi-AZ, nhóm node hệ thống và node Karpenter on-demand trải ba AZ, bảo vệ xoá), cài Argo CD và root GitOps
qua tunnel SSM (`aws/gitops/prd`), chạy đúng commit `svp-gitops` mà stg đã chạy, đo (thời gian dựng, failover RDS Multi-AZ, drain một AZ,
khởi động lại một broker MSK khi đang ghi, failover Valkey, alarm), diễn tập khôi phục (backup on-demand và copy sang account `svp-backup`,
PITR của RDS, một object S3 từ AWS Backup), rồi gỡ sạch trong cùng buổi. Các diễn tập là chỗ kiểm bù của nhóm "giảm
có điều kiện" ở stg ([ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) §4). Thiết kế:
[ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) (§4 truy cập API, §6 bootstrap EKS, §7 ghim revision,
§8 promote, §9 kết thúc buổi, §10 chi phí), [ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md)
(Kafka là Amazon MSK, Valkey là ElastiCache; prd mất một AZ không mất event đã xác nhận), [ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md) (zone của mỗi env),
[ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md) (web ACL WAF; gói flat-rate
Free chỉ ở media của stg),
[ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md) (Karpenter, Envoy và Kyverno HA, trải zone),
[ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md) (PostgreSQL 17, `verify-full`, không proxy kết nối),
[ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) (CloudWatch alarm tới email),
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) (edge: CloudFront, VPC origin, ALB
internal, WAF, cert ACM, log CloudFront, DNS), [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md)
(image từ ECR của account prd, chỉ vào qua `promote-prd`),
[ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) (telemetry vào dịch vụ managed sống qua
destroy), [ADR-0064](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0064-interface-endpoints.md) (endpoint interface ở mọi AZ của
prd), [ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md) (transcode bằng AWS Elemental
MediaConvert, giống hệt stg), [ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) (backup và DR, giống
stg trừ retention, vault lock và OU của Backup policy).

Buổi prd đi đúng chuỗi script của buổi stg; khác biệt là dữ liệu (dòng `prd` của `env_table` trong `aws/scripts/lib.sh`: profile `anhnv-prd`,
biến `SVP_AWS_PRD_ACCOUNT_ID`, tunnel cổng 6443, file `teardown.tfvars`, không thang k6) và các bước tay ở đây. Mọi mục chung (luật chạy lệnh,
thư mục buổi, mở lại terminal, ý nghĩa từng bước script, xác nhận email của alarm, tunnel tới API, phép kiểm nền tảng, **Destroy kẹt**, **Lệnh
xoá tay theo loại**, đổi secret) ở
[`session-stg.md`](session-stg.md): đọc trước, thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`. File này chỉ ghi phần riêng của prd.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster, kể cả lệnh chỉ đọc; AI đọc output dán lại và nhắc tới khi
bốn bước gỡ của mục **Kết thúc buổi** đều xong.

```sh
aws/scripts/session.sh --print prd                 # mọi lệnh script của buổi, theo thứ tự, không chạy gì
```

## Chi phí và giới hạn

- **Trần một buổi C ≈ $11,0** = 4 giờ × (H₀ $0,90 + H_k $1,09)/giờ + O₀ $2,8 + O_k $0,22 (ADR-0053 §16 và bảng ở phụ lục của nó; H_k là
  3 broker `kafka.m7g.large` cộng 2 node `cache.m7g.large` cộng phần nhỏ; H₀, O₀ ở phụ lục ADR-0048), cộng node Karpenter on-demand ngoài
  nhóm hệ thống, KMS key và CloudWatch alarm (ADR-0056, ADR-0058), cộng phần edge (ALB, ba web ACL, log; bảng "Thêm mỗi buổi" ở phụ lục
  ADR-0061 §13), cộng phần nền tảng managed (endpoint interface ở mọi AZ, mẫu AMP, log, span, Inspector mỗi digest bên thứ ba mới, AMG ở buổi
  đầu tháng: bảng tổng ở
  [ADR-0063 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md#12-chi-phí-hợp-đồng-cluster-và-adr-cũ)
  và phụ lục của nó); buổi prd đầu đo số thật ở Cost Explorer. **Phí giữ R ≈ $4,6/tháng** giữa các buổi (trail, KMS, bucket state của
  management; bucket state, KMS key, zone của hai baseline), cộng phần edge lúc không buổi (key DNSSEC, topic và alarm DNSSEC, query log: bảng
  "Lúc không buổi" ở phụ lục ADR-0061 §13) và phần registry, observability lúc không buổi (key KMS, secret của cache, lưu trữ ECR, AMG: cùng
  bảng của ADR-0063 §12), báo riêng, không cộng vào C. Phần transcode (job MediaConvert của buổi, endpoint `mediaconvert` ở mọi AZ, SQS, request
  S3; $0 lúc không buổi) ở
  [ADR-0066 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí) và mục "Chi phí" của
  phụ lục, cộng vào C. Phần backup mỗi buổi (instance `svp-prd-pitr` của diễn tập theo lớp của nguồn, key `uploads`, hai alarm backup, request và
  restore S3) cộng vào C; bản copy ở `svp-backup` và ba key của vault sống giữa các buổi, báo riêng như R: cả hai ở
  [ADR-0067 §13](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#13-chi-phí) và mục "Chi phí" của phụ lục.
- **Cả buổi 4 giờ**, từ cổng promote tới hai lượt `sweep.sh` sạch. Quá 3 giờ mà chưa đo xong thì bỏ phần đo còn lại, sang gỡ. Quên gỡ 24
  giờ ≈ $48 (24 × (H₀ + H_k)); budget `svp-prd-monthly` và budget tổng của org gửi email ở 50 %, 80 %, 100 %.
- Ba distribution của prd (web, api, media) và ba web ACL là pay-as-you-go, có access log; prd không đăng ký gói flat-rate nào. Web ACL sót
  tính phí theo giờ, nên `sweep.sh` bắt nó.
- MSK và ElastiCache dựng, gỡ lâu như stg (`session-stg.md`, mục "Giới hạn"; số giả định của ADR-0053 §16, số đo của buổi stg thay nó khi
  đã có).

## Điều kiện trước buổi

1. Root `aws/org` đã apply (account `svp-prd`, SCP, permission set `SvpAdmin` gán vào account đó); profile `anhnv-prd` đã tạo bằng
   `aws configure sso`; baseline `aws/accounts/prd` đã apply và zone gốc `aws.<domain>` của nó đã được uỷ quyền bằng bốn bản ghi `NS` `aws` ở DNS cha của domain
   ([`aws/accounts/README.md`](../../aws/accounts/README.md), mục 5); zone `stg.aws.<domain>` là zone con của nó, uỷ quyền bằng
   `delegated_subdomains` của chính root `aws/accounts/prd`.
2. Buổi stg ở account `svp-stg` đã chạy xong theo [`session-stg.md`](session-stg.md), và mọi PR của code, `svp-gitops`, repo này đã merge.
3. **Bằng chứng stg**: commit `svp-gitops` sẽ promote (`stg_ref`) có commit status `argocd/stg` trạng thái `success` (Argo CD Notifications
   của stg ghi khi sync xong commit đó). Job `promote-prd` từ chối commit không có nó. `stg_ref` là commit ghi ở `stg-ref.txt` của thư mục buổi
   stg (`session-stg.md` bước 14) mà buổi đó đã qua mục [Phép kiểm transcode](session-stg.md#phép-kiểm-transcode): prd chạy đúng `platforms/`
   có bridge MediaConvert mà stg đã kiểm. Promote theo mục "Promote" của
   [README `svp-gitops`](https://github.com/anhnvcoder/svp-gitops/blob/main/README.md#promote), làm ở **Cổng promote prd** dưới. Kiểm:

   ```sh
   gh api "repos/anhnvcoder/svp-gitops/commits/<stg_ref>/statuses" --jq '.[] | select(.context == "argocd/stg") | "\(.state) \(.created_at)"' | head -n 1
   ```

4. Account prd: AWS đã xác minh cho CloudFront (case Support mở từ account prd, như `session-stg.md` điều kiện 1) và quota EC2 on-demand đủ
   cho mọi node của prd, cả node Karpenter (NodePool prd on-demand): đọc quota vCPU on-demand chuẩn (`L-1216C47A`):

   ```sh
   AWS_PROFILE=anhnv-prd aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-southeast-1 \
     --query 'Quota.Value'
   ```

   Cần ≥ 14 vCPU cộng `limits.cpu` của NodePool prd (`envs/prd/svp-cluster.yaml` của `svp-gitops`, số ở ADR-0056 §2): nhóm node hệ thống tới
   `system_node_max_size` 6 node `m7g.large` × 2 vCPU, bastion `t4g.nano` 2 vCPU
   ([trang loại instance của AWS](https://aws.amazon.com/ec2/instance-types/)); thiếu thì xin tăng và chờ trước buổi.
5. Trên máy, ngoài các công cụ của stg: `gh` đã đăng nhập.
6. `aws/backend-prd.hcl` và `aws/envs/prd/prd.auto.tfvars` như điều kiện 4, 5 của stg (profile `anhnv-prd`, root `aws/accounts/prd`,
   `domain = "aws.<domain>"`: tên zone prd, web ở đỉnh, API ở `api.aws.<domain>`; `alarm_email` là hộp thư nhận alarm). Root env đọc id
   workspace AMG `svp-prd` từ tham số SSM `/svp/prd/grafana-workspace-id` của `aws/accounts/prd`; file có sẵn còn dòng
   `grafana_workspace_id` thì xoá như điều kiện 5 của stg:

   ```sh
   AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw backend_hcl > aws/backend-prd.hcl
   zone=$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw zone_id)
   cat > aws/envs/prd/prd.auto.tfvars <<EOF
   hosted_zone_id = "$zone"
   domain         = "aws.<domain>"
   alarm_email    = "<email>"
   EOF
   ```

7. **Không gói CloudFront nào**: prd không đăng ký gói flat-rate, nên một gói còn ở account là sót (của buổi trước hay của console), giữ
   distribution của nó. Mỗi buổi, trước bước 3 (chỉ đọc):

   ```sh
   AWS_PROFILE=anhnv-prd aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

   Mong `[]`; dán lại. Còn gói: huỷ theo `session-stg.md`, mục **Lệnh xoá tay theo loại** (CloudFront), với `AWS_PROFILE=anhnv-prd`.
8. **Nền bảo mật của org đã áp** tới ít nhất bước (3) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu), và biến
   `SVP_AWS_LOG_ACCOUNT_ID` đặt trong terminal của buổi: như `session-stg.md` điều kiện 6 (root env prd ghi flow log, log WAF vào bucket
   của `svp-log-archive`).
9. **Edge đã áp lần đầu** theo [`edge-setup.md`](edge-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (3), như `session-stg.md` điều kiện 7 (destination
   `svp-cloudfront-prd`, `CAA`, zone `aws.<domain>` ký và có `DS` ở DNS cha); file có sẵn từ trước còn dòng `acme_email` thì xoá như
   `session-stg.md` điều kiện 5.
10. **Nền tảng managed đã áp** theo [`platform-setup.md`](platform-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (9) cho account prd, như
    `session-stg.md` điều kiện 8: registry, cache có credential, AMP, log group `/svp/prd/otel`, AMG, quota chu kỳ luật 15 s; role
    `svp-ci-ecr-promote` có, nên `promote-prd` của cổng dưới chép được image vào ECR prd.
11. **Backup đã áp** theo [`backup-setup.md`](backup-setup.md#thứ-tự-áp-lần-đầu), như `session-stg.md` điều kiện 10, với Backup policy
    `svp-backup-prd` gắn OU `Prod`, vault `svp-prd-copy`, vault `svp-prd` cùng role `svp-prd-backup` và opt-in của `aws/accounts/prd`.

## Mở terminal của buổi

Như `session-stg.md` với profile và biến của prd:

```sh
cd infra
AWS_PROFILE=anhnv-prd aws sso login --region us-east-1
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                                             # cho lượt sweep.sh mgmt cuối buổi
export SVP_AWS_PRD_ACCOUNT_ID=<12 số của account svp-prd> SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_AWS_LOG_ACCOUNT_ID=<12 số của account svp-log-archive> SVP_AWS_BACKUP_ACCOUNT_ID=<12 số của account svp-backup>
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"
```

## Thứ tự

Các bước script, theo đúng thứ tự `session.sh --print prd`; bước tay của prd chen giữa, ở các mục dưới (cổng promote trước bước 1, email
của alarm và tunnel sau bước 8, làm nóng cache sau bước 9, CORS của media, phép kiểm edge, phép kiểm nền tảng, phép kiểm nền tảng managed,
commit status, phép kiểm transcode và diễn tập của mục **Đo** sau bước 14, đọc bản copy sau bước 15, ghi truy vấn dữ liệu và finding bảo mật
trước bước 18, đọc recovery point sau bước 23, final snapshot sau bước 25, chạy lại truy vấn dữ liệu sau bước 29):

| # | Lệnh | Hạn | Dán lại cho AI |
| --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh prd` | 2 phút | dòng `ok account …` (account, ARN) |
| 2 | `aws/scripts/check-dns.sh prd` | 2 phút | ba dòng `ok` hay dòng `FAIL` |
| 3 | `aws/scripts/tf.sh prd account init` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` |
| 4 | `aws/scripts/tf.sh prd account plan --open` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` |
| 5 | `aws/scripts/tf.sh prd account apply` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` |
| 6 | `aws/scripts/tf.sh prd env init` | 5 phút | dòng cuối |
| 7 | `aws/scripts/tf.sh prd env plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan |
| 8 | `aws/scripts/tf.sh prd env apply` | 70 phút | dòng `Apply complete! …`, hai dòng `mark` và hai dòng `Creation complete after …` của cluster MSK, replication group ElastiCache |
| 9 | `aws/scripts/bootstrap.sh prd secrets` | 5 phút | mọi dòng `ok`/`FAIL` |
| 10 | `aws/scripts/tf.sh prd gitops init` | 2 phút | dòng cuối |
| 11 | `aws/scripts/tf.sh prd gitops plan` | 5 phút | dòng `ok chart svp-cluster at …`, dòng `Plan: …` |
| 12 | `aws/scripts/tf.sh prd gitops apply` | 15 phút | dòng `Apply complete! …`, output `bootstrap_revision` |
| 13 | `aws/scripts/bootstrap.sh prd wait` | 45 phút | mọi dòng `ok`/`FAIL` |
| 14 | `aws/scripts/measure.sh prd` | 10 phút | dòng `ok smoke passed …` |
| 15 | `aws/scripts/restore-drill.sh prd backup` | 60 phút | mọi dòng `ok`/`FAIL`, dòng `PASS backup …` |
| 16 | `aws/scripts/restore-drill.sh prd rds` | 75 phút | mọi dòng `ok`/`FAIL`, dòng `PASS rds …` hay `FAIL rds …` |
| 17 | `aws/scripts/restore-drill.sh prd s3` | 30 phút | mọi dòng `ok`/`FAIL`, dòng `PASS s3 …` hay `FAIL s3 …` |
| 18 | `aws/scripts/pre-destroy.sh prd` | 30 phút | mọi dòng `ok`/`FAIL`/`note` |
| 19 | `aws/scripts/tf.sh prd gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` |
| 20 | `aws/scripts/tf.sh prd gitops destroy` | 10 phút | dòng `Apply complete! …` |
| 21 | `aws/scripts/tf.sh prd env plan --teardown` | 5 phút | dòng `note … targets …`, dòng `Plan: 0 to add, N to change, 0 to destroy` và đường dẫn file text (hay dòng `skip`) |
| 22 | `aws/scripts/tf.sh prd env apply --teardown` | 10 phút | dòng `Apply complete! …`, mốc `env-teardown-applied` (hay dòng `skip`) |
| 23 | `aws/scripts/restore-drill.sh prd cleanup` | 30 phút | mọi dòng `ok`/`FAIL`/`skip`, mốc `backup-drained` |
| 24 | `aws/scripts/tf.sh prd env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan |
| 25 | `aws/scripts/tf.sh prd env destroy` | 60 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster MSK, replication group ElastiCache |
| 26 | `aws/scripts/tf.sh prd account plan --close` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` |
| 27 | `aws/scripts/tf.sh prd account apply` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` |
| 28 | `aws/scripts/sweep.sh prd` | 5 phút | toàn bộ output |
| 29 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output |

## Cổng promote prd (trước mọi lệnh tốn tiền)

prd chỉ chạy commit `svp-gitops` stg đã chạy: khoá `gitopsRevision` của `envs/prd/charts.yaml` phải có giá trị trước bước 11 (plan của root
gitops dừng khi khoá vắng, `require_pinned_revision = true`). Làm cổng này **trước bước 1**, khi chưa tài nguyên nào tính tiền:

1. Dispatch job `promote-prd` của repo code với `stg_ref` là commit có bằng chứng stg (điều kiện 3):

   ```sh
   gh workflow run images.yml -R anhnvcoder/svp-backend --ref main -f promote_prd=true -f stg_ref=<stg_ref 40 hex>
   gh run list -R anhnvcoder/svp-backend --workflow images.yml --limit 1
   ```

2. Duyệt environment `promote-prd` của lượt chạy đó (trang của run trên GitHub, "Review deployments"). Job mở PR ở `svp-gitops` (nhánh
   `bot/promote-prd`) đặt `gitopsRevision = <stg_ref>` cùng image và chart của commit đó.
3. Code Owner duyệt PR đó, check của `svp-gitops` xanh, merge.
4. Kiểm hai khoá trên `main` (dán lại hai dòng in ra): `revision` là commit của repo code (chart), `gitopsRevision` là commit `svp-gitops`
   (`stg_ref`):

   ```sh
   git -C ../gitops fetch origin && git -C ../gitops show origin/main:envs/prd/charts.yaml | grep -E '^(revision|gitopsRevision):'
   ```

Job từ chối (`stg_ref` không có `argocd/stg` `success`, hay không trên `main`), environment hay PR bị từ chối: **dừng buổi**, không chạy bước 1.
Job `promote-prd` chép và kiểm mọi image của `envs/stg/images/` vào ECR prd trước khi mở PR; một image lỗi thì không có PR: đọc log của job,
dán dòng lỗi (`vuln` quá hạn thì dòng đó nêu lệnh rescan).

**Chart có nền tảng managed** (sau bước 4, vẫn trước bước 1): `revision` vừa kiểm phải là commit của repo code có Collector theo nền tảng và
value `canaryPrometheus`. Values eks của `svp-gitops` chỉ đúng với chart đó; chart cũ chạy với chúng thì Prometheus thành agent mà canary cũ vẫn
hỏi nó (Inconclusive), Collector cũ gửi tới Prometheus, Loki, Tempo không còn trên eks (mất metric, log, trace), không luật trên AMP, không
dashboard ở AMG, image kéo thẳng upstream, Kyverno và External Secrets bị NetworkPolicy chặn tới endpoint interface (Secret không tạo được).
Mong hai dòng `ok`; thiếu thì **không dựng prd**: promote lại từ một `stg_ref` mà buổi stg đã chạy với chart mới.

```sh
rev=$(git -C ../gitops show origin/main:envs/prd/charts.yaml | sed -n 's/^revision: *//p')
git -C ../backend fetch origin
git -C ../backend cat-file -e "$rev:deploy/observability/otelcol/k8s-eks.yaml" && echo ok
git -C ../backend show "$rev:deploy/helm/svp-service/values.yaml" | grep -q '^canaryPrometheus:' && echo ok
```

**Bản ghim có transcode MediaConvert** (sau bước 4, vẫn trước bước 1): ở `gitopsRevision` (`G`), release `media-worker` của nền tảng eks chạy
lệnh con `mediaconvert`, nhận ba biến của queue, role, hàng đợi từ hợp đồng cluster và được ra TCP 443 trong VPC (endpoint interface); ở
`revision` (`R`), schema của chart `svp-service` nhận value `args` và Deployment đưa nó vào container chính. Thiếu một điều: prd sẽ chạy
`media-worker serve` (ffmpeg) hay pod không khởi động, **không dựng prd**; promote lại từ `stg_ref` của một buổi stg đã qua phép kiểm transcode.
Chỉ đọc bản clone, không đổi nhánh:

```sh
G=$(git -C ../gitops show origin/main:envs/prd/charts.yaml | sed -n 's/^gitopsRevision: *//p')
R=$(git -C ../gitops show origin/main:envs/prd/charts.yaml | sed -n 's/^revision: *//p')
git -C ../gitops show "$G:platforms/eks/media-worker.yaml" | grep -x 'args: \[mediaconvert\]'
git -C ../gitops show "$G:platforms/eks/media-worker.values.tpl" |
  grep -c -E '^ +(MEDIACONVERT_QUEUE_ARN|MEDIACONVERT_ROLE_ARN|TRANSCODE_EVENTS_QUEUE_URL):|cidr: .*vpcCidr.*ports: \[443\]'
git -C ../gitops show "$G:argocd/apps/templates/applications.yaml" | grep -c -E 'mediaconvertQueueArn|mediaconvertRoleArn|transcodeEventsQueueUrl'
git -C ../backend show "$R:deploy/helm/svp-service/values.schema.json" | jq -e '.properties.args.type == "array"'
git -C ../backend show "$R:deploy/helm/svp-service/templates/deployment.yaml" | grep -c 'with .Values.args'
```

Mong `args: [mediaconvert]`, `4` (ba biến và mục egress), `3` (ba khoá của hợp đồng cluster được kiểm dạng), `true`, `1`; dán lại cả
năm dòng. Khác: dán cho AI trước bước 1.

## Bước 1–8: account, DNS, root account, root env

Như `session-stg.md` bước 1–8, với `prd`. `check-account.sh prd` phải in account `svp-prd`. Bước 3–5 in `ok no session feature of prd in
aws/paid-features.json: …` và không chạy gì: prd không có cờ `session`, AMG `svp-prd` và tham số SSM của nó sống giữa các buổi
(mục [Cờ chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi) của stg). `check-dns.sh prd` hỏi `NS aws.<domain>` (tên là
`zone_name` của `aws/accounts/prd/prd.auto.tfvars`) ở `1.1.1.1` và `8.8.8.8` và so với output `name_servers` của `aws/accounts/prd`; `FAIL`
thì bốn bản ghi `NS` `aws` ở DNS cha chưa lan hay sai: sửa theo `aws/accounts/README.md` (mục 5), không bắt đầu buổi. Zone stg nằm dưới zone
prd nên `check-dns.sh stg` cũng phải xanh trước buổi stg. Plan của root env đọc `prd.tfvars` (mức prd); đọc
file text `prd-env-plan.txt`: chỉ `to add`, có ba web ACL và `module.edge` như stg (`session-stg.md`, mục 6–8) với ALB `svp-prd-edge`
`enable_deletion_protection = true`, distribution `svp-prd-media` không gói flat-rate (không `aws_pricingplanmanager_subscription`) với
response headers policy `svp-prd-media` và delivery log, bastion SSM, ba NAT gateway, RDS `multi_az = true`,
cluster MSK ba broker `kafka.m7g.large` (configuration RF 3, min ISR 2) cùng log group `/aws/msk/svp-prd`, replication group ElastiCache hai
node `cache.m7g.large` (`automatic_failover_enabled`, `multi_az_enabled` `true`). Apply ~65–70 phút (MSK là phần dài nhất). `apply` đỏ giữa
chừng và lỗi apply đã biết (account chưa xác minh, delivery destination chưa có, ElastiCache không nhận access string) theo
`session-stg.md`, mục 6–8: lượt đỏ đã ghi một tài nguyên mang mật khẩu của nhóm Kafka hay Valkey thì tăng `msk_password_version` hay
`valkey_password_version` trong `aws/envs/prd/prd.auto.tfvars` trước khi `plan` lại, rồi `bootstrap.sh prd secrets` ở bước 9. Plan có cùng
các tài nguyên của Karpenter, bastion, KMS key, SNS và alarm như stg (`session-stg.md`, mục 6–8), tên `svp-prd-*`. Sau apply, xác nhận email
của topic `svp-prd-alarms` theo `session-stg.md`, mục 6–8 (`AWS_PROFILE=anhnv-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`).

## Tunnel tới API (sau bước 8, trước bước 9)

Như `session-stg.md`, mục **Tunnel tới API**, với cổng `127.0.0.1:6443` của prd. Mở ở **một terminal riêng** từ gốc repo, giữ chạy tới hết
bước 20 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/envs/prd output -raw api_tunnel_command)"
```

`FAIL no tunnel …` của một script là tunnel chưa mở hay đã rớt: mở lại rồi chạy lại đúng bước đó. Context `svp-prd`: server
`https://127.0.0.1:6443`, TLS server name là host của endpoint private.

## Bước 9–13: secret, root gitops, chờ

Như `session-stg.md` bước 9–13, với `prd`, gồm token Grafana Operator ở bước 9 (entry `svp/prd/grafana-operator`) và mục
[Làm nóng cache](session-stg.md#làm-nóng-cache-sau-bước-9-trước-bước-10) giữa bước 9 và 10, với danh sách của prd (render chart ở `revision` của
`envs/prd/charts.yaml`):

```sh
(cd ../backend && deploy/ci/image-list.sh ../gitops prd) >"$SVP_SESSION_DIR/images-prd.txt"
aws/scripts/ecr-warm.sh prd "$SVP_SESSION_DIR/images-prd.txt"
```

Hai commit phải khớp hai khoá đã kiểm ở bước 4 của cổng promote: `<sha>` của dòng `ok chart
svp-cluster at <sha>` (bước 11) là `revision` (commit repo code của chart), output `bootstrap_revision` (bước 12) là `gitopsRevision` (commit
`svp-gitops`). Chat Telegram lấy từ `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (giá trị trần hay trong một cặp nháy kép hoặc nháy đơn,
như `make eks-secrets` đọc). Lệnh `kubectl` tay vào prd ghi profile và context:

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io
```

## Bước 14: smoke, edge, commit status

`measure.sh prd` chỉ chạy smoke (`make eks-smoke CONTEXT=svp-prd DOMAIN=<domain>`), không seed, không thang k6 (số đo của prd là các diễn tập
dưới). Sau smoke: phép (d) của mục [Gói Free và CORS của media](session-stg.md#gói-free-và-cors-của-media) của `session-stg.md` với
`AWS_PROFILE=anhnv-prd` (playlist là của video smoke vừa tải lên; mong `access-control-allow-origin: https://<domain>` của policy
`svp-prd-media`, không `*`; prd không có gói nên không phép (c)); phép kiểm edge (a)–(f) theo mục
[Phép kiểm edge](session-stg.md#phép-kiểm-edge) với `anhnv-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`, `svp-prd-edge`, đích `svp-cloudfront-prd` (media có
HSTS, nosniff; log CloudFront có cả media, chưa có trong buổi thì ghi `chờ giao` và kiểm lại sau buổi như phép (e) đó); phép kiểm (a)–(e) của
ADR-0053 theo mục
[Kafka và Valkey managed](session-stg.md#kafka-và-valkey-managed), với `anhnv-prd`, `--context svp-prd`, tên `svp-prd` (mong `kafka.m7g.large`,
`3` broker; replication group `2` node), phép kiểm (a)–(f) của mục
[Nền tảng EKS, TLS Postgres và alarm](session-stg.md#nền-tảng-eks-tls-postgres-và-alarm) với `anhnv-prd`, `--context svp-prd`, `svp-prd`
(mong ba node `nodegroup=system` ở ba zone, node Karpenter `capacity-type=on-demand`, pod Kyverno trên ba zone, `db.m7g.large`, trần storage
của `prd.tfvars`), gồm plan lần hai sau apply, phải cho `No changes` (`ok plan text in …: No changes.`):

```sh
aws/scripts/tf.sh prd env plan
```

Output vào phụ lục của ADR tương ứng, một dòng kết luận vào mục "Xác nhận". Sau đó kiểm commit status `argocd/prd` (Argo CD
Notifications của prd) có trên commit `svp-root`
đã sync (`main` của `svp-gitops`):

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.sync.revision}{"\n"}'
gh api "repos/anhnvcoder/svp-gitops/commits/<sha trên>/statuses" --jq '.[] | select(.context == "argocd/prd") | "\(.state) \(.created_at)"' | head -n 1
```

Mong `success`; dán lại cả hai dòng.

## Phép kiểm nền tảng managed

Sau smoke, mục [Phép kiểm nền tảng managed](session-stg.md#phép-kiểm-nền-tảng-managed) của `session-stg.md` với `E=prd` ở khối dùng chung,
`AWS_PROFILE=anhnv-prd`, `--context svp-prd`, `svp-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`, `aws/accounts/prd`, log group `/svp/prd/otel`, cluster
`svp-prd` trong truy vấn:

- (a) image: như stg; image phát hành ở ECR prd chỉ tới qua `promote-prd` của cổng trên, nên mọi pod của `svp` có host ECR của account prd là
  bằng chứng đường promote chép đủ; `cosign verify` cùng identity (nguồn của bản phát hành không đổi).
- (b) mạng: mỗi endpoint interface `available True 3` (ENI ở mọi AZ của prd, ADR-0064 §4).
- (c) telemetry: như stg, khung là lúc diễn tập (mục Đo dưới đây đọc dashboard trên AMG `svp-prd`).
- (d) chỉ phần luật: hai namespace `ACTIVE`, Alertmanager `ACTIVE`, chu kỳ `15`. prd chạy commit `svp-gitops` mà stg đã chạy (`gitopsRevision`
  ghim), nên không PR annotation nào tới được nó: canary, AnalysisRun thủ công và cảnh báo `page` qua AMP được kiểm ở stg, cùng chart; alarm
  `page` của prd là mục 6 của **Đo**.
- (e) dữ liệu còn sau destroy: như stg, thư mục `.session/persist-prd/`; ghi trước bước 18 (sau các diễn tập), chạy lại sau bước 29 cùng ngày
  (mục **Kết thúc buổi**) và ở buổi prd kế. Retention của prd dài hơn stg (`locals` của `aws/accounts/prd`).

Dán output của từng phép như mục của stg.

## Phép kiểm transcode

Sau smoke, (a) và (f) của mục [Phép kiểm transcode](session-stg.md#phép-kiểm-transcode) của `session-stg.md` với `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, queue `svp-prd`, hàng đợi `svp-prd-transcode-events`, `svp-prd-transcode-events-dlq`, alarm `svp-prd-transcode-events-dlq`
(không cần clip; của khối biến và hàm dùng chung chỉ cần hai dòng đầu, `values` và `media`):

- (a) smoke đi qua MediaConvert: Deployment `media-worker` chạy `["mediaconvert"]`; bảng đếm chỉ có `record-job COMPLETE`, một cho video smoke
  (khi đọc lại sau các diễn tập: một cho mỗi video smoke và `eks-seed` của mục **Đo**), cùng các dòng `orphan-job` được chấp nhận như ở stg
  (job lạc không quyết kết quả).
- (f) hai hàng đợi về hai số `0`, alarm DLQ `OK` hay `INSUFFICIENT_DATA`, log của bridge không có dòng bỏ message. Chạy lại sau các diễn tập của
  mục **Đo** (failover, khởi động lại broker không được làm mất event của job), trước bước 15.

Kiểm FF-9, lớp cắt và header qua CloudFront chạy ở stg trên cùng code và cùng module; prd không lặp lại. Một dòng kết luận mỗi phép vào
"Xác nhận" của ADR-0066; DLQ có message: runbook
[`transcode-events-dlq.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/transcode-events-dlq.md) của repo code.

## Đo

Mỗi phép đo ghi kết quả (đạt hay không, output chính, thời điểm UTC) vào một file trong `$SVP_SESSION_DIR`, để sau buổi điền cột Kết quả của
mục "Xác nhận" của ADR-0048 và ADR-0053 ((g), (h)). Phép đo không truy vấn database nào: event đếm ở Kafka qua CLI vận hành (`svp-kafka` của
Deployment `svp-data/svp-ops`); một truy vấn tay vào database của service chỉ được là `SELECT`.

1. **Thời gian dựng**: từ `env-apply-start` tới `svp-root-healthy` của `timeline.tsv` (phút):

   ```sh
   awk -F '\t' '$3 == "env-apply-start" { s = $2 } $3 == "svp-root-healthy" { e = $2 } END { printf "%.0f min\n", (e - s) / 60 }' "$SVP_SESSION_DIR/timeline.tsv"
   ```

2. **Failover RDS Multi-AZ** bằng reboot with failover. Đọc AZ chính và AZ dự phòng, reboot, chờ `available`, đọc lại (hai AZ phải đổi chỗ),
   đọc sự kiện để lấy thời gian failover, rồi smoke lại để chứng minh service nối lại được:

   ```sh
   AWS_PROFILE=anhnv-prd aws rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
   AWS_PROFILE=anhnv-prd aws rds reboot-db-instance --db-instance-identifier svp-prd --force-failover --region ap-southeast-1 \
     --query 'DBInstance.DBInstanceStatus' --output text
   AWS_PROFILE=anhnv-prd aws rds wait db-instance-available --db-instance-identifier svp-prd --region ap-southeast-1
   AWS_PROFILE=anhnv-prd aws rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
   AWS_PROFILE=anhnv-prd aws rds describe-events --source-type db-instance --source-identifier svp-prd --duration 60 --region ap-southeast-1 \
     --query 'Events[].[Date,Message]' --output text
   AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
   ```

   Dán lại: hai dòng AZ, các sự kiện `failover` (bắt đầu, xong), dòng cuối của smoke. **Thời gian nối lại** của service (số đo cho mục "Xem
   lại khi" của **Proxy kết nối**, ADR-0057): từ sự kiện failover bắt đầu tới request lỗi cuối của `user-service`, `video-service`,
   `engagement-service`, `feed-service` ở dashboard SLO (AMG `svp-prd` như `session-stg.md` bước 14, panel lỗi theo route), ghi giây. Alarm
   `rds-*` nào đổi trạng thái trong lúc đó: đọc lịch sử, đối chiếu thư tới `alarm_email`:

   ```sh
   AWS_PROFILE=anhnv-prd aws cloudwatch describe-alarm-history --history-item-type StateUpdate \
     --start-date "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" --region ap-southeast-1 --output text \
     --query "AlarmHistoryItems[?starts_with(AlarmName, 'svp-prd-rds-')].[Timestamp,AlarmName,HistorySummary]"
   ```

3. **Drain một AZ** (ADR-0056, phép kiểm buổi prd): cordon rồi drain mọi node của một zone, cả node hệ thống. Pod bị đuổi theo PDB (Envoy
   `minAvailable: 1`, Kyverno `maxUnavailable: 1`, controller nền tảng), chạy lại trên node của hai zone còn lại; pod còn Pending thì Karpenter
   dựng node mới. Karpenter không biết zone đó "mất" và có thể dựng node mới ngay ở zone đó (nhóm node hệ thống cũng vậy): zone của node mới
   là số đo, không là trượt. Trong lúc drain chạy, terminal thứ hai chạy smoke và đọc Envoy, Kyverno:

   ```sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes -L topology.kubernetes.io/zone,eks.amazonaws.com/nodegroup,karpenter.sh/nodepool
   zone=ap-southeast-1a                                                                                     # một zone của dòng trên
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd cordon -l topology.kubernetes.io/zone="$zone"
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd drain -l topology.kubernetes.io/zone="$zone" --ignore-daemonsets --delete-emptydir-data \
     --timeout=15m 2>&1 | tee "$SVP_SESSION_DIR/drain-$zone.log"
   ```

   Terminal thứ hai, trong lúc drain:

   ```sh
   AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=svp -o wide
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodeclaims.karpenter.sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get pods -A --field-selector=status.phase=Pending
   ```

   Rồi trả zone về và đọc lại node:

   ```sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd uncordon -l topology.kubernetes.io/zone="$zone"
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool
   ```

   Mong: smoke đạt trong lúc drain; luôn còn ít nhất một pod Envoy `Running` và hai pod Kyverno `Running`; drain xong không lỗi
   `Cannot evict pod as it would violate the pod's disruption budget` kéo quá `--timeout`; không pod nào Pending quá vài phút. Dán lại: zone đã
   drain, dòng cuối của smoke, ba output đọc pod, NodeClaim mới (zone, thời gian tới `Ready`), các dòng `evicting`/`error` của log drain.

4. **Khởi động lại một broker MSK khi đang ghi, không mất event** (phép kiểm (g) của ADR-0053): tải k6 profile `cloud` từ trong cluster (Job
   `svp-k6` tới Service `svp-envoy`, không qua CloudFront, WAF: `session-stg.md` bước 14; view ghi vào `engagement.views.v1`), cộng một
   producer đếm được trên topic thử `svp-durability-check` (`acks=all`,
   idempotent, như producer của service), cả hai chạy trong lúc một broker khởi động lại. Target `k8s-traffic-*` của repo code chỉ dành cho
   k3d. Terminal của buổi, tunnel mở; dữ liệu cho k6 rồi tải 2 pod, giữ 20 phút (seed và đặt lại rate limit là việc của chính lab, **LOCAL
   LAB ONLY**: xoá khoá `svp:gw:rl:register:*` ở db 10 của ElastiCache prd):

   ```sh
   AWS_PROFILE=anhnv-prd make -C ../backend eks-seed CONTEXT=svp-prd DOMAIN=<domain>
   AWS_PROFILE=anhnv-prd make -C ../backend eks-rl-reset CONTEXT=svp-prd
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> --pods 2 --ramp 2m --hold 20m start
   ```

   Khi k6 đã qua bậc lên (2 phút), terminal thứ hai (cùng biến của buổi): tạo topic thử bằng `svp-admin` (RF 3, min ISR 2 của configuration),
   rồi ghi 3 000 bản ghi, ~10 mỗi giây (~5 phút), log vào thư mục buổi:

   ```sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --create --topic svp-durability-check --partitions 3
   seq 1 3000 | while IFS= read -r i; do echo "$i"; sleep 0.1; done |
     AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec -i deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka console-producer \
       --topic svp-durability-check --producer-property acks=all --producer-property enable.idempotence=true \
       --producer-property delivery.timeout.ms=300000 2>&1 | tee "$SVP_SESSION_DIR/msk-reboot-producer.log"
   ```

   Trong lúc nó ghi, terminal thứ ba: ARN của cluster, danh sách broker, khởi động lại broker 1, đọc trạng thái tới khi `ACTIVE` lại
   (`REBOOTING_BROKER` trong lúc đó), rồi đọc thời điểm của thao tác:

   ```sh
   arn=$(AWS_PROFILE=anhnv-prd aws kafka list-clusters-v2 --cluster-name-filter svp-prd --region ap-southeast-1 --query 'ClusterInfoList[0].ClusterArn' --output text)
   AWS_PROFILE=anhnv-prd aws kafka list-nodes --cluster-arn "$arn" --region ap-southeast-1 --query 'NodeInfoList[].BrokerNodeInfo.[BrokerId,ClientSubnet]' --output text
   AWS_PROFILE=anhnv-prd aws kafka reboot-broker --cluster-arn "$arn" --broker-ids 1 --region ap-southeast-1 --query ClusterOperationArn --output text
   AWS_PROFILE=anhnv-prd aws kafka describe-cluster-v2 --cluster-arn "$arn" --region ap-southeast-1 --query ClusterInfo.State --output text
   AWS_PROFILE=anhnv-prd aws kafka describe-cluster-operation --cluster-operation-arn <ARN của reboot-broker> --region ap-southeast-1 \
     --query 'ClusterOperationInfo.[OperationType,OperationState,CreationTime,EndTime]' --output text
   ```

   Khi producer xong và k6 hết giờ giữ: đếm. Tổng end offset của topic thử phải bằng 3 000 (thiếu là mất bản ghi đã xác nhận, thừa là trùng),
   log producer không có lần gửi hỏng (dòng `ERROR Error when sending message …` của callback; dòng `WARN` thử lại, như
   `NotLeaderOrFollowerException` khi leader chuyển sang broker khác, là số đo, không là trượt); mỗi partition của group `engagement-service`
   `LAG` 0 (đọc lại sau một phút nếu còn), DLQ `engagement.views.v1.dlq` vẫn 0 (cluster mới mỗi buổi); rồi xoá topic thử, đọc kết quả k6 và
   xoá Job:

   ```sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka get-offsets --topic svp-durability-check --time -1 |
     awk -F: '$3 ~ /^[0-9]+$/ { s += $3 } END { print s }'
   grep -c 'Error when sending message' "$SVP_SESSION_DIR/msk-reboot-producer.log"
   grep -c ' WARN ' "$SVP_SESSION_DIR/msk-reboot-producer.log"
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka consumer-groups --describe --group engagement-service
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka get-offsets --topic engagement.views.v1.dlq --time -1
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --delete --topic svp-durability-check
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> logs
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> delete
   ```

   Mong `3000`, `0` lần gửi hỏng, mọi `LAG` 0, mọi dòng DLQ kết thúc bằng `:0`; số dòng `WARN` (thử lại) chỉ ghi lại. Dán lại: output của
   `list-nodes` và `describe-cluster-operation` (thời gian khởi động lại), các số trên, bảng của `run.sh logs`. Request lỗi của k6 trong lúc
   broker khởi động lại (dashboard SLO, `run.sh logs`) là số đo, không là trượt: producer của service thử lại tới `delivery.timeout.ms`.

5. **Failover Valkey** (phép kiểm (h) của ADR-0053): dưới tải của một lượt k6 mới (mục 4 đã xoá lượt của nó), đọc vai trò hai node, ép
   failover, đọc sự kiện và vai trò lại (primary và replica đổi chỗ), rồi smoke. Dữ liệu seed của mục 4 còn nguyên, không seed lại; lượt mới
   lại đăng ký user nên đặt lại rate limit đăng ký trước `start` (**LOCAL LAB ONLY**, như mục 4), rồi chờ k6 qua bậc lên (2 phút):

   ```sh
   AWS_PROFILE=anhnv-prd make -C ../backend eks-rl-reset CONTEXT=svp-prd
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> --pods 2 --ramp 2m --hold 10m start
   ```

   Rồi, cùng terminal khi k6 đang giữ tải:

   ```sh
   AWS_PROFILE=anhnv-prd aws elasticache describe-replication-groups --replication-group-id svp-prd --region ap-southeast-1 --output text \
     --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].[CacheClusterId,PreferredAvailabilityZone,CurrentRole]'
   AWS_PROFILE=anhnv-prd aws elasticache test-failover --replication-group-id svp-prd --node-group-id 0001 --region ap-southeast-1 \
     --query ReplicationGroup.Status --output text
   AWS_PROFILE=anhnv-prd aws elasticache describe-events --source-type replication-group --source-identifier svp-prd --duration 30 \
     --region ap-southeast-1 --query 'Events[].[Date,Message]' --output text
   AWS_PROFILE=anhnv-prd aws elasticache describe-replication-groups --replication-group-id svp-prd --region ap-southeast-1 --output text \
     --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].[CacheClusterId,PreferredAvailabilityZone,CurrentRole]'
   AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
   ```

   Khi k6 hết giờ giữ, đọc kết quả rồi xoá lượt của mục này:

   ```sh
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> logs
   AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> delete
   ```

   Đọc lại sự kiện tới khi có dòng failover xong; không có dòng nào sau vài phút thì thay `--source-type replication-group` bằng
   `cache-cluster`, bỏ `--source-identifier`. Dán lại: hai lần vai trò, các sự kiện failover (bắt đầu, xong), dòng cuối của smoke, bảng của `run.sh logs`, và từ
   dashboard SLO số request lỗi của `gateway`, `web` trong khoảng giữa hai sự kiện: lỗi chỉ trong khoảng đó, không quá timeout Redis của
   service, là đạt.

6. **Alarm `page` tới email**: phép (f) của mục
   [Nền tảng EKS, TLS Postgres và alarm](session-stg.md#nền-tảng-eks-tls-postgres-và-alarm) với `anhnv-prd`, `svp-prd-rds-storage-low`:
   thư `ALARM` có URL runbook, rồi thư `OK`. Dán lại lịch sử của alarm.

(Tuỳ chọn) **Đổi một secret của env đang chạy**: như mục cùng tên của `session-stg.md`, với `aws/scripts/bootstrap.sh prd secrets`,
`aws/envs/prd/prd.auto.tfvars` (version write-only của mật khẩu Kafka, Valkey), `aws/scripts/tf.sh prd env plan|apply`, `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, tunnel mở: cùng các dòng `ok`, `FAIL` (`cluster svp-prd …`). Không broker nào restart: MSK đọc mật khẩu từ secret SCRAM,
ElastiCache từ user của nó; chỉ pod client restart (Reloader).

## Bước 15–17: diễn tập khôi phục

Như `session-stg.md`, mục **15–17. Diễn tập khôi phục**, với `prd`, chạy sau mọi phép của mục **Đo** (lượt k6 cuối đã xoá, không client nào
ghi) và sau lượt chạy lại (f) của mục **Phép kiểm transcode**, tunnel mở:

```sh
aws/scripts/restore-drill.sh prd backup
aws/scripts/restore-drill.sh prd rds
aws/scripts/restore-drill.sh prd s3
```

Khác stg ở dữ liệu: plan `svp-prd` của Backup policy `svp-backup-prd`, vault `svp-prd`, role `svp-prd-backup`, bản copy vào `svp-prd-copy`
(retention và vault lock của prd, ADR-0067 §4); instance `svp-prd-pitr` một AZ cùng lớp với `svp-prd` (nguồn Multi-AZ, bản khôi phục không),
nên giờ của nó là khoản lớn nhất của phần backup mỗi buổi. Cùng mục tiêu RTO/RPO, cùng cách đọc dòng `FAIL`. Đọc bản copy bằng lệnh của mục
stg với `svp-prd-copy`:

```sh
k=$(AWS_PROFILE=anhnv-backup-ro aws backup describe-backup-vault --backup-vault-name svp-prd-copy --region ap-southeast-1 \
  --query EncryptionKeyArn --output text)
AWS_PROFILE=anhnv-backup-ro aws backup list-recovery-points-by-backup-vault --backup-vault-name svp-prd-copy --region ap-southeast-1 \
  --by-created-after "$(head -n 1 "$SVP_SESSION_DIR/timeline.tsv" | cut -f 1)" --output json |
  jq -r --arg k "$k" '.RecoveryPoints[] | [.ResourceType, .Status, .CreationDate, .CalculatedLifecycle.DeleteAt,
    (if .EncryptionKeyArn == $k then "vault-key" else "other-key" end)] | @tsv'
```

Mong ba dòng `COMPLETED`, `DeleteAt` cách `CreationDate` đúng retention bản copy của prd, `vault-key`. Lệnh xem log quanh T_r, khôi phục
object bằng delete marker khi restore job lỗi: như stg với `anhnv-prd`, `--context svp-prd`, bucket `svp-prd-media-<account prd>-ap-southeast-1`.
Dán bảng `restore-drill.tsv` (lệnh `column` của mục stg); số đo vào phụ lục ADR-0067 cùng số của stg.

## Kết thúc buổi

**Trước bước 18, finding bảo mật của buổi** (chỉ đọc, khi tài nguyên của buổi còn sống, cả khi buổi dừng sớm): hai lệnh và cách xử lý của
`session-stg.md`, mục [Finding bảo mật của buổi](session-stg.md#finding-bảo-mật-của-buổi-sau-bước-17-trước-bước-18), cùng điều kiện
(bước (4), (5) của nền bảo mật org), với dòng đầu `ACC="${SVP_AWS_PRD_ACCOUNT_ID:?not set}"` của prd (comment trên dòng `ACC` của stg) thay
dòng của stg: dòng của stg chạy ở terminal prd thì đọc finding của account stg. Mốc của diễn tập prd cũng nằm trong `timeline.tsv` của buổi.

Theo thứ tự, mỗi bước xong mới sang bước sau:

1. **Destroy root gitops rồi root env** (bước 18–25, tunnel còn mở tới hết bước 20). Bảo vệ của prd được nhấc trước: bước 21 đọc
   `terraform state list` của `aws/envs/prd` rồi plan với `prd.tfvars` và `teardown.tfvars`, chỉ nhắm (`-target`) DB instance, ALB edge và
   bucket có trong state (đọc `prd-env-teardown-plan.txt`: chỉ `to change`, deletion protection của RDS và của ALB `svp-prd-edge` về `false`,
   `force_destroy` của bucket; cảnh báo
   "Resource targeting is in effect" của Terraform là đúng ý), bước 22 apply nó; `tf.sh prd env plan --destroy` dừng với `FAIL the protections
   of aws/envs/prd are still on` khi chưa có mốc `env-teardown-applied`. Apply của bước 22 cũng gắn lại tag `Backup`, nên bước 23
   (`restore-drill.sh prd cleanup`, mục **21–25** của `session-stg.md`) chạy sau nó: xoá `svp-prd-pitr` nếu còn, gỡ tag, chờ job, xoá recovery
   point của vault `svp-prd` đã có bản copy, ghi `backup-drained`; thiếu mốc đó thì `plan --destroy` dừng với `FAIL the backups of prd are not
   drained`. Rồi plan `-destroy` với cả hai file, không `-target`. Destroy vẫn ghi final snapshot của RDS (`skip_final_snapshot` giữ `false`) và
   giữ backup tự động. Bước 26, 27 (đóng root account) in `ok no session feature of prd …` như bước 3–5.

   Apply của bước 8 đỏ giữa chừng (vd thiếu quota): vẫn làm bước 21, 22, 23 trước `plan --destroy` (với `--no-cluster` khi chưa có cluster
   EKS, điều kiện ở `session-stg.md`, mục 21–25). Plan chỉ nhắm những gì đã được tạo nên không tạo thêm phần còn thiếu và không gặp lại lỗi
   cũ; state không có DB instance, ALB hay bucket nào thì bước 21 in `skip`, ghi mốc `env-teardown-applied` (không có gì để nhấc) và bước 22 in
   `skip`; bước 23 in `skip` cho phần chưa tạo.
2. **Recovery point, final snapshot và backup tự động**: đọc recovery point của buổi (lệnh đầu: vault `svp-prd` của account không còn recovery
   point nào sau bước 23, mong `0`; bản copy của buổi còn ở `svp-prd-copy`: lệnh **Đọc bản copy** của mục **Bước 15–17**, mong cùng ba dòng
   như lúc đọc sau bước 15). Snapshot `awsbackup:*` của AWS Backup không phải `manual`, không hiện ở lệnh thứ hai. Đọc final snapshot có thật
   (dán tên và thời điểm: bằng chứng bảo vệ chạy), rồi xoá nó; đọc backup tự động được giữ, rồi xoá từng cái:

   ```sh
   AWS_PROFILE=anhnv-prd aws backup list-recovery-points-by-backup-vault --backup-vault-name svp-prd --region ap-southeast-1 \
     --query 'length(RecoveryPoints)' --output text
   AWS_PROFILE=anhnv-prd aws rds describe-db-snapshots --db-instance-identifier svp-prd --snapshot-type manual --region ap-southeast-1 \
     --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' --output text
   AWS_PROFILE=anhnv-prd aws rds delete-db-snapshot --db-snapshot-identifier <svp-prd-final-…> --region ap-southeast-1 --query 'DBSnapshot.Status' --output text
   AWS_PROFILE=anhnv-prd aws rds describe-db-instance-automated-backups --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstanceAutomatedBackups[].[DBInstanceAutomatedBackupsArn,Status]' --output text
   AWS_PROFILE=anhnv-prd aws rds delete-db-instance-automated-backup --db-instance-automated-backups-arn <arn> --region ap-southeast-1 \
     --query 'DBInstanceAutomatedBackup.Status' --output text
   ```

3. **`aws/scripts/sweep.sh prd`** (profile `anhnv-prd`): chỉ còn dòng `kept` (`Stack=baseline`: bucket state, KMS key state, zone
   `aws.<domain>` cùng `CAA` và bản ghi `NS` uỷ quyền `stg.aws.<domain>` dưới đỉnh của nó, ở `us-east-1` key DNSSEC, hai alarm DNSSEC, log
   group query log, topic `svp-prd-dns-alarms` và key của nó; registry ECR, rule và repo của cache, OIDC provider, role CI, workspace AMP, log
   group `/svp/prd/otel`, workspace AMG và tham số SSM `/svp/prd/grafana-workspace-id` của nó (cờ `managed_grafana` là `always`), key của
   chúng; vault `svp-prd`, role `svp-prd-backup` và key của vault; `Stack=security-baseline`:
   CMK EBS), không endpoint interface, không rule groups
   namespace của AMP, và `pending deletion` (KMS key của root
   env: RDS, MSK, alarm, Secrets của EKS; 7 ngày), exit 0; không còn dòng MSK, ElastiCache, `AmazonMSK_*`, log group `/aws/msk/svp-prd` (phép kiểm (f) của ADR-0053),
   không còn instance, launch template, instance profile, hàng đợi SQS hay rule EventBridge nào của Karpenter; không còn queue MediaConvert
   `svp-prd`, role `svp-prd-mediaconvert`, hàng đợi `svp-prd-transcode-events*`, rule `svp-prd-mediaconvert-job-state` (phép kiểm gỡ của
   ADR-0066); không còn recovery point, job AWS Backup chưa kết thúc hay instance `svp-prd-pitr` (phép kiểm gỡ của ADR-0067).
   Còn gì khác: chạy lệnh `delete:` nó in, rồi chạy lại. Gói của account rỗng (mong `[]`), cùng lượt sweep sạch này:

   ```sh
   AWS_PROFILE=anhnv-prd aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

4. **`aws/scripts/sweep.sh mgmt`** (profile `anhnv-sso`): chỉ `Stack=bootstrap|org|security-baseline|security` (bucket state, trail,
   baseline bảo mật, detector GuardDuty của management), không hosted zone, exit 0.

Một lượt `sweep.sh prd` chạy trước bước 2 được phép exit khác 0 (final snapshot, backup tự động còn đó) và chỉ để xem. **Buổi chỉ xong khi
lượt `sweep.sh prd` sau bước 2 và lượt `sweep.sh mgmt` cùng exit 0.** AI nhắc tới khi người học xác nhận đủ bốn bước. Rồi, cùng ngày, chạy
lại truy vấn dữ liệu đã ghi trước bước 18 (mục **Phép kiểm nền tảng managed** (e), `after-destroy.txt` của `.session/persist-prd/`) và dán
`diff`; buổi đầu có span của account prd: retention của `aws/spans` theo bước (10) của
[`platform-setup.md`](platform-setup.md#bước-10-retention-của-awsspans). Sau 24 giờ: Cost Explorer của account prd theo dịch vụ, so với C.

### Web ACL WAF sót

Lệnh xoá web ACL (sau khi distribution đã xoá) dùng chung cho hai env: `session-stg.md`, mục
[Lệnh xoá tay theo loại](session-stg.md#lệnh-xoá-tay-theo-loại), với `AWS_PROFILE=anhnv-prd`.

Loại sót khác: `session-stg.md`, mục **Lệnh xoá tay theo loại**, với `AWS_PROFILE=anhnv-prd`.
