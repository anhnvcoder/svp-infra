# Runbook: dựng env stg và cài Argo CD (bước 1–15)

← [session-stg](session-stg.md) · [Mục lục](README.md) · [Phép kiểm release](session-stg-check-release.md) →

> **Tóm tắt**
>
> - **Làm gì:** kiểm account và DNS, mở tính năng của buổi (`aws/accounts/stg`), dựng root `aws/envs/stg` (mạng, EKS, RDS, MSK,
>   ElastiCache, edge, media), ghi secret, làm nóng cache ECR, cài Argo CD bằng root `aws/gitops/stg`, rồi chờ mọi Application Healthy
>   và ALB edge có target `healthy`.
> - **Khi nào và bao lâu:** đầu mỗi buổi stg, sau khi đủ điều kiện ở trang chủ. Apply root env xong ~T+70 phút (MSK là phần dài nhất),
>   mọi Application Healthy ~T+1 giờ 55; hạn từng bước ở bảng [Thứ tự](session-stg.md#thứ-tự).
> - **Phí trong lúc chạy:** phí của buổi bắt đầu từ bước 9 (EKS, RDS, MSK, ElastiCache, ALB, NAT…), tính theo giờ tới khi destroy; ước
>   tính ở [Giới hạn](session-stg.md#giới-hạn) của trang chủ.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người học dán
lại. Mỗi bước dán lại phần ghi ở cột "Dán lại cho AI" của bảng [Thứ tự](session-stg.md#thứ-tự). Vì sao từng phần dựng:
[09. Env và mạng](../handbook/09-envs-network.md), [10. EKS](../handbook/10-eks.md), [13. GitOps](../handbook/13-gitops.md).

## Điều kiện trước

- [ ] **Mười một điều kiện** của [Điều kiện trước](session-stg.md#điều-kiện-trước) ở trang chủ đã đủ (baseline stg, DNS uỷ quyền, code đã
  merge, file backend và `stg.auto.tfvars`, nền bảo mật, edge, nền tảng managed, backup).
- [ ] **Cờ của buổi** đã đọc: [Cờ chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi) (đổi cờ chỉ giữa hai buổi).

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ. Trang này cần các biến
`SVP_SESSION_DIR`, `SVP_AWS_STG_ACCOUNT_ID`, `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_BACKUP_ACCOUNT_ID` và profile `anhnv-stg`; terminal mở lại
giữa buổi dùng thư mục buổi đang dở, không phải thư mục mới.

## 1. Kiểm account

Loại: `lõi`. Kiểm profile `anhnv-stg` trỏ đúng account `svp-stg` trước mọi lệnh ghi.

```sh
aws/scripts/check-account.sh stg
```

- **Mong đợi:** `ok    account <12 số> of stg, arn:aws:sts::<12 số>:assumed-role/AWSReservedSSO_SvpAdmin_…` với đúng account `svp-stg`.
- **Bẫy:** `FAIL … not SVP_AWS_STG_ACCOUNT_ID` là profile `anhnv-stg` trỏ account khác: dừng, không chạy gì nữa. Mọi script chạm account
  (trừ `check-dns.sh`) tự kiểm lại điều này trước lệnh đầu tiên của nó, nên `tf.sh` không bao giờ chạy trên account khác. Cùng lệnh với
  `prd`, `mgmt` kiểm account của env đó trước một lệnh ghi bằng tay.

## 2. Kiểm DNS

Loại: `lõi`.

```sh
aws/scripts/check-dns.sh stg
```

Script đọc name server của zone `stg.aws.<domain>` (tên là `zone_name` của `aws/accounts/stg/stg.auto.tfvars`) từ output `name_servers` của
`aws/accounts/stg` (không gọi API AWS nào khác), hỏi `NS stg.aws.<domain>` ở `1.1.1.1` và `8.8.8.8`.

- **Mong đợi:** `ok hosted zone …`, rồi `ok resolver 1.1.1.1 …`, `ok resolver 8.8.8.8 …`.
- **Bẫy:** `FAIL … returns no NS` hay `returns NS … not the hosted zone's`: uỷ quyền chưa lan hay sai (validation DNS của cert ACM và ba tên
  của buổi sẽ hỏng). Lời của script là một câu chung: uỷ quyền zone con nằm ở `delegated_subdomains` của `aws/accounts/prd`, zone gốc ở
  bản ghi `NS` `aws` của DNS cha. Zone stg đi qua cả hai nấc, nên kiểm cả hai theo
  [`accounts-setup.md`, bước (5)](accounts-setup.md#bước-5-uỷ-quyền-zone-của-env): sửa nấc sai, **không bắt đầu buổi**.

## 3–5. Root account: mở tính năng của buổi

Loại: `lõi`. Với giá trị của file (`managed_grafana` `off`) ba lệnh in `ok no session feature of stg …` và không chạy gì; phần dưới là của
buổi bật `session` cho phép kiểm dashboard.

```sh
aws/scripts/tf.sh stg account init
aws/scripts/tf.sh stg account plan --open
aws/scripts/tf.sh stg account apply
```

Root `aws/accounts/stg` dựng phần mà cờ `session` của stg chỉ cho có trong buổi (mục
[Cờ chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi)). Với `managed_grafana` là bảy tài nguyên dưới `module.observability`: workspace
AMG `svp-stg`, role `svp-stg-grafana` và policy của nó, hai `aws_grafana_role_association`, service account `svp-grafana-operator`, tham số
SSM `/svp/stg/grafana-workspace-id` (root env đọc id workspace từ tham số này). Mỗi buổi là một workspace mới, nên id và URL của nó đổi
mỗi buổi.

- **Mong đợi:** `init` chạy `terraform init -reconfigure` với `../../backend-stg.hcl` và key `aws/accounts/stg/terraform.tfstate`,
  state của baseline. `plan --open` plan với `-var session_open=true`, ghi `aws/accounts/stg/stg.account-open.tfplan` (xoá plan
  đóng cũ nếu còn) và bản text `stg-account-open-plan.txt` ở thư mục buổi. **Đọc file text đó trước khi apply**: chỉ `to add`,
  `0 to change, 0 to destroy`, đúng bảy tài nguyên trên. `apply` chỉ nhận đúng một plan đã lưu của root này, áp nó, ghi mốc
  `account-open-applied` rồi xoá file.
- **Kiểm:** `tf.sh stg env plan` từ chối tới khi mốc cuối trong `account-open-applied`, `account-close-applied` của buổi là
  `account-open-applied` (`FAIL the session features of stg (managed_grafana) are not open …`). Env không có cờ `session` (prd sau khi đổi
  về giá trị production theo điều kiện của [`session-prd.md`](session-prd.md)) thì ba lệnh in `ok no session
  feature of <env> in aws/paid-features.json: …` và không chạy gì.
- **Bẫy:** plan có tài nguyên khác (baseline, registry, backup) là state của root lệch code trên `main`: dừng, dán plan cho AI. Cần
  `aws/accounts/stg/stg.auto.tfvars` (có từ khi dựng baseline) và `SVP_AWS_BACKUP_ACCOUNT_ID` (key của vault `svp-stg`). `apply` đỏ giữa
  chừng: đọc lỗi, `plan --open` lại, `apply` lại.
- **Bẫy:** **trong buổi, root `aws/accounts/stg` chỉ apply qua `tf.sh stg account`.** Biến `session_open` mặc định `false` và
  không nằm trong file nào, nên `terraform plan`, `apply` trần ở root đó (lệnh của [`accounts-setup.md`](accounts-setup.md), của
  [`platform-setup.md`](platform-setup.md)) giữa bước 5 và bước 29 xoá workspace AMG mà cluster đang dùng. Đổi root đó giữa buổi
  (hiếm) thì thêm `-var session_open=true` vào lệnh `plan` và đọc plan: không dòng `destroy` nào dưới `module.observability`.

## 6–10. Root env: init, khoá ký, plan lưu file, đọc, apply file đó, kích hoạt khoá ký

Loại: `lõi`.

```sh
aws/scripts/tf.sh stg env init
aws/scripts/media-signing-key.sh stg new a
aws/scripts/tf.sh stg env plan
aws/scripts/tf.sh stg env apply
aws/scripts/media-signing-key.sh stg activate a
```

**Bước 6, `init`.** Luôn chạy `terraform init -reconfigure -backend-config=../../backend-stg.hcl
-backend-config=key=aws/stg/terraform.tfstate`:
file backend của account stg cộng key của chính root này. `-reconfigure` bỏ cấu hình backend cũ mà `.terraform` còn giữ (lần init đầu ở
account mới, `.terraform` vẫn trỏ bucket của management) và **không bao giờ migrate state**: state cũ `aws/stg/terraform.tfstate` ở bucket
management đã được chứng minh rỗng khi dựng baseline, buổi này bắt đầu từ state trống ở bucket của account stg.

**Bước 7, khoá ký.** `new a` sinh khoá ký URL premium của buổi: khoá riêng vào thư mục khoá ngoài repo, khoá công khai vào ô `a` của
`aws/envs/stg/media-signing.auto.tfvars.json` (git bỏ qua), file `plan` đọc; ô `b` của buổi trước bị bỏ, khoá của nó đã đi cùng root env.
Lệnh, phép kiểm và cách xoay: [`media-signing-keys.md`](media-signing-keys.md).

- **Mong đợi:** `ok slot a: … (slots a)`; dòng `note slot b dropped …` là đúng ý.
- **Bẫy:** thiếu file đó thì `plan` dừng ở `No value for required variable` (`media_signing_public_keys`).

**Bước 8, `plan`.** Ghi `aws/envs/stg/stg.tfplan` (nhị phân, git bỏ qua) và ngay sau đó bản text của nó vào
`$SVP_SESSION_DIR/stg-env-plan.txt` (thư mục buổi, git bỏ qua: plan có tên miền và IP thật nên không vào cây repo); `ok` cuối của
`plan` nêu đường dẫn file text. Ghi lại bản text từ plan hiện có: `aws/scripts/tf.sh stg env show`.

- **Kiểm:** **đọc file text đó trước khi apply**: lần đầu mỗi buổi chỉ `to add`, `0 to change, 0 to destroy`. Plan có ba web ACL
  `module.waf["web"]`, `["api"]`, `["media"]` (`aws_wafv2_web_acl.this`, provider `us-east-1`); `module.edge`: ALB `svp-stg-edge`
  với `internal = true` ở subnet edge, listener HTTPS 443, target group `svp-stg-envoy`, VPC origin `svp-stg-edge`, distribution
  `svp-stg-web`, `svp-stg-api`, cert ACM (`us-east-1` cho distribution, region nhà cho ALB), bản ghi A, AAAA và validation,
  delivery log `us-east-1`; distribution `svp-stg-media` (`media.<domain>`) với gói
  `module.media.aws_pricingplanmanager_subscription.media[0]` `plan_tier = "FREE"` (phép kiểm (b) của ADR-0052), behavior mặc định
  có `trusted_key_groups` (`media/*`, `preview/*` không), public key `module.media.aws_cloudfront_public_key.media["a"]`
  (`svp-stg-media-a-<8 hex>`) và key group `svp-stg-media`. Plan có cluster `module.msk.aws_msk_cluster.this` (`kafka_version =
  "4.1.x.kraft"`, `kafka.t3.small`, 2 broker), mỗi user của module `msk` một secret `AmazonMSK_svp-stg-*`, replication group
  `module.elasticache.aws_elasticache_replication_group.this` (`engine = "valkey"`, `engine_version = "9.1"`) và bốn
  `aws_elasticache_user`; mật khẩu của chúng là đối số write-only, plan chỉ in `(write-only attribute)`, không giá trị. Plan cũng
  có: node group `system` của `module.eks` (không node group nào khác), submodule `module.eks.module.karpenter` (hàng đợi SQS
  `svp-stg-karpenter`, rule EventBridge, role `svp-stg-karpenter`, `svp-stg-karpenter-node`, Pod Identity association), bastion
  `module.ssm_bastion`, KMS key của `module.rds`, `module.msk`, `module.alarms` và của Secrets EKS, topic SNS `svp-stg-alarms` với
  một subscription `email`, các `aws_cloudwatch_metric_alarm` của `module.rds`, `module.msk`, `module.elasticache` (bảng alarm của
  ADR-0058 §2), target và policy autoscaling storage của MSK, log group slow-log của Valkey.
- **Bẫy:** có `destroy` hay `change` là state còn tài nguyên của buổi trước (destroy dở): dừng, dán plan cho AI.

**Bước 9, `apply`.** Chỉ nhận file plan của bước 8 (không plan lại tại chỗ), rồi xoá nó. Thời gian: EKS ~10–15 phút, RDS ~10 phút, ba
distribution CloudFront và cert ACM (DNS validation) ~5–15 phút, MSK ≤ 45 phút, ElastiCache ≤ 20 phút (giả định của ADR-0053 §16), song
song; gói Free chờ tới `ACTIVE` (vài phút tới hơn nửa giờ). Root này cũng tạo các entry `svp/stg/*` của Secrets Manager: `kafka-admin`,
`kafka-users`, `valkey-users` có giá trị ngay trong apply này (Terraform sinh mật khẩu, ghi cùng một giá trị vào secret `AmazonMSK_*`, user
ElastiCache và entry; không vào plan hay state), `media-signing` còn rỗng tới bước 10, các entry khác tới bước 11.

- **Mong đợi:** ghi lại hai dòng `Creation complete after …` của cluster MSK và replication group ElastiCache trong output (phút dựng, phép
  kiểm (a) của ADR-0053).
- **Bẫy:** `apply` đỏ giữa chừng: đọc lỗi, `plan` lại, `apply` lại. Ngoại lệ là khi output của lượt đỏ đã có `Creation complete`
  hay `Modifications complete` của một tài nguyên mang mật khẩu: `aws_secretsmanager_secret_version` hay `aws_elasticache_user`
  dưới `module.msk` (nhóm Kafka) hay `module.elasticache` (nhóm Valkey). Mật khẩu là write-only: phần đã ghi giữ mật khẩu của lượt
  đỏ, `plan` lại không thấy lệch (in `No changes` cho chúng), còn phần chưa ghi nhận mật khẩu mới của lượt sau, nên user và entry
  lệch nhau (`WRONGPASS` ở phép kiểm (d) của ADR-0053 ở bước 16, MSK từ chối đăng nhập). Khi đó tăng version của nhóm đó trước khi
  `plan` lại, đúng cách của mục [Đổi một secret của env đang chạy](session-stg.md#đổi-một-secret-của-env-đang-chạy) (`tfvars.sh
  bump stg msk|valkey` tăng `msk_password_version`, `valkey_password_version` trong `stg.auto.tfvars`): apply với version mới ghi
  lại mọi mật khẩu của nhóm từ cùng một giá trị; rồi đi tiếp bước 11 (`bootstrap.sh stg secrets`, lệnh kết thúc lượt xoay đó). Lỗi
  nằm ở chính access string của user ElastiCache thì không apply lại (bảng dưới).
- **Bẫy:** muốn bỏ buổi thì sang bước 20 (`pre-destroy.sh` tự ghi context `svp-stg`, nên chạy được cả khi apply đỏ sau khi cluster EKS đã
  có), hay bước 25 rồi 26 với `--no-cluster` khi apply đỏ trước khi tạo cluster EKS (điều kiện ở
  [23–27](session-stg-teardown.md#2327-gỡ-root-env)).

Lỗi apply đã biết, không sửa bằng `plan` lại:

| Lỗi | Nguyên nhân | Cách xử lý |
| --- | --- | --- |
| `AccessDenied: Your account must be verified before you can add new CloudFront resources` ở `aws_cloudfront_distribution` | account chưa được AWS xác minh cho CloudFront | gỡ buổi như trên, rồi case AWS Support của điều kiện 1 |
| lỗi ở `module.elasticache.aws_elasticache_user.this[…]` về `access_string` (ElastiCache không nhận một luật của chuỗi) | access string của ADR-0053 §9 chưa qua phép kiểm (a) của buổi stg; `plan` lại, version mới đều gửi lại đúng chuỗi đó | không apply lại; gỡ buổi như trên, dán lỗi cho AI: sửa chuỗi bằng PR (ADR-0053 §9, module `elasticache`, aclfile local cùng chuỗi), rồi buổi mới |
| lỗi ở `aws_cloudwatch_log_delivery` của `module.edge` hay `module.media` nêu delivery destination `svp-cloudfront-stg` | destination chưa có hay policy của nó chưa cho account stg: bước (1) của `edge-setup.md` chưa áp | gỡ buổi như trên, áp bước (1) của [`edge-setup.md`](edge-setup.md#bước-1-log-cloudfront-và-quyền-đọc), rồi buổi mới |
| `ServiceQuotaExceededException` ở `aws_pricingplanmanager_subscription.media` (câu của mô hình API: "You have reached the maximum number of subscriptions allowed for your account"; câu lúc chạy có thể khác, nhận theo tên lỗi) | account đã dùng hết 3 gói Free; tài liệu AWS không nói gói đã huỷ có bị đếm hay không (ADR-0052, Hệ quả) | không apply lại; gỡ buổi như trên, rồi mở case AWS Support từ account đó kèm dòng lỗi và RequestID |

**Bước 10, `activate a`** (sau apply). Đọc ID của ô `a` từ output `media_signing_key_ids`, kiểm CloudFront giữ đúng khoá công khai của file
dưới ID đó, ghi ID và khoá riêng vào entry `svp/stg/media-signing` (không giá trị nào qua đối số hay output) rồi xoá file khoá riêng.

- **Mong đợi:** `ok entry svp/stg/media-signing: key <ID> of slot a (not shown), version <id>; …`; rồi phép (a), (b) của
  [`media-signing-keys.md`](media-signing-keys.md#kiểm).
- **Bẫy:** `make eks-secrets` của bước 11 dừng khi entry này chưa có giá trị.

**Xác nhận email của alarm** (mỗi buổi, sau apply).

- **Việc tay:** SNS gửi thư "AWS Notification - Subscription Confirmation" tới `alarm_email`; mở link "Confirm subscription" trong
  thư. Chưa xác nhận thì không alarm nào tới email. Đọc lại (ARN của topic tính từ biến account của buổi):

  ```sh
  AWS_PROFILE=anhnv-stg aws --no-cli-pager sns list-subscriptions-by-topic --region ap-southeast-1 \
    --topic-arn "arn:aws:sns:ap-southeast-1:$SVP_AWS_STG_ACCOUNT_ID:svp-stg-alarms" --query 'Subscriptions[].SubscriptionArn' --output text |
    sed -E 's/^arn:.*/confirmed/'
  ```

- **Mong đợi:** `confirmed` (lệnh thay ARN bằng chữ đó, để output dán lại không có account).
- **Bẫy:** `PendingConfirmation` là chưa mở link (thư có thể ở mục spam). Subscription chưa xác nhận ở lại account sau destroy tới
  khi AWS tự xoá nó ([README của `aws/modules/alarms`](../../aws/modules/alarms/README.md)).

## Tunnel tới API (sau bước 9, trước bước 11)

Loại: `lõi`. Endpoint công khai của API tắt ở cả hai env (ADR-0055 §2): máy tới endpoint private qua phiên port forwarding của
Session Manager tới bastion `t4g.nano` trong subnet private (module `ssm-bastion`), cổng local `127.0.0.1:6444` (prd `6443`, cột
`tunnel` của `env_table`: một lệnh nhầm context không bao giờ tới cluster kia). Mở ở **một terminal riêng**
(mới mở, ở thư mục chứa các clone như khối [Mở terminal](session-stg.md#mở-terminal)), giữ chạy tới hết bước 22 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-stg terraform -chdir=aws/envs/stg output -raw api_tunnel_command)"
```

- **Mong đợi:** lệnh của output có sẵn profile `anhnv-stg` và `--region`; phiên chạy tiếp, không in lỗi. Context `svp-stg` do
  `bootstrap.sh stg secrets` (và `pre-destroy.sh stg`) ghi: server `https://127.0.0.1:6444`, TLS server name là host của endpoint private.
  Root `aws/gitops/stg` đi qua cùng tunnel (`api_server_url` của `aws/gitops/stg/stg.tfvars`). Mọi lệnh `kubectl` tay của buổi chạy khi
  tunnel mở.
- **Bẫy:** mọi script cần API (`bootstrap.sh stg wait`, `tf.sh stg gitops plan|apply|plan --destroy|destroy`, `measure.sh stg`,
  `pre-destroy.sh stg`) kiểm `127.0.0.1:6444` trước lệnh đầu tới API và dừng với `FAIL no tunnel …` khi tunnel chưa mở hay đã rớt (phiên SSM
  hết hạn): mở lại tunnel rồi chạy lại đúng bước đó.

## 11. Giá trị secret

Loại: `lõi`.

```sh
aws/scripts/bootstrap.sh stg secrets
```

Theo thứ tự: kiểm account; repo code ở `main` = `origin/main`, sạch; `aws eks update-kubeconfig --alias svp-stg`; ghi
`cluster-values.json`; đọc **mật khẩu** master của RDS (trường `password` của secret mà RDS giữ, username luôn `postgres`) vào môi
trường của đúng lệnh `make` (không ra file, không in), rồi `make -C ../backend eks-secrets CONTEXT=svp-stg` với
`AWS_PROFILE=anhnv-stg`: ghi các entry `svp/stg/*` từ `.env` (mỗi entry một `put-secret-value --secret-string file://…`, giá trị
không qua đối số hay output); `glitchtip-runtime` ba key rỗng chỉ khi chưa có giá trị. Ba entry của Kafka và Valkey
(`kafka-admin`, `kafka-users`, `valkey-users`) Terraform đã ghi ở bước 9: `make eks-secrets` chỉ kiểm chúng có, không ghi, không
đọc mật khẩu Kafka, Valkey của `.env` (mật khẩu của stack local). Rồi token của Grafana Operator, chỉ khi cờ `managed_grafana`
khác `off` (`off`: dòng `skip managed_grafana of stg is off …`, không workspace nên không token): tìm service account
`svp-grafana-operator` của workspace AMG (id từ `grafanaUrl` của `cluster-values.json`), xoá mọi token cũ của nó (quota 100 token
mỗi workspace, kể cả token hết hạn), tạo token sống 24 giờ và ghi thẳng vào entry `svp/stg/grafana-operator` qua pipe (token không
qua đối số, file hay output). Nguồn của mọi Secret trên EKS có trước Argo CD.

- **Mong đợi:** `ok a token of svp-grafana-operator valid 24 h in entry svp/stg/grafana-operator (not shown)` (cờ khác `off`),
  `ok entries svp/stg/* written (kafka-admin, kafka-users, valkey-users by the apply of aws/envs/stg); next: aws/scripts/ecr-warm.sh stg
  <image list>, …` và mốc `secrets-written`.
- **Bẫy:** đỏ thì dán ~30 dòng cuối của `$SVP_SESSION_DIR/eks-secrets.log` (script nêu tên biến thiếu, không in giá trị), hay dòng
  `FAIL` của phần Grafana (thiếu `grafanaUrl`, thiếu service account: `aws/accounts/stg` chưa có bước (5) của
  [`platform-setup.md`](platform-setup.md#bước-5-awsaccountsenv), hay cờ `managed_grafana` là `session` mà bước 3–5 chưa apply).

## Làm nóng cache (sau bước 11, trước bước 12)

Loại: `lõi`. Mọi image của cluster ghim digest, mà ECR không kéo được theo digest một image pull-through cache chưa từng thấy
([ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) §7). Nên trước khi Argo CD
cài gì, `ecr-warm.sh` kéo **theo tag** qua cache mọi image bên thứ ba của bản render eks của env, rồi kiểm digest ghim có ở ECR.
Danh sách do `deploy/ci/image-list.sh` của repo code in, mỗi dòng `<ref upstream>:<tag>@<digest>` (không image phát hành của lab:
chúng vào ECR qua CI). Lập danh sách không chạm AWS, làm được từ đầu buổi (render các chart ở `revision` của env như `make
helm-check`, ~1–2 phút, cần mạng và Docker):

```sh
(cd ../backend && deploy/ci/image-list.sh ../gitops stg) >"$SVP_SESSION_DIR/images-stg.txt"
wc -l <"$SVP_SESSION_DIR/images-stg.txt"
aws/scripts/ecr-warm.sh stg "$SVP_SESSION_DIR/images-stg.txt"
```

Script đọc hết danh sách trước lệnh đầu tiên (dòng sai dạng, image không thuộc năm tiền tố cache thì dừng, nêu dòng), kiểm account, rồi mỗi
image một `aws ecr batch-get-image` theo tag qua repo cache và so digest (đi hết danh sách, rồi mới dừng nếu có image đỏ).

- **Mong đợi:** mỗi image một dòng `ok`, dòng cuối `ok every image of … in the cache of stg at its pinned digest; next: …`, mốc
  `ecr-warm-start`, `ecr-warmed` trong `timeline.tsv`.
- **Bẫy:** dòng `FAIL` nêu image, tag, digest ghim và digest ECR trả: tag upstream đã dời (cache làm mới một tag tối đa mỗi ngày một lần;
  Renovate mở PR đổi digest ghim) hay credential của cache sai (dòng GHCR, Docker Hub:
  [`platform-setup.md`](platform-setup.md#xoay-credential)); dán mọi dòng `FAIL`. PR đổi digest bên thứ ba merge giữa buổi thì lập lại danh
  sách và chạy lại script trước khi Argo CD sync bản đó.
- **Kiểm:** xem trước lệnh, không chạy gì: `aws/scripts/ecr-warm.sh --print stg <file>` (`session.sh --print` không gồm bước này).

## 12–14. Root gitops: Argo CD và root GitOps

Loại: `lõi`.

```sh
aws/scripts/tf.sh stg gitops init
aws/scripts/tf.sh stg gitops plan
aws/scripts/tf.sh stg gitops apply
```

Root `aws/gitops/stg` ([README](../../aws/gitops/README.md)) đọc root env qua `terraform_remote_state`, cài theo thứ tự namespace (nhãn Pod
Security) → Argo CD (chart, version, values từ `svp-gitops` ở commit bootstrap) → AppProject → cluster Secret `in-cluster` (metadata của
cluster, `cluster_values`, chat Telegram) → ApplicationSet `svp-bootstrap` tạo Application `svp-root`. Plan đầu tiên của buổi chạy sau
apply root env: provider đọc output `cluster_endpoint`, `cluster_values` từ state đó, root env chưa apply thì plan lỗi ở
`terraform_remote_state`. Tunnel phải mở (mục [Tunnel tới API](#tunnel-tới-api-sau-bước-9-trước-bước-11)).

- **Việc tay:** không bắt buộc: `tf.sh` tự đặt `TF_VAR_telegram_chat_id` từ `.env` của repo code. Muốn đặt `telegram_chat_id` tay thì
  `aws/scripts/tfvars.sh example aws/gitops/stg` chép file ví dụ thành `stg.auto.tfvars` (git bỏ qua), rồi sửa.
- **Mong đợi:** `init` như bước 6 với key `aws/gitops/stg/terraform.tfstate`. `plan` trước hết fetch hai bản clone, giải nén chart
  `svp-cluster` của repo code ở `revision` của `envs/stg/charts.yaml` (`origin/main` của `svp-gitops`) bằng `git archive` vào
  `$SVP_SESSION_DIR/svp-cluster-chart/` (`TF_VAR_svp_cluster_chart`), lấy `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code
  (`TF_VAR_telegram_chat_id`), rồi plan; dòng `ok chart svp-cluster at <sha>` nêu commit. **Đọc file text `stg-gitops-plan.txt`**: chỉ thêm
  namespace, ba `helm_release`, Secret `in-cluster`. `apply` như bước 9; output `bootstrap_revision` là commit bootstrap B.
- **Bẫy:** plan cần mạng tới GitHub (raw file, REST API của `svp-gitops`).

## 15. Chờ Argo CD

Loại: `lõi`.

```sh
aws/scripts/bootstrap.sh stg wait
```

Script chờ Application `svp-observability` Healthy (GlitchTip chạy), chạy `make -C ../backend eks-glitchtip-init CONTEXT=svp-stg`
(DSN và token của GlitchTip vào entry `glitchtip-runtime`, dựng lại ba ExternalSecret; Secret `svp/sentry` đổi nên Reloader
restart service đọc DSN), rồi chờ `svp-root` Synced và Healthy (Argo CD báo Healthy khi mọi Application nó tạo Healthy), rồi chờ
target group `svp-stg-envoy` của ALB edge có một target `healthy` (pod Envoy do `TargetGroupBinding` `svp-envoy` đăng ký, health
check cổng 19003): smoke của bước 16 đi qua CloudFront và ALB đó. Mỗi lần chờ tối đa 30 phút.

- **Mong đợi:** `ok every Application Synced and Healthy on svp-stg`, mốc `svp-root-healthy`, rồi `ok the edge's target group has a healthy
  target; next: …` và mốc `edge-healthy`.
- **Bẫy:** `FAIL no healthy target in …` nêu trạng thái từng target: đọc
  `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system describe targetgroupbinding svp-envoy`. Đỏ: dán dòng `FAIL` (có
  trạng thái sync, health) và

  ```sh
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd get applications.argoproj.io
  ```

  sửa xong chạy lại (chạy lại được). Muốn bỏ buổi ở đây: sang bước 20; `pre-destroy.sh` chạy được cả khi Argo CD chưa được cài.
- **Bẫy:** cảnh báo `PublicUptimeBudgetBurn` (SLO `public-uptime`, hai mức cùng tên: `page` và `ticket`) cháy sau khi dựng cluster mới là do
  probe lỗi lúc dựng (probe chạy trước các service, thứ tự ở `argocd/apps/components.json` của svp-gitops): chờ, không điều tra. Khi ba đích
  đã xanh, page hết sau chừng 30 phút, ticket theo cửa sổ 6 giờ; cửa sổ của hai mức ở
  `deploy/observability/prometheus/rules/slo-generated.yaml` của svp-backend, cách đọc ở
  [`public-uptime-budget-burn.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/public-uptime-budget-burn.md).

## Chạy tay một root (không qua script)

Khi cần chạy `terraform` trần ở root env (đọc plan từng bước, kiểm một lỗi), mỗi lệnh đặt đủ biến account và profile như script. Script
`tf.sh` vẫn là đường chính của buổi: nó thêm các kiểm mốc (`session_open`, `backup-drained`) mà lệnh trần không có.

Kiểm account trước (cột `Account` phải bằng `$SVP_AWS_STG_ACCOUNT_ID`, `Arn` là role SSO `SvpAdmin`; khác thì dừng):

```sh
cd aws/envs/stg                                          # từ infra/, thư mục của terminal buổi
AWS_PROFILE=anhnv-stg aws --no-cli-pager sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_STG_ACCOUNT_ID"
```

Dựng:

```sh
cp example.auto.tfvars.example stg.auto.tfvars          # rồi sửa bốn giá trị
AWS_PROFILE=anhnv-stg terraform init -reconfigure -backend-config=../../backend-stg.hcl -backend-config=key=aws/stg/terraform.tfstate
export SVP_SESSION_DIR="$(git rev-parse --show-toplevel)/.session/$(date -u +%Y%m%dT%H%M%SZ)"  # thư mục buổi đang dở
../../scripts/media-signing-key.sh stg new a     # plan reads slot a's public key from media-signing.auto.tfvars.json
AWS_PROFILE=anhnv-stg \
TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" \
TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" \
  terraform plan -input=false -var-file=stg.tfvars -out=stg.tfplan
AWS_PROFILE=anhnv-stg terraform show -no-color stg.tfplan > "$SVP_SESSION_DIR/stg-plan.txt"
```

Đọc `stg-plan.txt` ([Đọc plan an toàn](../reference/operations.md#đọc-plan-an-toàn)): chỉ tài nguyên của `aws/envs/stg`, không
`destroy` nào. Đúng thì apply:

```sh
AWS_PROFILE=anhnv-stg terraform apply -input=false stg.tfplan && rm stg.tfplan
cd ../../..                                              # về infra/ cho các lệnh sau
```

Sau `apply`: xác nhận email của topic `svp-stg-alarms` (xem sau bước 10), rồi mở tunnel (mục
[Tunnel tới API](#tunnel-tới-api-sau-bước-9-trước-bước-11));
`AWS_PROFILE=anhnv-stg terraform -chdir=aws/envs/stg output -raw rds_master_user_secret_arn` cho script buổi.
Tiếp theo: ghi khoá ký của ô `a` vào entry
`svp/stg/media-signing` (`aws/scripts/media-signing-key.sh stg activate a` với cùng `SVP_SESSION_DIR`), giá trị các secret khác
(`aws/scripts/bootstrap.sh stg secrets`), rồi apply root `aws/gitops/stg` khi tunnel đang mở.

## Gỡ

Gỡ cuối buổi ở [`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31): gỡ trong cluster, root gitops, root env, đóng tính năng,
quét sót. Bỏ buổi giữa chừng: xem **Bẫy** của bước 9 và 15.

## Khi một bước đỏ

Đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được). Không đi tiếp qua một bước đỏ. Lỗi riêng của từng
bước ở nhãn **Bẫy** của nó; apply đỏ: bảng "Lỗi apply đã biết" ở bước 6–10; destroy kẹt:
[Destroy kẹt](session-stg.md#destroy-kẹt) của trang chủ; `Error acquiring the state lock` kèm Lock ID sau một lệnh `terraform` trần bị
ngắt (mục [Chạy tay một root](#chạy-tay-một-root-không-qua-script)): [Khoá state kẹt](../reference/operations.md#khoá-state-kẹt).
