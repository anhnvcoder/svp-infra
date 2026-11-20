# Sơ đồ

Trang này tra cách dựng và cập nhật sơ đồ của repo: sơ đồ chính vẽ bằng D2 rồi sinh ra SVG, sơ đồ tổng có icon AWS giữ ở draw.io.
Lý do chọn D2 nằm ở [ADR-0079](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0079-d2-diagrams.md).

## Lệnh

Chạy từ gốc repo; D2 chạy trong container ghim digest (`D2_IMAGE` của `Makefile`), không mạng.

| Lệnh | Việc |
| --- | --- |
| `make diagrams` | Sinh mọi `docs/diagrams/*.d2` (trừ `tokens.d2`) thành `.svg` cùng tên |
| `make diagrams-check` | Sinh vào thư mục tạm, so với SVG đã commit; lệch, thiếu, hay SVG không còn `.d2` cùng tên thì exit 1 kèm tên file |
| `make diagrams PNG=1` | Sinh thêm `.png` bên cạnh để xem; không commit |
| `make diagrams LAYOUT=<engine> OUT=<thư mục> SUFFIX=<chữ>` | Bản thử: engine khác `layout-engine` của file, thư mục khác, hậu tố tên; không commit |
| `python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py --pdf --docs` | Sinh `svp-aws.drawio` (sơ đồ tổng có icon AWS) cùng PDF, PNG mỗi trang từ spec, không sửa tay; cỡ trang env đọc từ `<env>.tfvars` và `variables.tf` của `aws/envs/<env>`, đổi cỡ thì build lại; cần CLI draw.io (`brew install --cask drawio` hay biến `DRAWIO`) |
| `check_diagram.py docs/diagrams/svp-aws.drawio`, `check_svp_counts.py` (cùng thư mục script) | Kiểm offline trước khi commit: hình học; số AZ, subnet, NAT, node, bastion, RDS, broker, node ElastiCache khớp cỡ env |

`diagrams-check` chạy một lần mỗi lượt CI, ở job `docs` của `check.yml` (job chạy mọi PR, kể cả PR chỉ đổi `.d2`, `.svg`). CI chỉ kiểm
SVG khớp `.d2`; `.d2` khớp Terraform do người viết và review kiểm. Cùng nguồn, cùng digest của image thì ra cùng byte, arm64 lẫn amd64.
Đổi digest `D2_IMAGE` có thể đổi byte của SVG: PR đổi nó chạy `make diagrams` trên nhánh của PR và commit SVG mới cùng PR.

## Một file `.d2`

Mỗi sơ đồ mở bằng `vars` đặt engine, hai theme và lề, rồi nạp token. Engine là ELK: phân tầng trên xuống hợp luồng một chiều, hẹp
hơn để đọc trên điện thoại. Engine khác chỉ khi có lý do, ghi ở comment đầu file `.d2`. Một SVG chứa cả theme sáng và tối (thiếu
`dark-theme-id` thì `make diagrams` báo lỗi); nhúng bằng `![<câu hỏi>](../diagrams/<tên>.svg)`.

```d2
vars: {d2-config: {layout-engine: elk; theme-id: 0; dark-theme-id: 200; pad: 20}}
...@tokens
```

## Token

`tokens.d2` giữ các `class` dùng chung; nút gắn bằng `class: <tên>`, mũi tên gắn bằng `{class: <tên>}`. Một khối là container bo góc nền
nhạt, viền màu theo chức năng, nhãn đậm là tiêu đề; `grid-rows` xếp các dòng con dưới tiêu đề: dòng `sub` liệt kê dịch vụ bằng ` · `, dòng
`root` ghi root Terraform (ví dụ: `security-layers.d2`). Nền nhạt đi với chữ tối nên đọc được ở cả hai theme; font mặc định của D2 hiển
thị đủ dấu tiếng Việt.

| Class | Dùng cho |
| --- | --- |
| `governance`, `prevention`, `detection`, `alerting`, `investigation`, `recovery` | sáu lớp bảo mật: quản trị, phòng ngừa, phát hiện, cảnh báo, điều tra, phục hồi |
| `workload`, `data` | dịch vụ chạy tải, nơi giữ dữ liệu |
| `sub`, `root` | dòng phụ dưới tiêu đề: dịch vụ (chữ thường), root Terraform (chữ đơn cách) |
| `account` | container một account AWS: bo góc, nét liền |
| `region` | vị trí (region): nét đứt mảnh; không phải ranh giới tin cậy |
| `trust` | ranh giới tin cậy thật (tổ chức, mạng ngoài): nét đứt dày |
| `group` | nhóm nhiều account theo vòng đời hay mục đích (sống lâu, trong buổi): nét chấm mảnh; không phải account hay ranh giới |
| `data-flow`, `control-flow` | mũi tên mảnh: dữ liệu (nét liền), điều khiển như chính sách, API, trigger (nét đứt) |

## Luật

- PR đổi kiến trúc mà một sơ đồ `.d2` tả (account, luồng, dịch vụ) thì sửa `.d2` đó và chạy `make diagrams` trong cùng PR; không sửa
  SVG bằng tay (`diagrams-check` đỏ, lần sinh sau ghi đè).
- Mỗi sơ đồ trả lời một câu hỏi, tối đa khoảng 15 nút, mọi nút đối chiếu được với Terraform; luồng phức tạp có một sơ đồ tổng quan
  (khoảng 8 nút) và một sơ đồ chi tiết. Sơ đồ khái niệm (lớp phòng thủ) ghi ở chú thích dưới hình là khái niệm, không phải luồng API;
  khối chạy song song đặt cạnh nhau, không ép thành chuỗi.
- Trước khi giao, `make diagrams PNG=1` rồi xem PNG (theme sáng) và SVG trên trình duyệt ở chế độ tối: chữ không tràn, mũi tên không
  cắt nhãn khung, đọc được ở bề rộng điện thoại.
