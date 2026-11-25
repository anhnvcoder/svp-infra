# Runbook: kiểm và đo env prd (bước 16)

← [Dựng prd](session-prd-deploy.md) · [Mục lục](README.md) · [Diễn tập khôi phục](session-prd-drills.md) →

> **Tóm tắt**
>
> - **Làm gì:** chứng minh prd chạy đúng sau khi dựng: smoke đầu-cuối, phép kiểm edge, Kafka, Valkey, nền tảng EKS và managed, transcode,
>   rồi sáu phép đo (thời gian dựng, failover RDS, drain một AZ, khởi động lại broker MSK, failover Valkey, alarm).
> - **Khi nào và bao lâu:** sau bước 15, tunnel mở. `measure.sh prd` 10 phút; mỗi phép kiểm mục con ghi dòng `Loại:` (`lõi` hay
>   `chuẩn ngành`) và hạn của nó; đường mặc định chỉ chạy `lõi`. Quá 3 giờ của buổi mà chưa đo xong thì bỏ phần đo còn lại.
> - **Phí trong lúc chạy:** phép `lõi` không tốn thêm; mỗi phép `chuẩn ngành` ghi khoản thêm ở dòng `Loại:` của nó (k6, MediaConvert của
>   seed, Inspector, OpenCost); nguồn số ở [Chi phí và giới hạn](session-prd.md#chi-phí-và-giới-hạn).

Trang này chỉ ghi phần riêng của prd; mỗi phép kiểm chạy đúng như stg thì trỏ mục của buổi stg và nêu giá trị thay (profile, context, tên
tài nguyên). **Người học chạy mọi lệnh ở đây**; AI đọc output dán lại. Output vào phụ lục của ADR tương ứng, một dòng kết luận vào mục
"Xác nhận".

## Điều kiện trước

- [ ] **Bước 1–15 xong** ([`session-prd-deploy.md`](session-prd-deploy.md)): `bootstrap.sh prd wait` in `ok`, các Application `Synced`
  `Healthy`.
- [ ] **Tunnel tới API mở** ([Tunnel tới API](session-prd-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11)), giữ tới hết bước 22.
- [ ] **Terminal của buổi** theo [Mở terminal](session-prd.md#mở-terminal): `SVP_SESSION_DIR`, biến account.
- [ ] **Hàm và biến dùng chung** của các phép kiểm nền tảng managed và Đo (`E`, `amp_get`, `promql`…): định nghĩa ở mục
  [Phép kiểm nền tảng managed](session-stg-check-managed.md#phép-kiểm-nền-tảng-managed) của buổi stg; chạy khối đó với `E=prd`
  trước các mục dùng nó.

## Mở terminal

Dùng khối của [Mở terminal ở trang chủ buổi prd](session-prd.md#mở-terminal); mọi lệnh `AWS_PROFILE=anhnv-prd` và `--context svp-prd`
chạy từ gốc repo này (`infra/`), tunnel còn mở.

## Bước 16: smoke, edge, commit status

`measure.sh prd` chỉ chạy smoke (`make eks-smoke CONTEXT=svp-prd DOMAIN=<domain>`), không seed, không thang k6 (số đo
của prd là mục **Đo** dưới). Phép kiểm sau smoke ở các mục con, mỗi mục một dòng `Loại:`. Output vào phụ lục của ADR
tương ứng, một dòng kết luận vào mục "Xác nhận".

```sh
aws/scripts/measure.sh prd
```

- **Mong đợi:** dòng `ok smoke passed …`.

### Smoke, phát video và alarm

Loại: `lõi`. Smoke là bước 16 (dòng `ok smoke passed …`). Sau smoke: mục [Phát video và CORS của
media](session-stg-check-edge-media.md#phát-video-và-cors-của-media) của buổi stg với `AWS_PROFILE=anhnv-prd` (playlist là của
video smoke vừa tải lên; mong `access-control-allow-origin: https://<domain>` của policy `svp-prd-media`, không `*`), và phép (f)
của mục [Alarm tới email](session-stg-check-security.md#alarm-tới-email) là mục **Đo 6** dưới.

### Edge, Kafka, Valkey và nền tảng EKS

Loại: `chuẩn ngành`, không cần đổi cờ (mọi phép chỉ đọc hay gọi API qua HTTPS). Thêm: request của edge premium và phép
kiểm edge tính pay-as-you-go như request khác (bảng "Thêm mỗi buổi" ở phụ lục ADR-0061 §13), một plan của root env (hạn
của bước 8); ADR không có số thời gian cho phần còn lại.

Phép kiểm edge (a)–(f) theo mục [Phép kiểm edge](session-stg-check-edge-media.md#phép-kiểm-edge) với `anhnv-prd`,
`$SVP_AWS_PRD_ACCOUNT_ID`, `svp-prd-edge`, đích `svp-cloudfront-prd` (media có HSTS, nosniff; log CloudFront có cả media, chưa có
trong buổi thì ghi `chờ giao` và kiểm lại sau buổi như phép (e) đó); hai lượt `make eks-premium-check` của mục [Phép kiểm edge
premium](session-stg-check-edge-media.md#phép-kiểm-edge-premium) với `CONTEXT=svp-prd` và một lượt **Xoay khoá ký** của
[`media-signing-keys.md`](media-signing-keys.md#xoay-khoá-ký) với `prd`; phép kiểm (a)–(e) của ADR-0053 theo mục [Kafka và Valkey
managed](session-stg-check-managed.md#kafka-và-valkey-managed), với `anhnv-prd`, `--context svp-prd`, tên `svp-prd` (mong
`kafka.m7g.large`, `3` broker; replication group `2` node); phép kiểm (a)–(e) của mục [Nền tảng EKS và TLS
Postgres](session-stg-check-platform.md#nền-tảng-eks-và-tls-postgres) với `anhnv-prd`, `--context svp-prd`, `svp-prd` (mong ba
node `nodegroup=system` ở ba zone, node Karpenter `capacity-type=on-demand`, pod Kyverno trên ba zone, `db.m7g.large`, trần
storage của `prd.tfvars`); và plan lần hai sau apply, phải cho `No changes` (`ok plan text in …: No changes.`; mục [Plan lần hai của root
env](session-stg-check-edge-media.md#plan-lần-hai-của-root-env) với `prd`):

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

### Deploy qua GitOps ở prd

Loại: `lõi`. Thêm: không gì ngoài cổng promote đã chạy trước bước 1.

prd không merge bản mới giữa buổi: đường phát hành của prd là [Cổng promote prd](session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền)
(CI job `promote-prd`, PR `bot/promote-prd`, Code Owner merge), chạy trước bước 1. Phép này kiểm phần cuối của đường đó sau bước 15:
Argo CD đã sync bộ của PR, pod chạy đúng digest của `envs/prd/images/`. Lệnh của bước 4 trong mục [Deploy qua
GitOps](session-stg-check-release.md#deploy-qua-gitops) của buổi stg, với `AWS_PROFILE=anhnv-prd`, `--context svp-prd`, `svc=feed-service`
và digest đọc ở `main` của `svp-gitops`:

```sh
svc=feed-service; git -C ../gitops fetch origin
want=$(git -C ../gitops show "origin/main:envs/prd/images/${svc}.yaml" | sed -n 's/^ *digest: *"\(sha256:[0-9a-f]*\)"/\1/p'); echo "$want"
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io "$svc" \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp get pods -l "app.kubernetes.io/name=$svc" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].imageID}{"\n"}{end}'
```

Mong `Synced` `Healthy`, mỗi pod một `imageID` kết thúc bằng `want`; cùng mục [Commit status argocd/prd](#commit-status-argocdprd)
(`success`) và smoke của bước 16. Dán lại cả ba output.

### Migration của release ở prd

Loại: `lõi`.

Mục [Migration của release](session-stg-check-release.md#migration-của-release) của buổi stg với `AWS_PROFILE=anhnv-prd`,
`--context svp-prd`, log group `/svp/prd/otel`, sau bước 15. Mong như stg: mỗi release hai bản ghi của runner (`lock_timeout`
`2s`), bốn Application `Synced` `Healthy`; thiếu bản ghi thì ghi lại, không sync lại.

### Xác thực qua CloudFront ở prd

Loại: `lõi`; (d) giữ một trang web mở hơn 15 phút.

Mục [Xác thực qua CloudFront](session-stg-check-release.md#xác-thực-qua-cloudfront) của buổi stg, (a)–(d), với `api` từ
`cluster-values.json` của buổi prd (CloudFront `svp-prd-api`), `AWS_PROFILE=anhnv-prd`, `--context svp-prd` ở lệnh
port-forward. Mong như stg. `429` của `register`: chờ `Retry-After`, không xoá khoá nào ở Valkey của prd. User thử của
(c) nằm trong database prd tới khi env gỡ cuối buổi.

### Trải zone và chạy thử DLQ ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; khi commit `gitopsRevision` của `envs/prd/charts.yaml` có `dlq-replay` trong
`argocd/apps/components.json` và `zoneSpread` ở `platforms/eks`. Thêm: như stg, lệnh chỉ đọc và bốn lượt `--dry-run`;
ADR không có số thời gian.

Mục [Trải zone và chạy thử DLQ](session-stg-check-platform.md#trải-zone-và-chạy-thử-dlq) của buổi stg với `anhnv-prd`,
`--context svp-prd`; điều kiện đọc ở commit `gitopsRevision` (dòng `ok envs/prd/charts.yaml: …` của cổng promote) thay
cho `origin/main`. prd trải pod trên ba AZ: mong release nhiều pod (`gateway`, `web`, `user-service`, `video-service`,
`engagement-service`, `feed-service`…) ở `min(số pod, 3)` zone, `spread=DoNotSchedule/3`. DLQ của prd có record: chỉ
chạy thử ở đây, phát lại thật theo `kafka-dlq-records.md` khi người trực quyết.

### Service mesh ở prd

Loại: `lõi`.

Mục [Service mesh](session-stg-check-platform.md#service-mesh) của buổi stg với `AWS_PROFILE=anhnv-prd`, `--context svp-prd`,
sau bước 15. Mong như stg; node của nhóm hệ thống và node Karpenter (on-demand) trên ba zone, DaemonSet `istio-cni-node`,
`ztunnel` mỗi node một pod. Khác mong đợi: không chạy mục **Đo**, theo runbook `mesh-traffic-denied.md` của mục stg.

### Service mesh ở prd: danh tính lạ bị từ chối

Loại: `chuẩn ngành`, không cần đổi cờ; tạo rồi xoá một ServiceAccount và hai pod trong `svp`. Thêm: như stg, khoảng 3
phút, chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Khối của mục [Service mesh: danh tính lạ bị từ chối](session-stg-check-platform.md#service-mesh-danh-tính-lạ-bị-từ-chối) với
`anhnv-prd`, `--context svp-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`; cùng mong đợi, lệnh cuối không còn tài nguyên nào.

### Bảo vệ của account ở prd

Loại: `lõi`; chạy ≥ 15 phút sau bước 15.

Mục [Bảo vệ của account: GuardDuty, flow log, log WAF, quét
malware](session-stg-check-security.md#bảo-vệ-của-account-guardduty-flow-log-log-waf-quét-malware) của buổi stg, (a)–(d), với
`anhnv-prd`, `--context svp-prd`, `A=$SVP_AWS_PRD_ACCOUNT_ID`, cluster `svp-prd`, web ACL `svp-prd-media` trong bộ lọc key của
(c). Mong như stg: coverage `HEALTHY` khi DaemonSet có một pod mỗi node trên ba zone; bucket ở (d) là
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
org=$(AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 ls "s3://$b/AWSLogs/" --region ap-southeast-1 | awk '$2 ~ /^o-/ { sub("/", "", $2); print $2 }')
AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3api list-objects-v2 --bucket "$b" --region ap-southeast-1 \
  --prefix "AWSLogs/$org/$P/CloudTrail/ap-southeast-1/$(date -u +%Y/%m/%d)/" --query 'Contents[].[Key,LastModified]' --output json |
  jq -r --arg s "$since" '(. // [])[] | select(.[1] >= $s) | .[0]' |
  while read -r k; do AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 cp "s3://$b/$k" - --region ap-southeast-1 | gunzip -c; done |
  jq -r --arg a "$P" '.Records[] | select(.eventCategory == "Data" and .eventSource == "s3.amazonaws.com")
    | "\(.eventName) \(.requestParameters.bucketName | sub($a; "<account>"))"' | sort | uniq -c
```

Mong, mỗi dòng một số đếm: `PostObject svp-prd-uploads-<account>-ap-southeast-1` (video smoke tải lên bằng form presigned POST), `GetObject
svp-prd-uploads-…` (MediaConvert, quét malware đọc), `PutObject svp-prd-media-<account>-ap-southeast-1` (output của
transcode); không dòng `GetObject svp-prd-media-…` (trail chỉ ghi phần ghi của `media`). Rỗng: đọc lại sau 10 phút; ngay
sau 00:00 UTC đổi ngày trong `--prefix` về ngày trước. Vẫn thiếu một trong ba: dán output và selector của trail `svp-audit`
(`aws/org`) cho AI:

```sh
AWS_PROFILE=anhnv-sso aws --no-cli-pager cloudtrail get-event-selectors --trail-name svp-audit --region ap-southeast-1
```

## Phép kiểm nền tảng managed

Sau smoke, mục [Phép kiểm nền tảng managed](session-stg-check-managed.md#phép-kiểm-nền-tảng-managed) của buổi stg với `E=prd` ở
khối dùng chung, `AWS_PROFILE=anhnv-prd`, `--context svp-prd`, `svp-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`, `aws/accounts/prd`, log group
`/svp/prd/otel`, cluster `svp-prd` trong truy vấn. Khối dùng chung là `lõi` (luật cảnh báo cần nó); mỗi phép một mục con có dòng
`Loại:`. Dán output của từng phép như mục của stg.

### Nền tảng managed (a), (b), (c) ở prd

Loại: `chuẩn ngành`, không cần đổi cờ: Inspector của (a) và AMG của (c) có sẵn vì cờ của prd là `always` trong buổi. Thêm:
Inspector tới $9 khi digest bên thứ ba mới (dòng `inspector_ecr` của [phụ lục ADR-0071,
Cờ](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#cờ)), đã gồm trong chi phí buổi
của [ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §8; phần còn lại
chỉ đọc.

- (a) image: như stg; image phát hành ở ECR prd chỉ tới qua `promote-prd` của cổng trên, nên mọi pod của `svp` có host
  ECR của account prd là bằng chứng đường promote chép đủ; `cosign verify` cùng identity (nguồn của bản phát hành không
  đổi). Đoạn Inspector theo cờ `always`.
- (b) mạng: mỗi endpoint interface `available True 3` (ENI ở mọi AZ của prd, ADR-0064 §4).
- (c) telemetry: như stg, khung là lúc các phép của mục **Đo**; Explore, dashboard trên AMG `svp-prd`.

### Nền tảng managed (d) ở prd: luật cảnh báo

Loại: `lõi`. Chỉ phần luật, lệnh và bẫy (`409` của ACK) như [mục (d) của
stg](session-stg-check-managed.md#nền-tảng-managed-d-luật-cảnh-báo-trên-amp): hai namespace `ACTIVE`, Alertmanager `ACTIVE`, chu kỳ `30`
như stg ([ADR-0086](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0086-amp-rule-interval-prd.md)). prd chạy commit
`svp-gitops` mà stg đã chạy (`gitopsRevision` ghim), nên không PR annotation nào tới được nó: canary, AnalysisRun thủ công và cảnh báo
`page` qua AMP được kiểm ở buổi stg đã bật các phép đó (`chuẩn ngành`), cùng chart; alarm `page` của prd là mục **Đo 6**.

### Nền tảng managed (e) ở prd: dữ liệu còn sau destroy

Loại: `chuẩn ngành`, không cần đổi cờ. Thêm: khoảng ghi ít nhất 10 phút trước bước 20, truy vấn chạy lại sau bước 31.

Như stg, thư mục `.session/persist-prd/`; ghi trước bước 20 (sau mục **Đo**), chạy lại sau bước 31 cùng ngày (mục **Kết
thúc buổi**). Lượt so ở buổi kế chỉ có ở stg: prd không có buổi kế.

### Độ trễ mesh ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; cần k6 của mục **Đo 4** đang giữ tải. Thêm: truy vấn AMP và `kubectl top`, chỉ
đọc; chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Khối của mục [Độ trễ mesh khi giữ tải](session-stg-check-platform.md#độ-trễ-mesh-khi-giữ-tải) với `E=prd` ở khối dùng chung,
`anhnv-prd`, `--context svp-prd`, trong lúc k6 của **Đo 4** giữ tải: sau 2 phút lên tải, trước lệnh `reboot-broker` (số đo lúc
broker còn đủ). Mong và cách dán như stg; prd chạy service trên node on-demand ở ba zone.

### Uptime ở prd

Loại: `lõi`; chạy ≥ 30 phút sau mốc `edge-healthy`.

Mục [Uptime: probe và cảnh báo](session-stg-check-edge-media.md#uptime-probe-và-cảnh-báo) với `E=prd` ở khối dùng chung, `anhnv-prd`,
`--context svp-prd`; mong như stg; prd có ba zone nhưng hai pod blackbox trải zone bằng `ScheduleAnyway`: cùng một zone vẫn hợp lệ (ghi
zone), lỗi thật là pod `Pending`, `CrashLoopBackOff` hay chỉ còn một pod. Thư `UptimeProbesAbsent` đọc sau bước 4 của
mục **Kết thúc buổi**, như stg đọc sau bước 31.

### Chi phí theo namespace ở prd

Loại: `chuẩn ngành`, không cần đổi cờ: dashboard `svp-cost`, `svp-uptime` trên AMG `svp-prd` có vì cờ của prd là
`always` trong buổi. Thêm: OpenCost ~$0,08–0,16 mỗi buổi prd ([phụ lục ADR-0074
§11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0074-cost-uptime.md#mỗi-buổi-4-giờ-mỗi-env)),
đã gồm trong chi phí buổi; truy vấn và port-forward chỉ đọc.

Mục [Chi phí theo namespace](session-stg-check-platform.md#chi-phí-theo-namespace) với `E=prd` ở khối dùng chung, `anhnv-prd`, `--context
svp-prd`, cả đoạn dashboard. Khác stg: node prd on-demand nên số khớp giá niêm yết, không là trần; OpenCost không gọi
giá Spot.

### Canary gRPC theo request ở prd

Loại: `chuẩn ngành`, không cần đổi cờ; khi buổi prd phát hành bản mới của một release gRPC có `canary: true` (PR
`bot/promote-prd` của `svp-gitops` merge giữa buổi) trong lúc k6 của mục **Đo 4** giữ tải. Thêm: như stg, một canary
khoảng 3–4 phút; chi phí của mesh chưa có số (phụ lục ADR-0075, Số đo).

Mục [Canary gRPC theo request](session-stg-check-platform.md#canary-grpc-theo-request) với `E=prd` ở khối dùng
chung, `anhnv-prd`, `--context svp-prd`, sau 2 phút lên tải của **Đo 4** và trước lệnh `reboot-broker`. Mong như stg: waypoint chia
theo trọng số của route, không theo số replica, nên phần lời gọi của pod canary gần bằng trọng số của bước. Buổi không phát hành bản mới
nào của release gRPC: ghi `không có canary`.

## Phép kiểm transcode

Loại: `lõi`.

Sau smoke, (a) và (f) của mục [Phép kiểm transcode](session-stg-check-edge-media.md#phép-kiểm-transcode) với
`AWS_PROFILE=anhnv-prd`, `--context svp-prd`, queue `svp-prd`, hàng đợi `svp-prd-transcode-events`,
`svp-prd-transcode-events-dlq`, alarm `svp-prd-transcode-events-dlq` (không cần clip; của khối biến và hàm dùng chung chỉ cần hai
dòng đầu, `values` và `media`):

- (a) smoke đi qua MediaConvert: Deployment `media-worker` chạy `["mediaconvert"]`; bảng đếm chỉ có `record-job COMPLETE`, một cho
  video smoke (khi đọc lại sau các diễn tập: một cho mỗi video smoke và `eks-seed` của mục **Đo**), cùng các dòng `orphan-job`
  được chấp nhận như ở stg (job lạc không quyết kết quả).
- (f) hai hàng đợi về hai số `0`, alarm DLQ `OK` hay `INSUFFICIENT_DATA`, log của bridge không có dòng bỏ message. Chạy lại sau
  các diễn tập của mục **Đo** (failover, khởi động lại broker không được làm mất event của job), trước bước 17.

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
AWS_PROFILE=anhnv-prd aws --no-cli-pager rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
  --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager rds reboot-db-instance --db-instance-identifier svp-prd --force-failover --region ap-southeast-1 \
  --query 'DBInstance.DBInstanceStatus' --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager rds wait db-instance-available --db-instance-identifier svp-prd --region ap-southeast-1
AWS_PROFILE=anhnv-prd aws --no-cli-pager rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
  --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager rds describe-events --source-type db-instance --source-identifier svp-prd --duration 60 --region ap-southeast-1 \
  --query 'Events[].[Date,Message]' --output text
AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
```

Dán lại: hai dòng AZ, các sự kiện `failover` (bắt đầu, xong), dòng cuối của smoke. **Thời gian nối lại** của service (số
đo cho mục "Xem lại khi" của **Proxy kết nối**, ADR-0057): từ sự kiện failover bắt đầu tới request lỗi cuối của
`user-service`, `video-service`, `engagement-service`, `feed-service` ở dashboard SLO (AMG `svp-prd` như mục
[Dashboard SLO khi giữ tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải) ở bước 16 của buổi stg, panel lỗi theo route),
ghi giây. Alarm `rds-*` nào đổi trạng thái trong lúc đó: đọc lịch sử,
đối chiếu thư tới `alarm_email`:

```sh
AWS_PROFILE=anhnv-prd aws --no-cli-pager cloudwatch describe-alarm-history --history-item-type StateUpdate \
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
CloudFront, WAF: mục [Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6) của buổi stg;
view ghi vào `engagement.views.v1`), cộng một producer đếm
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
arn=$(AWS_PROFILE=anhnv-prd aws --no-cli-pager kafka list-clusters-v2 --cluster-name-filter svp-prd --region ap-southeast-1 --query 'ClusterInfoList[0].ClusterArn' --output text)
AWS_PROFILE=anhnv-prd aws --no-cli-pager kafka list-nodes --cluster-arn "$arn" --region ap-southeast-1 --query 'NodeInfoList[].BrokerNodeInfo.[BrokerId,ClientSubnet]' --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager kafka reboot-broker --cluster-arn "$arn" --broker-ids 1 --region ap-southeast-1 --query ClusterOperationArn --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager kafka describe-cluster-v2 --cluster-arn "$arn" --region ap-southeast-1 --query ClusterInfo.State --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager kafka describe-cluster-operation --cluster-operation-arn <ARN của reboot-broker> --region ap-southeast-1 \
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
AWS_PROFILE=anhnv-prd aws --no-cli-pager elasticache describe-replication-groups --replication-group-id svp-prd --region ap-southeast-1 --output text \
  --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].[CacheClusterId,PreferredAvailabilityZone,CurrentRole]'
AWS_PROFILE=anhnv-prd aws --no-cli-pager elasticache test-failover --replication-group-id svp-prd --node-group-id 0001 --region ap-southeast-1 \
  --query ReplicationGroup.Status --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager elasticache describe-events --source-type replication-group --source-identifier svp-prd --duration 30 \
  --region ap-southeast-1 --query 'Events[].[Date,Message]' --output text
AWS_PROFILE=anhnv-prd aws --no-cli-pager elasticache describe-replication-groups --replication-group-id svp-prd --region ap-southeast-1 --output text \
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

Phép (f) của mục [Alarm tới email](session-stg-check-security.md#alarm-tới-email) với `anhnv-prd`, `svp-prd-rds-storage-low`: thư
`ALARM` có URL runbook, rồi thư `OK`. Dán lại lịch sử của alarm.

(Tuỳ chọn) **Đổi một secret của env đang chạy**: như mục cùng tên của
[trang chủ buổi stg](session-stg.md#đổi-một-secret-của-env-đang-chạy), với `aws/scripts/bootstrap.sh prd secrets`,
`aws/envs/prd/prd.auto.tfvars` (version write-only của mật khẩu Kafka, Valkey), `aws/scripts/tf.sh prd env plan|apply`,
`AWS_PROFILE=anhnv-prd`, `--context svp-prd`, tunnel mở: cùng các dòng `ok`, `FAIL` (`cluster svp-prd …`). Không broker nào restart: MSK
đọc mật khẩu từ secret SCRAM, ElastiCache từ user của nó; chỉ pod client restart (Reloader).

## Gỡ

Mỗi phép kiểm ghi cách xoá thứ nó tạo ngay trong mục của nó (Job k6 bằng `run.sh … delete`, topic `svp-durability-check`, ServiceAccount
và pod thử của mesh); user thử của xác thực qua CloudFront nằm trong database prd tới khi env gỡ. Phần còn lại gỡ cùng env ở bước
20–31: [Kết thúc buổi](session-prd.md#kết-thúc-buổi). Ghi truy vấn dữ liệu của
[Nền tảng managed (e)](#nền-tảng-managed-e-ở-prd-dữ-liệu-còn-sau-destroy) trước bước 20.

## Khi một bước đỏ

- **`FAIL no tunnel …`:** tunnel chưa mở hay đã rớt; mở lại ([Tunnel tới
API](session-prd-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11))
  rồi chạy lại đúng bước đó.
- **Smoke đỏ:** dán output; chưa chạy các phép `chuẩn ngành` khi smoke chưa đạt.
- **Quá 3 giờ của buổi mà chưa đo xong:** bỏ phần đo còn lại, sang [Kết thúc buổi](session-prd.md#kết-thúc-buổi).
- **Phép kiểm chạy như stg và đỏ:** đọc mục tương ứng của các trang kiểm của buổi stg
  ([release](session-stg-check-release.md), [platform](session-stg-check-platform.md),
  [security](session-stg-check-security.md), [edge-media](session-stg-check-edge-media.md),
  [managed](session-stg-check-managed.md)) cho cách đọc lỗi, với giá trị của prd.
