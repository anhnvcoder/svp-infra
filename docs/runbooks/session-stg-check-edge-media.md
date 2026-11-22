# Runbook: phép kiểm edge và media của buổi stg (bước 16)

← [Phép kiểm bảo mật](session-stg-check-security.md) · [Mục lục](README.md) · [Phép kiểm managed](session-stg-check-managed.md) →

> **Tóm tắt**
>
> - **Làm gì:** chứng minh đường vào và media: gói Free của media, phát video và CORS, phép kiểm edge và edge premium (khoá ký media),
>   uptime (probe và cảnh báo), transcode bằng MediaConvert (đo hai đường, header, hàng đợi rỗng). `lõi`: phát video và CORS, uptime,
>   transcode (a) và (f); `chuẩn ngành`: gói Free, edge, edge premium, transcode (b)–(e). Không phép nào cần cờ chi phí.
> - **Khi nào và bao lâu:** sau bước 15, tunnel mở; uptime chạy ít nhất 30 phút sau mốc `edge-healthy`; clip của phép transcode sinh
>   trong lúc chờ bước 9; edge premium chờ dưới thời lượng clip cộng 20 phút khi chạy lượt `WAIT_EXPIRY=1`.
> - **Phí trong lúc chạy:** request edge nằm trong phần edge đã tính của buổi; job MediaConvert của transcode (b)–(e) là khoản thêm ghi ở
>   dòng `Loại:` của mục đó ([Giới hạn](session-stg.md#giới-hạn)).

Thiết kế: [ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md) (gói CloudFront
flat-rate Free, web ACL WAF); [ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md)
(edge: CloudFront trước web, API, media, VPC origin tới ALB internal, ba web ACL, cert ACM, log CloudFront, DNS của buổi);
[ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md) (transcode bằng AWS Elemental
MediaConvert: queue, role, rule EventBridge, SQS và DLQ của root env, endpoint `mediaconvert`).

## Điều kiện trước

- [ ] **Bước 1–15 xong**: apply root env và root gitops thành công, `bootstrap.sh stg wait` (bước 15) báo mọi Application `Healthy`
  ([`session-stg-deploy.md`](session-stg-deploy.md#15-chờ-argo-cd)).
- [ ] **Tunnel tới API còn mở** ([Tunnel tới API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11), giữ tới hết bước 22).
- [ ] **Terminal của buổi** ([Mở terminal](session-stg.md#mở-terminal)): cùng `SVP_SESSION_DIR` với các bước trước.
- [ ] **Hàm dùng chung đã nạp** ([Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo)): `amp_get`, `promql`, `insights`
  nằm ở trang chủ, chạy khối đó một lần trong terminal (mở lại terminal thì chạy lại).
- [ ] **Edge và khoá ký media sẵn sàng**: bước 7, 10 (khoá ký slot `a` đã kích hoạt), mốc `edge-healthy` trong `timeline.tsv`; mục
  Uptime chạy ít nhất 30 phút sau mốc đó.
- [ ] **Clip của phép transcode (b)–(e) đã sinh**, chỉ khi buổi chạy các phép đó (lệnh ở mục
  [Transcode (b)–(e)](#transcode-be-đo-hai-đường-header-ff-9-lớp-cắt), chạy trong lúc chờ bước 9, vài phút CPU); máy có `ffmpeg` (với
  `libx264`), `ffprobe`, `python3`.

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ (mở lại giữa buổi: cùng mục đó, với
`SVP_SESSION_DIR` là thư mục của buổi đang dở). Lệnh chạy từ gốc repo (`infra/`).
Trang này cần `SVP_SESSION_DIR` và ba biến `SVP_AWS_{STG,PRD,LOG}_ACCOUNT_ID`.

## Gói Free của media

Loại: `chuẩn ngành`, không cần cờ. Thêm: ba lệnh đọc và một plan của root env (hạn của bước 8 trong bảng Thứ tự).

Hai phép tay sau smoke, (c) ở đây và (d) ở mục dưới, của ADR-0052; lệnh và output có thời điểm UTC vào phụ lục, một dòng kết luận vào mục
"Xác nhận" của [ADR-0052](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0052-cloudfront-flat-rate-free.md#xác-nhận). Buổi
prd chạy đúng các lệnh này với `anhnv-prd`, `prd`.

(c) Gói đã có hiệu lực trên đúng hai tài nguyên, rồi plan lần hai không còn gì để đổi:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager list-subscriptions --region us-east-1 --query 'subscriptionSummaries[].arn' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager get-subscription --arn <arn trên> --region us-east-1 --query '[subscription.status,subscription.planTier]' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager pricing-plan-manager get-subscription --arn <arn trên> --region us-east-1 --query 'subscription.resourceArns' --output json
aws/scripts/tf.sh stg env plan
```

Mong một ARN; `ACTIVE FREE`; hai ARN là distribution media (`arn:aws:cloudfront::<12 số>:distribution/<E…>`) và web ACL
(`arn:aws:wafv2:us-east-1:<12 số>:global/webacl/svp-stg-media/<id>`): AWS nhận giá trị enum, số luật của web ACL và alias `media.<domain>`.
Plan lần hai (sau apply, `aws/envs/stg`) phải cho `No changes`: dòng `ok plan text in …: No changes.` (AWS không đổi gì trên distribution
khi gói có hiệu lực, `price_class` khớp). Nó ghi đè `stg-env-plan.txt` của bước 8 và để lại `stg.tfplan` không thay đổi gì, không cần apply.
Có `change`: không apply, dán file text cho AI. `PENDING_APPROVAL`, `SYNC_IN_PROGRESS`: đọc lại sau vài phút; `FAILED`: dán output cho AI.

## Phát video và CORS của media

Loại: `lõi`.

(d) CloudFront trả header CORS của policy managed `Managed-SimpleCORS` cho playlist của một video (của smoke, hay đã
seed), rồi trình duyệt phát video; ghi như mục trên:

```sh
values=$SVP_SESSION_DIR/cluster-values.json
key=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-objects-v2 --bucket "$(jq -r .mediaBucket "$values")" --prefix media/ --region ap-southeast-1 \
  --query "Contents[?ends_with(Key, 'master.m3u8')].Key | [0]" --output text)
curl -sI -H "Origin: https://$(jq -r .domain "$values")" "https://$(jq -r .mediaDomain "$values")/$key" | grep -i -E '^(HTTP|access-control-allow-origin)'
```

Mong `HTTP/2 200` và `access-control-allow-origin: *`; rồi mở `https://<domain>` trên trình duyệt, đăng nhập và phát một video của feed.
Thiếu header hay video không phát: dán output và lỗi ở console của trình duyệt cho AI.

## Phép kiểm edge

Loại: `chuẩn ngành`, không cần cờ. Thêm: request đi trong phần edge đã tính của buổi (bảng "Thêm mỗi buổi" ở phụ lục
ADR-0061 §13), chờ hai phút cho span ở (d), năm phút cho log ở (e).

Phép kiểm của mục "Xác nhận" của
[ADR-0061](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0061-edge-cloudfront-waf-acm.md#xác-nhận), sau smoke; lệnh và
output có thời điểm UTC vào một file của `$SVP_SESSION_DIR`, một dòng kết luận mỗi env vào "Xác nhận". Buổi prd chạy đúng các lệnh này với
`anhnv-prd`, `$SVP_AWS_PRD_ACCOUNT_ID`, tên `svp-prd`. `curl -4` đi IPv4, để IP so ở (d) là một địa chỉ. Tên của buổi đọc từ
`cluster-values.json`:

```sh
values=$SVP_SESSION_DIR/cluster-values.json
d=$(jq -r .domain "$values"); m=$(jq -r .mediaDomain "$values")
# route công khai, không token; id không có nên 404
api="https://api.$d/public/videos/00000000-0000-4000-8000-000000000000"
```

(a) Header, cert ACM đúng tên, TLS ≥ 1.2 của ba tên (`key` là playlist mà phép (d) của mục [Gói Free của media](#gói-free-của-media) vừa
đọc):

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
DENY`, `referrer-policy: strict-origin-when-cross-origin` (ở web, header nào web đã tự đặt thì giữ giá trị của web); api thêm
`content-security-policy: default-src 'none'; frame-ancestors 'none'` và `HTTP/2 404`. Media của stg (gói Free, `Managed-SimpleCORS`) chỉ
có `HTTP/2 200`, không HSTS, nosniff (khác biệt stg/prd của ADR-0061); media của prd (policy `svp-prd-media`) có HSTS và nosniff. Mỗi tên:
`subject` là đúng tên đó, `issuer` của Amazon, đúng một `DNS:` là tên đó; `TLS 1.1: exit` khác 0 (CloudFront từ chối dưới TLS 1.2).

(b) ALB edge không có tên công khai: scheme `internal`, tên DNS chỉ ra IP private trong CIDR của VPC:

```sh
lb=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager elbv2 describe-load-balancers --names svp-stg-edge --region ap-southeast-1 \
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
limit theo IP dùng), nên phép này đọc span ở log group `aws/spans` (Transaction Search của X-Ray) bằng CloudWatch Logs Insights, 15 phút
gần nhất, hai truy vấn (hai phút sau ba request, để span đã tới). Hàm `insights` nằm ở khối biến và hàm dùng chung của mục [Hàm dùng chung
của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo): chạy khối đó trước, một lần trong terminal (buổi prd với `E=prd`):

```sh
for f in "= \"$ip\"" 'in ["203.0.113.7", "198.51.100.7"]'; do
  echo "== client.address $f"
  insights aws/spans "$(( $(date +%s) - 900 ))" "$(date +%s)" \
    "filter \`attributes.client.address\` $f | stats count(*) as spans, count_distinct(traceId) as traces" || echo "query failed"
done
```

Mong truy vấn đầu có ít nhất ba trace ở thời điểm ba request, truy vấn sau không dòng nào (không trace nào): CloudFront đè
`CloudFront-Viewer-Address` viewer tự gửi, gateway không đọc `X-Forwarded-For`. Truy vấn sau có trace: dừng buổi, dán output cho AI (mục
"Xem lại khi" của ADR-0061). Truy vấn đầu cũng rỗng: span chưa tới X-Ray (mục [Nền tảng managed
(c)](session-stg-check-managed.md#nền-tảng-managed-c-telemetry)), dán output. Dòng `query failed` là truy vấn hỏng, không phải kết quả
rỗng: dán dòng lỗi ngay trên nó (lỗi của `aws`, như phiên SSO hết hạn, hay dòng `insights:`).

(e) Log mới ở bucket log CloudFront và bucket log WAF của account Log Archive (năm phút sau các request trên; profile `anhnv-log-ro` của
bước (4) của [`org-security-setup.md`](org-security-setup.md#bước-4-awsorg-đủ)):

```sh
L=$SVP_AWS_LOG_ACCOUNT_ID A=$SVP_AWS_STG_ACCOUNT_ID
AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 ls "s3://svp-cloudfront-$L-us-east-1/$A/" --recursive --region us-east-1 |
  tail -n 3 | sed "s/$A/<account>/g"
AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 ls "s3://aws-waf-logs-svp-$L-us-east-1/AWSLogs/$A/WAFLogs/" --recursive --region us-east-1 |
  tail -n 3 | sed "s/$A/<account>/g"
```

Mong ở mỗi bucket object có thời điểm của buổi: log CloudFront (Parquet) của `svp-stg-web`, `svp-stg-api` (media của stg trong gói Free
không có access log; prd có cả media), log WAF của các web ACL. WAF giao file mỗi năm phút: bucket WAF rỗng sau năm phút nữa là lỗi, dán
output cho AI.

CloudFront giao log chậm hơn: thường trong một giờ sau request, nhưng chỉ giao đều khoảng bốn giờ sau khi bật log (buổi tạo lại
distribution và delivery), có phần trễ tới 24 giờ ([CloudFront: Standard logging
reference](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logs-reference.html)), nên bucket CloudFront rỗng
trong buổi chưa phải lỗi. Khi đó kiểm delivery của account env trỏ đúng đích:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager logs describe-deliveries --region us-east-1 \
  --query 'deliveries[].[deliverySourceName,deliveryDestinationArn]' --output text | sed "s/$L/<log>/g"
```

Mong mỗi distribution có log (`svp-stg-web`, `svp-stg-api`; prd thêm `svp-prd-media`) một dòng tới
`arn:aws:logs:us-east-1:<log>:delivery-destination:svp-cloudfront-stg`. Thiếu dòng hay đích khác là lỗi cấu hình: dán output cho AI. Đủ
dòng: ghi `chờ giao` cùng thời điểm UTC của request cuối vào file phép kiểm, đi tiếp buổi, chạy lại khối `aws s3 ls` trên cuối buổi và sau
buổi (chỉ đọc bucket của Log Archive, không cần env còn dựng). Có object thì ghi kết luận; bốn giờ sau request cuối vẫn rỗng thì dán cả
hai output cho AI.

(f) DNSSEC của zone prd và `CAA` của zone env:

```sh
dig +dnssec SOA aws.<domain> @1.1.1.1 | grep -E '^;; (flags|->>HEADER)'
dig +short CAA "$d" @1.1.1.1 | sort
```

Mong `status: NOERROR` và cờ `ad`; tám dòng `0 issue`, `0 issuewild` cho bốn CA của Amazon. Không cờ `ad`: [`edge-setup.md`](edge-setup.md),
bước (3).

(g) Plan lần hai `No changes`: phép (c) của mục [Gói Free của media](#gói-free-của-media) (prd: bước 16 của `session-prd.md`). (h) Sau
destroy, `sweep.sh stg` sạch: bước 30.

## Phép kiểm edge premium

Loại: `chuẩn ngành`, không cần cờ. Thêm: lượt `WAIT_EXPIRY=1` chờ dưới thời lượng clip cộng 20 phút; lượt **Xoay khoá
ký** chạy lại `bootstrap.sh stg secrets` (hạn của bước 11).

Phép kiểm của mục "Xác nhận" của
[ADR-0073](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0073-premium-playback.md#xác-nhận), sau smoke (smoke đã có luồng
premium); output có thời điểm UTC vào phụ lục của ADR, một dòng kết luận mỗi env vào "Xác nhận". Script chỉ gọi API và CDN qua HTTPS, không
API AWS, không `kubectl`; buổi prd chạy đúng các lệnh này với `CONTEXT=svp-prd`:

```sh
domain=$(jq -r .domain "$SVP_SESSION_DIR/cluster-values.json")
make -C ../backend eks-premium-check CONTEXT=svp-stg DOMAIN="$domain"
# Waits past a signed URL's expiry: < clip + 20 min.
make -C ../backend eks-premium-check CONTEXT=svp-stg DOMAIN="$domain" WAIT_EXPIRY=1
```

Mong mỗi dòng `ok` (ca âm 403: segment `premium/` không ký, chữ ký của V1 trên segment V2 hay trên 720p, playlist ngoài gói; bản xem thử
không ký 200), bảng `round video segments hit miss …` với tỉ lệ trúng của lượt 2–3 ở V1 (đã ký) xấp xỉ V0 (công khai): query, kể cả chữ
ký, không vào cache key; dòng cuối `ok every check of the premium edge`. Lượt `WAIT_EXPIRY=1` thêm dòng `ok V1 360p signed segment 5 s
past DateLessThan: 403`; chạy nó trong lúc chờ bậc k6. Dòng `FAIL`: dán toàn bộ output. Một lượt **Xoay khoá ký** trong buổi theo
[`media-signing-keys.md`](media-signing-keys.md#xoay-khoá-ký), rồi lượt đầu lại một lần. Chạy lượt xoay sau khi `measure.sh` kết thúc,
không trong lúc chờ bậc k6: `bootstrap.sh stg secrets` đồng bộ lại `svp-data` và Reloader khởi động lại video-service, nên lỗi và p99 của
bậc đang đo có thể vượt ngưỡng và kết thúc thang k6.

## Uptime: probe và cảnh báo

Loại: `lõi`; chạy ≥ 30 phút sau mốc `edge-healthy` (probe cần chạy đủ lâu; trước mốc đó ALB chưa có target khoẻ nên probe lỗi).

Blackbox exporter trong cluster probe `web`, `api`, `media` qua domain công khai (CloudFront, WAF, ALB, Envoy) và DNS của ba tên;
SLO `public-uptime` và nhóm luật `svp-uptime` ở ruler AMP
([ADR-0074](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0074-cost-uptime.md); luồng probe ở
`docs/explanation/cost-and-uptime.md` của repo code). Đường mặc định thường đã qua 30 phút đó khi tới mục này; chưa đủ thì làm các
mục `lõi` khác trước, chạy mục này cuối, trước mục [Finding bảo mật của
buổi](session-stg-drills.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20). Terminal có khối dùng chung của mục [Hàm dùng
chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo):

```sh
d=$(jq -r .domain "$SVP_SESSION_DIR/cluster-values.json")
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter -o wide
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs get probes.monitoring.coreos.com
echo "$(( ($(date +%s) - $(awk -F '\t' '$3 == "edge-healthy" { t = $2 } END { print t }' "$SVP_SESSION_DIR/timeline.tsv")) / 60 )) min"
{ promql 'probe_success{job="blackbox-http"}'
  promql 'min_over_time(probe_success{job="blackbox-http"}[30m])'
  promql '(probe_ssl_earliest_cert_expiry{job="blackbox-http"} - time()) / 86400'
  promql 'probe_success{job="blackbox-dns"}'; } | sed "s/$d/<domain>/g"
amp_get api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname | test("^(Uptime|TLSCert|PublicUptime)"))
  | "\(.labels.alertname) \(.labels.severity) \(.state) \(.activeAt)"'
```

Mong: hai pod `Running` (hai zone là ý định, không phải điều kiện: pod trải zone bằng `ScheduleAnyway`, nên cả hai cùng một zone vẫn hợp
lệ, ghi zone vào kết quả; lỗi thật là pod `Pending`, `CrashLoopBackOff` hay chỉ còn một pod); sáu `Probe` (`uptime-web`, `uptime-api`,
`uptime-media`, `uptime-dns-web`, `uptime-dns-api`, `uptime-dns-media`); số phút ≥ 30; ba dòng `probe_success` giá trị `1`, ba dòng
`min_over_time` giá trị `1` (xanh suốt 30 phút, tính từ `edge-healthy`); ba dòng số ngày tới hạn cert lớn hơn 21 (cert ACM tự gia hạn); ba
dòng DNS giá trị `1`; không dòng `UptimeProbesAbsent`, `TLSCert…`. `PublicUptimeBudgetBurn` còn cháy là probe lỗi lúc dựng (mục [15. Chờ
Argo CD](session-stg-deploy.md#15-chờ-argo-cd)): ghi lại, không điều tra. Probe nào `0`: dán output và theo runbook
[`public-uptime-budget-burn.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/public-uptime-budget-burn.md).

Sau bước 31, hộp thư `alarm_email`: thư `UptimeProbesAbsent` nào trong buổi, giờ UTC của nó. Mong không thư nào lúc gỡ: bước 20 xoá luật ở
AMP trước khi gỡ blackbox (bước 20 in `note left in AMP: …` thì luật còn đánh giá và thư tới là đúng: xoá luật bằng lệnh của dòng đó). Thư
lúc dựng: so giờ của nó với mốc `observability-healthy`, `svp-root-healthy`, `edge-healthy`, dán cho AI.

## Phép kiểm transcode

Loại: `lõi` (biến và hàm dùng chung, (a) dưới đây); (b)–(e) và (f) là hai mục con có dòng `Loại:` riêng.

Phép kiểm buổi của mục "Xác nhận" của
[ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#xác-nhận): `media-worker`
chạy lệnh con `mediaconvert` và video đi qua MediaConvert, header của output qua CloudFront, FF-9 của threat model, lớp cắt đầu
vào, hàng đợi sự kiện rỗng, và đường MediaConvert của phép đo hai đường. Làm sau smoke, tunnel mở. Lệnh và output có thời điểm UTC
vào một file của `$SVP_SESSION_DIR`, một dòng kết luận mỗi phép vào "Xác nhận" của ADR-0066, số thô của (b) vào bảng "Kết quả" ở
phụ lục của nó. Buổi prd chạy (a) và (f) với `anhnv-prd`, `--context svp-prd`, tên `svp-prd`
([`session-prd-checks.md`](session-prd-checks.md#phép-kiểm-transcode)). Chi phí của mục này nằm trong phần chi phí của transcode ở
[ADR-0066 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí).

Biến và hàm dùng chung, một lần trong terminal của buổi (mở lại terminal thì chạy lại khối này). Bản ghi job
(`transcode-jobs/<video_id>/<version>.json` của bucket media) là nguồn duy nhất của kết quả mỗi version: job của version
hay lý do hỏng trước khi có job (`docs/explanation/transcode.md` của repo code):

```sh
values=$SVP_SESSION_DIR/cluster-values.json
media=$(jq -r .mediaBucket "$values"); dom=$(jq -r .domain "$values"); cdn=https://$(jq -r .mediaDomain "$values")
record_key() {          # job record key of video $1
  AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-objects-v2 --bucket "$media" --prefix "transcode-jobs/$1/" --region ap-southeast-1 \
    --query 'Contents[0].Key' --output text
}
last_key() {            # newest job record: the video just uploaded
  AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-objects-v2 --bucket "$media" --prefix transcode-jobs/ --region ap-southeast-1 \
    --query 'sort_by(Contents, &LastModified)[-1].Key' --output text
}
show() { AWS_PROFILE=anhnv-stg aws --no-cli-pager s3 cp "s3://$media/$1" - --region ap-southeast-1; }
```

(a) Smoke đi qua MediaConvert: Deployment `media-worker` chạy lệnh con `mediaconvert`, và job trong bản ghi của mỗi
video smoke (và seed, khi thang đo chạy) là `COMPLETE` trên queue `svp-stg`. Một video có thể có thêm job lạc:
`CreateJob` mất response, bridge thử lại và tạo job thứ hai; job đó chạy tới `COMPLETE` hay `ERROR` nhưng không có tên
trong bản ghi, nên không quyết kết quả. Khối dưới chép mọi bản ghi về thư mục buổi, rồi đếm mỗi bản ghi theo trạng thái
job của nó (`record-job`) hay lý do của nó (`reason`), và mỗi job khác của cùng video (`orphan-job`):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get deploy media-worker \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="media-worker")].args}{"\n"}'
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert list-jobs --queue svp-stg --region ap-southeast-1 --output json > "$SVP_SESSION_DIR/mediaconvert-jobs.json"
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3 sync "s3://$media/transcode-jobs/" "$SVP_SESSION_DIR/transcode-jobs/" --region ap-southeast-1 --only-show-errors
find "$SVP_SESSION_DIR/transcode-jobs" -name '*.json' -exec jq -c '{video: (input_filename | split("/")[-2]), job: .job_id, reason}' {} + |
  jq -rs --slurpfile all "$SVP_SESSION_DIR/mediaconvert-jobs.json" '($all[0].Jobs | map({key: .Id, value: .Status}) | from_entries) as $st
    | map(.job | select(.)) as $own | map(.video) as $videos
    | (.[] | if .reason then "reason \(.reason)" else "record-job \($st[.job] // "MISSING")" end),
      ($all[0].Jobs[] | select((.UserMetadata.video_id | IN($videos[])) and (.Id | IN($own[]) | not)) | "orphan-job \(.Status)")' |
  sort | uniq -c
```

Mong `["mediaconvert"]`, rồi dòng `record-job COMPLETE` với số đếm bằng số video smoke (và seed) đã `READY`, không dòng
`record-job` nào khác, không dòng `reason`. Dòng `orphan-job <trạng thái>` được chấp nhận (job lạc, như trên); ghi số
của nó vào dòng kết luận. `record-job` khác `COMPLETE` (`MISSING`: job của bản ghi không có trên queue) hay có dòng
`reason`: dán bảng đếm và output của `jq -c '.Jobs[] | select(.Status != "COMPLETE") | {Id, Status, ErrorCode,
ErrorMessage, UserMetadata}' "$SVP_SESSION_DIR/mediaconvert-jobs.json"` cho AI.

## Transcode (b)–(e): đo hai đường, header, FF-9, lớp cắt

Loại: `chuẩn ngành`, không cần cờ. Thêm: job MediaConvert của năm clip 60 s ở (b) và của clip khai 60 s ở (e) (clip 200
s của (d) không thành job), theo phần transcode của [ADR-0066
§12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí); vài phút
CPU trên máy cho clip.

Khi thang đo chạy, làm trong lúc bậc k6 đầu tiên (1 pod) giữ tải: k6 chỉ gọi `POST /videos`, không tải file, nên không
job nào khác chen vào số đo. Dùng biến và hàm dùng chung của mục trên.

Ba clip sinh trên máy một lần, trong lúc chờ bước 9 (vài phút CPU): clip tham chiếu 60 s và 200 s (lệnh của mục "Phép đo hai đường: phương
pháp" ở [phụ lục ADR-0066][adr-0066-phương-pháp]), và một bản 200 s không edit list mà header MP4 khai 60 s, cho (e). Script Python chỉ
ghi lại trường thời lượng của ba hộp `mvhd`, `tkhd`, `mdhd` (version 0, như ffmpeg ghi); mẫu của luồng giữ nguyên 200 s:

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

(b) Phép đo hai đường, đường MediaConvert: script đo thời gian tới `READY` (`deploy/compose/transcode-timing.sh`) qua
`make eks-transcode-timing` của repo code, 5 lần clip 60 s, rồi `GetJob` của 5 job (job ID ở bản ghi job) cho phút output theo loại:

```sh
AWS_PROFILE=anhnv-stg make -C ../backend eks-transcode-timing CONTEXT=svp-stg DOMAIN="$dom" CLIP="$SVP_SESSION_DIR/clip-60s.mp4" N=5 |
  tee "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt"
grep -E '^[0-9a-f-]{36} [0-9]+$' "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt" | cut -d ' ' -f 1 | while read -r id; do
  job=$(show "$(record_key "$id")" | jq -r .job_id)
  AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert get-job --id "$job" --region ap-southeast-1 --output json \
    --query 'Job.{id: Id, status: Status, timing: Timing, outputs: OutputGroupDetails[].OutputDetails[].[DurationInMs, VideoDetails.WidthInPx, VideoDetails.HeightInPx]}'
done | tee "$SVP_SESSION_DIR/transcode-timing-jobs.json"
```

Mong năm dòng `<video_id> <giây>`, dòng `p50=<giây> max=<giây>` và năm JSON `COMPLETE`. Dán nguyên `transcode-timing-mediaconvert.txt` và
`transcode-timing-jobs.json` (output thô, AI tính chi phí theo công thức ở mục "Chi phí mỗi phút video" của phụ lục). Đường ffmpeg trên
compose chạy ngoài buổi, một lần, theo cùng mục của phụ lục; tổng MediaConvert của ngày buổi ở Cost Explorer đọc ở mục [Kết thúc
buổi](session-stg.md#kết-thúc-buổi).

(c) Header của output qua CloudFront: master, playlist rendition, một segment và thumbnail của một video vừa đo, đọc qua `media.<domain>`:

```sh
id=$(grep -E -m 1 '^[0-9a-f-]{36} [0-9]+$' "$SVP_SESSION_DIR/transcode-timing-mediaconvert.txt" | cut -d ' ' -f 1)
key=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-objects-v2 --bucket "$media" --prefix "media/$id/" --region ap-southeast-1 \
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
AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert list-jobs --queue svp-stg --region ap-southeast-1 --output json \
  --query "Jobs[?UserMetadata.video_id=='$(cut -d / -f 2 <<<"$key")'].[Id,Status]"
```

Mong: `make` dừng ở `FAIL  video v went FAILED instead of READY`; key `transcode-jobs/<video_id>/<version>.json`, nội dung
`{"reason":"DURATION_EXCEEDED"}`; `[]`. Video `READY`, lý do khác hay có job: dán cả ba output cho AI (FF-9 không giữ được).

(e) Lớp cắt: file khai 60 s mà dài thật 200 s không ra output quá 3 phút:

```sh
AWS_PROFILE=anhnv-stg make -C ../backend eks-transcode-timing CONTEXT=svp-stg DOMAIN="$dom" CLIP="$SVP_SESSION_DIR/clip-200s-says-60s.mp4" N=1
key=$(last_key); echo "$key"; show "$key"
job=$(show "$key" | jq -r '.job_id // empty')
[ -z "$job" ] || AWS_PROFILE=anhnv-stg aws --no-cli-pager mediaconvert get-job --id "$job" --region ap-southeast-1 --output json \
  --query 'Job.[Status,ErrorCode,OutputGroupDetails[].OutputDetails[].DurationInMs]'
```

Đạt khi không output nào dài quá 180 000 ms. Ghi trường hợp gặp: video `READY`, bản ghi có `job_id`, job `COMPLETE` với mọi `DurationInMs`
quanh 60 000 (cắt tại thời lượng Probe báo: lớp cắt chạy); hay `FAILED` với bản ghi `{"reason":"INVALID_INPUT"}` hoặc job `ERROR` (không
output); hay `{"reason":"DURATION_EXCEEDED"}` (Probe không tin header, lớp cắt không được thử tới). Có output trên 180 000 ms: trần chi phí
hỏng, dừng mục này và dán output cho AI.

## Transcode (f): hàng đợi rỗng

Loại: `lõi`.

(f) Hàng đợi sự kiện rỗng, alarm DLQ không báo, bridge không bỏ message nào. Chạy sau cùng, khi mọi job của mục này đã xong:

```sh
for q in svp-stg-transcode-events svp-stg-transcode-events-dlq; do
  url=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager sqs get-queue-url --queue-name "$q" --region ap-southeast-1 --query QueueUrl --output text)
  echo "$q $(AWS_PROFILE=anhnv-stg aws --no-cli-pager sqs get-queue-attributes --queue-url "$url" --region ap-southeast-1 --output text \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]')"
done
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudwatch describe-alarms --alarm-names svp-stg-transcode-events-dlq --region ap-southeast-1 --output text \
  --query 'MetricAlarms[].[AlarmName,StateValue]'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp logs deploy/media-worker --since=3h |
  grep -c -E 'transcode event (ignored|interrupted)|transcode result undecided'
```

Mong hai dòng kết thúc bằng hai số `0` (hàng đợi nguồn còn số khác 0 thì đọc lại sau một phút), alarm `OK` hay `INSUFFICIENT_DATA`, và
`0`. DLQ có message hay alarm `ALARM`: theo runbook
[`transcode-events-dlq.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/transcode-events-dlq.md) của repo code, dán
output cho AI. Rồi chạy lại ba lệnh cuối của (a) (`list-jobs`, `s3 sync`, bảng đếm). Mong `record-job` chỉ `COMPLETE` (thêm `ERROR` khi
(e) gặp job `ERROR`), không `reason` (khi (b)–(e) đã chạy: chỉ `DURATION_EXCEEDED` của (d) và lý do (e) đã ghi); `orphan-job` như ở (a);
khác: dán bảng đếm cho AI. `mediaconvert-jobs.json` khi đó giữ mọi job của buổi cùng thời lượng từng output, đầu vào đối chiếu chi phí ở
mục [Kết thúc buổi](session-stg.md#kết-thúc-buổi).

## Gỡ

Các phép kiểm ở trang này không để lại tài nguyên của buổi ngoài những thứ nó tự nêu (pod, tệp trong `$SVP_SESSION_DIR`); gỡ cuối buổi ở
[`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31).

## Khi một bước đỏ

Phép kiểm đỏ thì ghi kết quả, dán output cho AI rồi sang phép kế: bước 16 là bước duy nhất của bảng
[Thứ tự](session-stg.md#thứ-tự) được đi tiếp khi đo hỏng. Lỗi riêng của từng phép ở nhãn **Bẫy** hay phần **Mong** của nó; destroy kẹt:
[Destroy kẹt](session-stg.md#destroy-kẹt).

[adr-0066-phương-pháp]:
  https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md#phép-đo-hai-đường-phương-pháp
