# Module `media`

Hai bucket S3 `uploads`, `media` và CloudFront trước `media`, cộng hai policy IAM (JSON) cho video-service và media-worker. Thiết kế:
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) mục 9 và 11; ngưỡng an toàn theo threat model
UP-4…UP-6, WEB-10 của repo code.

## Bucket

- Tên `<name_prefix>-uploads-<account_id>-<region>`, `<name_prefix>-media-<account_id>-<region>` (quy ước của bucket do AWS tạo như CDK,
  Control Tower): duy nhất toàn cầu không cần phần ngẫu nhiên, biết lúc `plan`, nhìn tên là biết account và region. Account ID không phải bí
  mật theo AWS; tên bucket `uploads` nằm trong mọi URL form upload presigned trình duyệt thấy. Root truyền `account_id`, `region` của nó, nên
  file commit không chứa account thật. Bucket sót của một `destroy` dở trùng tên với lần `apply` sau: script quét sót (`aws/scripts/sweep.sh`) liệt kê
  nó theo tiền tố tên `svp-`, người học xoá trước khi `apply` theo runbook của buổi.
- Chặn public (cả bốn cờ), `BucketOwnerEnforced` (không ACL), SSE-S3, không versioning (object `media` ghi một lần dưới đường version mới,
  `uploads` bị xoá khi hết cần; giữ version chỉ giữ byte đã xoá). Policy của cả hai bucket từ chối request không TLS bằng statement `Deny`
  `s3:*` như mẫu của AWS: action S3 thêm sau này cũng bị từ chối qua HTTP. Wildcard ở `Deny` chỉ mở rộng thứ bị cấm, không cấp quyền nào (các
  statement `Allow` của module không dùng wildcard dịch vụ).
- **Key giữ tiền tố:** bucket `uploads` chứa `uploads/<video_id>`, bucket `media` chứa `media/<video_id>/<version>/…` (như object store local,
  `internal/objstore` chọn bucket theo tiền tố), nên key, policy và URL giống nhau ở mọi nền tảng.
- **CORS theo bucket như local:** `uploads` chỉ `POST` (form presigned của web, expose `Retry-After`), `media` chỉ `GET`, `HEAD`; origin là
  `cors_allowed_origins` (origin trơn, không `*`, không path).
- **Lifecycle:** `uploads/` 30 ngày ở lớp chuẩn → Glacier Deep Archive, xoá sau 365 ngày (sau 30 ngày không transcode lại được nếu chưa
  restore, restore tới 48 giờ); multipart dở bị huỷ sau 1 ngày ở cả hai bucket. Hôm nay không service nào ghi bằng multipart (mỗi file một
  `PutObject`, form của trình duyệt là một POST), nhưng `s3:PutObject` cho phép bắt đầu một lần multipart mà không service nào được abort,
  nên phần của một lần ghi dở (client sau này, credential bị lạm dụng) chỉ được dọn bằng rule này.
- **`force_destroy`:** `true` làm `terraform destroy` xoá **mọi object** của cả hai bucket rồi xoá bucket. Chỉ đặt `true` ở stg (dữ liệu
  buổi lab bỏ đi được); prd `false`, destroy dừng ở bucket còn object. Biến không có mặc định để mỗi env phải ghi rõ.

## CloudFront

- Origin là bucket `media` qua **OAC** (ký SigV4 mọi request); policy bucket chỉ cho `cloudfront.amazonaws.com` `s3:GetObject` trên
  `media/*` với điều kiện `AWS:SourceArn` là ARN của distribution này; không `ListBucket`, nên key không có trả 403 thay vì 404.
- Tên mặc định `<id>.cloudfront.net`, chứng chỉ mặc định, viewer chỉ HTTPS (`https-only`), HTTP/2 và HTTP/3, IPv6, price class biến
  (`PriceClass_200`: gồm Singapore, Việt Nam, bỏ Nam Mỹ, Úc). Không WAF (nội dung HLS công khai, bất biến; web ACL tính phí theo tháng mỗi
  ACL và rule), không access log.
- **Cache:** policy managed `Managed-CachingOptimized`: cache key không có query, cookie, header; TTL theo `Cache-Control` của object trong
  khoảng 1 s tới 1 năm (object không gửi header thì 24 giờ). Mọi object của một version HLS mang `max-age=31536000, immutable`, nên edge giữ
  một năm.
- **CORS ở CloudFront, không ở bucket:** header CORS của S3 phụ thuộc `Origin` của request, mà `Origin` không nằm trong cache key; bản cache
  của request không `Origin` (thẻ `<img>`, curl) sẽ trả cho player cần nó mà không có `Access-Control-Allow-Origin`. Nên distribution không
  chuyển header nào của viewer tới bucket (không origin request policy: S3 không bao giờ thấy `Origin`, mọi viewer dùng chung một bản cache),
  còn response headers policy `<bucket media>-cors` thêm header CORS (`GET`, `HEAD`, origin của web, `origin_override`) vào mỗi câu trả lời
  có `Origin` thuộc danh sách. Request của player không mang header nào cần preflight, nên distribution chỉ nhận `GET`, `HEAD`.
- **Đường của một object:** gateway ghép `MEDIA_PUBLIC_BASE_URL` = `https://<media_domain>` với key, key đã có `media/`. Ví dụ segment:
  `https://d111111abcdef8.cloudfront.net/media/<video_id>/<version>/<attempt>/<rendition>/seg_000.ts` là object
  `media/<video_id>/<version>/<attempt>/<rendition>/seg_000.ts` của bucket `media`; master là `…/media/<video_id>/<version>/master.m3u8`.
  Không có đoạn `/media` thêm như đường path-style của k3d.

## Policy IAM của hai service

Dịch `deploy/s3/video-service-policy.json`, `media-worker-policy.json` của repo code sang ARN bucket thật, **thêm một quyền** mà store local
không cần: `ListBucket` trên bucket `uploads` cho cả hai service (sid `ListUploads`). `s3:PutObject` đã gồm các bước multipart và ghi có
điều kiện `If-None-Match: *`; không service nào được abort multipart.

| Service | Quyền |
| --- | --- |
| video-service | `PutObject`, `GetObject`, `DeleteObject` trên `<uploads>/uploads/*`; `ListBucket` trên `<uploads>` (không điều kiện, khác local); `ListBucket` trên `<media>` với `s3:prefix` `media/*`; `DeleteObject` trên `<media>/media/*` |
| media-worker | `GetObject` trên `<uploads>/uploads/*`; `ListBucket` trên `<uploads>` (không điều kiện, khác local); `PutObject`, `GetObject` trên `<media>/media/*`; `ListBucket` trên `<media>` với `s3:prefix` `media/*` |

**Vì sao thêm `ListBucket` trên `uploads`:** caller không có `s3:ListBucket` trên bucket thì S3 trả `HEAD`/`GET` của key không có bằng
**403**, không phải 404 (RustFS của local trả 404). Code dựa vào 404: video-service đổi 404 của `HEAD uploads/<id>` thành 400
`UPLOAD_NOT_FOUND` (`POST /videos/{id}/complete` khi chưa tải file lên), lỗi khác thành 503 `DEPENDENCY_UNAVAILABLE` mà web thử lại mãi;
media-worker đổi 404 của file gốc thành `SOURCE_MISSING` (event `video.uploaded` phát lại cho video đã `FAILED`, file gốc đã xoá), lỗi khác
thành thử lại rồi vào DLQ. Thiếu quyền này thì "file không có" thành "store hỏng". Không gắn điều kiện `s3:prefix`: bucket chỉ chứa
`uploads/<id>` (chỉ form do video-service ký ghi vào), nên điều kiện không thu hẹp gì, mà tài liệu S3 không nói phép quyết 403 hay 404 có
xét điều kiện đó. Liệt kê chỉ lộ id video, thứ cả hai service đã biết. Bucket `media` giữ như local: code kiểm có hay không bằng
`ListObjectsV2` theo tiền tố (`Exists`), thoả điều kiện `media/*`, không dựa vào 404 của `HEAD`.

Kiểm ở buổi AWS: `POST /videos/{id}/complete` khi chưa tải file trả 400 `UPLOAD_NOT_FOUND`, không 503.

Root của env gắn mỗi JSON vào role của Pod Identity association `svp/video-service`, `svp/media-worker`.

## Biến

| Biến | Kiểu | Mặc định | stg (7a) | prd (7b) | Ý nghĩa |
| --- | --- | --- | --- | --- | --- |
| `name_prefix` | string | — | `svp-stg` | `svp-prd` | Đầu tên bucket, OAC, response headers policy (2–27 ký tự: tên bucket `uploads` tối đa 63) |
| `account_id` | string | — | `var.account_id` của root | `var.account_id` của root | Account của bucket (12 số), phần của tên bucket |
| `region` | string | — | `var.region` của root | `var.region` của root | Region của bucket (tối đa 14 ký tự), phần của tên bucket |
| `cors_allowed_origins` | list(string) | — | `["https://<domain của stg>"]` | `["https://<domain của prd>"]` | Origin của web cho CORS hai bucket và CloudFront |
| `force_destroy` | bool | **không có** | `true` | `false` | Destroy xoá mọi object rồi xoá bucket |
| `price_class` | string | `PriceClass_200` | `PriceClass_200` | `PriceClass_200` | Nhóm edge của CloudFront |

## Output

| Output | Giá trị |
| --- | --- |
| `uploads_bucket` | Tên bucket `uploads` (`UPLOAD_ORIGIN` của web: `https://<tên>.s3.<region>.amazonaws.com`) |
| `media_bucket` | Tên bucket `media` |
| `media_domain` | `<id>.cloudfront.net`: `mediaDomain` của `cluster_values` (`MEDIA_PUBLIC_BASE_URL`, `MEDIA_ORIGIN` là `https://<domain>`) |
| `media_distribution_arn` | ARN của distribution |
| `video_service_policy_json` | Policy IAM (JSON) của video-service |
| `media_worker_policy_json` | Policy IAM (JSON) của media-worker |

## Chi phí theo giờ (`ap-southeast-1`, giá đọc 2026-10-31, nguồn ở ADR-0034 [N9], [N10])

| Tài nguyên | Giá | Mỗi giờ của buổi stg |
| --- | --- | --- |
| S3 lớp chuẩn | $0,025/GB-tháng (50 TB đầu); PUT/POST $0,005/1 000, GET $0,004/10 000 | ~$0 (vài GB, vài chục nghìn request) |
| S3 Glacier Deep Archive | theo trang giá [N9] (chưa ghi số ở đây); chỉ object `uploads/` quá 30 ngày, buổi stg xoá bucket trước đó | $0 |
| CloudFront pay-as-you-go | 1 TB ra Internet và 10 triệu request HTTP(S) mỗi tháng miễn phí; vượt thì nhóm có Singapore $0,120/GB | $0 |
| OAC, cache policy, response headers policy, CORS, lifecycle | Không tính tiền | $0 |

S3 tới từ cluster đi qua gateway endpoint của VPC (module `network`), không qua NAT. Tạo và xoá distribution mỗi lần mất vài phút
(Terraform chờ tới khi deploy xong); destroy phải tắt distribution trước, Terraform tự làm.

## Có thể sót sau destroy

- **Bucket còn object khi `force_destroy = false`** (prd): destroy dừng ở bucket, cố ý. stg đặt `true` nên không sót.
- **Bucket, distribution của một `apply` hay `destroy` dở:** bucket mang tag `Project=svp` của root (quét theo tag); distribution, OAC,
  response headers policy tìm theo tên hay comment có `name_prefix` (OAC và response headers policy không có tag).
- Distribution đã tắt mà chưa xoá không tính tiền request nhưng vẫn là tài nguyên sót; xoá sau khi trạng thái `Deployed`.
