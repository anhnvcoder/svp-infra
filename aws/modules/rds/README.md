# Module `rds`

Một instance RDS PostgreSQL cho mọi service của một env (mỗi service vẫn một database và cặp role riêng, do Job bootstrap của cluster
tạo; module không tạo database nào). Thiết kế: [ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md)
mục 9 và 11.

Tạo: DB subnet group (subnet private), security group chỉ nhận TCP 5432 từ các security group truyền vào (không rule egress), parameter group
`postgres<major>` với `rds.force_ssl = 1` (kết nối không TLS bị từ chối), instance gp3 mã hoá bằng key AWS quản lý của RDS, không public,
master username cố định `postgres`, mật khẩu master do RDS tạo và giữ ở Secrets Manager (`manage_master_user_password`: không đi qua
Terraform, không có trong plan hay state). Performance Insights và enhanced monitoring tắt (tốn tiền, thêm role IAM; lab đọc Prometheus của
cluster). Minor tự nâng trong cửa sổ bảo trì, major không bao giờ tự nâng.

## Biến

| Biến | Kiểu | Mặc định | stg (7a) | prd (7b) | Ý nghĩa |
| --- | --- | --- | --- | --- | --- |
| `name` | string | — | `svp-stg` | `svp-prd` | Identifier của instance, tiền tố của security group, subnet group, parameter group |
| `vpc_id` | string | — | VPC của module `network` | như stg | VPC của instance |
| `subnet_ids` | list(string) | — | subnet private, ≥ 2 AZ | subnet private, 3 AZ | Subnet group (RDS đòi ≥ 2 AZ kể cả single-AZ) |
| `allowed_security_groups` | map(string) | — | `{ node = …, cluster = … }` của EKS | như stg | Được vào 5432; khoá là nhãn cố định nên `for_each` biết trước lúc plan dù id chưa có |
| `engine_major_version` | string | `"15"` | `"15"` | `"15"` | Major PostgreSQL (như local); nâng major là bài riêng |
| `instance_class` | string | `db.t4g.small` | `db.t4g.small` | đo ở 7b | Lớp instance |
| `allocated_storage` | number | `20` | `20` | đo ở 7b | GiB gp3 (tối thiểu 20) |
| `multi_az` | bool | `false` | `false` | `true` | Standby đồng bộ ở AZ khác, tự chuyển khi lỗi (gấp đôi giá instance) |
| `backup_retention_period` | number | `1` | `1` | ≥ 7, chốt ở 7b | Ngày backup tự động và PITR (1–35; 0 sẽ tắt backup nên không nhận) |
| `delete_automated_backups` | bool | `true` | `true` | `false` | Xoá backup tự động (và cửa sổ PITR) cùng instance; prd giữ lại để sau khi xoá instance vẫn phục hồi được tới từng giây trong `backup_retention_period`, snapshot cuối chỉ giữ một thời điểm |
| `deletion_protection` | bool | **không có** | `false` | `true` | Từ chối xoá instance tới khi một `apply` tắt nó |
| `skip_final_snapshot` | bool | **không có** | `true` | `false` | Xoá instance không chụp snapshot cuối |

Hai biến bảo vệ dữ liệu không có mặc định: quên đặt thì hoặc mất dữ liệu prd, hoặc buổi stg không destroy được, nên mỗi env phải ghi rõ.
Snapshot cuối (khi `skip_final_snapshot = false`) tên `<name>-final-<8 hex>`, hậu tố ngẫu nhiên sống cùng instance, nên dựng lại rồi destroy
lần hai không trùng tên snapshot cũ.

## Output

| Output | Giá trị |
| --- | --- |
| `address` | Tên host của instance (phân giải ra IP private trong VPC): `rdsAddress` của `cluster_values` |
| `port` | `5432` |
| `master_user_secret_arn` | ARN secret Secrets Manager mà RDS giữ mật khẩu master (JSON `username`, `password`); ARN không phải bí mật, đọc giá trị cần `secretsmanager:GetSecretValue` |
| `security_group_id` | Security group của instance |

## Mật khẩu master xoay vòng

Secrets Manager xoay mật khẩu master do RDS quản lý theo chu kỳ mặc định 7 ngày. Script buổi AWS đọc mật khẩu từ `master_user_secret_arn`
**ngay trước** khi nạp secret nguồn `pg-superuser` của cluster (chỉ `password`; username luôn `postgres`), không ra file, không in. Một
lần xoay giữa buổi làm secret trong cluster cũ đi: Job bootstrap chạy lại sẽ không đăng nhập được tới khi nạp lại. Buổi dài hơn chu kỳ xoay
nằm ngoài phạm vi 7a.

## Chi phí theo giờ (`ap-southeast-1`, giá đọc 2026-10-31, nguồn ở ADR-0034 [N7], [N11])

| Tài nguyên | Giá | Mỗi giờ |
| --- | --- | --- |
| Instance `db.t4g.small` single-AZ | $0,051/giờ (Multi-AZ $0,102/giờ) | $0,051 |
| gp3 20 GB | $0,138/GB-tháng | ~$0,004 (Multi-AZ tính theo giá Multi-AZ của trang giá, chưa ghi số ở đây) |
| Backup tự động | Miễn phí tới bằng dung lượng database mỗi region (trang giá [N7]); retention 1 ngày ở stg | ~$0 |
| Secret master (Secrets Manager) | $0,40/secret-tháng, $0,05/10 000 API | ~$0,0006 |
| Subnet group, security group, parameter group | Không tính tiền | $0 |

stg ~$0,055/giờ. Snapshot cuối của prd tính theo giá lưu trữ backup tới khi xoá tay.

## Có thể sót sau destroy

- **Secret master của RDS** (Secrets Manager, tên bắt đầu `rds!db-`): đi theo instance, chưa kiểm trên account; destroy dở (instance chưa
  xoá xong) thì còn. Quét Secrets Manager kể cả secret đang chờ xoá.
- **Snapshot cuối** `<name>-final-<hex>` khi `skip_final_snapshot = false` (prd): cố ý giữ lại, xoá tay khi không cần. stg không có.
- **Backup tự động:** stg `delete_automated_backups = true` nên xoá cùng instance; prd `false` nên còn lại sau destroy tới hết
  `backup_retention_period` (cố ý, tính tiền lưu trữ backup), xoá sớm bằng tay. `copy_tags_to_snapshot = true` nên snapshot mang tag
  `Project=svp` của root, quét được theo tag.
- **Instance còn `deletion_protection = true`:** `terraform destroy` dừng ở instance; phải `apply` với `false` trước.
