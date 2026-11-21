# Sơ đồ

Trang này tra cách dựng và cập nhật sơ đồ của repo: sơ đồ chính vẽ bằng D2 rồi sinh ra SVG, sơ đồ tổng có icon AWS giữ ở draw.io.
Lý do chọn D2 nằm ở [ADR-0079](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0079-d2-diagrams.md).

## Lệnh

Chạy từ gốc repo; D2 chạy trong container ghim digest (`D2_IMAGE` của `Makefile`), không mạng.

| Lệnh | Việc |
| --- | --- |
| `make diagrams` | Sinh mọi `docs/diagrams/*.d2` (trừ `tokens.d2`) thành hai SVG: `<tên>.svg` (theme sáng) và `<tên>-dark.svg` (theme tối) |
| `make diagrams-check` | Sinh vào thư mục tạm, so với cả hai SVG đã commit; lệch, thiếu, hay SVG không còn `.d2` cùng tên thì exit 1 kèm tên file |
| `make diagrams PNG=1` | Sinh thêm `<tên>.png` và `<tên>-dark.png` bên cạnh để xem; không commit |
| `make diagrams LAYOUT=<engine> OUT=<thư mục> SUFFIX=<chữ>` | Bản thử: engine khác `layout-engine` của file, thư mục khác, hậu tố tên; không commit |
| `python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py --pdf --docs` | Sinh `svp-aws.drawio` (sơ đồ tổng có icon AWS) cùng PDF, PNG mỗi trang từ spec, không sửa tay; cỡ trang env đọc từ `<env>.tfvars` và `variables.tf` của `aws/envs/<env>`, đổi cỡ thì build lại; cần CLI draw.io (`brew install --cask drawio` hay biến `DRAWIO`) |
| `check_diagram.py docs/diagrams/svp-aws.drawio`, `check_svp_counts.py` (cùng thư mục script) | Kiểm offline trước khi commit: hình học; số AZ, subnet, NAT, node, bastion, RDS, broker, node ElastiCache khớp cỡ env |

`diagrams-check` chạy một lần mỗi lượt CI, ở job `docs` của `check.yml` (job chạy mọi PR, kể cả PR chỉ đổi `.d2`, `.svg`). CI chỉ kiểm
SVG khớp `.d2`; `.d2` khớp Terraform do người viết và review kiểm. Cùng nguồn, cùng digest của image thì ra cùng byte, arm64 lẫn amd64.
Đổi digest `D2_IMAGE` có thể đổi byte của SVG: PR đổi nó chạy `make diagrams` trên nhánh của PR và commit SVG mới cùng PR.

## Một file `.d2`

Mỗi sơ đồ mở bằng `vars` đặt engine và lề, rồi nạp token. Theme không nằm trong file: `make diagrams` truyền theme 0 cho bản sáng và
theme 200 cho bản tối. Engine ở gốc là ELK; khối nào có `grid-rows`, `grid-columns` thì D2 xếp theo lưới (mục [Bố cục](#bố-cục)).
Engine khác chỉ khi có lý do, ghi ở comment đầu file `.d2`.

```d2
vars: {d2-config: {layout-engine: elk; pad: 20}}
...@tokens
```

## Bố cục

Đích: đọc trọn trong một màn hình laptop, chữ cỡ thường. Cỡ thật của hình (viewBox, đọc bằng
`grep -o 'viewBox="[^"]*"' docs/diagrams/<tên>.svg`) rộng khoảng 1000–1500 px; tỉ lệ cao/rộng không quá 1,3, thường 0,5–1. Hình dựng
dọc một chuỗi dài (tỉ lệ trên 1,5) bị GitHub kéo cho rộng bằng cột chữ rồi dài hơn một màn hình, nên không dùng `direction: down` cho
chuỗi dài.

- **Lưới thay cho chuỗi dọc.** Bọc các khối cấp gốc vào một container trong suốt `all` (`style: {stroke: transparent; fill: transparent}`)
  có `grid-rows`, `grid-columns`; chuỗi dài xếp thành hàng rắn (hàng trên trái sang phải, hàng dưới phải sang trái, xem
  `readme-apply-flow.d2`). Tiêu đề `title` đứng ngoài `all`.
- **Luôn đặt cả `grid-rows` lẫn `grid-columns`.** Chỉ có `grid-columns` thì D2 điền theo cột; đặt cả hai thì điền theo hàng, đúng thứ tự
  khai báo.
- **Mũi tên trong lưới là đoạn thẳng giữa hai ô.** Đặt hai nút nối nhau ở hai ô kề nhau; mũi tên không đi xuyên nút khác. Nhãn mũi tên nằm
  giữa đoạn: chừa khoảng cách ô (`horizontal-gap` 75–110) cho nhãn, ngắt nhãn dài bằng `\n`.
- **Ô cùng hàng cùng cao, ô cùng cột cùng rộng.** Khối cao kéo giãn các ô cùng hàng; gom nhóm nhỏ vào container trong suốt (`grid-rows`
  riêng) để cột bên cạnh chia đều chiều cao. Khối đứng một mình cạnh cột cao (hộp email, máy người học) đặt trong cột trong suốt cùng
  một nút trống có `height` phía trên, để khối giữ cỡ thật và ngang hàng với khối nó nối tới.
- **`grid-gap` cũng là lề trong của container.** Container trong suốt đặt `grid-gap: 0` và chừa khoảng cách bằng nút trống có `width`
  hay `height` (`style: {stroke: transparent; fill: transparent}`), nếu không hình có khoảng trống lớn quanh viền.
- **Nhãn mũi tên không nằm trên viền khung.** Mũi tên đi từ ngoài vào khối trong account hay region có nhãn ở giữa đoạn: khoảng cách
  trước khung phải lớn hơn lề trong của khung cộng nửa nhãn. Mũi tên đi qua góc có nhãn khung thì dời nhãn khung (`label.near:
  top-right` hay `bottom-left`).
- **Hai nguồn đứng cạnh nhau cùng nối hai đích** (hai repo tới máy người học và Argo CD) cho hai mũi tên cắt nhau: xếp nguồn và đích để
  chỗ cắt nằm xa nhãn của hai mũi tên đó (`13-gitops.d2`).
- **Ngắt dòng `sub`, `root` quanh 28 ký tự** bằng `\n` để khối hẹp, hình không rộng quá; chữ giữ nguyên.
- Tên `top`, `layers` là từ khoá của D2: không dùng làm tên nút hay container.

Một hình giữ tỉ lệ trên 1,2: `15-cost` (1,24: bốn chốt đọc từ trên xuống, đúng thứ tự trước merge, giữa buổi, trong buổi, sau khi
tiêu). Hình rộng hơn 1500 px là hình có ba cột việc song song, hay một account (máy, dịch vụ ngoài) đứng cạnh account chính; chúng giữ
ngang, GitHub thu xuống vừa cột chữ nên chữ nhỏ hơn cỡ thật.

## Nhúng vào trang

Mỗi sơ đồ có hai SVG, mỗi file một theme, và trang nhúng cả hai:

```md
![<câu hỏi>](../diagrams/<tên>.svg#gh-light-mode-only)
![<câu hỏi>](../diagrams/<tên>-dark.svg#gh-dark-mode-only)
```

- **Vì sao không một SVG chứa cả hai theme.** SVG trong thẻ `<img>` chọn theme theo `prefers-color-scheme` của hệ điều hành, không theo
  theme người dùng chọn trong GitHub: máy sáng mà GitHub tối thì hình vẫn sáng, nền trắng trên trang tối.
- **Vì sao hậu tố `#gh-light-mode-only`, `#gh-dark-mode-only`.** Đây là cách GitHub tài liệu hoá để chọn ảnh theo theme của nó, cùng với
  `<picture>`. `.markdownlint.yaml` bật `no-inline-html` (MD033), nên dùng cú pháp Markdown thuần. Chỗ khác GitHub (xem trước trong
  editor) hiện cả hai ảnh.
- **Cỡ.** `make diagrams` truyền `--scale 1` nên SVG mang `width`, `height` của cỡ thật, không `width` trên thẻ ảnh. GitHub chỉ thu hình
  rộng hơn cột chữ, không phóng hình nhỏ hơn.
- Hai file cùng tên gốc, hậu tố `-dark`; `diagrams-check` kiểm cả hai và coi `<tên>-dark.svg` không còn `<tên>.d2` là mồ côi.

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
- Trước khi giao, `make diagrams PNG=1` rồi xem `<tên>.png` (sáng) và `<tên>-dark.png` (tối): chữ không tràn, mũi tên không xuyên nút hay
  cắt nhãn khung, tỉ lệ cao/rộng không quá 1,3. Xoá PNG sau khi xem.
