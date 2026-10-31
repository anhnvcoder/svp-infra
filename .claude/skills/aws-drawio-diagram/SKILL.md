---
name: aws-drawio-diagram
description: Sinh sơ đồ hạ tầng AWS của svp-infra thành .drawio cộng PDF từ spec Python — icon aws4 chuẩn, container Cloud/VPC/AZ/subnet, mọi toạ độ trên lưới chính 40px của draw.io, icon 80px, đường thẳng, mỗi tài nguyên nằm trong đúng subnet của nó; một trang mỗi env (stg, prd) sinh từ cùng hàm với cỡ đọc từ Terraform, cộng trang luồng. Dùng khi vẽ hay sửa sơ đồ AWS, khi hạ tầng đổi và docs/diagrams/svp-aws.drawio phải theo, hay khi cần kiểm một file .drawio trước khi giao. File .drawio là sản phẩm sinh từ spec — không bao giờ sửa tay trong draw.io.
---

# aws-drawio-diagram

Bản chép của skill cùng tên ở `templates/terraform-base` (commit `ecc4349`): `drawio_lib.py`, `check_diagram.py` chép nguyên và ghi
nguồn ở dòng đầu, cộng các thay đổi ở mục "Khác bản gốc"; `build_svp.py`, `check_svp_counts.py` là của repo này.

## Thành phần

| File | Vai trò |
| --- | --- |
| [`scripts/drawio_lib.py`](scripts/drawio_lib.py) | Thư viện vẽ: `Page` (group / icon / flat / k8s / badge / text / box / edge / table), bảng màu và style aws4, `write()`, `export()` (PDF/PNG qua CLI draw.io). Từ chối ngay mọi toạ độ lệch lưới 40px. |
| [`scripts/check_diagram.py`](scripts/check_diagram.py) | Cổng hình học cho mọi file `.drawio` (11 phép, liệt kê trong docstring), exit 1 khi có lỗi; `--counts` in số mỗi loại (icon, AZ, subnet) mỗi trang, `kind_counts()` cho spec import. |
| [`scripts/build_svp.py`](scripts/build_svp.py) | Spec của [`docs/diagrams/svp-aws.drawio`](../../../docs/diagrams/svp-aws.drawio): trang `stg`, `prd`, `flows`. |
| [`scripts/check_svp_counts.py`](scripts/check_svp_counts.py) | Đếm icon mỗi trang env so với cỡ của Terraform (AZ, subnet, NAT, node group, RDS và mọi loại khác), offline. |

## Vòng làm

Từ gốc repo:

```bash
python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py --pdf --png /tmp/svp   # .drawio + .pdf, PNG để xem
python3 .claude/skills/aws-drawio-diagram/scripts/check_diagram.py docs/diagrams/svp-aws.drawio   # 0 lỗi trước khi giao
python3 .claude/skills/aws-drawio-diagram/scripts/check_svp_counts.py                              # 0 lệch
python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py --pdf --docs   # khi giao: PNG scale 2 cạnh .drawio cho Markdown
```

Rồi mở PNG và nhìn: checker đo lệch lưới và đường gãy, nhưng đường đi qua nhãn hay qua icon chỉ mắt thấy. PNG trong `/tmp` để xem, không
commit; PDF commit cạnh `.drawio`; PNG `--docs` (`svp-aws-<trang>.png`) commit vì `docs/architecture.md` của repo code nhúng nó.

`export()` tìm CLI draw.io theo thứ tự: biến `DRAWIO`, `drawio` trên `PATH` (cask Homebrew, gói Linux), rồi app
`/Applications/draw.io.app/Contents/MacOS/draw.io`; không có thì lỗi nêu ba chỗ. Wrapper của Homebrew còn trên `PATH` sau khi app bị gỡ
thì lỗi export in nguyên thông báo của wrapper (đường app đã mất). File đích cũ bị xoá trước khi export, nên export hỏng không trốn sau
file của lượt trước.

**Dùng lại ở project khác:** chép `drawio_lib.py`, `check_diagram.py` vào skill của project đó, ghi "copied from …" ở dòng đầu, để phép
audit của project so với bản gốc mà báo lệch. Viết spec theo `build_svp.py` hay `build_terraform_base.py` của bản gốc; có mô hình
inventory thì đặt `cid` của icon là id tài nguyên và `cid` của box subnet là id subnet để audit kiểm vị trí bằng hình học.

## Luật nội dung

1. **Tài nguyên vẽ trong box của subnet nó thuộc về.** Một hàng mỗi AZ, một box mỗi subnet, nhãn có CIDR; **mọi subnet của một AZ nằm
   trong khung AZ đó** (public bên trái, private bên phải), không có box subnet nào ngoài khung AZ. NAT và bastion theo subnet của chúng,
   task hay EC2 theo subnet của instance, RDS/ElastiCache theo subnet group. Không gộp nhiều subnet vào một box, không đoán vị trí. Chỗ AWS
   chọn AZ (một task, primary RDS) thì ghi quy ước trong dòng phụ đề. Không tài nguyên nào nằm ở khe giữa hai AZ hay ngoài mọi subnet trừ
   loại của luật 3.
2. **Mọi load balancer ELB (ALB, NLB) internet-facing là một icon, vắt qua biên của hai box subnet public kề nhau.** Node theo subnet của
   load balancer do ELB tạo và quản, người dùng không thấy; sơ đồ của AWS vẽ một icon. Một icon mỗi subnet đọc thành nhiều load balancer.
   Hai box public bật viền để thấy biên. Box public nằm trong khung AZ (luật 1) thì hai hàng AZ đầu chạm nhau (không khe) và icon bắc qua
   biên chung: cạnh trên tựa đáy box public của AZ đầu, cạnh dưới tựa đỉnh box public của AZ sau. Có ba AZ trở lên thì icon vẫn bắc qua
   hai AZ đầu, phụ đề ghi "một NLB trên mọi subnet public".
3. **Tài nguyên ngoài subnet nằm ở tầng riêng:** WAF (regional, gắn ALB) trong Cloud ngoài VPC; VPC endpoint (cả gateway endpoint S3)
   trong VPC ngoài các subnet; IGW cạnh VPC; **tài nguyên theo AZ mà không theo subnet (volume EBS) trong khung AZ, ngoài các box subnet,
   một icon mỗi AZ**; dịch vụ regional trong dải "Regional services" dưới VPC; dịch vụ toàn cầu (Route 53, CloudFront) ngoài Cloud (trang
   env: bên trái; trang luồng: theo chiều luồng).
4. Nhãn ngắn, không tên tài nguyên, không id, không account ID, IP, email hay tên miền thật (`aws.&lt;domain&gt;`). Người đọc cần hình
   dạng; danh mục nằm ở inventory.
5. Số icon mỗi loại bằng inventory (NAT, EC2, RDS, cache, load balancer, WAF, endpoint…). Bảng giá (khi có) và hình nói cùng một điều.
   Với spec nhiều env, một script đếm (`check_svp_counts.py`) đọc lại file và so với cỡ của env.
6. **Ghi chú nhiều mục là danh sách**, dựng bằng `bullets(...)` của `drawio_lib` (mỗi mục một `<li>`), không phải một đoạn văn. Phụ đề
   một dòng nối bằng `·` thì được. Text box ~16px mỗi dòng ở cỡ 11, làm tròn lên bội số 40.

### EKS

7. **Control plane do AWS quản lý vẽ ngoài VPC, trong Cloud** (dải trên VPC), với một đường tới box cluster; ENI của nó trong subnet
   private không vẽ.
8. **Managed node group: một icon mỗi AZ, trong subnet private của AZ đó** (node group trải mọi subnet của danh sách). Nhãn nêu loại
   cấp (Spot, on-demand).
9. **Pod không vẽ từng cái; namespace là khung trên vùng node.** Box cluster bao các icon node, trải box private của mọi hàng AZ (cluster
   trải mọi AZ, như sơ đồ EKS của AWS). Mỗi namespace là một khung (box không nền, không phải container aws4: viền AZ và nền subnet thấy
   qua nó) đặt trong box private, không bao giờ ở khe giữa hai AZ; tiêu đề là tên namespace thật (khung gom vài namespace nhỏ thì liệt kê
   đủ tên, không đặt tên bịa). Pod do scheduler đặt trên node bất kỳ của AZ bất kỳ: phụ đề ghi "hàng của một khung hay icon không nói pod
   chạy ở đâu". Namespace của ứng dụng (ở `svp-aws`: `svp`) vẽ vắt qua box private của hai AZ đầu như luật 2, để thấy replica trải nhiều
   AZ; mọi icon Kubernetes trong khung vẫn nằm trọn trong một box private (phần khung ở khe giữa hai box để trống).
10. **Phần AWS dùng `aws4`, phần Kubernetes dùng thư viện Kubernetes chính thức của draw.io** (`mxgraph.kubernetes.icon2`, bản có chữ
    viết tắt trong icon, qua `Page.k8s()`). Box cluster là group aws4 mang icon Amazon EKS (`gr="eks"`), managed node group là icon
    `ec2` mỗi AZ. Mỗi khung namespace có icon `ns`. **Mỗi workload một icon** theo kind (`deploy` cho Deployment, `sts` cho StatefulSet,
    `svc` cho Service mà NLB nhắm tới, cạnh từ load balancer vào thẳng icon đó), chữ bên phải icon hai dòng: tên, rồi số replica theo
    values (`×2`, `×2–4 · HPA`, `×1–2 · KEDA`); kind không có icon (Argo Rollout) dùng icon gần nhất (`deploy`) và ghi kind vào chữ
    (`×2 · Rollout`). Không gộp nhiều service vào một dòng chữ: người đọc tưởng mỗi service là một node. **Công cụ bên thứ ba** (Argo CD,
    Kyverno, Prometheus…) là chữ trong khung namespace có icon; không nhúng logo ảnh ngoài thư viện chuẩn.
11. **Add-on của EKS không vẽ** (CoreDNS, kube-proxy, VPC CNI; phụ đề nói vậy). **Controller tạo tài nguyên AWS** có khung namespace của nó
    với đường đứt nét tới tài nguyên nó tạo (AWS Load Balancer Controller → NLB, ExternalDNS và cert-manager → Route 53, EBS CSI → EBS);
    tài nguyên có một icon mỗi AZ (EBS) thì một đường tới icon gần nhất là đủ (luật hình học 12).

### Một spec nhiều env

12. **Một hàm vẽ một trang env**, tham số là cỡ của env (số AZ, NAT một hay mỗi AZ, RDS một AZ hay Multi-AZ, loại cấp node, log). Cỡ đọc
    từ nguồn của hạ tầng, không gõ lại trong spec: stg từ `aws/envs/stg/stg.tfvars` (cộng mặc định ở `variables.tf`), prd từ cột `prd`
    của bảng biến trong `aws/modules/*/README.md` tới khi có root prd. Số nằm ở repo khác (replica của workload, ở `svp-gitops`) gõ vào
    **một** bảng trong spec, comment nêu file nguồn: repo này phải build được khi clone một mình. Trang luồng (không theo env) đi sau các
    trang env.

## Luật hình học

1. **Lưới chính 40px.** Lưới draw.io có ô phụ 10px và đường đậm 40px. Mọi x, y, rộng, cao của container, icon, text, bảng là bội số
   của 40. Bội số 10 chưa đủ: cạnh hình phải nằm trên đường đậm.
2. **Icon 80×80** (2×2 ô chính) để tâm nằm trên đường đậm. Icon cùng hàng chung y, cùng cột chung x. Icon mặc định 70px có tâm lệch 5,
   nên không dùng.
3. **Cạnh orthogonal không waypoint chỉ thẳng khi hai đầu chung tâm.** Lệch vài pixel là draw.io vẽ một bậc ngay trước icon. Dời icon,
   không vá bằng waypoint. Cạnh từ một box tới icon (hay ngược lại) chọn `exit_`/`entry` để điểm nối trùng tâm của đầu kia.
4. **Badge 40px** (WAF) không thể vừa trên lưới 40 vừa chung tâm với icon 80px: nối qua tỉ lệ cạnh (`exit_=(1, 0.25)` /
   `entry=(0, 0.25)`) để đường thẳng ở y tâm của badge.
5. **Waypoint** chỉ khi đường tự động cắt icon khác hay chồng cạnh khác. Waypoint trên lưới phụ 10px, waypoint đầu và cuối chung x hoặc y
   với điểm nối. Hành lang quen dùng: khe 40px giữa hai container (chạy giữa khe), dải giữa đáy các hàng AZ và đáy VPC, dải giữa đáy dải
   regional và đáy Cloud, dải giữa đỉnh Cloud và đỉnh VPC.
6. **Ra hay vào icon qua đáy là cắt nhãn của icon đó.** Chấp nhận cho đường dọc tự nhiên (replication, control plane → cluster), không
   cho cạnh của icon khác. Icon cần vào từ đáy (S3 `uploads` nhận POST của trình duyệt qua hành lang dưới) đặt nhãn trên
   (`label_top=True`).
7. **Bảng:** header 40, hàng 40, cột `[240, 320, 120]`, đặt ở x=40 dưới Cloud. Trang tự cao thêm cho vừa bảng.
8. **Icon nằm trọn trong mọi container nó chạm và cách cạnh container ít nhất một ô 40px** (checker phép 10). Icon chạm viền trông dính
   khung; thiếu chỗ thì nới container chứ không đẩy icon ra sát cạnh. Ngoại lệ duy nhất là load balancer của luật nội dung 2.
9. **Container tạo trước icon.** draw.io vẽ theo thứ tự cell trong file; box có nền tạo sau sẽ che icon.
10. **Container nét đứt không nền (AZ) phải bật viền** (`grstroke=True`). Trên shape aws4.group, `grStroke=0` nghĩa là không viền nào,
    không chỉ bỏ viền icon. Box cluster EKS viền liền, không nền, để viền AZ và nền subnet vẫn thấy qua nó; khung namespace cũng không nền.
11. **Trang có chữ Nhật, Trung, Hàn đặt `Page(font=…)`** (ví dụ "Hiragino Sans"). Với Helvetica mặc định, PDF của CLI draw.io mất chữ
    Hán còn PNG vẫn đúng; xem PDF bằng `sips -s format png x.pdf`.
12. Ba đường vòng cần ba hành lang mà mỗi hàng chỉ có hai (trên, dưới). Bỏ đường mang ít thông tin nhất thay vì ép (ở `svp-aws`: chỉ NAT
    của AZ đầu vẽ đường tới IGW; ở stg chỉ node của AZ có NAT vẽ đường tới NAT; EBS CSI chỉ vẽ đường tới EBS của AZ thứ hai). Hai đường
    không cắt nhau: đường đi lên từ hàng AZ dưới tới load balancer đi bên phải cột node rồi vào cạnh của nó, không cắt đường node → NAT
    của mỗi AZ.
13. **Box subnet cùng loại cùng rộng** (checker phép 11): box ít tài nguyên không hẹp hơn box nhiều; lấy rộng theo box bận nhất của hàng.
    Loại là nền cộng chiều cao: box public và private cùng hàng AZ, cùng cao là hai loại; box public cao (load balancer vắt qua) cũng là
    loại riêng. Checker nhận box subnet bằng nhãn chứa chữ "subnet", nên nhãn box subnet phải có chữ đó.
14. **Icon Kubernetes theo cùng luật đặt icon** (checker phép 4, 5, 8, 10 coi `mxgraph.kubernetes` là icon): mỗi icon trong khung cách
    cạnh box private, AZ, cluster ít nhất 40, kể cả icon của khung vắt qua hai AZ (hàng icon trong mỗi box private, không ở khe). Icon 40
    (badge) trong khung, chữ bên phải trong ô 120 (hai dòng); icon 80 khi đứng một mình (trang luồng), chữ dưới nằm trọn trong container.
15. **Cạnh trái box cluster không cắt nhãn** của subnet và AZ nó vắt qua: đặt box cluster bên phải chữ dài nhất (`Private subnet
    10.0.32.0/19`), nới subnet private chứ không kéo cluster sát cạnh trái.
16. **Cạnh không chạy trên viền nét đứt:** đường giữa hai hàng AZ chạm nhau chạy cách biên chung 20 (trong lề dưới của AZ trên hay lề trên
    của AZ dưới), không trên chính biên. Nhãn của cạnh nằm giữa đường đi; đường gãy mà điểm giữa rơi trên viền container hay ra mép trang
    thì dời nhãn bằng `edge(label_pos=…)` (-1 nguồn … 1 đích).

## Bố cục chuẩn (trang env của `svp-aws`)

```text
x:  40 users · 160 Route 53, CloudFront (ngoài Cloud) │ Cloud 280.. · IGW 320 │ VPC 440 · AZ 480..2720
    public 520..880 (NAT 560, NLB 760) · EBS 920 (trong AZ, ngoài subnet) · private 1040..2680
    cluster 1280..2400: node 1320, cột namespace 1440 / 1680 / 1920 / 2160 (rộng 200; svp 3 cột, platform 2 cột) · RDS 2560
y:  phụ đề 40, 80 · Cloud 160 · control plane 240 (nhãn trên) · hành lang DNS 340 · VPC 360 · AZ k ở 400 + 480k, các hàng chạm nhau
    box public, private +40 (cao 400): NAT, node +80, EBS +200; hàng khung namespace của AZ đầu +200, +320, của AZ sau +160, +280
    NLB ở biên hai AZ đầu (đỉnh = đáy box public đầu), IGW → NLB → Envoy chạy 20 trên biên, kube-system → NLB 20 dưới biên
    svp từ +320 của AZ đầu tới +160 của AZ sau (hàng icon 4 + 3), RDS primary ngang hàng icon đầu của svp, standby ở AZ sau
    gateway endpoint S3 dưới AZ cuối (+80) · dải regional dưới VPC, icon: media 480, uploads 640, Secrets Manager 880,
    CloudWatch Logs 1120 (khi có log) · hành lang users → uploads dưới dải
```

Thêm AZ hay dịch vụ: giữ các hàng, cột ở trên, chỉ thêm icon ở bội số 40.

## Khác bản gốc (để chuyển ngược)

- `drawio_lib.export()`: tìm CLI qua `drawio_cli()` (`DRAWIO`, `PATH`, app macOS; lỗi rõ khi không có), xoá file đích trước khi export,
  lỗi nêu CLI và exit code.
- `drawio_lib`: `Page.k8s(label, kind, x, y, size=40)` vẽ icon của thư viện Kubernetes (`mxgraph.kubernetes.icon2`, `kubernetesLabel=1`,
  chữ 11 như icon aws4); hằng `K8S` (xanh của icon, viền khung namespace); `Page.edge(label_pos=…)` dời nhãn dọc đường (thuộc tính `x` của
  `mxGeometry` của cạnh).
- `check_diagram.py`: phép 4 cho mọi shape ELB vắt qua (`ELB_RE`: `elastic_load_balancing`, `application_load_balancer`,
  `network_load_balancer`, `gateway_load_balancer`), kể cả bắc qua hai hàng AZ chạm nhau; phép 11 nhận loại box subnet bằng nền cộng chiều
  cao (public và private cùng hàng, cùng cao); `ICON_RE` gồm cả `mxgraph.kubernetes` (luật đặt icon áp cho icon Kubernetes);
  `kind_counts()` (icon Kubernetes đếm là `k8s_<kind>`) và cờ `--counts`.
- `SKILL.md`: luật nội dung 1 (subnet trong khung AZ), 2 cho mọi load balancer ELB và cách bắc qua hai AZ chạm nhau, 3 thêm gateway
  endpoint, tài nguyên theo AZ (EBS) và dịch vụ toàn cầu, 7–11 (EKS, khung namespace trên vùng node, mỗi workload một icon có replica,
  thư viện Kubernetes), 12 (một spec nhiều env, số của repo khác); luật hình học 3, 5, 6, 10, 12, 13 thêm ý về box → icon, hành lang trên
  VPC, `label_top`, box cluster và khung không nền, đường không cắt nhau, loại subnet; 14–16 (icon Kubernetes, cạnh cluster không cắt
  nhãn, cạnh không chạy trên viền nét đứt và `label_pos`); bẫy về shape Kubernetes và `grIcon`.

## Bẫy kỹ thuật

- CLI draw.io: `-p` đánh số trang từ 1. Thứ tự đối số `-x -f png -s 1 -p N -o out in`; đặt `-s` hay `-p` trước `-f` thì CLI đọc `png`
  thành file đầu vào.
- `sips -c` trên macOS cắt từ tâm ảnh; không dùng để cắt một góc (`--cropOffset <y> <x>` thì cắt đúng chỗ).
- `grIcon` của `mxgraph.aws4.group` nhận cả stencil của icon dịch vụ (`gr="eks"` vẽ logo EKS ở góc bằng màu viền); tên đã render thử:
  `eks`. Icon Kubernetes `icon2` gốc 50×48: vẽ 40 hay 80 hơi giãn, mắt không thấy; tên `prIcon` có thật (đã render): `ns`, `deploy`,
  `sts`, `svc`, `ing`; danh sách đủ ở sidebar Kubernetes của draw.io (`pod`, `ds`, `job`, `cronjob`, `pvc`, `secret`, `cm`, `hpa`…).
- Định tuyến tự động của draw.io không né icon: hai icon cùng hàng nối nhau thì đường đi qua mọi icon ở giữa.
- `Page._id` sinh id dạng `r_53` để không trùng id spec tự đặt (`cid="r53"`); id trùng làm checker đọc sai hình học.
- Mọi nhãn (icon, cạnh, text, box, ô bảng) được draw.io render như HTML: chỗ giữ chỗ như `<env>`, `<domain>` phải viết `&lt;…&gt;`,
  nếu không draw.io coi là thẻ và nuốt mất. Checker không bắt được; chỉ PNG cho thấy.
- Checker không đo được nhãn chồng nhau hay đường qua chữ: icon có nhãn dài đặt cách 240 thay vì 160, xem PNG sau mỗi lần build. Nhãn
  của cạnh nằm giữa cạnh: cạnh cắt viền container ở giữa thì nhãn đè viền (dời icon đầu kia hay bỏ nhãn, ghi ý vào khung đích).
- Nhúng vào Markdown: xuất PNG scale 2 (`export(out, 'png', ..., scale=2)`, cờ `--docs` của `build_svp.py`), không SVG: draw.io xuất nhãn
  thành `foreignObject` kèm chữ thay thế "Text is not SVG", nhiều trình xem (Safari, Quick Look, vài renderer Markdown) hiện chữ hỏng.
