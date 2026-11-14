# Thử Probe và một job MediaConvert ở account sandbox

Hướng dẫn này chạy `Probe` của AWS Elemental MediaConvert trên hai clip tham chiếu và nộp đúng job mẫu của bridge
(`media-worker mediaconvert`) ở account management (account sandbox, profile `anhnv-sso`), với bucket, queue và role tạm theo thiết kế
của role MediaConvert. Output thô của nó (kết quả Probe, `get-job`, danh sách key, playlist rendition, header của một segment) thành testdata
của bridge: phần "Account sandbox" của mục "Xác nhận" ở
[ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#xác-nhận). Bảng quyền của role
và các giá trị mà lần thử đối chiếu ở [phụ lục ADR-0066](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0066-mediaconvert-transcode.md)
(§4, §5, §9). Hướng dẫn kết thúc bằng lệnh gỡ và lệnh quét sót, trong cùng lần chạy.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output dán lại và nhắc tới khi gỡ và
quét sót đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`), ghi profile và region ngay trong lệnh: `ap-southeast-1` cho S3, MediaConvert,
STS; `us-east-1` cho IAM.

Chi phí: một job của clip 60 s và hai lần `Probe`, nằm trong phần chi phí của transcode ở
[ADR-0066 §12](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0066-mediaconvert-transcode.md#12-chi-phí) (Probe miễn phí
trong hạn mức tháng); queue on-demand, role và bucket không tính phí cố định.

## Trước khi bắt đầu

- AWS CLI v2 có lệnh `probe` (`AWS_PROFILE=anhnv-sso aws mediaconvert probe help --region ap-southeast-1` in trang trợ giúp; lỗi
  `Invalid choice` thì cập nhật AWS CLI), `jq` 1.6 trở lên (`walk`), `ffmpeg`.
- Bản clone repo code có file job mẫu `services/media-worker/internal/mediaconvert/testdata/create-job.json`: `CreateJobInput` mà bridge dựng
  cho nguồn 1080×1920 có âm thanh, với ARN và tên bucket giả (`000000000000`). Test của bridge so khớp nó từng byte, nên đây là job bridge nộp.
- Phiên SSO của `anhnv-sso` và 12 số của account management.

Tài nguyên tạm, mọi tên mang tiền tố `svp-` để `sweep.sh mgmt` liệt kê cái còn sót:

| Tài nguyên | Tên |
| --- | --- |
| Bucket (input dưới `uploads/`, output dưới `media/`) | `svp-mcprobe-<account>-ap-southeast-1` |
| Queue on-demand | `svp-mcprobe` |
| Role MediaConvert | `svp-mcprobe-mediaconvert`, policy inline `s3` |

Một bucket giữ cả hai tiền tố, nên quyền của role vẫn đúng bảng "Role MediaConvert" của phụ lục §9: chỉ đọc `uploads/*`, chỉ ghi `media/*`.

## 1. Mở terminal

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>        # never written to a file: the repo is public
export SVP_SESSION_DIR="$PWD/.session/mediaconvert-probe-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SVP_SESSION_DIR"; d=$SVP_SESSION_DIR
# The job the bridge submits, from your clone of the code repo.
JOB_SRC=../backend/services/media-worker/internal/mediaconvert/testdata/create-job.json
b=svp-mcprobe-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1
aws/scripts/check-account.sh mgmt
```

Tìm: `ok    account <12 số> of mgmt, …` với đúng account management. `FAIL` thì dừng, không chạy gì nữa. Mọi bước sau chạy trong **cùng terminal
này**. Mở lại terminal giữa chừng: đặt lại các biến trên với `SVP_SESSION_DIR` là thư mục cũ, rồi đọc lại hai ARN ở `$d/arns.txt` (bước 3).

## 2. Sinh hai clip tham chiếu

Lệnh của mục "Phép đo hai đường: phương pháp" ở phụ lục ADR-0066, với `-t 60` và `-t 200` (vài phút CPU):

```sh
for t in 60 200; do
  ffmpeg -f lavfi -i testsrc2=size=1080x1920:rate=30 -f lavfi -i sine=frequency=440 -t "$t" -c:v libx264 -pix_fmt yuv420p -c:a aac "$d/clip-${t}s.mp4"
done
```

## 3. Tạo bucket, queue, role

Lệnh ghi: chạy ngay sau `check-account.sh mgmt` của bước 1 (hay chạy lại nó). Bucket mới có sẵn chặn truy cập công khai và mã hoá SSE-S3.
Trust của role như role `svp-<env>-mediaconvert` của module `transcode`: `mediaconvert.amazonaws.com`, `aws:SourceAccount` là account,
`aws:SourceArn` là ARN queue:

```sh
AWS_PROFILE=anhnv-sso aws s3api create-bucket --bucket "$b" --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1 --query Location --output text
queue_arn=$(AWS_PROFILE=anhnv-sso aws mediaconvert create-queue --name svp-mcprobe --pricing-plan ON_DEMAND --region ap-southeast-1 \
  --query Queue.Arn --output text)
jq -n --arg acc "$SVP_AWS_MGMT_ACCOUNT_ID" --arg q "$queue_arn" '{Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Service: "mediaconvert.amazonaws.com"}, Action: "sts:AssumeRole",
  Condition: {StringEquals: {"aws:SourceAccount": $acc}, ArnLike: {"aws:SourceArn": $q}}}]}' > "$d/trust.json"
jq -n --arg b "$b" '{Version: "2012-10-17", Statement: [
  {Sid: "ReadInput", Effect: "Allow", Action: "s3:GetObject", Resource: "arn:aws:s3:::\($b)/uploads/*"},
  {Sid: "WriteOutput", Effect: "Allow", Action: "s3:PutObject", Resource: "arn:aws:s3:::\($b)/media/*"}]}' > "$d/policy.json"
role_arn=$(AWS_PROFILE=anhnv-sso aws iam create-role --role-name svp-mcprobe-mediaconvert --region us-east-1 \
  --assume-role-policy-document "file://$d/trust.json" --query Role.Arn --output text)
AWS_PROFILE=anhnv-sso aws iam put-role-policy --role-name svp-mcprobe-mediaconvert --policy-name s3 --region us-east-1 \
  --policy-document "file://$d/policy.json"
echo "$queue_arn $role_arn" | tee "$d/arns.txt"
```

Tìm: dòng `Location` của bucket, rồi `arn:aws:mediaconvert:ap-southeast-1:<12 số>:queues/svp-mcprobe` và
`arn:aws:iam::<12 số>:role/svp-mcprobe-mediaconvert`. Một lệnh lỗi (`BucketAlreadyOwnedByYou`, `EntityAlreadyExists`, `ConflictException`:
sót của lần chạy trước): sang bước 8 gỡ phần đó, rồi chạy lại bước này.

## 4. Probe hai clip

`Probe` đọc S3 bằng quyền người gọi (`anhnv-sso`), không qua role:

```sh
for t in 60 200; do
  AWS_PROFILE=anhnv-sso aws s3 cp "$d/clip-${t}s.mp4" "s3://$b/uploads/clip-${t}s" --region ap-southeast-1
  AWS_PROFILE=anhnv-sso aws mediaconvert probe --input-files "FileUrl=s3://$b/uploads/clip-${t}s" --region ap-southeast-1 \
    --output json > "$d/probe-${t}s.json"
done
cat "$d/probe-60s.json" "$d/probe-200s.json"
```

Tìm: thời lượng của container và của track video quanh `60` và `200` (giây), một track audio, kích thước 1080 × 1920, tốc độ khung 30. Dán
lại nguyên hai file.

## 5. Nộp job mẫu

`jq` thay ARN queue, ARN role và tên hai bucket giả của file mẫu bằng tài nguyên tạm; mọi trường khác giữ nguyên. Clip 60 s được chép vào đúng
key input mà job đọc:

```sh
jq --arg q "$queue_arn" --arg r "$role_arn" --arg b "$b" \
  '.Queue = $q | .Role = $r | walk(if type == "string" then gsub("svp-stg-(uploads|media)-000000000000-ap-southeast-1"; $b) else . end)' \
  "$JOB_SRC" > "$d/create-job.json"
grep -c 000000000000 "$d/create-job.json"
in=$(jq -r '.Settings.Inputs[0].FileInput' "$d/create-job.json"); echo "$in"
AWS_PROFILE=anhnv-sso aws s3 cp "$d/clip-60s.mp4" "$in" --region ap-southeast-1
job=$(AWS_PROFILE=anhnv-sso aws mediaconvert create-job --cli-input-json "file://$d/create-job.json" --region ap-southeast-1 \
  --query Job.Id --output text)
echo "$job" | tee "$d/job-id.txt"
```

Tìm: `0` (không còn định danh giả), `s3://svp-mcprobe-<12 số>-ap-southeast-1/uploads/<uuid>`, rồi một job ID. `create-job` lỗi tham số: dán lỗi
và `$d/create-job.json` cho AI, không sửa file mẫu.

## 6. Chờ job xong

```sh
for i in $(seq 1 90); do
  st=$(AWS_PROFILE=anhnv-sso aws mediaconvert get-job --id "$job" --region ap-southeast-1 --query Job.Status --output text)
  echo "$(date -u +%H:%M:%S) $st"
  case $st in COMPLETE | ERROR | CANCELED) break ;; esac
  sleep 10
done
AWS_PROFILE=anhnv-sso aws mediaconvert get-job --id "$job" --region ap-southeast-1 --output json > "$d/get-job.json"
jq -r '.Job | [.Status, .ErrorCode, .ErrorMessage] | map(tostring) | @tsv' "$d/get-job.json"
```

Tìm: `COMPLETE`. `ERROR`: dán `$d/get-job.json` cho AI và sang bước 8; không thêm quyền nào cho role (mã lỗi quyền S3 là phát hiện: bảng
quyền của phụ lục §9 thiếu). Hết 15 phút mà vẫn `SUBMITTED`, `PROGRESSING`: huỷ job (lệnh đầu của bước 8), dán output.

## 7. Đọc output

Danh sách key, mọi playlist rendition (tên theo `NameModifier` của output group HLS trong file job) và header của một segment, trước bước chép
mà bridge làm:

```sh
AWS_PROFILE=anhnv-sso aws s3 ls "s3://$b/media/" --recursive --region ap-southeast-1 | tee "$d/keys.txt"
hls='.Settings.OutputGroups[] | select(.OutputGroupSettings.Type == "HLS_GROUP_SETTINGS")'
pfx=$(jq -r "$hls | .OutputGroupSettings.HlsGroupSettings.Destination" "$d/create-job.json"); pfx=${pfx%index}
for m in $(jq -r "$hls | .Outputs[].NameModifier" "$d/create-job.json"); do
  echo "== index$m.m3u8"; AWS_PROFILE=anhnv-sso aws s3 cp "${pfx}index$m.m3u8" - --region ap-southeast-1
done | tee "$d/playlists.txt"
seg=$(awk '$4 ~ /\.ts$/ { print $4; exit }' "$d/keys.txt")
AWS_PROFILE=anhnv-sso aws s3api head-object --bucket "$b" --key "$seg" --region ap-southeast-1 --output json | tee "$d/head-segment.json"
```

Tìm: mọi key nằm phẳng trong `media/<video_id>/<version>/<attempt>/` (ba UUID của file mẫu): `index_<rendition>.m3u8` mỗi rendition,
`index.m3u8` của output group, segment `.ts`, một ảnh `thumb.<số>.jpg`; mỗi playlist là playlist media HLS trỏ segment bằng tên tương đối;
`head-object` có `ContentType` mà không có `CacheControl` (bridge đặt header bằng bước chép sau `COMPLETE`).

Dán lại nguyên: `probe-60s.json`, `probe-200s.json`, `get-job.json`, `keys.txt`, `playlists.txt`, `head-segment.json`. Các file chứa account
và tên bucket thật: chỉ dán cho AI (định danh được thay bằng `000000000000` và tên giả của file mẫu trước khi thành testdata); thư mục
`.session/` git bỏ qua.

## 8. Gỡ

Lệnh ghi, theo thứ tự: huỷ job còn dở (chỉ khi bước 6 dừng ở `SUBMITTED`, `PROGRESSING`; queue còn job thì không xoá được), bucket cùng mọi
object, policy inline rồi role, queue:

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws mediaconvert cancel-job --id "$job" --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws s3 rb "s3://$b" --force --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws iam delete-role-policy --role-name svp-mcprobe-mediaconvert --policy-name s3 --region us-east-1
AWS_PROFILE=anhnv-sso aws iam delete-role --role-name svp-mcprobe-mediaconvert --region us-east-1
AWS_PROFILE=anhnv-sso aws mediaconvert delete-queue --name svp-mcprobe --region ap-southeast-1
```

Bỏ lệnh `cancel-job` khi job đã `COMPLETE`, `ERROR` (nó trả lỗi, không đổi gì). Một lệnh khác lỗi `NoSuchBucket`, `NoSuchEntity`,
`NotFoundException`: phần đó đã gỡ, chạy tiếp lệnh sau.

## 9. Quét sót

```sh
aws/scripts/sweep.sh mgmt
```

Tìm: `ok nothing left in account … but what it keeps` (exit 0), không dòng nào nhắc `svp-mcprobe`. Có dòng `FAIL <loại>: N left`: chạy lệnh
`delete:` in dưới mỗi tài nguyên, rồi chạy lại tới khi sạch. Dán lại toàn bộ output. **Lần thử chỉ xong khi lượt quét này exit 0.**
