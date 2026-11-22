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
| `make inventory` | Sinh `inventory/*.d2`, SVG của chúng và trang inventory từ plan giả của mọi root (mục [Sơ đồ inventory](#sơ-đồ-inventory)) |
| `python3 docs/diagrams/drawio/build_svp.py --pdf --docs` | Sinh `svp-aws.drawio` (sơ đồ tổng có icon AWS) cùng PDF, PNG mỗi trang từ spec, không sửa tay; mục [draw.io](#drawio) |
| `python3 "$SKILL/scripts/check_diagram.py" docs/diagrams/svp-aws.drawio` | Kiểm hình học của `.drawio`: lệch lưới, đường gãy; 0 lỗi trước khi giao (`SKILL` ở mục [Vòng làm](#vòng-làm)) |
| `python3 docs/diagrams/drawio/check_svp_counts.py` | Kiểm offline: số AZ, subnet, NAT, node, bastion, RDS, broker, node ElastiCache khớp cỡ env, trang `org` khớp `org_expected()` |

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

Mỗi sơ đồ có hai SVG, mỗi file một theme, và trang nhúng cả hai bằng một thẻ `<picture>`; đường dẫn tương đối tính từ trang nhúng:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../diagrams/<tên>-dark.svg">
  <img src="../diagrams/<tên>.svg" alt="<câu hỏi của sơ đồ>">
</picture>
```

Đặt một dòng trống trước và sau khối để khối HTML không nuốt đoạn văn bên cạnh.

- **Vì sao không một SVG chứa cả hai theme.** SVG trong thẻ `<img>` chọn theme theo `prefers-color-scheme` của hệ điều hành, không theo
  theme người dùng chọn trong GitHub: máy sáng mà GitHub tối thì hình vẫn sáng, nền trắng trên trang tối.
- **Vì sao `<picture>`, không hậu tố riêng của GitHub trên URL ảnh** (kiểu `#gh-…-mode-only`). Loại hậu tố này chỉ GitHub hiểu; xem trước
  trong editor hay trình xem markdown khác hiện cả hai ảnh liền nhau. `<picture>` là HTML: GitHub chọn nguồn theo theme của nó, editor
  theo theme của editor hay hệ điều hành, trình không hiểu `<source>` hiện bản sáng. `.markdownlint.yaml` bật `no-inline-html` (MD033) và
  chỉ cho ba thẻ `picture`, `source`, `img` (`allowed_elements`).
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

## Icon

Sơ đồ D2 dùng icon dịch vụ AWS khi khối của nó là một dịch vụ (sơ đồ inventory ở `inventory/`, mục dưới). Icon là SVG cỡ 48 của
[AWS Architecture Icons](https://aws.amazon.com/architecture/icons/), bản `07312026` (gói `Icon-package_07312026`, thư mục
`Architecture-Service-Icons_07312026/<nhóm>/48/Arch_<dịch vụ>_48.svg`), chép vào [`icons/`](icons/) với tên ngắn kebab-case (`kms.svg`,
`ecr.svg`, `amp.svg`). AWS cho dùng bộ này để vẽ sơ đồ kiến trúc; không sửa hình, không đổi màu.

- **Trong repo, không URL.** D2 chạy trong container `--network none` nên không tải icon từ mạng; đường dẫn tương đối tính từ file
  `.d2` (`icon: ../icons/kms.svg`) và D2 nhúng hình vào SVG (base64), nên máy và CI ra cùng byte.
- **Chỉ icon dùng tới.** Thêm dịch vụ mới thì chép đúng một file từ gói cùng bản, đặt tên theo bảng `SERVICES` của `ci/inventory.sh`;
  nâng bản gói thì thay mọi file trong `icons/` cùng lúc, sửa bản ở đoạn trên, chạy lại `make inventory`, `make diagrams`.
- **Cỡ.** Nút icon là `shape: image`, `width: 48; height: 48`, nhãn `<dịch vụ> · <số>` nằm dưới hình; nhãn nằm trên nền nhạt của khối
  nên đặt `font-color` tối ở cả hai theme (theme tối của D2 tô chữ sáng, không đọc được trên nền nhạt).

### Sơ đồ inventory

`inventory/<slug>.d2` cùng hai SVG của nó do `make inventory` sinh từ plan giả của mỗi root, không sửa tay; `make inventory-check`
(không phải `diagrams-check`) kiểm chúng. Mỗi khối một phần của root, tiêu đề ghi số tài nguyên, mỗi icon một dịch vụ với số của nó.
Trang nhúng: [`docs/reference/inventory.md`](../reference/inventory.md); cách sinh: [`checks.md`, mục
Inventory](../reference/checks.md#inventory).

## Luật

- PR đổi kiến trúc mà một sơ đồ `.d2` tả (account, luồng, dịch vụ) thì sửa `.d2` đó và chạy `make diagrams` trong cùng PR; không sửa
  SVG bằng tay (`diagrams-check` đỏ, lần sinh sau ghi đè).
- Mỗi sơ đồ trả lời một câu hỏi, tối đa khoảng 15 nút, mọi nút đối chiếu được với Terraform; luồng phức tạp có một sơ đồ tổng quan
  (khoảng 8 nút) và một sơ đồ chi tiết. Sơ đồ khái niệm (lớp phòng thủ) ghi ở chú thích dưới hình là khái niệm, không phải luồng API;
  khối chạy song song đặt cạnh nhau, không ép thành chuỗi.
- Trước khi giao, `make diagrams PNG=1` rồi xem `<tên>.png` (sáng) và `<tên>-dark.png` (tối): chữ không tràn, mũi tên không xuyên nút hay
  cắt nhãn khung, tỉ lệ cao/rộng không quá 1,3. Xoá PNG sau khi xem.

## draw.io

Sơ đồ tổng [`svp-aws.drawio`](svp-aws.drawio) (trang `stg`, `prd`, `org`, `flows`) có icon AWS nên vẽ bằng draw.io, không bằng D2. File
`.drawio`, PDF và PNG mỗi trang là sản phẩm sinh từ spec Python ở [`drawio/`](drawio/); không sửa tay trong draw.io.

### Engine và cách cài

Thư viện vẽ (`drawio_lib.py`), checker hình học (`check_diagram.py`) và luật chung (lưới 40px, icon 80px, lồng Cloud → Account → Region →
VPC → AZ → subnet, EKS, bẫy của CLI draw.io) là skill `aws-drawio-diagram` của
[`anhnvcoder/agent-skills`](https://github.com/anhnvcoder/agent-skills), không chép vào repo này. Spec tìm skill qua biến
`AWS_DRAWIO_SKILL`, mặc định `~/.claude/skills/aws-drawio-diagram`, và dừng với thông báo cài đặt khi không thấy.

```sh
git clone git@github.com:anhnvcoder/agent-skills.git
ln -s "$PWD/agent-skills/aws-drawio-diagram" ~/.claude/skills/aws-drawio-diagram  # hay: AWS_DRAWIO_SKILL=<thư mục đó>
```

CI không build draw.io; xuất PDF, PNG cần CLI draw.io (`brew install --cask drawio` hay biến `DRAWIO`).

### Vòng làm

Từ gốc repo, `SKILL` là thư mục skill (`${AWS_DRAWIO_SKILL:-$HOME/.claude/skills/aws-drawio-diagram}`):

```sh
SKILL="${AWS_DRAWIO_SKILL:-$HOME/.claude/skills/aws-drawio-diagram}"
python3 docs/diagrams/drawio/build_svp.py --pdf --png /tmp/svp          # .drawio + .pdf, PNG để xem
python3 "$SKILL/scripts/check_diagram.py" docs/diagrams/svp-aws.drawio   # 0 lỗi trước khi giao
python3 docs/diagrams/drawio/check_svp_counts.py                        # 0 lệch
python3 docs/diagrams/drawio/build_svp.py --pdf --docs                  # khi giao: PNG scale 2 cạnh .drawio
```

Rồi mở PNG và nhìn: checker đo lệch lưới và đường gãy, còn đường đi qua nhãn hay icon chỉ mắt thấy. PNG trong `/tmp` không commit; PDF
commit cạnh `.drawio`; PNG `--docs` (`svp-aws-<trang>.png`) commit vì tài liệu của repo code nhúng chúng.

### Luật riêng của sơ đồ svp

Thêm vào luật của skill:

- **Cỡ đọc từ Terraform, không gõ lại.** Mỗi trang env sinh từ cùng một hàm; cỡ lấy từ `aws/envs/<env>/<env>.tfvars` và mặc định của
  `variables.tf` trong root đó. Số của repo khác (replica của workload ở `svp-gitops`) nằm trong một bảng của spec, comment nêu file nguồn,
  để repo build được khi clone một mình. Đổi cỡ env thì build lại.
- **Subnet của mỗi AZ theo tầng, từ trái sang phải:** public (chỉ NAT), edge (chỉ ALB internal `svp-<env>-edge`, không route ra ngoài
  VPC, nhãn `Edge subnet`), private, database (nhãn `Database subnet`). Một ALB là một icon bắc qua biên hai box edge của hai AZ đầu
  (phụ đề ghi "một ALB trên mọi subnet edge").
- **Interface endpoint:** một icon `endpoints` mỗi AZ có ENI (`interface_endpoint_az_count` của root: stg một AZ, prd mọi AZ), bên trái
  box cluster, nhãn nêu số dịch vụ đọc từ `interface_endpoint_services` của module `network`; đường đứt `443` tới box cluster.
- **Dải "Regional services" dưới VPC** có hai hàng: dịch vụ regional (S3, Secrets Manager, KMS, CloudWatch Logs, ACM của ALB) rồi dịch vụ
  cấp account sống qua `destroy` (ECR, Inspector, AMP, AMG, log group ứng dụng, X-Ray; cạnh nối láng giềng cùng hàng). Dịch vụ toàn cầu
  (Route 53, mỗi distribution CloudFront cùng web ACL của nó) ở Account ngoài Region, bên trái; web ACL nối bằng đường đứt không mũi tên,
  nhãn đặt trên; distribution vào mép trái của ALB (VPC origin). Cert ACM của distribution (`us-east-1`) không thêm icon.
- **Namespace:** `svp` vắt qua box private của hai AZ đầu; mỗi workload một icon Kubernetes theo kind kèm replica; Argo CD, Kyverno,
  Prometheus là chữ trong khung; add-on của EKS không vẽ. Controller tạo tài nguyên AWS có khung riêng và đường đứt tới thứ nó tạo
  (AWS Load Balancer Controller → ALB, EBS CSI → EBS).
- **Tầng database:** mỗi dịch vụ một cột, gần cluster nhất ở hàng thấp nhất (RDS +280, ElastiCache +160, MSK +40 so với mép trái box);
  broker MSK một icon mỗi AZ.
- **Số icon khớp Terraform:** `check_svp_counts.py` đọc lại file và so từng loại icon của mỗi trang env với cỡ của env, trang `org` với
  `org_expected()` (account cùng dịch vụ của từng account).
- **Trang `org`:** không VPC, AZ, subnet. Root của Organization chứa hộp chính sách gắn ở root (tên và loại đọc từ
  `aws/modules/org-policies/main.tf`) và ba cột: account quản lý, OU `Security` (`svp-log-archive`, `svp-security`, `svp-backup`), OU
  `Workloads` (`Prod` với `svp-prd`, `NonProd` với `svp-stg`). OU là group aws4 nét liền không nền; account là group `ACCOUNT`. Luồng log
  (xanh) từ mọi account vào bucket của `svp-log-archive`; luồng phát hiện (đỏ): GuardDuty, Access Analyzer → Security Hub → bus
  `svp-security-events` ← rule `svp-security-*` của mọi account → SNS → email. Account có cờ `off` trong `aws/paid-features.json` có ghi chú
  `Off in …` đọc từ file cờ; icon AMG của account env chỉ có khi cờ `managed_grafana` không phải `off`.
- **Trang env vẽ `svp-log-archive` chỉ cho bucket env ghi vào** (flow log, log WAF, log CloudFront), dưới account env, trong Cloud.
- **Trang `flows`** gồm các khối dọc, mỗi khối một tiêu đề: phát hành image (GitHub Actions → GHCR → ECR qua role OIDC; PR promote →
  `svp-gitops` → Argo CD), upload tới phát lại, request, telemetry, transcode, backup và restore, plan trên PR. Tên role, repo, log group
  khớp code; nhiều đường ra từ một icon dùng chung một thân dọc.

Toạ độ của trang env (cột x, hàng y) nằm ở phần "geometry of an env page" của [`build_svp.py`](drawio/build_svp.py); thêm AZ hay dịch vụ
thì giữ hàng, cột đó và chỉ thêm icon ở bội số 40.
