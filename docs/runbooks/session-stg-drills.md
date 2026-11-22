# Runbook: diễn tập khôi phục và finding bảo mật của buổi stg (bước 17–19)

← [Phép kiểm managed](session-stg-check-managed.md) · [Mục lục](README.md) · [Gỡ buổi stg](session-stg-teardown.md) →

> **Tóm tắt**
>
> - **Làm gì:** diễn tập khôi phục AWS Backup (bước 17 `backup`, 18 `rds` PITR, 19 `s3` object), rồi đọc finding bảo mật của buổi
>   (GuardDuty, Access Analyzer, control Security Hub khi cờ bật) trước khi tài nguyên của buổi bị gỡ.
> - **Khi nào và bao lâu:** sau các phép kiểm của bước 16, khi không còn tải, và trước bước 20. Hạn 60, 75, 30 phút cho bước 17,
>   18, 19; đường mặc định bỏ bước 17–19 và chỉ đọc finding.
> - **Phí trong lúc chạy:** diễn tập là `chuẩn ngành`: instance `svp-stg-pitr`, request và restore S3 (bảng "Mỗi buổi" ở mục "Chi phí" của
>   [phụ lục ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#mỗi-buổi)); đọc finding
>   không tốn tiền; control Security Hub cần cờ trả phí (mục cuối).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output người học dán lại.

## Điều kiện trước

- [ ] **Bước 1–15 xong và bước 16 đã chạy** ([`session-stg-deploy.md`](session-stg-deploy.md)); không client nào còn ghi (k6 đã xong).
- [ ] **Backup đã áp** (điều kiện 10 của [trang chủ](session-stg.md#điều-kiện-trước)): plan `svp-stg`, vault `svp-stg-copy`, profile
  `anhnv-backup-ro`.
- [ ] **Tunnel còn mở** (bước 18 đọc dữ liệu qua `svp-pg` trong pod `svp-ops`).
- [ ] **Finding bảo mật:** bước (4), (5) của [`org-security-setup.md`](org-security-setup.md#thứ-tự-áp-lần-đầu) đã áp (profile
  `anhnv-security-ro`, Security Hub ở `svp-security`). Org mới áp tới bước (3) thì chưa có gì để đọc: bỏ qua mục
  [Finding bảo mật của buổi](#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20) (script sẽ `FAIL` ở profile đó). Kiểm:
  `aws configure list-profiles | grep -x anhnv-security-ro` không in gì là chưa có.

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ; cần `SVP_SESSION_DIR` của buổi
đang dở, `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID`, profile `anhnv-stg`, `anhnv-backup-ro` và `anhnv-security-ro`.

## 17–19. Diễn tập khôi phục

Loại: `chuẩn ngành`, không cần cờ. Thêm: hạn 60, 75, 30 phút của bước 17, 18, 19 (bảng [Thứ tự](session-stg.md#thứ-tự)); instance
`svp-stg-pitr`, request và restore S3 (bảng "Mỗi buổi" ở mục "Chi phí" của [phụ lục
ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#mỗi-buổi)). Bỏ chúng không đổi bước 25: nó
chạy ở mọi đường.

```sh
aws/scripts/restore-drill.sh stg backup
aws/scripts/restore-drill.sh stg rds
aws/scripts/restore-drill.sh stg s3
```

Chạy sau bước 16 và các phép kiểm của nó, khi không còn tải: k6 đã xong, không client nào ghi (Diễn tập PITR chỉ so nội dung tại
các mẫu). Tunnel còn mở: bước 18 đọc dữ liệu qua `svp-pg` trong pod `svp-ops`. Mục tiêu RTO/RPO, cách đo và giới hạn của kết luận:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §2, §9, §10; hạn của từng lần chờ ở đầu
`restore-drill.sh`. Mỗi lệnh con ghi mốc `backup-undrained` sau kiểm account, trước lệnh ghi đầu tiên, nên sau nó `tf.sh` chỉ
destroy root env khi bước 25 đã chạy lại.

- **Kiểm:** xem trước lệnh của một lệnh con, không chạy gì: `aws/scripts/restore-drill.sh --print stg backup` (hay `rds`, `s3`, `cleanup`).
- **Mong đợi:** kết quả mỗi lần chạy thêm một dòng vào `restore-drill.tsv` (cột `kind t0 t1 rto_s rpo_s check note`, giờ UTC). Dán
  lại bảng sau bước 19:

  ```sh
  column -t -s "$(printf '\t')" "$SVP_SESSION_DIR/restore-drill.tsv"
  ```

  Số đo (RTO, RPO, thời gian của từng bước) vào phụ lục ADR-0067 sau buổi.

**Bước 17, `backup`.**

Kiểm cấu hình mà lịch hằng ngày dựa vào: plan `svp-stg` do Backup policy `svp-backup-stg` sinh trong account, selection
`svp-stg-tagged` của nó, opt-in RDS và S3 của account. Rồi job on-demand cho instance `svp-stg` và hai bucket vào vault `svp-stg`
bằng role `svp-stg-backup` (retention là của rule `daily`), chờ xong; copy từng recovery point sang vault `svp-stg-copy` của
`svp-backup` (retention bản copy của plan), chờ xong; ghi `restore-drill-points.tsv` (**Điểm của buổi**, bước 19 và bước 25 đọc
nó).

- **Mong đợi:** `ok plan svp-stg: …`, `ok selection svp-stg-tagged: …`, `ok opt-in of RDS and S3 on …`, ba dòng `ok backup job …
  completed` và ba dòng `ok copy job … completed`, rồi `PASS  backup: …`.
- **Bẫy:** dòng `FAIL`:

  | Dòng `FAIL` | Nguyên nhân | Cách xử lý |
  | --- | --- | --- |
  | `no backup plan svp-stg in the account of stg` | policy `svp-backup-stg` chưa gắn OU `NonProd`, hay AWS chưa sinh plan trong account | kiểm theo bước (7) của [`backup-setup.md`](backup-setup.md#bước-7-kiểm-sau-áp); chưa có thì bỏ diễn tập, sang bước 20 |
  | `plan svp-stg is not the policy's` hay `selection svp-stg-tagged is not the policy's` | plan trong account khác Backup policy của `aws/org` | dán dòng đó cho AI; không sửa plan ở account (plan của policy là bất biến) |
  | `opt-in of the account of stg …` | `aws/accounts/stg` chưa áp phần backup | áp theo bước (6) của `backup-setup.md`, rồi chạy lại bước 17 |
  | `backup job … ended …: no recovery point` hay `copy job … is FAILED` | job lỗi | đọc `StatusMessage` (lệnh dưới), dán cho AI; lỗi quyền ở copy job thường là vault access policy của `svp-stg-copy` hay key policy |
  | `backup jobs still running after …` | job chưa xong khi hết hạn chờ | đọc job bằng lệnh script in ra; xong thì chạy lại bước 17 (lượt mới tạo job mới; recovery point của job cũ không có copy job, nên bước 25 giữ nó và `FAIL … has no completed copy … kept`: chọn copy lại hay xoá theo lệnh in ra) |

  ```sh
  AWS_PROFILE=anhnv-stg aws --no-cli-pager backup describe-backup-job --backup-job-id <id> --region ap-southeast-1 --query '[State,StatusMessage]' --output text
  AWS_PROFILE=anhnv-stg aws --no-cli-pager backup describe-copy-job --copy-job-id <id> --region ap-southeast-1 \
    --query 'CopyJob.[State,StatusMessage]' --output text
  ```

**Đọc bản copy** (sau bước 17, chỉ đọc, profile `anhnv-backup-ro` của account `svp-backup`): recovery point của buổi trong
`svp-stg-copy`, mã hoá bằng key của chính vault đó (dùng được sau khi key RDS bị xoá cuối buổi, và cả khi key vault env, sống giữa
các buổi, bị xoá khi gỡ lab). Script không in ARN nào (ARN mang id account); cùng lệnh đọc finding bảo mật của mục [Finding bảo
mật của buổi](#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20), nên chạy được từ sau bước 17:

```sh
aws/scripts/preflight.sh findings stg
```

- **Mong đợi:** dòng của backup đứng đầu: ba `note  svp-stg-copy: RDS|S3 COMPLETED created <giờ>, deleted at <giờ>, vault-key` (một `RDS`,
  hai `S3`), rồi `ok    svp-stg-copy: every recovery point COMPLETED under the key of the vault (DeleteAt - CreationDate: compare with
  ADR-0067 §4)`. `DeleteAt` cách `CreationDate` phải đúng retention bản copy của stg (ADR-0067 §4). Phần security của cùng lệnh chạy lại an
  toàn sau bước 19.
- **Bẫy:** `FAIL  no recovery point in svp-stg-copy created after …` (bước 17 chưa xong, hay copy job chưa kết thúc), hay `FAIL  N
  recovery point(s) … not COMPLETED or not under the key of the vault` (một dòng `note` ở trên là `other-key` hay chưa
  `COMPLETED`): dán output cho AI. `FAIL  backup describe-backup-vault … (profile missing? …)`: profile `anhnv-backup-ro` chưa ghi
  hay permission set chưa gán (bước (1), (2) của `backup-setup.md`). Org mới áp tới bước (3) (điều kiện 6 của trang chủ, chưa
  profile `anhnv-security-ro`) thì lệnh kết thúc bằng `FAIL  aws sts get-caller-identity with profile anhnv-security-ro …` sau các
  dòng backup: đúng như mong đợi, chỉ đọc các dòng backup.

**Bước 18, `rds`.**

**Diễn tập PITR** của ADR-0067 §9: mẫu S1 (**Kiểm dữ liệu** trên `svp-stg` qua `svp-pg`), T_r là lúc S1 xong làm tròn lên giây kế; chờ
`LatestRestorableTime` ≥ T_r; mẫu S2 trên nguồn; restore `--restore-time` T_r ra `svp-stg-pitr` (cùng subnet group, security group,
parameter group, lớp; một AZ); chờ `available`; mẫu R trên bản khôi phục; so; rồi xoá `svp-stg-pitr` và chờ nó mất, kể cả khi FAIL.

- **Mong đợi:** `ok sample S1 of svp-stg; T_r …`, `ok sample S2 equals S1`, dòng `PASS  rds: RTO … s, RPO … s; R equals S1 on the
  tables checked`, rồi `ok svp-stg-pitr deleted`.
- **Bẫy:** dòng kết quả `FAIL rds` là số đo (sang bước 19), trừ dòng đầu của bảng:

  | Dòng | Nghĩa | Cách xử lý |
  | --- | --- | --- |
  | `source changed during window` | có ghi giữa S1 và S2 (còn tải, job, consumer): không restore gì | chờ hết ghi, chạy lại bước 18 |
  | `restore differs from sample S1` | R khác S1; chưa chứng minh restore sai: ghi giữa lúc S1 xong và T_r không để dấu ở S1, S2 | dán phần `diff` script in và log của ba service quanh T_r (lệnh dưới) cho AI |
  | `RTO over 3600 s`, `RPO over 300 s` | vượt mục tiêu của ADR-0067 §2 | ghi lại; số đo vào phụ lục |
  | `… is left from an earlier drill` | `svp-stg-pitr` còn từ lần trước | chạy lệnh xoá script in, chờ nó mất, chạy lại bước 18 |
  | `LatestRestorableTime of svp-stg is still before T_r` | RDS chưa đẩy log giao dịch tới T_r trong hạn chờ | đọc bằng lệnh script in, chạy lại bước 18 |
  | `could not read svp-stg-pitr` hay `svp-stg-pitr is still …` | xoá instance khôi phục chưa xong hay lỗi | chạy lệnh `delete-db-instance` script in; `sweep.sh stg` của bước 30 cũng bắt nó |

  ```sh
  for s in video-service engagement-service feed-service; do
    AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp logs "deploy/$s" --since-time=<T_r trừ 2 phút, RFC 3339> --timestamps | head -n 100
  done
  ```

**Bước 19, `s3`.**

**Diễn tập object S3** của ADR-0067 §10: recovery point là dòng của bucket media trong `restore-drill-points.tsv`; key là key
`.m3u8` đầu tiên theo thứ tự từ điển dưới `media/` có trước recovery point đó; tải, ghi độ dài và SHA-256; xoá key (delete
marker); restore item-level đúng key đó vào chính bucket bằng role `svp-stg-backup`; tải lại, so độ dài và SHA-256 (ETag không so:
AWS Backup không giữ ETag).

- **Mong đợi:** `ok s3://svp-stg-media-…/<key>: N bytes, SHA-256 …; deleting it`, rồi `PASS  s3: RTO … s, RPO … s; …`. `rpo_s` là tuổi của
  recovery point đã dùng, chỉ ghi lại: RPO của S3 là giới hạn cấu hình (ADR-0067 §2).
- **Bẫy:** dòng `FAIL`:
  - `no line of arn:aws:s3:::… in …restore-drill-points.tsv`: bước 17 chưa xong cho bucket media; chạy bước 17, rồi bước 19.
  - `no .m3u8 under media/ … older than its recovery point`: bucket media chưa có video nào trước lúc backup (smoke của bước 16 chưa chạy);
    không diễn tập được ở buổi này, ghi lại.
  - `restore job … ended …` hay `… after … s`: key vẫn bị xoá, version cũ còn (bucket có versioning). Khôi phục bằng cách xoá delete marker
    (lệnh dưới; key là key script in), dán `StatusMessage` của job cho AI.

  ```sh
  aws/scripts/check-account.sh stg
  b="svp-stg-media-$SVP_AWS_STG_ACCOUNT_ID-ap-southeast-1"
  AWS_PROFILE=anhnv-stg aws --no-cli-pager backup describe-restore-job --restore-job-id <id> --region ap-southeast-1 --query '[Status,StatusMessage]' --output text
  AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api list-object-versions --bucket "$b" --prefix <key> --region ap-southeast-1 \
    --query 'DeleteMarkers[?IsLatest].VersionId' --output text
  AWS_PROFILE=anhnv-stg aws --no-cli-pager s3api delete-object --bucket "$b" --key <key> --version-id <VersionId của delete marker> --region ap-southeast-1
  ```

## Finding bảo mật của buổi (sau bước 19, trước bước 20)

Loại: `lõi` (đọc finding GuardDuty, không tốn tiền); phần control Security Hub là mục con
[Control Security Hub của buổi](#control-security-hub-của-buổi). Đường mặc định không chạy bước 17–19: đọc mục này sau các phép của bước 16,
trước bước 20.

Chỉ đọc, profile `anhnv-security-ro` của account Security Tooling, khi tài nguyên của buổi **còn sống**: finding của buổi đọc
trước khi gỡ, và tài nguyên bị xoá thì finding control của nó chuyển `NOT_AVAILABLE` và `ARCHIVED` (Security Hub CSPM User Guide,
"Generating and updating control findings"), nên lượt đọc định kỳ của `security-alert.md` không bao giờ thấy tài nguyên chỉ sống
trong buổi. Buổi dừng sớm rồi đi thẳng tới gỡ: vẫn đọc mục này trước bước 20 (đường `--no-cluster` của mục
[23–27](session-stg-teardown.md#2327-gỡ-root-env): trước `plan --destroy`).

```sh
aws/scripts/preflight.sh findings stg      # prd session: findings prd
```

Script lấy giờ bắt đầu buổi từ dòng đầu của `$SVP_SESSION_DIR/timeline.tsv` và lọc theo account của env
(`SVP_AWS_STG_ACCOUNT_ID`), rồi đọc theo cờ `security_hub` của env (mục [Cờ chi phí của
buổi](session-stg.md#cờ-chi-phí-của-buổi)). Với giá trị của file (`off`) account không có control và GuardDuty của account không
gửi finding vào Security Hub, nên script đọc phần Access Analyzer ở Security Hub, và đọc finding GuardDuty thẳng ở delegated admin
GuardDuty, mỗi region một lần (`ap-southeast-1` và `us-east-1`, nơi nằm finding toàn cục: IAM, CloudFront, WAF).

- **Mong đợi:** `note  security_hub of stg is off …`, rồi `ok    GuardDuty <region>: no finding for the account since …` hay mỗi
  finding một dòng `note  GuardDuty <region> severity <số> (HIGH from 7, CRITICAL from 9): <loại>, <tiêu đề>`. Dòng của bản copy
  (profile `anhnv-backup-ro`, điều kiện 10 của trang chủ) đứng trước phần security. Lịch backup hằng ngày (18:00 UTC) chạy trong
  buổi, hay buổi đã chạy bước 17: dòng của bản copy đọc như đoạn **Đọc bản copy** của bước 17.
- **Bẫy:** đường mặc định không chạy bước 17, nên dòng `FAIL  no recovery point in svp-stg-copy created after … (step 17 of the
  session runbook not done, …)` là đúng như mong đợi: lệnh vẫn đọc phần security, rồi thoát mã 1 vì riêng dòng đó. Dòng `FAIL`
  khác nêu lệnh `aws` lỗi và profile của nó: sửa nguyên nhân (phiên SSO hết hạn: mục [Mở terminal](session-stg.md#mở-terminal))
  rồi chạy lại.
- **Việc tay:** dán toàn bộ output. Của finding, chỉ mức HIGH, CRITICAL tới email (cả finding phát sinh trong lúc gỡ), qua rule
  `svp-security-guardduty-findings` (dòng chung `svp-security: GuardDuty Finding …` cho finding ở `us-east-1`); mức thấp hơn
  (ngoài `[SAMPLE]`) đối chiếu thời điểm với `timeline.tsv` (diễn tập, đo) rồi xử lý theo mục "Đọc bảng Security Hub định kỳ" của runbook
  [`security-alert.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md#đọc-bảng-security-hub-định-kỳ).

### Control Security Hub của buổi

Loại: `chuẩn ngành`, cần `security_hub` và `config_recording` `always` của `stg` (Security Hub cần Config ở cùng account). Thêm:
Security Hub $1–3, Config $2–4,5 mỗi buổi (dòng `security_hub`, `config_recording` của [phụ lục ADR-0071,
Cờ](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#cờ)); hai lượt áp `aws/baseline`,
`aws/security` theo [`paid-features.md`](paid-features.md) trước và sau buổi.

Cùng lệnh `preflight.sh findings stg` của mục trên.

- **Mong đợi:** với cờ `always`: control FAILED của account (kể cả control của baseline đã có trong danh sách ban đầu, mục 7a của
  [`org-security-setup.md`](org-security-setup.md#7a-dịch-vụ-bật), lẫn của tài nguyên buổi) thành mỗi loại một dòng
  `note  Security Hub FAILED control x<n>: <control> <mức> <loại>`; id tài nguyên ghi vào `$SVP_SESSION_DIR/controls-failed.tsv` (mode 600),
  không in. Rồi finding GuardDuty và Access Analyzer cập nhật từ đầu buổi, mọi mức: `note  finding x<n> since the start: …`; không có thì
  `ok    Security Hub: no GuardDuty or Access Analyzer finding since …`.
- **Việc tay:** dán toàn bộ output, cùng `controls-failed.tsv` khi AI hỏi tới tài nguyên. Mỗi control FAILED, của tài nguyên buổi
  cũng như tài nguyên lâu dài, xử lý theo mục "Đọc bảng Security Hub định kỳ" của runbook `security-alert.md` (link ở mục trên):
  buổi sau tạo lại tài nguyên từ cùng code, nên lỗi không sửa trong Terraform sẽ quay lại.

## Gỡ

Diễn tập không để lại tài nguyên: `svp-stg-pitr` bị xoá cuối bước 18; recovery point của buổi xoá ở bước 25
([`session-stg-teardown.md`](session-stg-teardown.md#bước-25-xoá-backup-của-buổi)); bản copy ở `svp-stg-copy` ở lại tới hết retention.

## Khi một bước đỏ

Đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó**. Bước 18, 19 mà dòng kết quả là `FAIL` của phép đo: đó là số đo, sang bước kế
(bảng ở bước 18). Hết giờ thì bỏ diễn tập chưa chạy, sang bước 20; bước 25 không bao giờ bỏ.
