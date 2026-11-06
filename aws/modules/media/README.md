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
- Chặn public (cả bốn cờ), `BucketOwnerEnforced` (không ACL), SSE-S3. Versioning tắt mặc định (object `media` ghi một lần dưới đường
  version mới, `uploads` bị xoá khi hết cần; giữ version chỉ giữ byte đã xoá); `versioning_enabled = true` (mức prd) bật ở cả hai bucket
  và thêm rule lifecycle xoá bản cũ 30 ngày sau khi bị thay hay xoá, cùng delete marker không còn bản nào phía sau: xoá nhầm còn khôi phục
  được trong 30 ngày. Policy của cả hai bucket từ chối request không TLS bằng statement `Deny`
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
- **Access log:** `access_logging_enabled = true` (mức prd) ghi S3 server access log của hai bucket vào bucket thứ ba
  `<name_prefix>-logs-<account_id>-<region>` (tiền tố `uploads/`, `media/`) do module tạo: chặn public, `BucketOwnerEnforced`, SSE-S3 (đích
  của server access log chỉ nhận SSE-S3, ngoại lệ trivy AWS-0132), TLS-only, policy cho `logging.s3.amazonaws.com` `s3:PutObject` với điều
  kiện `aws:SourceArn` là hai bucket này và `aws:SourceAccount` là account này (mẫu của tài liệu S3), log xoá sau 90 ngày. Bucket log không
  ghi log của chính nó (vòng lặp vô hạn). `force_destroy` áp cho cả bucket log.
- **`force_destroy`:** `true` làm `terraform destroy` xoá **mọi object** của cả hai bucket rồi xoá bucket. Chỉ đặt `true` ở stg (dữ liệu
  buổi lab bỏ đi được); prd `false`, destroy dừng ở bucket còn object. Biến không có mặc định để mỗi env phải ghi rõ.

## CloudFront

- Origin là bucket `media` qua **OAC** (ký SigV4 mọi request); policy bucket chỉ cho `cloudfront.amazonaws.com` `s3:GetObject` trên
  `media/*` với điều kiện `AWS:SourceArn` là ARN của distribution này; không `ListBucket`, nên key không có trả 403 thay vì 404.
- Tên mặc định `<id>.cloudfront.net`, chứng chỉ mặc định, viewer chỉ HTTPS (`https-only`), HTTP/2 và HTTP/3, IPv6, price class biến
  (`PriceClass_200`: gồm Singapore, Việt Nam, bỏ Nam Mỹ, Úc). Không access log của CloudFront. Chứng chỉ `*.cloudfront.net` mặc định để
  CloudFront quyết policy TLS cho viewer; đặt phiên bản giao thức tối thiểu cần chứng chỉ riêng, trong ACM ở `us-east-1`, với tên riêng:
  module chưa có.
- **WAF:** `web_acl_arn` (ARN web ACL scope `CLOUDFRONT` của module `waf`, mức prd) gắn web ACL vào distribution; mặc định `null` không gắn
  (nội dung HLS công khai, bất biến, từ origin chỉ đọc; web ACL tính phí theo tháng mỗi ACL và rule, mà lab ngắn hạn không cần luật nào).
  Ngoại lệ trivy AWS-0011 chỉ áp khi `web_acl_id` rỗng
  (giá trị khi không gắn), nên env có WAF không bị che finding nào.
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

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudfront_distribution.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_cloudfront_response_headers_policy.media_cors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_response_headers_policy) | resource |
| [aws_s3_bucket.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_cors_configuration.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_cors_configuration) | resource |
| [aws_s3_bucket_cors_configuration.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_cors_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.uploads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_iam_policy_document.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.media](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.media_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.tls_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.video_service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| access\_logging\_enabled | Write S3 server access logs of both buckets to a third bucket, <name\_prefix>-logs-<account\_id>-<region>, which this module creates (private, TLS only, SSE-S3, logs deleted after 90 days). Off by default. | `bool` | `false` | no |
| account\_id | The AWS account of the buckets (12 digits), part of their names. The root passes its own account\_id, which never goes into a committed file. | `string` | n/a | yes |
| cors\_allowed\_origins | Origins of the web client (https://<domain>) that may post upload forms to the uploads bucket and read playlists, segments and thumbnails of media cross-origin. | `list(string)` | n/a | yes |
| force\_destroy | Let terraform destroy delete both buckets with every object in them. Without it destroy fails on a bucket that is not empty. | `bool` | n/a | yes |
| name\_prefix | Fixed start of every name (svp-stg, svp-prd): buckets are <name\_prefix>-uploads-<account\_id>-<region> and <name\_prefix>-media-<account\_id>-<region>. | `string` | n/a | yes |
| price\_class | Edge locations of the CloudFront distribution. PriceClass\_200 serves Asia, Singapore and Vietnam included, from nearby edges, and leaves out the dearest regions (South America, Australia). | `string` | `"PriceClass_200"` | no |
| region | Region of the buckets, part of their names; the root passes the region of its provider. | `string` | n/a | yes |
| versioning\_enabled | Keep earlier versions of overwritten and deleted objects in both buckets, each for 30 days after it was replaced (a lifecycle rule then deletes it). Off by default: objects are written once, and kept versions keep deleted bytes billed. | `bool` | `false` | no |
| web\_acl\_arn | ARN of an AWS WAF web ACL of scope CLOUDFRONT (in us-east-1, output web\_acl\_arn of the waf module) to put in front of the distribution. null (the default) attaches none. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| media\_bucket | Name of the media bucket. |
| media\_distribution\_arn | ARN of the CloudFront distribution in front of the media bucket. |
| media\_domain | Domain of the CloudFront distribution (<id>.cloudfront.net): MEDIA\_PUBLIC\_BASE\_URL of the gateway and MEDIA\_ORIGIN of the web are https://<domain>. |
| media\_worker\_policy\_json | IAM policy of media-worker (JSON) for the role of its Pod Identity association. |
| uploads\_bucket | Name of the uploads bucket (the web posts upload forms to https://<name>.s3.<region>.amazonaws.com). |
| video\_service\_policy\_json | IAM policy of video-service (JSON) for the role of its Pod Identity association. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->

## Giá trị theo env

| Biến | stg | prd |
| --- | --- | --- |
| `name_prefix` | `svp-stg` | `svp-prd` |
| `account_id` | `var.account_id` của root | `var.account_id` của root |
| `region` | `var.region` của root | `var.region` của root |
| `cors_allowed_origins` | `["https://<domain của stg>"]` | `["https://<domain của prd>"]` |
| `force_destroy` | `true` | `false` |
| `price_class` | `PriceClass_200` | `PriceClass_200` |

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
