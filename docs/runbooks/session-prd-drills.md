# Runbook: diễn tập khôi phục ở prd (bước 17–19)

← [Kiểm và đo](session-prd-checks.md) · [Mục lục](README.md) · [Buổi prd, Kết thúc buổi](session-prd.md#kết-thúc-buổi) →

> **Tóm tắt**
>
> - **Làm gì:** chứng minh bản backup của prd khôi phục được: backup on-demand rồi copy sang `svp-backup` (bước 17), khôi phục RDS tới
>   một thời điểm (bước 18), khôi phục một object S3 từ AWS Backup (bước 19).
> - **Khi nào và bao lâu:** tuỳ chọn (`chuẩn ngành`), sau các phép đã chọn của mục Đo và sau lượt chạy lại (f) của Phép kiểm transcode,
>   tunnel mở. Hạn 60, 75, 30 phút của bước 17, 18, 19. Bỏ chúng không đổi bước 25.
> - **Phí trong lúc chạy:** instance `svp-prd-pitr` cùng lớp với nguồn là khoản lớn nhất của phần backup mỗi buổi; bảng "Mỗi buổi" ở mục
>   "Chi phí" của [phụ lục ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#mỗi-buổi).

**Người học chạy mọi lệnh ở đây**; AI đọc output dán lại. Trang này chỉ ghi phần khác stg.

## Điều kiện trước

- [ ] **Bước 1–16 xong** ([dựng](session-prd-deploy.md), [kiểm và đo](session-prd-checks.md)); mục Đo đã chọn đã chạy xong, lượt k6
  cuối đã xoá, không client nào ghi.
- [ ] **Lượt chạy lại (f) của [Phép kiểm transcode](session-prd-checks.md#phép-kiểm-transcode)** đã xong (hai hàng đợi về `0`).
- [ ] **Tunnel tới API mở** ([Tunnel tới API](session-prd-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11)).
- [ ] **Backup đã áp** theo điều kiện **Backup đã áp** của [trang chủ buổi prd](session-prd.md#điều-kiện-trước).

## Mở terminal

Dùng khối của [Mở terminal ở trang chủ buổi prd](session-prd.md#mở-terminal); lệnh chạy từ gốc repo này (`infra/`).

## Bước 17–19: diễn tập khôi phục

Loại: `chuẩn ngành`, không cần đổi cờ. Như mục [17–19](session-stg-drills.md#1719-diễn-tập-khôi-phục) của buổi stg, với `prd`, tunnel mở:

```sh
aws/scripts/restore-drill.sh prd backup
aws/scripts/restore-drill.sh prd rds
aws/scripts/restore-drill.sh prd s3
```

- **Khác stg ở dữ liệu:** plan `svp-prd` của Backup policy `svp-backup-prd`, vault `svp-prd`, role `svp-prd-backup`, bản copy vào
  `svp-prd-copy` (retention và vault lock của prd, ADR-0067 §4); instance `svp-prd-pitr` một AZ cùng lớp với `svp-prd` (nguồn Multi-AZ,
  bản khôi phục không), nên giờ của nó là khoản lớn nhất của phần backup mỗi buổi. Cùng mục tiêu RTO/RPO, cùng cách đọc dòng `FAIL`.
- **Việc tay:** lệnh xem log quanh T_r, khôi phục object bằng delete marker khi restore job lỗi: như stg với `anhnv-prd`,
  `--context svp-prd`, bucket `svp-prd-media-<account prd>-ap-southeast-1`.
- **Mong đợi:** mọi dòng `ok`/`FAIL`, dòng `PASS backup …` (bước 17), `PASS rds …` hay `FAIL rds …` (bước 18), `PASS s3 …` hay
  `FAIL s3 …` (bước 19). Dán bảng `restore-drill.tsv` (lệnh `column` của mục stg); số đo vào phụ lục ADR-0067 cùng số của stg.

### Đọc bản copy

Đọc bản copy bằng lệnh của mục stg:

```sh
aws/scripts/preflight.sh findings prd
```

Mong ba dòng `note  svp-prd-copy: … COMPLETED … vault-key` rồi dòng `ok`, `DeleteAt` cách `CreationDate` đúng retention bản copy của prd;
chưa profile `anhnv-security-ro` thì dòng `FAIL` cuối ở profile đó là đúng, như stg.

## Gỡ

Diễn tập xoá `svp-prd-pitr` cuối bước 18 (`drop_pitr` của `restore-drill.sh`) nhưng để lại recovery point và tag `Backup`: bước 25
(`restore-drill.sh prd cleanup`) xoá chúng, và `plan --destroy` dừng khi chưa có mốc `backup-drained`. Xem
[Kết thúc buổi](session-prd.md#kết-thúc-buổi). Bỏ bước 17–19 không đổi bước 25.

## Khi một bước đỏ

- **`FAIL rds …` hay `FAIL s3 …`:** dán dòng `FAIL` cùng bảng `restore-drill.tsv`; cách đọc như
  [stg](session-stg-drills.md#khi-một-bước-đỏ).
- **`FAIL no recovery point in svp-prd-copy …` khi đọc bản copy:** bước 17 chưa chạy hay chưa xong; dòng này đúng như mong đợi khi
  không chạy bước 17.
- **Hết hạn (60, 75, 30 phút):** bỏ phần còn lại, sang [Kết thúc buổi](session-prd.md#kết-thúc-buổi).
