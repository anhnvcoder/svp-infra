# Runbook: phép kiểm bảo mật của buổi stg (bước 16)

← [Phép kiểm nền tảng](session-stg-check-platform.md) · [Mục lục](README.md) · [Phép kiểm edge và media](session-stg-check-edge-media.md) →

> **Tóm tắt**
>
> - **Làm gì:** chứng minh các lớp bảo mật của env đang chạy: bucket media không liệt kê được, bảo vệ của account (agent GuardDuty, flow
>   log, log WAF, quét malware), alarm tới email. `lõi`: bảo vệ của account, alarm tới email; `chuẩn ngành`: bucket media. Không phép nào
>   cần cờ chi phí (finding Security Hub và control của nó ở [trang diễn tập](session-stg-drills.md)).
> - **Khi nào và bao lâu:** bảo vệ của account chạy ít nhất 15 phút sau bước 15; alarm tới email sau khi subscription SNS đã xác nhận ở
>   bước 6–10. Bucket media là một lệnh `curl`.
> - **Phí trong lúc chạy:** không tốn thêm; đọc tag, log và subscription.

Thiết kế: [ADR-0058](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0058-managed-data-operations.md) (CloudWatch alarm tới
email qua SNS).

## Điều kiện trước

- [ ] **Bước 1–15 xong**: apply root env và root gitops thành công, `bootstrap.sh stg wait` (bước 15) báo mọi Application `Healthy`
  ([`session-stg-deploy.md`](session-stg-deploy.md#15-chờ-argo-cd)).
- [ ] **Tunnel tới API còn mở** ([Tunnel tới API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11), giữ tới hết bước 22).
- [ ] **Terminal của buổi** ([Mở terminal](session-stg.md#mở-terminal)): cùng `SVP_SESSION_DIR` với các bước trước.
- [ ] **Chờ ít nhất 15 phút sau bước 15** cho mục Bảo vệ của account: GuardDuty báo coverage EKS vài phút sau khi add-on `ACTIVE`.
- [ ] **Email alarm đã xác nhận**
  ([6–10](session-stg-deploy.md#610-root-env-init-khoá-ký-plan-lưu-file-đọc-apply-file-đó-kích-hoạt-khoá-ký), mục Xác nhận email của
  alarm) cho mục Alarm tới email.
- [ ] **Nền bảo mật của org đã áp** ([điều kiện 6](session-stg.md#điều-kiện-trước) của trang chủ): bucket flow log, log WAF ở account Log
  Archive; profile `anhnv-log-ro` đọc được chúng.

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ (mở lại giữa buổi: cùng mục đó, với
`SVP_SESSION_DIR` là thư mục của buổi đang dở). Lệnh chạy từ gốc repo (`infra/`).
Trang này cần `SVP_SESSION_DIR`, `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`.

## Bucket media không liệt kê được

Loại: `chuẩn ngành`, không cần cờ. Thêm: một lệnh `curl`, không tốn tiền.

Sau smoke: bucket `media` không liệt kê được ẩn danh khi gọi thẳng endpoint vùng của S3, không qua CloudFront (smoke chỉ thử phép liệt kê
qua gốc của CloudFront, không suy được tên bucket). Mong `403`; `200` là bucket liệt kê được, dừng buổi và báo lại:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://$(jq -r .mediaBucket "$SVP_SESSION_DIR/cluster-values.json").s3.$(jq -r .region "$SVP_SESSION_DIR/cluster-values.json").amazonaws.com/?list-type=2"
```

Dán lại mã in ra (ghi vào hàng tương ứng của mục "Kiểm chứng sau" của ADR-0034).

## Bảo vệ của account: GuardDuty, flow log, log WAF, quét malware

Loại: `lõi`; chạy ≥ 15 phút sau bước 15 (GuardDuty báo coverage EKS vài phút sau khi add-on `ACTIVE`).

Bảo vệ cơ bản của account env ([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md)
§5, §6; bucket của Log Archive ở điều kiện 6): agent GuardDuty trên mọi node và coverage EKS, flow log của VPC, log WAF
che header đăng nhập, quét Malware Protection for S3 trên `uploads`. Chỉ đọc, cộng một request tới media; dòng "Log WAF,
Malware Protection S3, data event prd" và "Flow log" của bảng "Thêm mỗi buổi" ở [phụ lục ADR-0060
§12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0060-org-detection-logging.md#thêm-mỗi-buổi)
đã gồm phần dùng thêm. Biến của mục, một lần:

```sh
values=$SVP_SESSION_DIR/cluster-values.json
L=$SVP_AWS_LOG_ACCOUNT_ID A=$SVP_AWS_STG_ACCOUNT_ID
```

(a) Add-on `aws-guardduty-agent`, DaemonSet của nó trên mọi node (cả node Karpenter), coverage EKS của cluster:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager eks describe-addon --cluster-name svp-stg --addon-name aws-guardduty-agent --region ap-southeast-1 \
  --query 'addon.[status,addonVersion]' --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes --no-headers | wc -l
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n amazon-guardduty get daemonset aws-guardduty-agent
det=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty list-detectors --region ap-southeast-1 --query 'DetectorIds[0]' --output text)
AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty list-coverage --detector-id "$det" --region ap-southeast-1 --output text \
  --query "Resources[?ResourceDetails.EksClusterDetails.ClusterName=='svp-stg'].[CoverageStatus,Issue]"
```

Mong `ACTIVE` với version ghim ở `aws/modules/eks/addons.tf`; `DESIRED`, `READY` của DaemonSet bằng số node; `HEALTHY None`. `UNHEALTHY`
hay không dòng nào: chờ 10 phút, chạy lại lệnh cuối một lần; vẫn vậy thì dán output (cột `Issue` nêu lý do) cho AI.

(b) Flow log của VPC vào bucket `svp-flowlogs-<log>-ap-southeast-1` dưới tiền tố của account env (Parquet, gom mỗi 60 s,
object tới trễ tới ~10 phút):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 describe-flow-logs --region ap-southeast-1 \
  --filter "Name=resource-id,Values=$(jq -r .vpcId "$values")" \
  --query 'FlowLogs[].[FlowLogStatus,DeliverLogsStatus,LogDestinationType,TrafficType]' --output text
p="AWSLogs/aws-account-id=$A/aws-service=vpcflowlogs/aws-region=ap-southeast-1/$(date -u +year=%Y/month=%m/day=%d)/"
AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 ls "s3://svp-flowlogs-$L-ap-southeast-1/$p" --recursive --region ap-southeast-1 | tail -n 3 |
  sed "s/$A/<account>/g"
```

Mong `ACTIVE SUCCESS s3 ALL`; ba object `.parquet` mới nhất, cái cuối trong 10 phút gần đây. Rỗng: đọc lại sau 10 phút
(ngay sau 00:00 UTC thư mục ngày mới còn rỗng: đọc lại sau 10 phút); vẫn rỗng mà dòng đầu đúng thì dán cả hai output.

(c) Log WAF của media che `authorization`, `cookie`: một request mang hai header giả tới object probe của media (web ACL
`svp-stg-media`), rồi đọc bản ghi của đúng request đó ở bucket log WAF. Lệnh đọc chỉ in tên header và giá trị của hai header
đó, không in cả bản ghi (bản ghi có IP người xem, URI, account):

```sh
since=$(date -u +%Y-%m-%dT%H:%M:%S)
curl -4 -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer session-redaction-check' \
  -H 'Cookie: svp_session_check=1' "https://$(jq -r .mediaDomain "$values")/media/uptime-probe.txt"
```

Mong `200`. Mười phút sau (WAF giao file mỗi năm phút):

```sh
b=aws-waf-logs-svp-$L-us-east-1
AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3api list-objects-v2 --bucket "$b" --prefix "AWSLogs/$A/WAFLogs/" --region us-east-1 \
  --query 'Contents[].[Key,LastModified]' --output json |
  jq -r --arg s "$since" '(. // [])[] | select((.[0] | contains("/svp-stg-media/")) and .[1] >= $s) | .[0]' |
  while read -r k; do AWS_PROFILE=anhnv-log-ro aws --no-cli-pager s3 cp "s3://$b/$k" - --region us-east-1 | gunzip -c; done |
  jq -c 'select(any(.httpRequest.headers[]?; (.name | ascii_downcase) == "authorization"))
    | [.httpRequest.headers[]? | .name as $n
      | if ($n | ascii_downcase | IN("authorization", "cookie")) then "\($n)=\(.value)" else $n end]' | head -n 3
```

Mong một dòng (probe uptime không gửi `Authorization`, nên chỉ request trên khớp): danh sách tên header, trong đó `authorization=REDACTED`
và `cookie=REDACTED`. Hai header mang giá trị gửi đi: logging của web ACL mất `redacted_fields` (`aws/modules/waf/main.tf`), dán dòng đó
cho AI. Không dòng nào: đọc lại sau năm phút; vẫn không thì dán output của lệnh `list-objects-v2` (chỉ số key) cho AI.

(d) Malware Protection for S3: plan của `uploads` `ACTIVE`, và object video mới nhất mà smoke tải lên mang tag kết quả
quét (luồng transcode không đổi: smoke đã tới `READY`):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty list-malware-protection-plans --region ap-southeast-1 \
  --query 'MalwareProtectionPlans[].MalwareProtectionPlanId' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager guardduty get-malware-protection-plan --malware-protection-plan-id <id trên> --region ap-southeast-1 \
  --query '[Status,ProtectedResource.S3Bucket.BucketName]' --output text | sed "s/$A/<account>/g"
up=$(jq -r .uploadsBucket "$values")
key=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-objects-v2 --bucket "$up" --region ap-southeast-1 --output text \
  --query "sort_by(Contents[?Key != 'malware-protection-resource-validation-object'], &LastModified)[-1].Key"); echo "$key"
AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api get-object-tagging --bucket "$up" --key "$key" --region ap-southeast-1 \
  --query "TagSet[?Key=='GuardDutyMalwareScanStatus'].Value" --output text
```

Mong một id; `ACTIVE svp-stg-uploads-<account>-ap-southeast-1`; key của video smoke; `NO_THREATS_FOUND`. Dòng cuối rỗng:
GuardDuty chưa quét xong, đọc lại sau một phút. Không key nào (lệnh `list-objects-v2` lỗi hay in `None`: bucket không còn
video, vd smoke chưa chạy): tải một video qua app (`AWS_PROFILE=anhnv-stg make -C ../backend eks-smoke CONTEXT=svp-stg
DOMAIN=<domain>`) rồi chạy lại ba lệnh cuối. Plan `WARNING`, `ERROR` hay tag khác: dán output cho AI.

## Alarm tới email

Loại: `lõi`.

(f) Alarm tới email (ADR-0058 §1), phép kiểm buổi stg của mục "Xác nhận" của ADR-0058, ghi như mục trên: mọi alarm của
bảng ở `OK` hay `INSUFFICIENT_DATA`, rồi ép một alarm `page` sang `ALARM`; email tới có URL runbook; CloudWatch đưa
alarm về trạng thái thật ở lần đánh giá kế (chu kỳ 60 s) và gửi thư `OK`:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudwatch describe-alarms --alarm-name-prefix svp-stg- --region ap-southeast-1 --output text \
  --query 'MetricAlarms[].[AlarmName,StateValue]'
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudwatch set-alarm-state --alarm-name svp-stg-rds-storage-low --state-value ALARM \
  --state-reason 'session test of the alarm path' --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudwatch describe-alarm-history --alarm-name svp-stg-rds-storage-low --history-item-type StateUpdate \
  --max-items 3 --region ap-southeast-1 --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
```

Mong một dòng mỗi alarm của bảng ADR-0058 §2 (`svp-stg-<alarm>`), không dòng nào `ALARM`; vài phút sau hai thư tới `alarm_email`: `ALARM:
"svp-stg-rds-storage-low"` có URL `…/docs/runbooks/rds-storage-low.md` trong phần mô tả, rồi `OK`; lịch sử có hai lần đổi trạng thái.
Không thư nào: đọc lại subscription (mục
[6–10](session-stg-deploy.md#610-root-env-init-khoá-ký-plan-lưu-file-đọc-apply-file-đó-kích-hoạt-khoá-ký)); subscription đã xác nhận mà
vẫn không thư: dán output cho AI (key policy của CMK, README của `aws/modules/alarms`).

## Gỡ

Các phép kiểm ở trang này không để lại tài nguyên của buổi ngoài những thứ nó tự nêu (pod, tệp trong `$SVP_SESSION_DIR`); gỡ cuối buổi ở
[`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31).

## Khi một bước đỏ

Phép kiểm đỏ thì ghi kết quả, dán output cho AI rồi sang phép kế: bước 16 là bước duy nhất của bảng
[Thứ tự](session-stg.md#thứ-tự) được đi tiếp khi đo hỏng. Lỗi riêng của từng phép ở nhãn **Bẫy** hay phần **Mong** của nó; destroy kẹt:
[Destroy kẹt](session-stg.md#destroy-kẹt).
