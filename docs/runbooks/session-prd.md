# Runbook: một buổi AWS prd

Một buổi dựng env prd trong account `svp-prd` (`aws/envs/prd`, mức production: NAT mỗi AZ, RDS Multi-AZ, node on-demand trải ba AZ, bảo vệ
xoá, WAF, API chỉ qua endpoint private), cài Argo CD và root GitOps qua tunnel SSM (`aws/gitops/prd`), chạy đúng commit `svp-gitops` mà stg
đã chạy, đo (thời gian dựng, failover RDS Multi-AZ, mất một node ở một AZ), rồi gỡ sạch trong cùng buổi. Thiết kế:
[ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) (§4 truy cập API, §6 bootstrap EKS, §7 ghim revision,
§8 promote, §9 kết thúc buổi, §10 chi phí), [ADR-0049](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0049-kafka-prd.md) (Kafka
ba broker).

Buổi prd đi đúng chuỗi script của buổi stg; khác biệt là dữ liệu (dòng `prd` của `env_table` trong `aws/scripts/lib.sh`: profile `anhnv-prd`,
biến `SVP_AWS_PRD_ACCOUNT_ID`, tunnel cổng 6443, file `teardown.tfvars`, không thang k6) và các bước tay ở đây. Mọi mục chung (luật chạy lệnh,
thư mục buổi, mở lại terminal, ý nghĩa từng bước script, **Destroy kẹt**, **Lệnh xoá tay theo loại**, đổi secret) ở
[`session-stg.md`](session-stg.md): đọc trước, thay `stg` bằng `prd`, `anhnv-stg` bằng `anhnv-prd`. File này chỉ ghi phần riêng của prd.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster, kể cả lệnh chỉ đọc; AI đọc output dán lại và nhắc tới khi
bốn bước gỡ của mục **Kết thúc buổi** đều xong.

```sh
aws/scripts/session.sh --print prd                 # mọi lệnh script của buổi, theo thứ tự, không chạy gì
```

## Chi phí và giới hạn

- **Trần một buổi C ≈ $6,6** = 4 giờ × (H₀ $0,90 + H_k $0,004)/giờ + O₀ $2,8 + O_k $0,16 (phụ lục ADR-0049, mục "Chi phí"; H₀, O₀ ở phụ lục
  ADR-0048). **Phí giữ R ≈ $4,6/tháng** giữa các buổi (trail, KMS, zone, bucket state của management và hai baseline), báo riêng, không cộng
  vào C.
- **Cả buổi 4 giờ**, từ cổng promote tới hai lượt `sweep.sh` sạch. Quá 3 giờ mà chưa đo xong thì bỏ phần đo còn lại, sang gỡ. Quên gỡ 24
  giờ ≈ $22 (24 × H₀); budget `svp-prd-monthly` và budget tổng của org gửi email ở 50 %, 80 %, 100 %.
- Chứng chỉ Let's Encrypt production, giới hạn như stg (`session-stg.md`, mục "Giới hạn"); prd có bộ tên riêng.

## Điều kiện trước buổi

1. Root `aws/org` đã apply (account `svp-prd`, SCP, permission set `SvpAdmin` gán vào account đó); profile `anhnv-prd` đã tạo bằng
   `aws configure sso`; baseline `aws/accounts/prd` đã apply và zone `prd.aws.<domain>` đã được uỷ quyền
   ([`aws/accounts/README.md`](../../aws/accounts/README.md)).
2. Buổi stg ở account `svp-stg` đã chạy xong theo [`session-stg.md`](session-stg.md), và mọi PR của code, `svp-gitops`, repo này đã merge.
3. **Bằng chứng stg**: commit `svp-gitops` sẽ promote (`stg_ref`) có commit status `argocd/stg` trạng thái `success` (Argo CD Notifications
   của stg ghi khi sync xong commit đó). Job `promote-prd` từ chối commit không có nó. Kiểm:

   ```sh
   gh api "repos/anhnvcoder/svp-gitops/commits/<stg_ref>/statuses" --jq '.[] | select(.context == "argocd/stg") | "\(.state) \(.created_at)"' | head -n 1
   ```

4. Account prd: AWS đã xác minh cho CloudFront (case Support mở từ account prd, như `session-stg.md` điều kiện 1) và quota EC2 on-demand đủ
   cho node của `prd.tfvars` (3 `m7g.large` hay `m6g.large`, tối đa 6, cộng bastion `t4g.nano`): đọc quota vCPU on-demand chuẩn
   (`L-1216C47A`):

   ```sh
   AWS_PROFILE=anhnv-prd aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region ap-southeast-1 \
     --query 'Quota.Value'
   ```

   Cần ≥ 14 vCPU: 6 node × 2 vCPU + bastion 2 vCPU (`m7g.large`, `m6g.large` và `t4g.nano` đều 2 vCPU,
   [trang loại instance của AWS](https://aws.amazon.com/ec2/instance-types/)); thiếu thì xin tăng và chờ trước buổi.
5. Trên máy, ngoài các công cụ của stg: Session Manager plugin của AWS CLI (`session-manager-plugin --version`), `nc`, `gh` đã đăng nhập.
6. `aws/backend-prd.hcl` và `aws/envs/prd/prd.auto.tfvars` như điều kiện 4, 5 của stg (profile `anhnv-prd`, root `aws/accounts/prd`,
   `domain = "prd.aws.<domain>"`); prd không có `eks_public_access_cidrs` (endpoint công khai tắt):

   ```sh
   AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw backend_hcl > aws/backend-prd.hcl
   zone=$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw zone_id)
   cat > aws/envs/prd/prd.auto.tfvars <<EOF
   hosted_zone_id = "$zone"
   domain         = "prd.aws.<domain>"
   acme_email     = "<email>"
   EOF
   ```

## Mở terminal của buổi

Như `session-stg.md` với profile và biến của prd:

```sh
cd infra
AWS_PROFILE=anhnv-prd aws sso login --region us-east-1
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1                                             # cho lượt sweep.sh mgmt cuối buổi
export SVP_AWS_PRD_ACCOUNT_ID=<12 số của account svp-prd> SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"
```

## Thứ tự

Các bước script, theo đúng thứ tự `session.sh --print prd`; bước tay của prd chen giữa, ở các mục dưới (cổng promote trước bước 1, tunnel
sau bước 5, commit status và diễn tập sau bước 11, final snapshot sau bước 18):

| # | Lệnh | Hạn | Dán lại cho AI |
| --- | --- | --- | --- |
| 1 | `aws/scripts/check-account.sh prd` | 2 phút | dòng `ok account …` (account, ARN) |
| 2 | `aws/scripts/check-dns.sh prd` | 2 phút | ba dòng `ok` hay dòng `FAIL` |
| 3 | `aws/scripts/tf.sh prd env init` | 5 phút | dòng cuối |
| 4 | `aws/scripts/tf.sh prd env plan` | 5 phút | dòng `Plan: N to add, 0 to change, 0 to destroy` và đường dẫn file text của plan |
| 5 | `aws/scripts/tf.sh prd env apply` | 40 phút | dòng `Apply complete! …` và hai dòng `mark` |
| 6 | `aws/scripts/bootstrap.sh prd secrets` | 5 phút | mọi dòng `ok`/`FAIL` |
| 7 | `aws/scripts/tf.sh prd gitops init` | 2 phút | dòng cuối |
| 8 | `aws/scripts/tf.sh prd gitops plan` | 5 phút | dòng `ok chart svp-cluster at …`, dòng `Plan: …` |
| 9 | `aws/scripts/tf.sh prd gitops apply` | 15 phút | dòng `Apply complete! …`, output `bootstrap_revision` |
| 10 | `aws/scripts/bootstrap.sh prd wait` | 45 phút | mọi dòng `ok`/`FAIL` |
| 11 | `aws/scripts/measure.sh prd` | 10 phút | dòng `ok smoke passed …` |
| 12 | `aws/scripts/pre-destroy.sh prd` | 30 phút | mọi dòng `ok`/`FAIL`/`note` |
| 13 | `aws/scripts/tf.sh prd gitops plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` |
| 14 | `aws/scripts/tf.sh prd gitops destroy` | 10 phút | dòng `Apply complete! …` |
| 15 | `aws/scripts/tf.sh prd env plan --teardown` | 5 phút | dòng `note … targets …`, dòng `Plan: 0 to add, N to change, 0 to destroy` và đường dẫn file text (hay dòng `skip`) |
| 16 | `aws/scripts/tf.sh prd env apply --teardown` | 10 phút | dòng `Apply complete! …`, mốc `env-teardown-applied` (hay dòng `skip`) |
| 17 | `aws/scripts/tf.sh prd env plan --destroy` | 5 phút | dòng `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan |
| 18 | `aws/scripts/tf.sh prd env destroy` | 40 phút | dòng `Apply complete! Resources: 0 added, 0 changed, N destroyed.` |
| 19 | `aws/scripts/sweep.sh prd` | 5 phút | toàn bộ output |
| 20 | `aws/scripts/sweep.sh mgmt` | 5 phút | toàn bộ output |

## Cổng promote prd (trước mọi lệnh tốn tiền)

prd chỉ chạy commit `svp-gitops` stg đã chạy: khoá `gitopsRevision` của `envs/prd/charts.yaml` phải có giá trị trước bước 8 (plan của root
gitops dừng khi khoá vắng, `require_pinned_revision = true`). Làm cổng này **trước bước 1**, khi chưa tài nguyên nào tính tiền:

1. Dispatch job `promote-prd` của repo code với `stg_ref` là commit có bằng chứng stg (điều kiện 3):

   ```sh
   gh workflow run images.yml -R anhnvcoder/svp-backend --ref main -f promote_prd=true -f stg_ref=<stg_ref 40 hex>
   gh run list -R anhnvcoder/svp-backend --workflow images.yml --limit 1
   ```

2. Duyệt environment `promote-prd` của lượt chạy đó (trang của run trên GitHub, "Review deployments"). Job mở PR ở `svp-gitops` (nhánh
   `bot/promote-prd`) đặt `gitopsRevision = <stg_ref>` cùng image và chart của commit đó.
3. Code Owner duyệt PR đó, check của `svp-gitops` xanh, merge.
4. Kiểm hai khoá trên `main` (dán lại hai dòng in ra): `revision` là commit của repo code (chart), `gitopsRevision` là commit `svp-gitops`
   (`stg_ref`):

   ```sh
   git -C ../gitops fetch origin && git -C ../gitops show origin/main:envs/prd/charts.yaml | grep -E '^(revision|gitopsRevision):'
   ```

Job từ chối (`stg_ref` không có `argocd/stg` `success`, hay không trên `main`), environment hay PR bị từ chối: **dừng buổi**, không chạy bước 1.

## Bước 1–5: account, DNS, root env

Như `session-stg.md` bước 1–5, với `prd`. `check-account.sh prd` phải in account `svp-prd`. Plan của root env đọc `prd.tfvars` (mức prd); đọc
file text `prd-env-plan.txt`: chỉ `to add`, có WAF (`us-east-1`), bastion SSM, ba NAT gateway, RDS `multi_az = true`. Apply ~35–40 phút.

## Tunnel tới API (sau bước 5, trước bước 6)

Endpoint công khai của API prd tắt; máy tới endpoint private qua SSM port forwarding tới bastion (`127.0.0.1:6443`). Mở ở **một terminal
riêng** từ gốc repo, giữ chạy tới hết bước 14 (Ctrl-C để đóng):

```sh
cd infra
eval "$(AWS_PROFILE=anhnv-prd terraform -chdir=aws/envs/prd output -raw api_tunnel_command)"
```

Lệnh của output có sẵn profile `anhnv-prd` và `--region`. Mọi script cần API (`tf.sh prd gitops plan|apply|plan --destroy|destroy`,
`bootstrap.sh prd wait`, `measure.sh prd`, `pre-destroy.sh prd`) kiểm `127.0.0.1:6443` trước lệnh đầu tới API và dừng với `FAIL no tunnel …`
khi tunnel chưa mở hay đã rớt (phiên SSM hết hạn): mở lại tunnel rồi chạy lại đúng bước đó. Context `svp-prd` do `bootstrap.sh prd secrets`
(và `pre-destroy.sh prd`) ghi: server `https://127.0.0.1:6443`, TLS server name là host của endpoint private.

## Bước 6–10: secret, root gitops, chờ

Như `session-stg.md` bước 6–10, với `prd`. Hai commit phải khớp hai khoá đã kiểm ở bước 4 của cổng promote: `<sha>` của dòng `ok chart
svp-cluster at <sha>` (bước 8) là `revision` (commit repo code của chart), output `bootstrap_revision` (bước 9) là `gitopsRevision` (commit
`svp-gitops`). Chat Telegram lấy từ `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (giá trị trần hay trong một cặp nháy kép hoặc nháy đơn,
như `make eks-secrets` đọc). Lệnh `kubectl` tay vào prd ghi profile và context:

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io
```

## Bước 11: smoke, commit status

`measure.sh prd` chỉ chạy smoke (`make eks-smoke CONTEXT=svp-prd DOMAIN=<domain>`), không seed, không thang k6 (số đo của prd là các diễn tập
dưới). Sau đó kiểm commit status `argocd/prd` (Argo CD Notifications của prd) có trên commit `svp-root` đã sync (`main` của `svp-gitops`):

```sh
AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.sync.revision}{"\n"}'
gh api "repos/anhnvcoder/svp-gitops/commits/<sha trên>/statuses" --jq '.[] | select(.context == "argocd/prd") | "\(.state) \(.created_at)"' | head -n 1
```

Mong `success`; dán lại cả hai dòng.

## Đo

Mỗi phép đo ghi kết quả (đạt hay không, output chính, thời điểm UTC) vào một file trong `$SVP_SESSION_DIR`, để sau buổi điền cột Kết quả của
mục "Xác nhận" của ADR-0048 và ADR-0049.

1. **Thời gian dựng**: từ `env-apply-start` tới `svp-root-healthy` của `timeline.tsv` (phút):

   ```sh
   awk -F '\t' '$3 == "env-apply-start" { s = $2 } $3 == "svp-root-healthy" { e = $2 } END { printf "%.0f min\n", (e - s) / 60 }' "$SVP_SESSION_DIR/timeline.tsv"
   ```

2. **Failover RDS Multi-AZ** bằng reboot with failover. Đọc AZ chính và AZ dự phòng, reboot, chờ `available`, đọc lại (hai AZ phải đổi chỗ),
   đọc sự kiện để lấy thời gian failover, rồi smoke lại để chứng minh service nối lại được:

   ```sh
   AWS_PROFILE=anhnv-prd aws rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
   AWS_PROFILE=anhnv-prd aws rds reboot-db-instance --db-instance-identifier svp-prd --force-failover --region ap-southeast-1 \
     --query 'DBInstance.DBInstanceStatus' --output text
   AWS_PROFILE=anhnv-prd aws rds wait db-instance-available --db-instance-identifier svp-prd --region ap-southeast-1
   AWS_PROFILE=anhnv-prd aws rds describe-db-instances --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone,DBInstanceStatus]' --output text
   AWS_PROFILE=anhnv-prd aws rds describe-events --source-type db-instance --source-identifier svp-prd --duration 60 --region ap-southeast-1 \
     --query 'Events[].[Date,Message]' --output text
   AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
   ```

   Dán lại: hai dòng AZ, các sự kiện `failover` (bắt đầu, xong), dòng cuối của smoke.
3. **Mất một node ở một AZ, Kafka vẫn ghi được**: chọn node đang chạy một broker Redpanda, xoá instance EC2 của nó (node group dựng node
   mới cùng AZ), trong lúc broker đó mất chạy smoke (upload ghi event vào Kafka với `acks=all`, đa số 2/3 broker), rồi chờ node mới và broker
   trở lại:

   ```sh
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes -L topology.kubernetes.io/zone
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data get pods -l app.kubernetes.io/name=redpanda -o wide
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get node <node của một broker> -o jsonpath='{.spec.providerID}{"\n"}'   # aws:///<az>/<i-…>
   AWS_PROFILE=anhnv-prd aws ec2 terminate-instances --instance-ids <i-…> --region ap-southeast-1 --query 'TerminatingInstances[0].CurrentState.Name' --output text
   AWS_PROFILE=anhnv-prd make -C ../backend eks-smoke CONTEXT=svp-prd DOMAIN=<domain>
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd get nodes -L topology.kubernetes.io/zone -w                            # chờ node mới Ready, Ctrl-C
   AWS_PROFILE=anhnv-prd kubectl --context svp-prd -n svp-data get pods -l app.kubernetes.io/name=redpanda -o wide -w      # chờ ba broker Ready, Ctrl-C
   ```

   Dán lại: AZ của node đã xoá, dòng cuối của smoke (phải đạt khi chỉ còn hai broker), thời gian tới khi node mới Ready và broker thứ ba
   Ready. Broker của AZ mất ở `Pending` cho tới khi có node mới ở đúng AZ đó (topology spread `minDomains: 3`, ADR-0049 §4) là đúng thiết kế.

(Tuỳ chọn) **Đổi một secret của env đang chạy**: như mục cùng tên của `session-stg.md`, với `aws/scripts/bootstrap.sh prd secrets`,
`AWS_PROFILE=anhnv-prd`, `--context svp-prd`, tunnel mở.

## Kết thúc buổi

Theo thứ tự, mỗi bước xong mới sang bước sau:

1. **Destroy root gitops rồi root env** (bước 12–18, tunnel còn mở tới hết bước 14). Bảo vệ của prd được nhấc trước: bước 15 đọc
   `terraform state list` của `aws/envs/prd` rồi plan với `prd.tfvars` và `teardown.tfvars`, chỉ nhắm (`-target`) DB instance và bucket có
   trong state (đọc `prd-env-teardown-plan.txt`: chỉ `to change`, deletion protection của RDS về `false`, `force_destroy` của bucket; cảnh báo
   "Resource targeting is in effect" của Terraform là đúng ý), bước 16 apply nó; `tf.sh prd env plan --destroy` dừng với `FAIL the protections
   of aws/envs/prd are still on` khi chưa có mốc `env-teardown-applied`, rồi plan `-destroy` với cả hai file, không `-target`. Destroy vẫn ghi
   final snapshot của RDS (`skip_final_snapshot` giữ `false`) và giữ backup tự động.

   Apply của bước 5 đỏ giữa chừng (vd thiếu quota): vẫn làm bước 15, 16 trước `plan --destroy` (với `--no-cluster` khi chưa có cluster EKS,
   điều kiện ở `session-stg.md`, mục 15–18). Plan chỉ nhắm những gì đã được tạo nên không tạo thêm phần còn thiếu và không gặp lại lỗi
   cũ; state không có DB instance hay bucket nào thì bước 15 in `skip`, ghi mốc `env-teardown-applied` (không có gì để nhấc) và bước 16 in
   `skip`.
2. **Final snapshot và backup tự động**: đọc final snapshot có thật (dán tên và thời điểm: bằng chứng bảo vệ chạy), rồi xoá nó; đọc backup
   tự động được giữ, rồi xoá từng cái:

   ```sh
   AWS_PROFILE=anhnv-prd aws rds describe-db-snapshots --db-instance-identifier svp-prd --snapshot-type manual --region ap-southeast-1 \
     --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' --output text
   AWS_PROFILE=anhnv-prd aws rds delete-db-snapshot --db-snapshot-identifier <svp-prd-final-…> --region ap-southeast-1 --query 'DBSnapshot.Status' --output text
   AWS_PROFILE=anhnv-prd aws rds describe-db-instance-automated-backups --db-instance-identifier svp-prd --region ap-southeast-1 \
     --query 'DBInstanceAutomatedBackups[].[DBInstanceAutomatedBackupsArn,Status]' --output text
   AWS_PROFILE=anhnv-prd aws rds delete-db-instance-automated-backup --db-instance-automated-backups-arn <arn> --region ap-southeast-1 \
     --query 'DBInstanceAutomatedBackup.Status' --output text
   ```

3. **`aws/scripts/sweep.sh prd`** (profile `anhnv-prd`): chỉ còn dòng `kept` (`Stack=baseline`: bucket state, KMS key state, zone
   `prd.aws.<domain>`) và `pending deletion` (KMS key của root env, 7 ngày), exit 0. Còn gì khác: chạy lệnh `delete:` nó in, rồi chạy lại.
4. **`aws/scripts/sweep.sh mgmt`** (profile `anhnv-sso`): chỉ `Stack=bootstrap|org`, exit 0.

Một lượt `sweep.sh prd` chạy trước bước 2 được phép exit khác 0 (final snapshot, backup tự động còn đó) và chỉ để xem. **Buổi chỉ xong khi
lượt `sweep.sh prd` sau bước 2 và lượt `sweep.sh mgmt` cùng exit 0.** AI nhắc tới khi người học xác nhận đủ bốn bước. Sau 24 giờ: Cost
Explorer của account prd theo dịch vụ, so với C.

### Web ACL WAF sót

Web ACL scope `CLOUDFRONT` nằm ở `us-east-1`; xoá cần lock token hiện tại (sau khi distribution không còn dùng nó):

```sh
AWS_PROFILE=anhnv-prd aws wafv2 get-web-acl --scope CLOUDFRONT --name <svp-prd-…> --id <id> --region us-east-1 --query LockToken --output text
AWS_PROFILE=anhnv-prd aws wafv2 delete-web-acl --scope CLOUDFRONT --name <svp-prd-…> --id <id> --lock-token <token> --region us-east-1
```

Loại sót khác: `session-stg.md`, mục **Lệnh xoá tay theo loại**, với `AWS_PROFILE=anhnv-prd`.
