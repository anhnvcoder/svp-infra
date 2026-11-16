# Runbook: một buổi AWS prd

Buổi prd duy nhất của lộ trình (buổi capstone,
[ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §3): mở
bằng đổi cờ prd về giá trị production, kết thúc bằng trả prd về giá trị rẻ của file. Buổi dựng env prd trong account
`svp-prd` (`aws/envs/prd`, mức production: NAT mỗi AZ, RDS Multi-AZ, MSK ba broker trên ba AZ, ElastiCache primary và
replica Multi-AZ, nhóm node hệ thống và node Karpenter on-demand trải ba AZ, bảo vệ xoá), cài Argo CD và root GitOps qua
tunnel SSM (`aws/gitops/prd`), chạy đúng commit `svp-gitops` mà stg đã chạy, đo (thời gian dựng, failover RDS Multi-AZ,
drain một AZ, khởi động lại một broker MSK khi đang ghi, failover Valkey, alarm), diễn tập khôi phục (backup on-demand
và copy sang account `svp-backup`, PITR của RDS, một object S3 từ AWS Backup), rồi gỡ sạch trong cùng buổi. Các diễn
tập, khi buổi chọn chạy (phép `chuẩn ngành`), là chỗ kiểm bù của nhóm "giảm có điều kiện" ở stg
([ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) §4). Thiết kế:
[ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) (§4 truy cập API, §6 bootstrap
EKS, §7 ghim revision, §8 promote, §9 kết thúc buổi, §10 chi phí),
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md) (Kafka là Amazon
MSK, Valkey là ElastiCache; prd mất một AZ không mất event đã xác nhận),
[ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md) (zone của mỗi env),
[ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md) (web ACL WAF;
gói flat-rate Free chỉ ở media của stg),
[ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md) (Karpenter, Envoy và
Kyverno HA, trải zone),
[ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md) (PostgreSQL 17,
`verify-full`, không proxy kết nối),
[ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) (CloudWatch
alarm tới email),
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md) (edge:
CloudFront, VPC origin, ALB internal, WAF, cert ACM, log CloudFront, DNS),
[ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) (image từ ECR của
account prd, chỉ vào qua `promote-prd`),
[ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) (telemetry vào
dịch vụ managed sống qua destroy),
[ADR-0064](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0064-interface-endpoints.md) (endpoint interface
ở mọi AZ của prd),
[ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md) (transcode bằng
AWS Elemental MediaConvert, giống hệt stg),
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) (backup và DR, giống stg trừ
retention, vault lock và OU của Backup policy).

Buổi prd đi đúng chuỗi script của buổi stg; khác biệt là dữ liệu (dòng `prd` của `env_table` trong `aws/scripts/lib.sh`: profile `anhnv-prd`,
biến `SVP_AWS_PRD_ACCOUNT_ID`, tunnel cổng 6443, file `teardown.tfvars`, không thang k6) và các bước tay ở đây. Mọi mục chung (luật chạy lệnh,
thư mục buổi, mở lại terminal, ý nghĩa từng bước script, xác nhận email của alarm, tunnel tới API, phép kiểm nền tảng, **Destroy kẹt**, **Lệnh
xoá tay theo loại**, đổi secret) ở
[`session-stg.md`](session-stg.md): đọc trước, thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`. File này chỉ ghi phần riêng của prd.

Mỗi bước và phép kiểm mang dòng `Loại:` `lõi` hay `chuẩn ngành` theo mục [Phép kiểm lõi và chuẩn
ngành](session-stg.md#phép-kiểm-lõi-và-chuẩn-ngành) của `session-stg.md`; đường mặc định chỉ chạy `lõi`. Buổi này chạy
với giá trị production, nên phép `chuẩn ngành` không cần đổi cờ nào thêm: chọn chạy phép nào là chọn thời gian và chi
phí ghi ở dòng `Loại:` của nó. Phép kiểm prd mà tài liệu khác đặt ở buổi prd sau đó (so dữ liệu ở buổi kế) chỉ còn ở
stg.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster, kể cả lệnh chỉ đọc; AI đọc output dán lại và nhắc tới khi
năm bước của mục **Kết thúc buổi** (gỡ, quét, trả cờ) đều xong.

```sh
aws/scripts/session.sh --print prd                 # mọi lệnh script của buổi, theo thứ tự, không chạy gì
```

## Chi phí và giới hạn

- **Trần một buổi C ≈ $11,0** = 4 giờ × (H₀ $0,90 + H_k $1,09)/giờ + O₀ $2,8 + O_k $0,22 (ADR-0053 §16 và bảng ở phụ lục
  của nó; H_k là 3 broker `kafka.m7g.large` cộng 2 node `cache.m7g.large` cộng phần nhỏ; H₀, O₀ ở phụ lục ADR-0048),
  cộng node Karpenter on-demand ngoài nhóm hệ thống, KMS key và CloudWatch alarm (ADR-0056, ADR-0058), cộng phần edge
  (ALB, ba web ACL, log; bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13), cộng phần nền tảng managed (endpoint interface ở
  mọi AZ, mẫu AMP, log, span, Inspector mỗi digest bên thứ ba mới, AMG của tháng buổi: bảng tổng ở [ADR-0063
  §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md#12-chi-phí-hợp-đồng-cluster-và-adr-cũ)
  và phụ lục của nó); buổi đo số thật ở Cost Explorer. Cả buổi với giá trị production, gồm lượt bật lại của cờ:
  [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8. **Phí
  giữ R ≈ $4,6/tháng** giữa các buổi (trail, KMS, bucket state của management; bucket state, KMS key, zone của hai
  baseline), cộng phần edge lúc không buổi (key DNSSEC, topic và alarm DNSSEC, query log: bảng "Lúc không buổi" ở phụ
  lục ADR-0061 §13) và phần registry, observability lúc không buổi (key KMS, secret của cache, lưu trữ ECR: cùng bảng
  của ADR-0063 §12; giữa các buổi prd không có AMG), báo riêng, không cộng vào C; tháng không buổi của cả org với giá
  trị rẻ của file:
  [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8, đổi
  cờ prd trước và sau buổi: §3, §7. Phần transcode (job MediaConvert của buổi, endpoint `mediaconvert` ở mọi AZ, SQS,
  request S3; $0 lúc không buổi) ở [ADR-0066
  §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí) và mục
  "Chi phí" của phụ lục, cộng vào C. Phần backup mỗi buổi (instance `svp-prd-pitr` của diễn tập theo lớp của nguồn, key
  `uploads`, hai alarm backup, request và restore S3) cộng vào C; bản copy ở `svp-backup` và ba key của vault sống giữa
  các buổi, báo riêng như R: cả hai ở [ADR-0067
  §13](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#13-chi-phí) và mục "Chi phí" của
  phụ lục.
- **Cả buổi 4 giờ**, từ cổng promote tới hai lượt `sweep.sh` sạch. Quá 3 giờ mà chưa đo xong thì bỏ phần đo còn lại, sang gỡ. Quên gỡ 24
  giờ ≈ $48 (24 × (H₀ + H_k)); budget `svp-prd-monthly` và budget tổng của org gửi email ở 50 %, 80 %, 100 %.
- Ba distribution của prd (web, api, media) và ba web ACL là pay-as-you-go, có access log; prd không đăng ký gói flat-rate nào. Web ACL sót
  tính phí theo giờ, nên `sweep.sh` bắt nó.
- MSK và ElastiCache dựng, gỡ lâu như stg (`session-stg.md`, mục "Giới hạn"; số giả định của ADR-0053 §16, số đo của buổi stg thay nó khi
  đã có).

## Đổi cờ prd trước buổi

Loại: `lõi` (bước dựng prd ở giá trị production của buổi). Giữa các buổi prd có giá trị rẻ của `aws/paid-features.json`
như stg; buổi này chạy với giá trị production
([ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §3). Làm
trước buổi, trước cổng promote và mốc bắt đầu 4 giờ của buổi, theo điều 3 của
[`paid-features.md`](paid-features.md#trước-khi-bắt-đầu):

1. Một PR xoá khoá `prd` khỏi file (mọi cờ của prd thành `always`); `infra-ok` xanh, merge.
2. Áp theo hướng bật: `aws/baseline`, `aws/security`, `aws/accounts/prd`, mỗi root đọc plan rồi apply theo mục của root
   đó trong `paid-features.md`; plan chỉ chạm tài nguyên của bốn cờ (AMG `svp-prd`, Inspector, Security Hub, Config);
   plan lần hai `No changes.` ở cả ba.
3. Kiểm điều kiện 12 dưới (lệnh `jq`, mong `"absent"`).

Account dùng chung giữ giá trị của file suốt buổi. Buổi kết thúc bằng trả prd về giá trị rẻ: bước 5 của mục
[Kết thúc buổi](#kết-thúc-buổi).

## Điều kiện trước buổi

1. Root `aws/org` đã apply (account `svp-prd`, SCP, permission set `SvpAdmin` gán vào account đó); profile `anhnv-prd` đã ghi bằng
   `aws/scripts/sso-profiles.sh write` ([`aws/org`, Profile](../../aws/org/README.md#profile)); baseline `aws/accounts/prd`
   đã apply và zone gốc `aws.<domain>` của nó đã được uỷ quyền bằng bốn bản ghi `NS` `aws` ở DNS cha của domain
   ([`aws/accounts/README.md`](../../aws/accounts/README.md), mục 5); zone `stg.aws.<domain>` là zone con của nó, uỷ quyền bằng
   `delegated_subdomains` của chính root `aws/accounts/prd`.
2. Buổi stg ở account `svp-stg` đã chạy xong theo [`session-stg.md`](session-stg.md), và mọi PR của code, `svp-gitops`, repo này đã merge.
3. **Bằng chứng stg**: commit `svp-gitops` sẽ promote (`stg_ref`) có commit status `argocd/stg` trạng thái `success` (Argo CD Notifications
   của stg ghi khi sync xong commit đó). Job `promote-prd` từ chối commit không có nó. `stg_ref` là commit ghi ở `stg-ref.txt` của thư mục buổi
   stg (`session-stg.md` bước 16) mà buổi đó đã qua các phép `lõi` (a), (f) của mục
   [Phép kiểm transcode](session-stg.md#phép-kiểm-transcode): prd chạy đúng `platforms/`
   có bridge MediaConvert mà stg đã kiểm. Promote theo mục "Promote" của
   [README `svp-gitops`](https://github.com/anhnvcoder/svp-gitops/blob/main/README.md#promote), làm ở **Cổng promote prd** dưới. Kiểm:

   ```sh
   gh api "repos/anhnvcoder/svp-gitops/commits/<stg_ref>/statuses" --jq '.[] | select(.context == "argocd/stg") | "\(.state) \(.created_at)"' | head -n 1
   ```

4. Account prd: AWS đã xác minh cho CloudFront (case Support mở từ account prd, như `session-stg.md` điều kiện 1) và quota EC2 on-demand đủ
   cho mọi node của prd, cả node Karpenter (NodePool prd on-demand). Đọc quota (chỉ đọc) ở terminal của buổi:

   ```sh
   aws/scripts/preflight.sh quotas prd
   ```

   Mong mỗi quota một dòng `ok    <mã> <tên>: <giá trị> (min|max <cần>)`; thiếu thì `FAIL  <mã> …: run preflight.sh quotas prd request`
   (xin tăng bằng đúng lệnh đó, chờ `APPROVED` trước buổi). Quota vCPU on-demand chuẩn (`L-1216C47A`) cần ≥ 14 vCPU cộng
   `limits.cpu` của NodePool prd (`envs/prd/svp-cluster.yaml` của `svp-gitops`, số ở ADR-0056 §2): nhóm node hệ thống tới
   `system_node_max_size` 6 node `m7g.large` × 2 vCPU, bastion `t4g.nano` 2 vCPU ([trang loại instance của
   AWS](https://aws.amazon.com/ec2/instance-types/)); số cần ở `quota_table` của script.
5. Trên máy, ngoài các công cụ của stg: `gh` đã đăng nhập.
6. `aws/backend-prd.hcl` và `aws/envs/prd/prd.auto.tfvars` như điều kiện 4, 5 của stg (root `aws/accounts/prd`; `domain = "aws.<domain>"`:
   tên zone prd, web ở đỉnh, API ở `api.aws.<domain>`; `alarm_email` là hộp thư nhận alarm). Root env đọc id workspace AMG `svp-prd` từ tham
   số SSM `/svp/prd/grafana-workspace-id` của `aws/accounts/prd`; dòng `grafana_workspace_id` có sẵn trong file thì script xoá:

   ```sh
   aws/scripts/tfvars.sh backend prd
   aws/scripts/tfvars.sh env prd
   ```

7. **Không gói CloudFront nào**: prd không đăng ký gói flat-rate, nên một gói còn ở account là sót (của buổi trước hay của console), giữ
   distribution của nó. Mỗi buổi, trước bước 3 (chỉ đọc):

   ```sh
   aws/scripts/preflight.sh freetier prd
   ```

   Mong `ok    no CloudFront flat-rate plan in prd` và `ok    account plan of prd is PAID`; dán lại. `FAIL  N CloudFront plan(s) left in
   prd …`: huỷ gói theo `session-stg.md`, mục **Lệnh xoá tay theo loại** (CloudFront), với `AWS_PROFILE=anhnv-prd`, rồi chạy lại.
8. **Nền bảo mật của org đã áp** tới ít nhất bước (3) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu), và biến
   `SVP_AWS_LOG_ACCOUNT_ID` đặt trong terminal của buổi: như `session-stg.md` điều kiện 6 (root env prd ghi flow log, log WAF vào bucket
   của `svp-log-archive`).
9. **Edge đã áp lần đầu** theo [`edge-setup.md`](edge-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (3), như `session-stg.md` điều kiện 7 (destination
   `svp-cloudfront-prd`, `CAA`, zone `aws.<domain>` ký và có `DS` ở DNS cha); file có sẵn từ trước còn dòng `acme_email` thì xoá như
   `session-stg.md` điều kiện 5.
10. **Nền tảng managed đã áp** theo [`platform-setup.md`](platform-setup.md#thứ-tự-áp-lần-đầu) tới hết bước (9) cho
    account prd, như `session-stg.md` điều kiện 8: registry, cache có credential, AMP, log group `/svp/prd/otel`, quota
    chu kỳ luật 15 s (AMG `svp-prd` có từ bước đổi cờ trước buổi); role `svp-ci-ecr-promote` có, nên `promote-prd` của
    cổng dưới chép được image vào ECR prd.
11. **Backup đã áp** theo [`backup-setup.md`](backup-setup.md#thứ-tự-áp-lần-đầu), như `session-stg.md` điều kiện 10, với Backup policy
    `svp-backup-prd` gắn OU `Prod`, vault `svp-prd-copy`, vault `svp-prd` cùng role `svp-prd-backup` và opt-in của `aws/accounts/prd`.
12. **Cờ prd ở giá trị production**: mục [Đổi cờ prd trước buổi](#đổi-cờ-prd-trước-buổi) đã xong. Kiểm (chỉ đọc, không
    chạm account):

    ```sh
    jq -c '.prd // "absent"' aws/paid-features.json
    ```

    Mong `"absent"`; in object cờ thì dừng, làm đổi cờ đó trước. Mọi mong đợi của runbook này tính theo giá trị
    production.

## Mở terminal của buổi

Như `session-stg.md` (cùng phiên SSO dùng chung cho mọi profile, cùng cách đọc `FAIL`; mục
[Mở terminal của buổi](session-stg.md#mở-terminal-của-buổi)), vì `accounts.sh` đặt cả `SVP_AWS_PRD_ACCOUNT_ID`:

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                          # one login per sso_session
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
eval "$(aws/scripts/accounts.sh)"
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"
aws/scripts/sso-profiles.sh check
```

## Thứ tự

Các bước script, theo đúng thứ tự `session.sh --print prd`; bước tay của prd chen giữa, ở các mục dưới (đổi cờ prd trước
buổi, cổng promote trước bước 1, email của alarm và tunnel sau bước 9, làm nóng cache sau bước 11, phát video và CORS
của media, phép kiểm edge, phép kiểm nền tảng, migration của release, xác thực qua CloudFront, trải zone và chạy thử
DLQ, service mesh, bảo vệ của account, data event của trail, phép kiểm nền tảng managed, commit status, phép kiểm
transcode và mục
**Đo** sau bước 16, đọc bản copy sau bước 17, ghi truy vấn dữ liệu và finding bảo mật trước bước 20, đọc recovery point
sau bước 25, final snapshot sau bước 27, chạy lại truy vấn dữ liệu sau bước 31, trả prd về giá trị rẻ sau cùng). Đường
mặc định chạy các mục `lõi` và bỏ bước 17–19:

| # | Lệnh | Hạn | Dán lại cho AI | Loại |
| --- | --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh prd` | 2 phút | dòng `ok account …` (account, ARN) | `lõi` |
| 2 | `aws/scripts/check-dns.sh prd` | 2 phút | ba dòng `ok` hay dòng `FAIL` | `lõi` |
| 3 | `aws/scripts/tf.sh prd account init` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` | `lõi` |
| 4 | `aws/scripts/tf.sh prd account plan --open` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` | `lõi` |
| 5 | `aws/scripts/tf.sh prd account apply` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` | `lõi` |
| 6 | `aws/scripts/tf.sh prd env init` | 5 phút | dòng cuối | `lõi` |
| 7 | `aws/scripts/media-signing-key.sh prd new a` | 1 phút | dòng `ok slot a: …` và mọi dòng `warn`/`note` | `lõi` |
| 8 | `aws/scripts/tf.sh prd env plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan | `lõi` |
| 9 | `aws/scripts/tf.sh prd env apply` | 70 phút | dòng `Apply complete! …`, hai dòng `mark` và hai dòng `Creation complete after …` của cluster MSK, replication group ElastiCache | `lõi` |
| 10 | `aws/scripts/media-signing-key.sh prd activate a` | 2 phút | dòng `ok entry …` (không có khoá) | `lõi` |
| 11 | `aws/scripts/bootstrap.sh prd secrets` | 5 phút | mọi dòng `ok`/`FAIL` | `lõi` |
| 12 | `aws/scripts/tf.sh prd gitops init` | 2 phút | dòng cuối | `lõi` |
| 13 | `aws/scripts/tf.sh prd gitops plan` | 5 phút | dòng `ok chart svp-cluster at …`, dòng `Plan: …` | `lõi` |
| 14 | `aws/scripts/tf.sh prd gitops apply` | 15 phút | dòng `Apply complete! …`, output `bootstrap_revision` | `lõi` |
| 15 | `aws/scripts/bootstrap.sh prd wait` | 45 phút | mọi dòng `ok`/`FAIL` | `lõi` |
| 16 | `aws/scripts/measure.sh prd` | 10 phút | dòng `ok smoke passed …` | `lõi` |
| 17 | `aws/scripts/restore-drill.sh prd backup` | 60 phút | mọi dòng `ok`/`FAIL`, dòng `PASS backup …` | `chuẩn ngành` |
| 18 | `aws/scripts/restore-drill.sh prd rds` | 75 phút | mọi dòng `ok`/`FAIL`, dòng `PASS rds …` hay `FAIL rds …` | `chuẩn ngành` |
| 19 | `aws/scripts/restore-drill.sh prd s3` | 30 phút | mọi dòng `ok`/`FAIL`, dòng `PASS s3 …` hay `FAIL s3 …` | `chuẩn ngành` |
| 20 | `aws/scripts/pre-destroy.sh prd` | 30 phút | mọi dòng `ok`/`FAIL`/`note` | `lõi` |
| 21 | `aws/scripts/tf.sh prd gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` | `lõi` |
| 22 | `aws/scripts/tf.sh prd gitops destroy` | 10 phút | dòng `Apply complete! …` | `lõi` |
| 23 | `aws/scripts/tf.sh prd env plan --teardown` | 5 phút | dòng `note … targets …`, dòng `Plan: 0 to add, N to change, 0 to destroy` và đường dẫn file text (hay dòng `skip`) | `lõi` |
| 24 | `aws/scripts/tf.sh prd env apply --teardown` | 10 phút | dòng `Apply complete! …`, mốc `env-teardown-applied` (hay dòng `skip`) | `lõi` |
| 25 | `aws/scripts/restore-drill.sh prd cleanup` | 30 phút | mọi dòng `ok`/`FAIL`/`skip`, mốc `backup-drained` | `lõi` |
| 26 | `aws/scripts/tf.sh prd env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan | `lõi` |
| 27 | `aws/scripts/tf.sh prd env destroy` | 60 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster MSK, replication group ElastiCache | `lõi` |
| 28 | `aws/scripts/tf.sh prd account plan --close` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` | `lõi` |
| 29 | `aws/scripts/tf.sh prd account apply` | 1 phút | dòng `ok no session feature of prd in aws/paid-features.json …` | `lõi` |
| 30 | `aws/scripts/sweep.sh prd` | 5 phút | toàn bộ output | `lõi` |
| 31 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output | `lõi` |

## Cổng promote prd (trước mọi lệnh tốn tiền)

Loại: `lõi`.

prd chỉ chạy commit `svp-gitops` stg đã chạy: khoá `gitopsRevision` của `envs/prd/charts.yaml` phải có giá trị trước bước 13 (plan của root
gitops dừng khi khoá vắng, `require_pinned_revision = true`). Làm cổng này **trước bước 1**, khi chưa tài nguyên nào tính tiền:

1. Dispatch job `promote-prd` của repo code với `stg_ref` là commit có bằng chứng stg (điều kiện 3):

   ```sh
   gh workflow run images.yml -R anhnvcoder/svp-backend --ref main -f promote_prd=true -f stg_ref=<stg_ref 40 hex>
   gh run list -R anhnvcoder/svp-backend --workflow images.yml --limit 1
   ```

2. Duyệt environment `promote-prd` của lượt chạy đó (trang của run trên GitHub, "Review deployments"). Job mở PR ở `svp-gitops` (nhánh
   `bot/promote-prd`) đặt `gitopsRevision = <stg_ref>` cùng image và chart của commit đó.
3. Code Owner duyệt PR đó, check của `svp-gitops` xanh, merge.
4. Kiểm cổng bằng script (sau khi PR đã merge), thay các lệnh `git show`/`grep` tay:

   ```sh
   aws/scripts/preflight.sh promote
   ```

   Script không gọi `aws`; nó đọc hai bản clone `../backend` và `../gitops` (`SVP_BACKEND_DIR`, `SVP_GITOPS_DIR` đổi chỗ),
   `git fetch origin` rồi đọc `origin/main`, không đổi nhánh. Mong, theo thứ tự:

   - `ok    clone … is clean and fetched` hai lần; clone có thay đổi trên file đã theo dõi thì `FAIL … has uncommitted changes`;
   - `ok    envs/prd/charts.yaml: revision <40 hex>, gitopsRevision <40 hex>`: `revision` là commit của repo code (chart), `gitopsRevision`
     là commit `svp-gitops` (`stg_ref`). `FAIL  gitopsRevision … is '', not a commit: promote-prd has not merged` là bước 1–3 chưa xong;
   - `ok    chart revision <…> has the eks Collector and canaryPrometheus`: **chart có nền tảng managed**. `revision` phải là
     commit của repo code có Collector theo nền tảng và value `canaryPrometheus`. Values eks của `svp-gitops` chỉ đúng với
     chart đó; chart cũ chạy với chúng thì Prometheus thành agent mà canary cũ vẫn hỏi nó (Inconclusive), Collector cũ gửi
     tới Prometheus, Loki, Tempo không còn trên eks (mất metric, log, trace), không luật trên AMP, không dashboard ở AMG,
     image kéo thẳng upstream, Kyverno và External Secrets bị NetworkPolicy chặn tới endpoint interface (Secret không tạo
     được);
   - `ok    media-worker runs mediaconvert at <…> and the chart at <…> takes args`: **bản ghim có transcode MediaConvert**. Ở
     `gitopsRevision` (`G`), release `media-worker` của nền tảng eks chạy lệnh con `mediaconvert`, nhận ba biến của queue,
     role, hàng đợi từ hợp đồng cluster và được ra TCP 443 trong VPC (endpoint interface); ở `revision` (`R`), schema của
     chart `svp-service` nhận value `args` và Deployment đưa nó vào container chính.

Script nêu điều kiện hụt trong mỗi `FAIL`. Hụt chart hay bản ghim (prd sẽ chạy `media-worker serve` với ffmpeg, hay pod không
khởi động): **không dựng prd**; promote lại từ `stg_ref` của một buổi stg đã chạy với
chart mới và đã qua phép kiểm transcode. Dán lại mọi dòng `ok`/`FAIL`.

Job từ chối (`stg_ref` không có `argocd/stg` `success`, hay không trên `main`), environment hay PR bị từ chối: **dừng buổi**, không chạy bước 1.
Job `promote-prd` chép và kiểm mọi image của `envs/stg/images/` vào ECR prd trước khi mở PR; một image lỗi thì không có PR: đọc log của job,
dán dòng lỗi (`vuln` quá hạn thì dòng đó nêu lệnh rescan).

## Bước 1–10: account, DNS, root account, root env, khoá ký

Loại: `lõi`.

Như `session-stg.md` bước 1–10, với `prd`. `check-account.sh prd` phải in account `svp-prd`. Bước 7
(`media-signing-key.sh prd new a`) và 10 (`activate a`) dựng khoá ký URL premium của buổi như stg (`session-stg.md`, mục
6–10; [`media-signing-keys.md`](media-signing-keys.md)). Bước 3–5 in `ok no session feature of prd in
aws/paid-features.json: …` và không chạy gì, chỉ khi có điều kiện 12: prd vắng khỏi file nên mọi cờ của nó là `always`,
không cờ nào `session`; AMG `svp-prd` và tham số SSM của nó có từ lần áp `aws/accounts/prd` của bước đổi cờ đó (mục [Cờ
chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi) của stg). Với giá trị rẻ của file (`managed_grafana` `off`) bước
3–5 in đúng dòng đó, nên dòng này không chứng minh điều kiện 12: lệnh `jq` của điều kiện 12 là phép kiểm duy nhất trước
bước 1. `check-dns.sh prd` hỏi `NS aws.<domain>` (tên là `zone_name` của `aws/accounts/prd/prd.auto.tfvars`) ở `1.1.1.1`
và `8.8.8.8` và so với output `name_servers` của `aws/accounts/prd`; `FAIL` thì bốn bản ghi `NS` `aws` ở DNS cha chưa
lan hay sai: sửa theo `aws/accounts/README.md` (mục 5), không bắt đầu buổi. Zone stg nằm dưới zone prd nên `check-dns.sh
stg` cũng phải xanh trước buổi stg. Plan của root env đọc `prd.tfvars` (mức prd); đọc file text `prd-env-plan.txt`: chỉ
`to add`, có ba web ACL và `module.edge` như stg (`session-stg.md`, mục 6–10) với ALB `svp-prd-edge`
`enable_deletion_protection = true`, distribution `svp-prd-media` không gói flat-rate (không
`aws_pricingplanmanager_subscription`) với response headers policy `svp-prd-media`, delivery log, behavior mặc định tin
key group `svp-prd-media` (`media/*`, `preview/*` công khai) (public key `svp-prd-media-a-<8 hex>`), bastion SSM, ba NAT
gateway, RDS `multi_az = true`, cluster MSK ba broker `kafka.m7g.large` (configuration RF 3, min ISR 2) cùng log group
`/aws/msk/svp-prd`, replication group ElastiCache hai node `cache.m7g.large` (`automatic_failover_enabled`,
`multi_az_enabled` `true`). Apply ~65–70 phút (MSK là phần dài nhất). `apply` đỏ giữa chừng và lỗi apply đã biết
(account chưa xác minh, delivery destination chưa có, ElastiCache không nhận access string) theo `session-stg.md`, mục
6–10: lượt đỏ đã ghi một tài nguyên mang mật khẩu của nhóm Kafka hay Valkey thì `aws/scripts/tfvars.sh bump prd msk` hay
`bump prd valkey` (tăng `msk_password_version` hay `valkey_password_version` trong `aws/envs/prd/prd.auto.tfvars`) trước
khi `plan` lại, rồi `bootstrap.sh prd secrets` ở bước 11. Plan có cùng các tài nguyên của Karpenter, bastion, KMS key,
SNS và alarm như stg (`session-stg.md`, mục 6–10), tên `svp-prd-*`. Sau apply, xác nhận email của topic `svp-prd-alarms`
theo `session-stg.md`, mục 6–10 (`AWS_PROFILE=anhnv-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`).

## Tunnel tới API (sau bước 9, trước bước 11)

Loại: `lõi`.

Như `session-stg.md`, mục **Tunnel tới API**, với cổng `127.0.0.1:6443` của prd. Mở ở **một terminal riêng** từ gốc repo, giữ chạy tới hết
bước 22 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/envs/prd output -raw api_tunnel_command)"
```

`FAIL no tunnel …` của một script là tunnel chưa mở hay đã rớt: mở lại rồi chạy lại đúng bước đó. Context `svp-prd`: server
`https://127.0.0.1:6443`, TLS server name là host của endpoint private.

## Bước 11–15: secret, root gitops, chờ

Loại: `lõi`.

Như `session-stg.md` bước 11–15, với `prd`, gồm token Grafana Operator ở bước 11 (entry `svp/prd/grafana-operator`) và mục
[Làm nóng cache](session-stg.md#làm-nóng-cache-sau-bước-11-trước-bước-12) giữa bước 11 và 12, với danh sách của prd (render chart ở `revision` của
`envs/prd/charts.yaml`):

```sh
(cd ../backend && deploy/ci/image-list.sh ../gitops prd) >"$SVP_SESSION_DIR/images-prd.txt"
aws/scripts/ecr-warm.sh prd "$SVP_SESSION_DIR/images-prd.txt"
```

Hai commit phải khớp hai khoá đã kiểm ở bước 4 của cổng promote: `<sha>` của dòng `ok chart
svp-cluster at <sha>` (bước 13) là `revision` (commit repo code của chart), output `bootstrap_revision` (bước 14) là `gitopsRevision` (commit
`svp-gitops`). Chat Telegram lấy từ `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (giá trị trần hay trong một cặp nháy kép hoặc nháy đơn,
như `make eks-secrets` đọc). Lệnh `kubectl` tay vào prd ghi profile và context:

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io
```

Cảnh báo `PublicUptimeBudgetBurn` (SLO `public-uptime`, hai mức cùng tên: `page` và `ticket`) cháy sau khi dựng cluster
mới là do probe lỗi lúc dựng (probe chạy trước các service, thứ tự ở `argocd/apps/components.json` của svp-gitops):
chờ, không điều tra. Khi ba đích đã xanh, page hết sau chừng 30 phút, ticket theo cửa sổ 6 giờ; cửa sổ của hai mức ở
`deploy/observability/prometheus/rules/slo-generated.yaml` của svp-backend, cách đọc ở
[`public-uptime-budget-burn.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/public-uptime-budget-burn.md).

## Bước 16: smoke, edge, commit status

`measure.sh prd` chỉ chạy smoke (`make eks-smoke CONTEXT=svp-prd DOMAIN=<domain>`), không seed, không thang k6 (số đo
của prd là mục **Đo** dưới). Phép kiểm sau smoke ở các mục con, mỗi mục một dòng `Loại:`. Output vào phụ lục của ADR
tương ứng, một dòng kết luận vào mục "Xác nhận".

### Smoke, phát video và alarm

Loại: `lõi`. Smoke là bước 16 (dòng `ok smoke passed …`). Sau smoke: phép (d) của mục [Phát video và CORS của
media](session-stg.md#phát-video-và-cors-của-media) của `session-stg.md` với `AWS_PROFILE=anhnv-prd` (playlist là của
video smoke vừa tải lên; mong `access-control-allow-origin: https://<domain>` của policy `svp-prd-media`, không `*`), và
phép (f) của mục [Alarm tới email](session-stg.md#alarm-tới-email) là mục **Đo 6** dưới.

### Edge, Kafka, Valkey và nền tảng EKS

Loại: `chuẩn ngành`, không cần đổi cờ (mọi phép chỉ đọc hay gọi API qua HTTPS). Thêm: request của edge premium và phép
kiểm edge tính pay-as-you-go như request khác (bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13), một plan của root env (hạn
của bước 8); ADR không có số thời gian cho phần còn lại.

Phép kiểm edge (a)–(f) theo mục [Phép kiểm edge](session-stg.md#phép-kiểm-edge) với `anhnv-prd`,
`$SVP_AWS_PRD_ACCOUNT_ID`, `svp-prd-edge`, đích `svp-cloudfront-prd` (media có HSTS, nosniff; log CloudFront có cả
media, chưa có trong buổi thì ghi `chờ giao` và kiểm lại sau buổi như phép (e) đó); hai lượt `make eks-premium-check`
của mục [Phép kiểm edge premium](session-stg.md#phép-kiểm-edge-premium) với `CONTEXT=svp-prd` và một lượt **Xoay khoá
ký** của [`media-signing-keys.md`](media-signing-keys.md#xoay-khoá-ký) với `prd`; phép kiểm (a)–(e) của ADR-0053 theo
mục [Kafka và Valkey managed](session-stg.md#kafka-và-valkey-managed), với `anhnv-prd`, `--context svp-prd`, tên
`svp-prd` (mong `kafka.m7g.large`, `3` broker; replication group `2` node); phép kiểm (a)–(e) của mục [Nền tảng EKS và
TLS Postgres](session-stg.md#nền-tảng-eks-và-tls-postgres) với `anhnv-prd`, `--context svp-prd`, `svp-prd` (mong ba node
`nodegroup=system` ở ba zone, node Karpenter `capacity-type=on-demand`, pod Kyverno trên ba zone, `db.m7g.large`, trần
storage của `prd.tfvars`); và plan lần hai sau apply, phải cho `No changes` (`ok plan text in …: No changes.`; prd không
có gói nên không phép (c) của mục Gói Free):

```sh
aws/scripts/tf.sh prd env plan
```

### Commit status argocd/prd

Loại: `lõi`. Commit status `argocd/prd` (Argo CD Notifications của prd) có trên commit `svp-root` đã sync (`main` của
`svp-gitops`):

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.sync.revision}{"\n"}'
gh api "repos/anhnvcoder/svp-gitops/commits/<sha trên>/statuses" --jq '.[] | select(.context == "argocd/prd") | "\(.state) \(.created_at)"' | head -n 1
```

Mong `success`; dán lại cả hai dòng.

### Migration của release ở prd

Loại: `lõi`.

Mục [Migration của release](session-stg.md#migration-của-release) của `session-stg.md` với `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, sau bước 15. Mong như stg: mỗi release hai dòng của runner (`"lock_timeout":"2s"`), bốn Application
`Synced` `Healthy`; Job không còn thì ghi lại, không sync lại.

### Xác thực qua CloudFront ở prd

Loại: `lõi`; (d) giữ một trang web mở hơn 15 phút.

Mục [Xác thực qua CloudFront](session-stg.md#xác-thực-qua-cloudfront) của `session-stg.md`, (a)–(d), với `api` từ
`cluster-values.json` của buổi prd (CloudFront `svp-prd-api`), `AWS_PROFILE=anhnv-prd`, `--context svp-prd` ở lệnh
port-forward. Mong như stg. `429` của `register`: chờ `Retry-After`, không xoá khoá nào ở Valkey của prd. User thử của
(c) nằm trong database prd tới khi env gỡ cuối buổi.

### Trải zone và chạy thử DLQ ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; khi commit `gitopsRevision` của `envs/prd/charts.yaml` có `dlq-replay` trong
`argocd/apps/components.json` và `zoneSpread` ở `platforms/eks`. Thêm: như stg, lệnh chỉ đọc và bốn lượt `--dry-run`;
ADR không có số thời gian.

Mục [Trải zone và chạy thử DLQ](session-stg.md#trải-zone-và-chạy-thử-dlq) của `session-stg.md` với `anhnv-prd`,
`--context svp-prd`; điều kiện đọc ở commit `gitopsRevision` (dòng `ok envs/prd/charts.yaml: …` của cổng promote) thay
cho `origin/main`. prd trải pod trên ba AZ: mong release nhiều pod (`gateway`, `web`, `user-service`, `video-service`,
`engagement-service`, `feed-service`…) ở `min(số pod, 3)` zone, `spread=DoNotSchedule/3`. DLQ của prd có record: chỉ
chạy thử ở đây, phát lại thật theo `kafka-dlq-records.md` khi người trực quyết.

### Service mesh ở prd

Loại: `lõi`.

Mục [Service mesh](session-stg.md#service-mesh) của `session-stg.md` với `AWS_PROFILE=anhnv-prd`, `--context svp-prd`,
sau bước 15. Mong như stg; node của nhóm hệ thống và node Karpenter (on-demand) trên ba zone, DaemonSet `istio-cni-node`,
`ztunnel` mỗi node một pod. Khác mong đợi: không chạy mục **Đo**, theo runbook `mesh-traffic-denied.md` của mục stg.

### Service mesh ở prd: danh tính lạ bị từ chối

Loại: `chuẩn ngành`, không cần đổi cờ; tạo rồi xoá một ServiceAccount và hai pod trong `svp`. Thêm: như stg, khoảng 3
phút, chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Khối của mục [Service mesh: danh tính lạ bị từ chối](session-stg.md#service-mesh-danh-tính-lạ-bị-từ-chối) với
`anhnv-prd`, `--context svp-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`; cùng mong đợi, lệnh cuối không còn tài nguyên nào.

### Bảo vệ của account ở prd

Loại: `lõi`; chạy ≥ 15 phút sau bước 15.

Mục [Bảo vệ của account: GuardDuty, flow log, log WAF, quét
malware](session-stg.md#bảo-vệ-của-account-guardduty-flow-log-log-waf-quét-malware) của `session-stg.md`, (a)–(d), với
`anhnv-prd`, `--context svp-prd`, `A=$SVP_AWS_PRD_ACCOUNT_ID`, cluster `svp-prd`, web ACL `svp-prd-media` trong bộ lọc
key của (c). Mong như stg: coverage `HEALTHY` khi DaemonSet có một pod mỗi node trên ba zone; bucket ở (d) là
`svp-prd-uploads-<account>-ap-southeast-1`.

### Data event S3 trong trail

Loại: `lõi`.

Chỉ prd: trail của org ghi data event của bucket `uploads` (ghi, đọc) và `media` (ghi) của prd (`aws/org/audit-trail.tf`).
CloudTrail `lookup-events` không trả data event, nên đọc chúng ở nơi trail giao: bucket `svp-cloudtrail-<log>-ap-southeast-1`
của Log Archive, profile `anhnv-log-ro`. Chạy ≥ 15 phút sau smoke (CloudTrail giao file trung bình trong khoảng 5 phút);
lệnh chỉ in tên sự kiện và bucket, không in bản ghi (bản ghi có IP, ARN của người gọi):

```sh
L=$SVP_AWS_LOG_ACCOUNT_ID P=$SVP_AWS_PRD_ACCOUNT_ID
b=svp-cloudtrail-$L-ap-southeast-1
since=$(awk -F '\t' '$3 == "svp-root-healthy" { t = $1 } END { print t }' "$SVP_SESSION_DIR/timeline.tsv" | tr -d Z)
org=$(AWS_PROFILE=anhnv-log-ro aws s3 ls "s3://$b/AWSLogs/" --region ap-southeast-1 | awk '$2 ~ /^o-/ { sub("/", "", $2); print $2 }')
AWS_PROFILE=anhnv-log-ro aws s3api list-objects-v2 --bucket "$b" --region ap-southeast-1 \
  --prefix "AWSLogs/$org/$P/CloudTrail/ap-southeast-1/$(date -u +%Y/%m/%d)/" --query 'Contents[].[Key,LastModified]' --output json |
  jq -r --arg s "$since" '(. // [])[] | select(.[1] >= $s) | .[0]' |
  while read -r k; do AWS_PROFILE=anhnv-log-ro aws s3 cp "s3://$b/$k" - --region ap-southeast-1 | gunzip -c; done |
  jq -r --arg a "$P" '.Records[] | select(.eventCategory == "Data" and .eventSource == "s3.amazonaws.com")
    | "\(.eventName) \(.requestParameters.bucketName | sub($a; "<account>"))"' | sort | uniq -c
```

Mong, mỗi dòng một số đếm: `PostObject svp-prd-uploads-<account>-ap-southeast-1` (video smoke tải lên bằng form presigned POST), `GetObject
svp-prd-uploads-…` (MediaConvert, quét malware đọc), `PutObject svp-prd-media-<account>-ap-southeast-1` (output của
transcode); không dòng `GetObject svp-prd-media-…` (trail chỉ ghi phần ghi của `media`). Rỗng: đọc lại sau 10 phút; ngay
sau 00:00 UTC đổi ngày trong `--prefix` về ngày trước. Vẫn thiếu một trong ba: dán output và selector của trail `svp-audit`
(`aws/org`) cho AI:

```sh
AWS_PROFILE=anhnv-sso aws cloudtrail get-event-selectors --trail-name svp-audit --region ap-southeast-1
```

## Phép kiểm nền tảng managed

Sau smoke, mục [Phép kiểm nền tảng managed](session-stg.md#phép-kiểm-nền-tảng-managed) của `session-stg.md` với `E=prd`
ở khối dùng chung, `AWS_PROFILE=anhnv-prd`, `--context svp-prd`, `svp-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`,
`aws/accounts/prd`, log group `/svp/prd/otel`, cluster `svp-prd` trong truy vấn. Khối dùng chung là `lõi` (luật cảnh báo
cần nó); mỗi phép một mục con có dòng `Loại:`. Dán output của từng phép như mục của stg.

### Nền tảng managed (a), (b), (c) ở prd

Loại: `chuẩn ngành`, không cần đổi cờ: Inspector của (a) và AMG của (c) có sẵn vì cờ của prd là `always` trong buổi.
Thêm: Inspector tới $9 khi digest bên thứ ba mới (dòng `inspector_ecr` của [phụ lục ADR-0071,
Cờ](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#cờ)), đã gồm trong chi
phí buổi của
[ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8; phần
còn lại chỉ đọc.

- (a) image: như stg; image phát hành ở ECR prd chỉ tới qua `promote-prd` của cổng trên, nên mọi pod của `svp` có host
  ECR của account prd là bằng chứng đường promote chép đủ; `cosign verify` cùng identity (nguồn của bản phát hành không
  đổi). Đoạn Inspector theo cờ `always`.
- (b) mạng: mỗi endpoint interface `available True 3` (ENI ở mọi AZ của prd, ADR-0064 §4).
- (c) telemetry: như stg, khung là lúc các phép của mục **Đo**; Explore, dashboard trên AMG `svp-prd`.

### Nền tảng managed (d) ở prd: luật cảnh báo

Loại: `lõi`. Chỉ phần luật: hai namespace `ACTIVE`, Alertmanager `ACTIVE`, chu kỳ `15`. prd chạy commit `svp-gitops` mà
stg đã chạy (`gitopsRevision` ghim), nên không PR annotation nào tới được nó: canary, AnalysisRun thủ công và cảnh báo
`page` qua AMP được kiểm ở buổi stg đã bật các phép đó (`chuẩn ngành`), cùng chart; alarm `page` của prd là mục
**Đo 6**.

### Nền tảng managed (e) ở prd: dữ liệu còn sau destroy

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: khoảng ghi ít nhất 10 phút trước bước 20, truy vấn chạy lại sau bước 31.

Như stg, thư mục `.session/persist-prd/`; ghi trước bước 20 (sau mục **Đo**), chạy lại sau bước 31 cùng ngày (mục **Kết
thúc buổi**). Lượt so ở buổi kế chỉ có ở stg: prd không có buổi kế.

### Độ trễ mesh ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; cần k6 của mục **Đo 4** đang giữ tải. Thêm: truy vấn AMP và `kubectl top`, chỉ
đọc; chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Khối của mục [Độ trễ mesh khi giữ tải](session-stg.md#độ-trễ-mesh-khi-giữ-tải) với `E=prd` ở khối dùng chung,
`anhnv-prd`, `--context svp-prd`, trong lúc k6 của **Đo 4** giữ tải: sau 2 phút lên tải, trước lệnh `reboot-broker` (số
đo lúc broker còn đủ). Mong và cách dán như stg; prd chạy service trên node on-demand ở ba zone.

### Uptime ở prd

Loại: `lõi`; chạy ≥ 30 phút sau mốc `edge-healthy`.

Mục [Uptime: probe và cảnh báo](session-stg.md#uptime-probe-và-cảnh-báo) với `E=prd` ở khối dùng chung, `anhnv-prd`,
`--context svp-prd`; mong như stg; prd có ba zone nhưng hai pod blackbox trải zone bằng `ScheduleAnyway`: cùng một zone vẫn hợp lệ (ghi
zone), lỗi thật là pod `Pending`, `CrashLoopBackOff` hay chỉ còn một pod. Thư `UptimeProbesAbsent` đọc sau bước 4 của
mục **Kết thúc buổi**, như stg đọc sau bước 31.

### Chi phí theo namespace ở prd

Loại: `chuẩn ngành`, không cần đổi cờ: dashboard `svp-cost`, `svp-uptime` trên AMG `svp-prd` có vì cờ của prd là
`always` trong buổi. Thêm: OpenCost ~$0,08–0,16 mỗi buổi prd ([phụ lục ADR-0074
§11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0074-cost-uptime.md#mỗi-buổi-4-giờ-mỗi-env)),
đã gồm trong chi phí buổi; truy vấn và port-forward chỉ đọc.

Mục [Chi phí theo namespace](session-stg.md#chi-phí-theo-namespace) với `E=prd` ở khối dùng chung, `anhnv-prd`, `--context
svp-prd`, cả đoạn dashboard. Khác stg: node prd on-demand nên số khớp giá niêm yết, không là trần; OpenCost không gọi
giá Spot.

### Canary gRPC theo request ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; khi buổi prd phát hành bản mới của một release gRPC có `canary: true` (PR
`bot/promote-prd` của `svp-gitops` merge giữa buổi) trong lúc k6 của mục **Đo 4** giữ tải. Thêm: như stg, một canary
khoảng 3–4 phút; chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Mục [Canary gRPC theo request](session-stg.md#canary-grpc-theo-request) của `session-stg.md` với `E=prd` ở khối dùng
chung, `anhnv-prd`, `--context svp-prd`, sau 2 phút lên tải của **Đo 4** và trước lệnh `reboot-broker`. Mong như stg: waypoint chia
theo trọng số của route, không theo số replica, nên phần lời gọi của pod canary gần bằng trọng số của bước. Buổi không phát hành bản mới
nào của release gRPC: ghi `không có canary`.

## Phép kiểm transcode

Loại: `lõi`.

Sau smoke, (a) và (f) của mục [Phép kiểm transcode](session-stg.md#phép-kiểm-transcode) của `session-stg.md` với `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, queue `svp-prd`, hàng đợi `svp-prd-transcode-events`, `svp-prd-transcode-events-dlq`, alarm `svp-prd-transcode-events-dlq`
(không cần clip; của khối biến và hàm dùng chung chỉ cần hai dòng đầu, `values` và `media`):

- (a) smoke đi qua MediaConvert: Deployment `media-worker` chạy `["mediaconvert"]`; bảng đếm chỉ có `record-job COMPLETE`, một cho video smoke
  (khi đọc lại sau các diễn tập: một cho mỗi video smoke và `eks-seed` của mục **Đo**), cùng các dòng `orphan-job` được chấp nhận như ở stg
  (job lạc không quyết kết quả).
- (f) hai hàng đợi về hai số `0`, alarm DLQ `OK` hay `INSUFFICIENT_DATA`, log của bridge không có dòng bỏ message. Chạy lại sau các diễn tập của
  mục **Đo** (failover, khởi động lại broker không được làm mất event của job), trước bước 17.

Kiểm FF-9, lớp cắt và header qua CloudFront chạy ở buổi stg đã bật các phép đó (`chuẩn ngành`), trên cùng code và cùng
module; prd không lặp lại. Một dòng kết luận mỗi phép vào "Xác nhận" của ADR-0066; DLQ có message: runbook
[`transcode-events-dlq.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/transcode-events-dlq.md) của repo code.

## Đo

Mỗi phép đo là một mục con có dòng `Loại:` riêng; mục 1–5 là `chuẩn ngành`, mục 6 là `lõi`.

Mỗi phép đo ghi kết quả (đạt hay không, output chính, thời điểm UTC) vào một file trong `$SVP_SESSION_DIR`, để sau buổi điền cột Kết quả của
mục "Xác nhận" của ADR-0048 và ADR-0053 ((g), (h)). Phép đo không truy vấn database nào: event đếm ở Kafka qua CLI vận hành (`svp-kafka` của
Deployment `svp-data/svp-ops`); một truy vấn tay vào database của service chỉ được là `SELECT`.

### Đo 1: thời gian dựng

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: một lệnh đọc `timeline.tsv`, không tốn tiền.

Từ `env-apply-start` tới `svp-root-healthy` của `timeline.tsv` (phút):

```sh
awk -F '\t' '$3 == "env-apply-start" { s = $2 } $3 == "svp-root-healthy" { e = $2 } END { printf "%.0f min\n", (e - s) / 60 }' "$SVP_SESSION_DIR/timeline.tsv"
```

### Đo 2: failover RDS Multi-AZ

Loại: `chuẩn ngành`, không cần đổi cờ (dashboard SLO trên AMG `svp-prd` có vì cờ `always` trong buổi). Thêm: một lần
reboot có failover và chờ `available`, một smoke; ADR không có số thời gian.

Failover bằng reboot with failover. Đọc AZ chính và AZ dự phòng, reboot, chờ `available`, đọc lại (hai AZ phải đổi chỗ),
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

Dán lại: hai dòng AZ, các sự kiện `failover` (bắt đầu, xong), dòng cuối của smoke. **Thời gian nối lại** của service (số
đo cho mục "Xem lại khi" của **Proxy kết nối**, ADR-0057): từ sự kiện failover bắt đầu tới request lỗi cuối của
`user-service`, `video-service`, `engagement-service`, `feed-service` ở dashboard SLO (AMG `svp-prd` như
`session-stg.md` bước 16, panel lỗi theo route), ghi giây. Alarm `rds-*` nào đổi trạng thái trong lúc đó: đọc lịch sử,
đối chiếu thư tới `alarm_email`:

```sh
AWS_PROFILE=anhnv-prd aws cloudwatch describe-alarm-history --history-item-type StateUpdate \
  --start-date "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" --region ap-southeast-1 --output text \
  --query "AlarmHistoryItems[?starts_with(AlarmName, 'svp-prd-rds-')].[Timestamp,AlarmName,HistorySummary]"
```

### Đo 3: drain một AZ

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: drain có `--timeout=15m`, node mới mà Karpenter dựng (on-demand, phần chưa
có số của [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md)
§8).

Phép kiểm buổi prd của ADR-0056: cordon rồi drain mọi node của một zone, cả node hệ thống. Pod bị đuổi theo PDB (Envoy
`minAvailable: 1`, Kyverno `maxUnavailable: 1`, controller nền tảng), chạy lại trên node của hai zone còn lại; pod còn
Pending thì Karpenter dựng node mới. Karpenter không biết zone đó "mất" và có thể dựng node mới ngay ở zone đó (nhóm
node hệ thống cũng vậy): zone của node mới là số đo, không là trượt. Trong lúc drain chạy, terminal thứ hai chạy smoke
và đọc Envoy, Kyverno:

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes -L topology.kubernetes.io/zone,eks.amazonaws.com/nodegroup,karpenter.sh/nodepool
zone=ap-southeast-1a  # một zone của dòng trên
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

Mong: smoke đạt trong lúc drain; luôn còn ít nhất một pod Envoy `Running` và hai pod Kyverno `Running`; drain xong không
lỗi `Cannot evict pod as it would violate the pod's disruption budget` kéo quá `--timeout`; không pod nào Pending quá
vài phút. Dán lại: zone đã drain, dòng cuối của smoke, ba output đọc pod, NodeClaim mới (zone, thời gian tới `Ready`),
các dòng `evicting`/`error` của log drain.

### Đo 4: khởi động lại một broker MSK khi đang ghi, không mất event

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: seed (MediaConvert của các video seed, [ADR-0066
§12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí)), k6 2 pod
lên 2 phút, giữ 20 phút, một broker khởi động lại.

Phép kiểm (g) của ADR-0053: tải k6 profile `cloud` từ trong cluster (Job `svp-k6` tới Service `svp-envoy`, không qua
CloudFront, WAF: mục Seed và thang k6 của `session-stg.md`; view ghi vào `engagement.views.v1`), cộng một producer đếm
được trên topic thử `svp-durability-check` (`acks=all`, idempotent, như producer của service), cả hai chạy trong lúc một
broker khởi động lại. Target `k8s-traffic-*` của repo code chỉ dành cho k3d. Terminal của buổi, tunnel mở; dữ liệu cho
k6 rồi tải 2 pod, giữ 20 phút (seed và đặt lại rate limit là việc của chính lab, **LOCAL LAB ONLY**: xoá khoá
`svp:gw:rl:register:*` ở db 10 của ElastiCache prd):

```sh
AWS_PROFILE=anhnv-prd make -C ../backend eks-seed CONTEXT=svp-prd DOMAIN=<domain>
AWS_PROFILE=anhnv-prd make -C ../backend eks-rl-reset CONTEXT=svp-prd
AWS_PROFILE=anhnv-prd bash ../backend/deploy/k6/cloud/run.sh --context svp-prd --domain <domain> --pods 2 --ramp 2m --hold 20m start
```

Khi k6 đã qua bậc lên (2 phút), terminal thứ hai (cùng biến của buổi): tạo topic thử bằng `svp-admin` (RF 3, min ISR 2
của configuration), rồi ghi 3 000 bản ghi, ~10 mỗi giây (~5 phút), log vào thư mục buổi:

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --create --topic svp-durability-check --partitions 3
seq 1 3000 | while IFS= read -r i; do echo "$i"; sleep 0.1; done |
  AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data exec -i deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka console-producer \
    --topic svp-durability-check --producer-property acks=all --producer-property enable.idempotence=true \
    --producer-property delivery.timeout.ms=300000 2>&1 | tee "$SVP_SESSION_DIR/msk-reboot-producer.log"
```

Trong lúc nó ghi, terminal thứ ba: ARN của cluster, danh sách broker, khởi động lại broker 1, đọc trạng thái tới khi
`ACTIVE` lại (`REBOOTING_BROKER` trong lúc đó), rồi đọc thời điểm của thao tác:

```sh
arn=$(AWS_PROFILE=anhnv-prd aws kafka list-clusters-v2 --cluster-name-filter svp-prd --region ap-southeast-1 --query 'ClusterInfoList[0].ClusterArn' --output text)
AWS_PROFILE=anhnv-prd aws kafka list-nodes --cluster-arn "$arn" --region ap-southeast-1 --query 'NodeInfoList[].BrokerNodeInfo.[BrokerId,ClientSubnet]' --output text
AWS_PROFILE=anhnv-prd aws kafka reboot-broker --cluster-arn "$arn" --broker-ids 1 --region ap-southeast-1 --query ClusterOperationArn --output text
AWS_PROFILE=anhnv-prd aws kafka describe-cluster-v2 --cluster-arn "$arn" --region ap-southeast-1 --query ClusterInfo.State --output text
AWS_PROFILE=anhnv-prd aws kafka describe-cluster-operation --cluster-operation-arn <ARN của reboot-broker> --region ap-southeast-1 \
  --query 'ClusterOperationInfo.[OperationType,OperationState,CreationTime,EndTime]' --output text
```

Khi producer xong và k6 hết giờ giữ: đếm. Tổng end offset của topic thử phải bằng 3 000 (thiếu là mất bản ghi đã xác
nhận, thừa là trùng), log producer không có lần gửi hỏng (dòng `ERROR Error when sending message …` của callback; dòng
`WARN` thử lại, như `NotLeaderOrFollowerException` khi leader chuyển sang broker khác, là số đo, không là trượt); mỗi
partition của group `engagement-service` `LAG` 0 (đọc lại sau một phút nếu còn), DLQ `engagement.views.v1.dlq` vẫn 0
(cluster mới mỗi buổi); rồi xoá topic thử, đọc kết quả k6 và xoá Job:

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

Mong `3000`, `0` lần gửi hỏng, mọi `LAG` 0, mọi dòng DLQ kết thúc bằng `:0`; số dòng `WARN` (thử lại) chỉ ghi lại. Dán
lại: output của `list-nodes` và `describe-cluster-operation` (thời gian khởi động lại), các số trên, bảng của `run.sh
logs`. Request lỗi của k6 trong lúc broker khởi động lại (dashboard SLO, `run.sh logs`) là số đo, không là trượt:
producer của service thử lại tới `delivery.timeout.ms`.

### Đo 5: failover Valkey

Loại: `chuẩn ngành`, không cần đổi cờ; chạy sau Đo 4 (dùng seed của nó). Thêm: một lượt k6 lên 2 phút, giữ 10 phút, một
failover của ElastiCache.

Phép kiểm (h) của ADR-0053: dưới tải của một lượt k6 mới (Đo 4 đã xoá lượt của nó), đọc vai trò hai node, ép failover,
đọc sự kiện và vai trò lại (primary và replica đổi chỗ), rồi smoke. Dữ liệu seed của Đo 4 còn nguyên, không seed lại;
lượt mới lại đăng ký user nên đặt lại rate limit đăng ký trước `start` (**LOCAL LAB ONLY**, như Đo 4), rồi chờ k6 qua
bậc lên (2 phút):

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

Đọc lại sự kiện tới khi có dòng failover xong; không có dòng nào sau vài phút thì thay `--source-type replication-group`
bằng `cache-cluster`, bỏ `--source-identifier`. Dán lại: hai lần vai trò, các sự kiện failover (bắt đầu, xong), dòng
cuối của smoke, bảng của `run.sh logs`, và từ dashboard SLO số request lỗi của `gateway`, `web` trong khoảng giữa hai sự
kiện: lỗi chỉ trong khoảng đó, không quá timeout Redis của service, là đạt.

### Đo 6: alarm page tới email

Loại: `lõi`.

Phép (f) của mục
[Alarm tới email](session-stg.md#alarm-tới-email) với `anhnv-prd`, `svp-prd-rds-storage-low`:
thư `ALARM` có URL runbook, rồi thư `OK`. Dán lại lịch sử của alarm.

(Tuỳ chọn) **Đổi một secret của env đang chạy**: như mục cùng tên của `session-stg.md`, với `aws/scripts/bootstrap.sh prd secrets`,
`aws/envs/prd/prd.auto.tfvars` (version write-only của mật khẩu Kafka, Valkey), `aws/scripts/tf.sh prd env plan|apply`, `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, tunnel mở: cùng các dòng `ok`, `FAIL` (`cluster svp-prd …`). Không broker nào restart: MSK đọc mật khẩu từ secret SCRAM,
ElastiCache từ user của nó; chỉ pod client restart (Reloader).

## Bước 17–19: diễn tập khôi phục

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: hạn 60, 75, 30 phút của bước 17, 18, 19; instance `svp-prd-pitr` cùng lớp
với nguồn là khoản lớn nhất của phần backup mỗi buổi (dưới), bảng "Mỗi buổi" ở mục "Chi phí" của [phụ lục
ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#mỗi-buổi). Bỏ chúng
không đổi bước 25.

Như `session-stg.md`, mục **17–19. Diễn tập khôi phục**, với `prd`, chạy sau các phép đã chọn của mục **Đo** (lượt k6
cuối đã xoá, không client nào ghi) và sau lượt chạy lại (f) của mục **Phép kiểm transcode**, tunnel mở:

```sh
aws/scripts/restore-drill.sh prd backup
aws/scripts/restore-drill.sh prd rds
aws/scripts/restore-drill.sh prd s3
```

Khác stg ở dữ liệu: plan `svp-prd` của Backup policy `svp-backup-prd`, vault `svp-prd`, role `svp-prd-backup`, bản copy vào `svp-prd-copy`
(retention và vault lock của prd, ADR-0067 §4); instance `svp-prd-pitr` một AZ cùng lớp với `svp-prd` (nguồn Multi-AZ, bản khôi phục không),
nên giờ của nó là khoản lớn nhất của phần backup mỗi buổi. Cùng mục tiêu RTO/RPO, cùng cách đọc dòng `FAIL`. Đọc bản copy bằng lệnh của mục
stg:

```sh
aws/scripts/preflight.sh findings prd
```

Mong ba dòng `note  svp-prd-copy: … COMPLETED … vault-key` rồi dòng `ok`, `DeleteAt` cách `CreationDate` đúng retention bản
copy của prd; chưa profile `anhnv-security-ro` thì dòng `FAIL` cuối ở profile đó là đúng, như stg. Lệnh xem log quanh T_r, khôi phục
object bằng delete marker khi restore job lỗi: như stg với `anhnv-prd`, `--context svp-prd`, bucket `svp-prd-media-<account prd>-ap-southeast-1`.
Dán bảng `restore-drill.tsv` (lệnh `column` của mục stg); số đo vào phụ lục ADR-0067 cùng số của stg.

## Kết thúc buổi

### Finding bảo mật của buổi (trước bước 20)

Loại: `lõi` (finding GuardDuty); dòng control FAILED là phần `chuẩn ngành` của mục [Control Security Hub của
buổi](session-stg.md#control-security-hub-của-buổi), có sẵn vì cờ `security_hub` của prd là `always` trong buổi.

Chỉ đọc, khi tài nguyên của buổi còn sống, cả khi buổi dừng sớm: lệnh và cách xử lý của
`session-stg.md`, mục [Finding bảo mật của buổi](session-stg.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20), cùng điều kiện
(bước (4), (5) của nền bảo mật org), với `prd`:

```sh
aws/scripts/preflight.sh findings prd
```

Script lọc theo `SVP_AWS_PRD_ACCOUNT_ID`: `findings stg` chạy ở terminal prd thì đọc finding của account stg. Mốc của diễn tập prd cũng
nằm trong `timeline.tsv` của buổi. Không chạy bước 17 thì dòng
`FAIL  no recovery point in svp-prd-copy created after …` đứng trước phần security là đúng như mong đợi, như stg.

### Gỡ, quét sót, trả cờ

Loại: `lõi`.

Theo thứ tự, mỗi bước xong mới sang bước sau:

1. **Destroy root gitops rồi root env** (bước 20–27, tunnel còn mở tới hết bước 22). Bảo vệ của prd được nhấc trước: bước 23 đọc
   `terraform state list` của `aws/envs/prd` rồi plan với `prd.tfvars` và `teardown.tfvars`, chỉ nhắm (`-target`) DB instance, ALB edge và
   bucket có trong state (đọc `prd-env-teardown-plan.txt`: chỉ `to change`, deletion protection của RDS và của ALB `svp-prd-edge` về `false`,
   `force_destroy` của bucket; cảnh báo
   "Resource targeting is in effect" của Terraform là đúng ý), bước 24 apply nó; `tf.sh prd env plan --destroy` dừng với `FAIL the protections
   of aws/envs/prd are still on` khi chưa có mốc `env-teardown-applied`. Apply của bước 24 cũng gắn lại tag `Backup`, nên bước 25
   (`restore-drill.sh prd cleanup`, mục **23–27** của `session-stg.md`) chạy sau nó: xoá `svp-prd-pitr` nếu còn, gỡ tag, chờ job, xoá recovery
   point của vault `svp-prd` đã có bản copy, ghi `backup-drained`; thiếu mốc đó thì `plan --destroy` dừng với `FAIL the backups of prd are not
   drained`. Rồi plan `-destroy` với cả hai file, không `-target`. Destroy vẫn ghi final snapshot của RDS (`skip_final_snapshot` giữ `false`) và
   giữ backup tự động. Bước 28, 29 (đóng root account) in `ok no session feature of prd …` như bước 3–5 (cùng
   điều kiện 12).

   Apply của bước 9 đỏ giữa chừng (vd thiếu quota): vẫn làm bước 23, 24, 25 trước `plan --destroy` (với `--no-cluster` khi chưa có cluster
   EKS, điều kiện ở `session-stg.md`, mục 23–27). Plan chỉ nhắm những gì đã được tạo nên không tạo thêm phần còn thiếu và không gặp lại lỗi
   cũ; state không có DB instance, ALB hay bucket nào thì bước 23 in `skip`, ghi mốc `env-teardown-applied` (không có gì để nhấc) và bước 24 in
   `skip`; bước 25 in `skip` cho phần chưa tạo.
2. **Recovery point, final snapshot và backup tự động**: đọc recovery point của buổi (lệnh đầu: vault `svp-prd` của account không còn recovery
   point nào sau bước 25, mong `0`; bản copy của buổi còn ở `svp-prd-copy`: lệnh **Đọc bản copy** của mục **Bước 17–19**, mong cùng ba dòng
   như lúc đọc sau bước 17). Snapshot `awsbackup:*` của AWS Backup không phải `manual`, không hiện ở lệnh thứ hai. Đọc final snapshot có thật
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
   group `/svp/prd/otel`, workspace AMG và tham số SSM `/svp/prd/grafana-workspace-id` của nó (cờ `managed_grafana` là
   `always` theo điều kiện 12; đổi cờ về giá trị rẻ sau buổi xoá chúng), key của
   chúng; vault `svp-prd`, role `svp-prd-backup` và key của vault; `Stack=security-baseline`:
   CMK EBS), không endpoint interface, không rule groups
   namespace của AMP, và `pending deletion` (KMS key của root
   env: RDS, MSK, alarm, Secrets của EKS; 7 ngày), exit 0; không còn dòng MSK, ElastiCache, `AmazonMSK_*`, log group `/aws/msk/svp-prd` (phép kiểm (f) của ADR-0053),
   không còn instance, launch template, instance profile, hàng đợi SQS hay rule EventBridge nào của Karpenter; không còn queue MediaConvert
   `svp-prd`, role `svp-prd-mediaconvert`, hàng đợi `svp-prd-transcode-events*`, rule `svp-prd-mediaconvert-job-state` (phép kiểm gỡ của
   ADR-0066); không còn recovery point, job AWS Backup chưa kết thúc hay instance `svp-prd-pitr` (phép kiểm gỡ của ADR-0067); không còn key
   group `svp-prd-media`, public key `svp-prd-media-*`, entry `svp/prd/media-signing` (phép kiểm gỡ của ADR-0073).
   Còn gì khác: chạy lệnh `delete:` nó in, rồi chạy lại. Gói của account rỗng (mong `[]`), cùng lượt sweep sạch này:

   ```sh
   AWS_PROFILE=anhnv-prd aws pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].[arn,planTier,status]' --output json
   ```

4. **`aws/scripts/sweep.sh mgmt`** (profile `anhnv-sso`): chỉ `Stack=bootstrap|org|security-baseline|security` (bucket state, trail,
   baseline bảo mật, detector GuardDuty của management), không hosted zone, exit 0.

5. **Trả prd về giá trị rẻ** (khi bước 3, 4 cùng exit 0): một PR ghi lại khoá `prd` của `aws/paid-features.json` như
   trước buổi (`managed_grafana`, `inspector_ecr`, `security_hub`, `config_recording` đều `off`), `infra-ok` xanh,
   merge; rồi áp theo hướng tắt: `aws/security`, `aws/baseline`, `aws/accounts/prd` (điều 3 của
   [`paid-features.md`](paid-features.md#trước-khi-bắt-đầu), plan lần hai `No changes.` ở cả ba). Rồi
   `aws/scripts/sweep.sh prd` lần nữa: exit 0, không còn workspace AMG `svp-prd` hay tham số
   `/svp/prd/grafana-workspace-id` (với `off` chúng là sót). Quên bước này thì prd giữ giá trị production cả tháng: AMG,
   Inspector, Security Hub, Config tính tiền giữa các buổi
   ([ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8).

Một lượt `sweep.sh prd` chạy trước bước 2 được phép exit khác 0 (final snapshot, backup tự động còn đó) và chỉ để xem.
**Buổi chỉ xong khi lượt `sweep.sh prd` sau bước 2 và lượt `sweep.sh mgmt` cùng exit 0, và prd đã về giá trị rẻ (bước
5).** AI nhắc tới khi người học xác nhận đủ năm bước. Buổi đã ghi truy vấn dữ liệu trước bước 20 (`chuẩn ngành`, mục
**Nền tảng managed (e) ở prd**): cùng ngày, chạy lại nó (`after-destroy.txt` của `.session/persist-prd/`) và dán `diff`;
span của account prd: retention của `aws/spans` theo bước (10) của
[`platform-setup.md`](platform-setup.md#bước-10-retention-của-awsspans). Sau 24 giờ: Cost Explorer của account prd theo
dịch vụ, so với C.

### Web ACL WAF sót

Loại: `lõi`.

Lệnh xoá web ACL (sau khi distribution đã xoá) dùng chung cho hai env: `session-stg.md`, mục
[Lệnh xoá tay theo loại](session-stg.md#lệnh-xoá-tay-theo-loại), với `AWS_PROFILE=anhnv-prd`.

Loại sót khác: `session-stg.md`, mục **Lệnh xoá tay theo loại**, với `AWS_PROFILE=anhnv-prd`.
