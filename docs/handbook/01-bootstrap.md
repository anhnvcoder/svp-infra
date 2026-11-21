# 01. Bootstrap

← [00. Tổng quan](00-tong-quan.md) · [Mục lục](README.md) · [02. GitHub](02-github.md) →

## Tổng quan

Chương này dựng hai thứ mà mọi phần sau cần trước tiên: chỗ giữ state của Terraform và cách biết tiền đang đi đâu. Cả hai nằm ở management
account, vì đó là nơi chạy các root quản trị và là nơi nhận hoá đơn gộp của cả tổ chức.

svp cần state chung vì nhiều root chạy từ cùng một account, ở nhiều terminal, qua nhiều tháng: state mất hay hỏng là Terraform không còn
biết tài nguyên nào của mình. svp cần cảnh báo tiền vì buổi stg, prd dựng tài nguyên tính theo giờ; một env quên gỡ qua đêm là khoản tốn
thường gặp nhất của lab.

Phần này sống suốt đời lab: dựng một lần, không gỡ cuối buổi, chỉ xoá khi lab kết thúc và mọi root khác đã gỡ. Mọi thứ ở đây gần như
không tốn tiền.

| Câu hỏi | Dịch vụ |
| --- | --- |
| State của Terraform nằm ở đâu, và ai khoá nó khi hai lệnh chạy cùng lúc? | Amazon S3 (bucket state, lock file) |
| Ai đọc được state, và state có bị đọc trên đường truyền không? | AWS KMS (key của state), bucket policy |
| Tháng này cả tổ chức sắp vượt hạn mức tiền chưa? | AWS Budgets |
| Có dịch vụ nào hôm nay tiêu khác hẳn mọi ngày không? | AWS Cost Anomaly Detection |
| Tiền đi về env nào, stack nào? | Tag phân bổ chi phí (AWS Billing and Cost Management) |

| Account | Region | Vòng đời | Root Terraform |
| --- | --- | --- | --- |
| management | `ap-southeast-1` (bucket, key); Budgets và Cost Explorer là dịch vụ toàn cục, gọi qua `us-east-1` | sống suốt lab | `aws/bootstrap` |

## Kiến trúc

![Bootstrap giữ state cho các root của management và báo tiền của cả tổ chức](../diagrams/01-bootstrap.svg#gh-light-mode-only)
![Bootstrap giữ state cho các root của management và báo tiền của cả tổ chức](../diagrams/01-bootstrap-dark.svg#gh-dark-mode-only)

State của root env (`aws/envs/<env>`, `aws/gitops/<env>`) không ở đây: mỗi account env có bucket riêng do `aws/accounts/<env>` tạo
(chương [08. Account env](08-accounts.md)). Bucket của management chỉ giữ state của các root chạy bằng
profile `anhnv-sso`; danh sách ở [README `aws/bootstrap`](../../aws/bootstrap/README.md#root-dùng-bucket-state).

| Thành phần | Ở đâu | Làm gì |
| --- | --- | --- |
| Bucket `svp-tfstate-<account>-<region>` | management, `ap-southeast-1` | Một key `<thư mục root>/terraform.tfstate` mỗi root; khoá bằng lock file của backend S3 |
| KMS key `alias/svp-tfstate` | management, `ap-southeast-1` | Mã hoá mặc định của bucket, S3 Bucket Key |
| `aws/backend.hcl` | máy người học, không commit | Cấu hình backend mà mọi root của management đọc bằng `-backend-config` |
| Budget `svp-monthly` | management, toàn cục | Email ở 50 %, 80 %, 100 % chi phí thực tế và 100 % dự báo của hoá đơn gộp |
| Monitor `svp-services`, subscription `svp-daily` | management, toàn cục | Bất thường chi phí theo từng dịch vụ; email tóm tắt hằng ngày |
| Tag phân bổ `Project`, `Env`, `Stack` | management, toàn cục | Lọc và nhóm chi phí trong Cost Explorer, Budgets |

## Kịch bản thực tế

**Câu hỏi của chương:** Một buổi stg kết thúc mà quên gỡ env, ai biết, qua đường nào?

1. Buổi stg dừng giữa chừng; bước destroy chưa chạy. Cluster EKS, node, NAT gateway của `svp-stg` vẫn tính tiền theo giờ.
2. Chi phí của `svp-stg` vào hoá đơn gộp của management. Dữ liệu billing có độ trễ: Cost Explorer có số của ngày sau khoảng một ngày,
   nên cảnh báo tiền không bao giờ tức thì.
3. Monitor `svp-services` (loại `DIMENSIONAL`, chiều `SERVICE`) so chi phí mỗi dịch vụ với mức thường ngày của nó. Một env để qua đêm làm
   EC2, EKS tăng vượt ngưỡng tác động `≥ 10` USD của `cost.tf`; một buổi thường thì không
   ([ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §11). Subscription `svp-daily`
   gom bất thường đó vào email tóm tắt hằng ngày tới `budget_emails`.
4. Budget `svp-monthly` tính dự báo cuối tháng từ tốc độ tiêu hiện tại. Env bị bỏ quên đẩy dự báo qua hạn mức trước chi phí thực tế:
   ngưỡng `FORECASTED` 100 % gửi email sớm hơn ngưỡng `ACTUAL`.
5. Người học mở Cost Explorer, nhóm theo tag `Env` và `Stack`: dòng `stg` tăng là env stg, không phải phần sống lâu (`Stack=org`,
   `Stack=security`…). Rồi chạy destroy và quét sót theo runbook buổi.

Cả hai đường chỉ báo, không dừng tài nguyên: svp không dùng Budget action. Cảnh báo cũng không thay bước quét sót cuối buổi, chỉ là lưới
an toàn khi bước đó bị bỏ.

## Các dịch vụ và cách svp dùng

### Amazon S3 (bucket state)

- **Làm gì:** giữ file state của mỗi root và một lock file cạnh nó trong lúc lệnh chạy. Ví dụ đời thực:
  - Hai terminal cùng `plan` `aws/org`: lệnh sau báo `Error acquiring the state lock` vì lock file `aws/org/terraform.tfstate.tflock`
    đang có.
  - Một `apply` lỗi làm state sai: versioning còn bản trước, chép lại được.
  - Một request HTTP không TLS tới bucket bị statement `DenyInsecureTransport` của bucket policy từ chối.
- **Ở svp:** bucket `svp-tfstate-<account>-ap-southeast-1` ở management; versioning, SSE-KMS mặc định với S3 Bucket Key, chặn public,
  `BucketOwnerEnforced` (ACL tắt), `prevent_destroy`. Khoá bằng `use_lockfile` của backend S3, không bảng DynamoDB.
- **Phí theo:** GB-tháng lưu trữ (cả bản cũ do versioning giữ), số request.

### AWS KMS (key của state)

- **Làm gì:** mã hoá object của bucket bằng một customer managed key; ai đọc state phải được `kms:Decrypt` trên key đó. Ví dụ đời thực:
  - Object state mới ghi có `ServerSideEncryption` là `aws:kms` và `SSEKMSKeyId` là ARN của key (lệnh `head-object` của runbook).
  - Key xoay tự động mỗi năm; object cũ vẫn đọc được bằng bản key cũ.
  - Key bị lên lịch xoá: 30 ngày chờ, trong thời gian đó `cancel-key-deletion` còn cứu được.
- **Ở svp:** key `alias/svp-tfstate`, xoay tự động, chờ xoá 30 ngày, `prevent_destroy`; key policy mặc định của AWS, nên IAM của
  management quyết ai dùng key, như ai đọc bucket.
- **Phí theo:** key-tháng (lần xoay tự động thứ nhất, thứ hai mỗi lần thêm một khoản key-tháng); request API, phần lớn bị S3 Bucket Key
  gom lại.

### AWS Budgets

- **Làm gì:** so chi phí thực tế và dự báo của kỳ với hạn mức, gửi email khi vượt ngưỡng phần trăm. Ví dụ đời thực:
  - Chi phí tháng qua 50 % hạn mức giữa tháng: nhắc rằng tháng này nhiều buổi.
  - Dự báo qua 100 % ngay sau một buổi để qua đêm: dấu hiệu env chưa gỡ.
  - Chi phí thực tế qua 100 %: hạn mức đã thấp hơn phí giữ cộng các buổi, xem lại hạn mức hay số buổi.
- **Ở svp:** budget `svp-monthly` loại `COST`, theo tháng, không filter, nên ở management nó tính hoá đơn gộp của mọi account. Hạn mức
  `budget_limit_usd`, email `budget_emails` (cả hai ở `bootstrap.auto.tfvars`, không commit); bốn ngưỡng ở `local.budget_alerts` của
  `budget.tf`. Email gửi thẳng, không có bước xác nhận như SNS.
- **Phí theo:** budget không có action không tính phí; budget có action tính theo ngày sau một số budget miễn phí.
- **Cố ý tắt:** Budget action (gắn policy chặn, dừng instance): báo đủ cho một người học tự gỡ; action dừng tài nguyên giữa buổi khó
  đoán hơn cái nó cứu.

### AWS Cost Anomaly Detection

- **Làm gì:** học mức chi tiêu thường ngày của từng dịch vụ bằng machine learning và báo khi một ngày khác hẳn mức đó. Ví dụ đời thực:
  - EC2 và EKS của `svp-stg` tăng sau một đêm không gỡ env: một bất thường mỗi dịch vụ trong email tóm tắt.
  - NAT gateway xử lý nhiều GB hơn thường lệ trong một buổi tải.
  - Một dịch vụ chưa từng dùng bắt đầu tính tiền (ai đó bấm bật trên console).
- **Ở svp:** monitor `svp-services` (`DIMENSIONAL`, `SERVICE`), subscription `svp-daily` (`DAILY`) gửi tới `budget_emails` khi
  `ANOMALY_TOTAL_IMPACT_ABSOLUTE` từ ngưỡng của `cost.tf` trở lên. Mỗi account chỉ có một monitor `DIMENSIONAL`/`SERVICE`, nên monitor do
  AWS tự tạo (`Default-Services-Monitor`) được nhận quản thay vì tạo thêm.
- **Phí theo:** không tính phí.

### Tag phân bổ chi phí

- **Làm gì:** biến một tag key thành chiều lọc và nhóm trong Cost Explorer, Budgets và báo cáo chi phí, cho chi phí từ ngày kích hoạt. Ví
  dụ đời thực:
  - Cost Explorer nhóm theo `Env`: tách phí một buổi stg khỏi phí giữ của tổ chức.
  - Nhóm theo `Stack`: phần sống lâu (`org`, `security`, `log-archive`…) so với phần dựng trong buổi.
  - Tag key chưa xuất hiện trong dữ liệu billing thì không kích hoạt được.
- **Ở svp:** `Project`, `Env`, `Stack` ở trạng thái `Active`, kích hoạt ở management (account trả tiền). Giá trị do `default_tags` của mọi
  root đặt; tag policy `svp-tags` giữ hoa thường và giá trị đúng (chương [03. Tổ chức](03-org.md)).
- **Phí theo:** không tính phí.
- **Cố ý tắt:** `ManagedBy`: mọi tài nguyên đều là `terraform`, không tách được gì.

## Chi phí

| Khoản | Đơn vị tính | Giữa các buổi | Trong buổi | Nguồn |
| --- | --- | --- | --- | --- |
| KMS key `alias/svp-tfstate` | key-tháng | 1 USD mỗi tháng | như giữa buổi | ADR-0078 phụ lục, dòng "Mọi KMS CMK" |
| Bucket state | GB-tháng, request | < 0,01 USD mỗi tháng (vài MB) | không có số đo | ADR-0048 phụ lục, bảng R, dòng "Bucket state" |
| Budget, Cost Anomaly Detection | — | 0 | 0 | ADR-0078 phụ lục, dòng "Budget, Cost Anomaly Detection" |
| Tag phân bổ chi phí | — | 0 | 0 | ADR-0060 §11 |

Bảng phí giữ và phí một buổi của mọi root ở chương [15. Chi phí](15-cost.md).

## Kiểm tra và vận hành

Đăng nhập console của management bằng profile `anhnv-sso` (permission set quản trị của người học).

| Muốn xem | Account | Region | Vào đâu | Trạng thái mong đợi |
| --- | --- | --- | --- | --- |
| Bucket state | management | `ap-southeast-1` | S3 → `svp-tfstate-…` → Objects | Một thư mục mỗi root đã áp; không object public |
| Key của state | management | `ap-southeast-1` | KMS → Customer managed keys → `alias/svp-tfstate` | `Enabled`, xoay tự động bật |
| Budget | management | toàn cục | Billing and Cost Management → Budgets → `svp-monthly` | Hạn mức đúng `budget_limit_usd`, bốn ngưỡng |
| Bất thường chi phí | management | toàn cục | Billing and Cost Management → Cost Anomaly Detection | Monitor `svp-services`, subscription `svp-daily` |
| Tag phân bổ | management | toàn cục | Billing and Cost Management → Cost allocation tags | `Project`, `Stack` `Active`; `Env` sau buổi đầu |

Bảng trên là trạng thái mà code khai báo. Phần đã kiểm thật là phần runbook có bước:
[`org-security-setup.md`, bước (1)](../runbooks/org-security-setup.md#bước-1-awsbootstrap) (áp, chuyển state, kiểm mã hoá, monitor và
tag) và mục 7f (chi phí theo dịch vụ sau 1 và 7 ngày, cùng monitor và tag).

## Thiết kế và đánh đổi

### Một bucket state cho management, một bucket mỗi account env

Root của management (tổ chức, log, bảo mật, baseline, backup, cài đặt GitHub) dùng chung bucket của management vì chúng cùng một người
chạy, cùng một profile. Root của env để state ở account env: state chứa giá trị nhạy cảm của env, và admin của env đọc nó mà không cần
quyền ở management. Lý do chung của hạ tầng AWS:
[ADR-0034](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0034-aws-stage7.md) §2.

### Bootstrap tự giữ state của chính nó

Bucket chưa có thì root không thể để state trong bucket. Lần áp đầu chạy trên state local (file override thay khối `backend "s3"`), rồi
`terraform init -migrate-state` chép state lên bucket vừa tạo. Cái giá là một bước tay khi dựng và khi gỡ (đưa state về local trước khi
xoá bucket).

### Báo tiền ở tầng tổ chức

Budget và monitor ở management, không filter, nên một cấu hình phủ mọi account. Ngưỡng tuyệt đối 10 USD của bất thường đặt trên mức một
buổi thường tăng mỗi dịch vụ, để email chỉ tới khi có chuyện (ADR-0060 §11).

| Lựa chọn của svp | Cái giá | Phương án khác | Khi nào chọn nó |
| --- | --- | --- | --- |
| Lock file native của backend S3 | Cần Terraform 1.10 trở lên | Bảng DynamoDB khoá state | Terraform cũ hơn 1.10; Terraform hiện đánh dấu cách này deprecated |
| SSE-KMS bằng customer managed key | Một key-tháng; ai đọc state cần quyền key | SSE-S3 mặc định | Không cần tách quyền đọc state khỏi quyền đọc bucket |
| Một budget không filter cho cả tổ chức | Không tách hạn mức theo env | Budget mỗi account hay mỗi tag `Env` | Nhiều team, mỗi team một hạn mức |
| Chỉ email, không Budget action | Người học phải tự gỡ | Budget action gắn SCP hay dừng instance | Có workload không ai trông và được phép dừng |
| Monitor theo dịch vụ | Không thấy bất thường của một account giữa nhiều account cùng dịch vụ | Monitor theo linked account, cost category hay tag | Nhiều account workload cùng dịch vụ |
| Ba tag phân bổ | Tag chỉ áp cho chi phí từ ngày kích hoạt | Cost category theo quy tắc | Cần nhóm theo quy tắc phức tạp hơn tag |

## Liên hệ đề SAP

- "Skill 3.3.5: Configure cost monitoring and alerting solutions that include budget thresholds and anomaly detection (for example, by
  using AWS Budgets, AWS Cost Anomaly Detection)." Budget `svp-monthly` với ngưỡng thực tế và dự báo; monitor `svp-services` và subscription
  `svp-daily`.
- "Skill 3.3.1: Design tagging strategies for cost allocation (for example, by using tags for business units, projects, and
  environments)." Ba tag `Project`, `Env`, `Stack` từ `default_tags` của mọi root.
- "Skill 3.3.2: Configure cost reporting and analytics solutions that use detailed billing data (for example, by using AWS Cost Explorer,
  AWS Cost and Usage Reports)." Cost Explorer nhóm theo tag trong kịch bản trên; runbook đọc chi phí theo dịch vụ bằng API Cost Explorer.
- "Skill 2.2.1: Implement encryption at rest by using customer managed keys and automatic key rotation (for example, by using AWS KMS)."
  Key `alias/svp-tfstate` xoay tự động, mã hoá mặc định của bucket state.

| Tình huống trong đề | Chọn | Vì sao không chọn cái gần giống |
| --- | --- | --- |
| Báo khi chi phí tháng sắp vượt một con số cố định | AWS Budgets | Cost Anomaly Detection so với mức thường ngày, không với hạn mức |
| Báo khi một dịch vụ tiêu khác hẳn mọi ngày dù tổng tháng còn thấp | Cost Anomaly Detection | Budget chỉ thấy tổng vượt ngưỡng, không thấy bất thường nhỏ |
| Tự động chặn tạo tài nguyên khi vượt budget | Budget action gắn SCP hay IAM policy | Budget thường chỉ gửi email |
| Phân tích chi phí theo env bằng tag | Kích hoạt tag phân bổ ở management account | Gắn tag thôi chưa đủ; account thành viên không kích hoạt được |
| Truy vấn chi tiết từng dòng billing bằng SQL | Cost and Usage Reports (Data Exports) với Athena | Cost Explorer chỉ có tổng hợp và lọc sẵn |
| Khoá state Terraform cho nhiều người chạy | Backend S3 với lock file (hay DynamoDB với Terraform cũ) | Versioning chỉ giữ bản cũ, không ngăn ghi đồng thời |

## Đọc sâu

- Backend S3 có `encrypt = true` mà không `kms_key_id` tự đặt SSE-S3 cho mỗi lần ghi, đè mã hoá mặc định của bucket. Vì thế
  `aws/backend.hcl` mang `kms_key_id`, và mọi root phải `init -reconfigure` sau khi file đổi; object cũ giữ SSE-S3 tới lần ghi kế, bản cũ
  do versioning giữ vẫn SSE-S3 (bucket không có lifecycle xoá bản cũ).
- Bật Cost Explorer lần đầu (chỉ trên console) làm AWS tạo `Default-Services-Monitor`; tạo thêm một monitor `DIMENSIONAL`/`SERVICE` thì
  `apply` lỗi `Limit exceeded on dimensional spend monitor creation`. Runbook nhận quản monitor đó bằng `terraform import` trước `plan`:
  plan đổi tên tại chỗ, không thay.
- Tag key chỉ kích hoạt được khi đã có trong dữ liệu billing: `Project`, `Stack` sau lần áp đầu (bucket mang tag), `Env` chỉ sau buổi env
  đầu tiên. Thiếu key thì `apply` lỗi ở đúng `aws_ce_cost_allocation_tag` của key đó, các tài nguyên khác vẫn tạo.
- Tên bucket `<tên>-<account>-<region>` như bucket của AWS CDK, Control Tower: duy nhất toàn cầu không cần phần ngẫu nhiên; account vào
  tên lúc chạy từ `TF_VAR_account_id`, không file commit nào chứa nó. Provider từ chối account khác (`allowed_account_ids`).
- Script quét sót của buổi bỏ qua `Stack=bootstrap`: tài nguyên của root này không bao giờ là đồ sót.
- Management không giữ hosted zone nào: zone của lab ở account env
  ([ADR-0051](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0051-dns-prd-apex.md)).

Làm và tra cứu:

- [`org-security-setup.md`, bước (1)](../runbooks/org-security-setup.md#bước-1-awsbootstrap): áp root này, chuyển state, init lại
  mọi root.
- [`lab-teardown.md`, Xoá bootstrap](../runbooks/lab-teardown.md#xoá-bootstrap): gỡ bucket và key khi lab kết thúc.
- [`aws/bootstrap`](../../aws/bootstrap/README.md): tài nguyên, root dùng bucket state.
- [ADR-0060](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0060-org-detection-logging.md) §11, §12: Cost Anomaly Detection,
  tag phân bổ, chi phí liên tục.
- [ADR-0078 phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0078-paid-features-lean-defaults.md#chi-phí):
  phí giữ theo khoản.
