# Sơ đồ

Trang này tra cách dựng và cập nhật sơ đồ của repo: sơ đồ chính vẽ bằng D2 rồi sinh ra SVG, sơ đồ tổng có icon AWS giữ ở draw.io.
Lý do chọn D2 nằm ở [ADR-0079](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0079-d2-diagrams.md).

## Lệnh

Chạy từ gốc repo; D2 chạy trong container ghim digest (`D2_IMAGE` của `Makefile`), không mạng.

| Lệnh | Việc |
| --- | --- |
| `make diagrams` | Sinh mọi `docs/diagrams/*.d2` (trừ `tokens.d2`) thành `.svg` cùng tên |
| `make diagrams-check` | Sinh vào thư mục tạm, so với SVG đã commit; lệch thì exit 1 kèm tên file |
| `make diagrams PNG=1` | Sinh thêm `.png` bên cạnh để xem; không commit |
| `make diagrams LAYOUT=elk` | Đổi engine (`elk`, `tala`) thay cho `layout-engine` của file |
| `make diagrams OUT=<thư mục> SUFFIX=<chữ>` | Ghi ra thư mục khác, thêm hậu tố vào tên (bản so: `pilot/<tên>-elk.svg`) |

`diagrams-check` nằm trong nhóm `check-lint` và trong job `docs` của `check.yml`, nên PR chỉ đổi `.d2` hay `.svg` vẫn bị kiểm.
Cùng nguồn và cùng digest của image thì ra cùng byte, trên arm64 lẫn amd64.

## Một file `.d2`

Mỗi sơ đồ mở bằng `vars` đặt engine và hai theme, rồi nạp token:

```d2
vars: {
  d2-config: {
    layout-engine: elk
    theme-id: 0
    dark-theme-id: 200
  }
}
...@tokens
```

Một SVG chứa cả theme sáng và tối; thiếu `dark-theme-id` thì `make diagrams` báo lỗi.
Nhúng vào `.md` bằng `![<câu hỏi của sơ đồ>](../diagrams/<tên>.svg)`.

## Token

`tokens.d2` giữ các `class` dùng chung; nút gắn bằng `class: <tên>`, mũi tên gắn bằng `{class: <tên>}`.

| Class | Dùng cho |
| --- | --- |
| `governance`, `prevention`, `detection`, `alerting`, `investigation`, `recovery` | sáu lớp bảo mật: quản trị, phòng ngừa, phát hiện, cảnh báo, điều tra, phục hồi |
| `workload`, `data` | dịch vụ chạy tải, nơi giữ dữ liệu |
| `account` | container một account AWS: bo góc, nét liền |
| `trust` | ranh giới tin cậy (tổ chức, mạng ngoài): nét đứt |
| `data-flow`, `control-flow` | mũi tên dữ liệu (nét liền), mũi tên điều khiển như chính sách, API, trigger (nét đứt) |

Màu nền nhạt đi với chữ tối nên đọc được ở cả hai theme; font mặc định của D2 hiển thị đủ dấu tiếng Việt.

## Luật

- PR đổi kiến trúc mà một sơ đồ `.d2` tả (account, luồng, dịch vụ) thì sửa `.d2` đó và chạy `make diagrams` trong cùng PR.
- Không sửa SVG bằng tay: `diagrams-check` đỏ và lần sinh sau ghi đè.
- Mỗi sơ đồ trả lời một câu hỏi, tối đa khoảng 15 nút; mọi nút đối chiếu được với Terraform.
- Trước khi giao, `make diagrams PNG=1` rồi xem: chữ không tràn, ít đường cắt nhau, đọc được ở bề rộng điện thoại.
