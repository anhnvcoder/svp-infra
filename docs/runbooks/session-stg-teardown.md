# Runbook: gỡ buổi stg và quét sót (bước 20–31)

← [Diễn tập khôi phục](session-stg-drills.md) · [Mục lục](README.md) · [session-prd](session-prd.md) →

> **Tóm tắt**
>
> - **Làm gì:** gỡ theo thứ tự ngược với dựng: tài nguyên Kubernetes tạo trong account (bước 20), root `aws/gitops/stg` (21–22), backup của
>   buổi và root `aws/envs/stg` (23–27), tính năng của buổi ở `aws/accounts/stg` (28–29), rồi quét sót ở stg và management (30–31).
> - **Khi nào và bao lâu:** cuối mỗi buổi, hoặc bất cứ lúc nào muốn bỏ buổi giữa chừng. Buổi chỉ xong khi hai lượt `sweep.sh` cùng
>   exit 0, trước mốc 4 giờ. Destroy root env ~50 phút (MSK, ElastiCache), bước 20 tới 30 phút.
> - **Phí trong lúc chạy:** tài nguyên của buổi tính theo giờ tới khi gỡ xong; quên destroy 24 giờ tốn gấp ~6 lần một buổi
>   ([Giới hạn](session-stg.md#giới-hạn)).

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account hay cluster EKS, kể cả lệnh chỉ đọc; AI đọc output người
học dán lại và nhắc tới khi destroy hai root và hai lượt `sweep.sh` (stg, mgmt) đều đã chạy.

## Điều kiện trước

- [ ] **Tunnel tới API còn mở** (bước 20–22; [`session-stg-deploy.md`](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11)).
- [ ] **Đã đọc finding bảo mật** trước bước 20
  ([`session-stg-drills.md`](session-stg-drills.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20)): tài nguyên bị xoá thì
  finding control của nó mất.
- [ ] **Bước 17–19** đã chạy hay đã bỏ có chủ đích; bước 25 chạy ở mọi đường.

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ, với `SVP_SESSION_DIR` là thư mục
của buổi đang dở: `tf.sh` đọc các mốc gỡ (`pre-destroy-done`, `gitops-destroy-end`) trong `timeline.tsv` của nó.

## 20. Gỡ trong cluster trước destroy

Loại: `lõi`.

```sh
aws/scripts/pre-destroy.sh stg
```

Tunnel còn mở. Script gỡ những gì Kubernetes tạo trong account mà Terraform không biết, **khi controller tạo ra chúng còn chạy**,
mỗi lần chờ có hạn: target của Envoy trong target group edge (`TargetGroupBinding`), volume EBS của PVC, node của Karpenter. Chỉ
cần apply đã tạo cluster: script tự chạy `aws eks update-kubeconfig --name svp-stg --alias svp-stg`, không đọc file nào của bước
11, nên chạy được cả khi bước 11 chưa chạy hay từ thư mục buổi mới. Thứ tự:

1. ApplicationSet `svp-bootstrap` (nó dựng lại `svp-root`), `svp-root` và `svp-apps` (auto-sync prune + self-heal, không finalizer): xoá
   finalizer và `automated` của hai Application, rồi xoá riêng ba cái (child ở yên); tắt auto-sync của mọi Application còn lại (để
   `svp-cluster` không dựng lại Gateway).
2. Trước hết luật và Alertmanager của AMP: xoá mọi `RuleGroupsNamespace`, `AlertManagerDefinition` của ACK khi controller ACK còn chạy (nó
   xoá chúng ở AMP, chờ tối đa 5 phút); không pod ACK nào Ready hay quá hạn thì gỡ finalizer của chúng và in dòng `note left in AMP: …` kèm
   lệnh xoá ở AMP (người học chạy sau bước 31; `sweep.sh stg` cũng liệt kê rule groups namespace còn lại). Mốc `pre-destroy-amp-rules`. Rồi
   Application workload theo sync wave từ cao xuống (finalizer của mỗi cái xoá thứ nó triển khai), trừ `svp-cluster` và controller nền
   tảng (cả `karpenter`); rồi, khi `media-worker` đã gỡ (không job mới), huỷ mọi job `SUBMITTED`, `PROGRESSING` của queue MediaConvert
   `svp-stg` và chờ tới khi không còn job nào dở (job dở chặn xoá queue và ghi vào bucket `media` mà destroy làm rỗng), in số job đã huỷ
   (`ok no MediaConvert queue …` khi account không có queue đó); rồi Gateway `svp-edge/svp`, rồi xoá tường minh TargetGroupBinding
   `envoy-gateway-system/svp-envoy` (chart `svp-cluster` render nó, không mất theo Gateway): LBC gỡ target của Envoy khỏi target group edge
   rồi mới thả nó, chờ có hạn. Chờ hết Service `LoadBalancer`, TargetGroupBinding, load balancer và target group mang tag
   `elbv2.k8s.aws/cluster=svp-stg` trong ELBv2 (của controller; ALB và target group edge của Terraform không mang tag này), trong khi LBC,
   Envoy Gateway còn chạy. Bản ghi DNS của buổi thuộc root env, gỡ cùng destroy của nó.
3. Mọi PVC ở mọi namespace (sinh từ `volumeClaimTemplates`, Argo CD không prune) khi EBS CSI còn chạy và namespace, StorageClass `gp3` của
   `svp-cluster` còn đó; chờ hết PVC, PV của `ebs.csi.aws.com`, volume EBS do driver tạo.
4. Mọi NodePool rồi mọi EC2NodeClass, khi Karpenter còn chạy (`svp-cluster`, chart render chúng, không sync lại từ bước 1); chờ tới khi hết
   NodeClaim và hết instance EC2 mang tag `karpenter.sh/nodepool` của cluster, giới hạn 15 phút (ADR-0056 §9: `terminationGracePeriod`
   10 phút của NodePool là trần drain một node, quá trần Karpenter tắt instance dù PDB còn chặn, cộng thời gian tắt instance). Mốc
   `pre-destroy-nodes`.
5. `svp-cluster` và Application nền tảng, theo wave; quá hạn chỉ ghi `note` (không gì của chúng tính tiền ngoài cluster).

Cluster chưa có Argo CD (root gitops chưa apply hay dừng trước Argo CD, dòng `note no Argo CD on svp-stg`): không có Application
nào để xoá, bước 1, 5 và phần Application của bước 2 bỏ qua; phần huỷ job MediaConvert của bước 2 vẫn chạy. Cluster chưa có CRD
của Karpenter (dòng `note no Karpenter on svp-stg`): bước 4 không xoá gì. Các phép chờ của bước 2–4 (Service `LoadBalancer`,
ELBv2, PVC, volume EBS, instance của Karpenter) vẫn chạy, rồi ghi mốc `pre-destroy-done` như thường.

- **Mong đợi:** mỗi bước `ok`, cuối cùng `ok ready for: aws/scripts/tf.sh stg gitops plan --destroy` và mốc `pre-destroy-done`
  (thiếu mốc này thì `tf.sh stg gitops plan --destroy` từ chối). Script ghi mốc `pre-destroy-start` ngay sau khi kiểm account,
  trước mọi bước khác.
- **Bẫy:** `FAIL kubeconfig context …` là account không có cluster `svp-stg`: sang bước 25, rồi 26 với `--no-cluster`. `FAIL` khác
  nêu thứ còn lại và lệnh xem; sửa rồi chạy lại script (mỗi bước tìm thứ còn lại). Bước 4 đỏ vì NodeClaim còn: đọc log của
  Karpenter (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --tail=50`); đỏ vì instance còn
  mà hết NodeClaim: `sweep.sh stg` in lệnh tắt nó. Bước 2 đỏ ở `svp-envoy`: dòng `FAIL` nêu lệnh xem finalizer, status của nó và
  log của LBC. Bước 2 đỏ ở job MediaConvert: dòng `FAIL` nêu lời gọi lỗi (quyền, throttle) hay job còn dở sau hạn chờ; sửa rồi
  chạy lại script, hay huỷ tay theo mục [Lệnh xoá tay theo loại](session-stg.md#lệnh-xoá-tay-theo-loại). **Hết giờ của buổi mà
  bước 2, 3 hay 4 vẫn đỏ sau khi đã chạy lại** (dòng `note` cuối sau `FAIL` nhắc lối này): sang bước 21 với `--leftovers`.

## 21–22. Gỡ root gitops

Loại: `lõi`.

```sh
aws/scripts/tf.sh stg gitops plan --destroy
aws/scripts/tf.sh stg gitops destroy
```

Root gitops gỡ **trước** root env (provider của nó cần cluster), qua tunnel: đóng tunnel được sau bước 22. `plan --destroy` ghi
`aws/gitops/stg/stg.destroy.tfplan` và bản text vào `$SVP_SESSION_DIR/stg-gitops-destroy-plan.txt`; từ chối khi thư mục buổi chưa có mốc
`pre-destroy-done`. `destroy` chỉ áp file đó (`terraform apply` file đó: không plan lại tại chỗ, không hỏi lại), ghi mốc
`gitops-destroy-end`.

- **Kiểm:** **đọc file text** trước `destroy`: chỉ tài nguyên của `aws/gitops/stg`, `0 to add, 0 to change`.
- **Mong đợi:** `Plan: 0 to add, 0 to change, N to destroy` rồi `Apply complete! Resources: 0 added, 0 changed, N destroyed.`
- **Bẫy:** root gitops chưa init trong bản checkout này (bỏ buổi trước bước 12): `aws/scripts/tf.sh stg gitops init` trước; state
  trống thì plan là `No changes` và destroy chỉ ghi mốc.
- **Bẫy:** hết giờ của buổi mà bước 20 vẫn đỏ ở bước 2, 3 hay 4 của nó sau khi đã chạy lại: lối thoát có kiểm, để cluster không tính tiền
  tiếp:

  ```sh
  aws/scripts/tf.sh stg gitops plan --destroy --leftovers
  ```

  Chỉ nhận khi `timeline.tsv` của buổi có mốc `pre-destroy-start` (bước 20 đã chạy trong thư mục buổi này) mà chưa có `pre-destroy-done`;
  thiếu `pre-destroy-start` thì từ chối và bảo chạy bước 20 trước, đã có `pre-destroy-done` thì từ chối (không cần cờ này). Dòng `note
  --leftovers: …` nhắc thứ Kubernetes tạo có thể còn (volume EBS của PVC, instance EC2 của Karpenter, load balancer của Load Balancer
  Controller), rồi ghi mốc `pre-destroy-skipped`. Tiếp: bước 22, rồi các bước sau (destroy có thể kẹt vì những thứ đó: mục
  [Destroy kẹt](session-stg.md#destroy-kẹt)); thứ `sweep.sh` liệt kê xoá bằng lệnh nó in, rồi chạy lại `sweep.sh` tới khi sạch.

## 23–27. Gỡ root env

Loại: `lõi`.

```sh
aws/scripts/tf.sh stg env plan --teardown
aws/scripts/tf.sh stg env apply --teardown
aws/scripts/restore-drill.sh stg cleanup
aws/scripts/tf.sh stg env plan --destroy
aws/scripts/tf.sh stg env destroy
```

Bước 23, 24 in `skip`: stg không có file nhấc bảo vệ (prd có, [`session-prd.md`](session-prd.md)). Bước 25 xoá backup của buổi (mục
[Bước 25](#bước-25-xoá-backup-của-buổi)). `plan --destroy` từ chối khi thư mục buổi chưa có mốc `gitops-destroy-end`, hay khi trong
`timeline.tsv` mốc cuối trong bốn mốc `backup-undrained`, `env-apply-end`, `env-teardown-applied`, `backup-drained` không phải
`backup-drained`; `destroy` cũng kiểm lại điều đó. Như bước 8 cho apply, `plan --destroy` ghi `aws/envs/stg/stg.destroy.tfplan` và bản text
`stg-env-destroy-plan.txt`; `destroy` chỉ áp file đó, rồi xoá file.

- **Mong đợi:** bước 23, 24: dòng `skip`. Bước 26: `Plan: 0 to add, 0 to change, N to destroy` và đường dẫn file text của plan.
  Bước 27: `Apply complete! Resources: 0 added, 0 changed, N destroyed.` và hai dòng `Destruction complete after …` của cluster
  MSK, replication group ElastiCache.
- **Kiểm:** **đọc file text đó trước bước 27**: chỉ tài nguyên của `aws/envs/stg`, `0 to add, 0 to change`; không có bucket
  `svp-tfstate`, không có `aws_route53_zone` (của baseline `aws/accounts/stg`, root khác). Thấy thứ khác: dừng, dán plan cho AI.
  Destroy gỡ edge theo tham chiếu trong code: bản ghi DNS và delivery log, rồi ba distribution (provider tắt từng cái, chờ
  `Deployed`, rồi xoá: mỗi cái vài phút tới ~15 phút, phần dài nhất của edge), rồi VPC origin (AWS từ chối xoá khi distribution
  còn dùng nó), rồi listener, ALB, target group, security group, cert ACM.
- **Bẫy:** `FAIL the backups of stg are not drained …` (mốc cuối không phải `backup-drained`): chạy bước 25, rồi bước 26 lại.
- **Bẫy:** kẹt: mục [Destroy kẹt](session-stg.md#destroy-kẹt), rồi `plan --destroy` lại (file plan cũ không áp lại được sau một apply dở) và
  `destroy`. Sau VPC origin, CloudFront tự gỡ ENI của nó trong subnet edge và security group `CloudFront-VPCOrigins-Service-SG` (ngoài
  state); chưa gỡ xong thì subnet edge hay VPC báo `DependencyViolation`: cũng mục Destroy kẹt.
- **Bẫy:** apply đỏ trước khi tạo cluster EKS (chưa gì chạy trên cluster, root gitops chưa bao giờ apply): đọc mục [Finding bảo
  mật của buổi](session-stg-drills.md#finding-bảo-mật-của-buổi-sau-bước-19-trước-bước-20) (VPC, NACL, RDS… đã tạo vẫn có control),
  bỏ bước 17–22, chạy bước 25 (apply đã gắn tag `Backup` và ghi `backup-undrained`), rồi `aws/scripts/tf.sh stg env plan --destroy
  --no-cluster`. Script tự kiểm điều đó trước khi plan: thư mục buổi không có `cluster-values.json` **và** `terraform state list`
  của `aws/envs/stg` (script tự chạy, profile `anhnv-stg`) không có `aws_eks_cluster`; không thì từ chối (`FAIL --no-cluster
  refused: …`). State còn cluster: chạy bước 20 trong thư mục buổi hiện tại (không cần bước 11), bước 21, 22, 25, rồi `plan
  --destroy` không `--no-cluster`.

### Bước 25: xoá backup của buổi

Loại: `lõi`. `restore-drill.sh stg cleanup` (**Xoá cuối buổi** của ADR-0067 §11) chạy sau lần ghi Terraform cuối vào root env (mọi
apply gắn lại tag `Backup`) và ngay trước `plan --destroy`, theo thứ tự: xoá `svp-stg-pitr` nếu còn; gỡ tag `Backup` khỏi instance
`svp-stg` và hai bucket (lịch không chọn chúng nữa); chờ mọi job backup, copy, restore của account kết thúc (có hạn); với mỗi
recovery point của vault `svp-stg`: có copy job `COMPLETED` tới `svp-stg-copy` thì xoá, không có thì giữ và in hai lệnh; cả bốn
xong thì ghi mốc `backup-drained`. Vault `svp-stg` ở lại (`aws/accounts/stg`), bản copy ở lại tới hết retention. Key RDS, key
`uploads` chỉ vào `PendingDeletion` ở destroy sau bước này, khi bản copy đã mã hoá bằng key của `svp-backup`. Không cờ nào bỏ qua
bước này.

- **Mong đợi:** `ok no svp-stg-pitr left`, `ok tag Backup removed …` (hay `skip` khi tài nguyên không còn), `ok no backup, copy or
  restore job running`, mỗi recovery point một dòng `ok recovery point … deleted: its copy is in svp-stg-copy`, mốc
  `backup-drained`, rồi `ok backups of stg drained: next, …`.
- **Bẫy:** **job kẹt** (`FAIL jobs still running after … s, nothing deleted`, kèm danh sách `kind id state resource`): không gì bị
  xoá. Backup job dừng được (lệnh dưới); copy job và restore job không dừng được, chỉ chờ (đọc lại trạng thái). Rồi chạy lại
  bước 25.
- **Bẫy:** **recovery point chưa có bản copy** (`FAIL recovery point … has no completed copy in svp-stg-copy, kept`, rồi `… kept,
  backup-drained not recorded`): copy job của nó lỗi hay chưa từng chạy (job theo lịch khi env sống qua 18:00 UTC mà copy lỗi).
  Chọn một trong hai lệnh script in dưới mỗi recovery point: copy lại (`start-copy-job`, đúng retention của plan; chạy lại bước 25
  khi copy job `COMPLETED`) hay chấp nhận mất bản đó (`delete-recovery-point`, ghi lại vào ghi chú của buổi); rồi chạy lại
  bước 25.
- **Bẫy:** bỏ cả buổi khi apply đỏ: bước 25 vẫn chạy trước `plan --destroy` (kể cả `--no-cluster`), vì `env apply` ghi
  `backup-undrained` trước khi tạo gì; khi chưa có instance hay bucket, nó in `skip` cho phần đó.

  ```sh
  aws/scripts/check-account.sh stg
  AWS_PROFILE=anhnv-stg aws backup describe-backup-job --backup-job-id <id> --region ap-southeast-1 --query '[State,PercentDone]' --output text
  AWS_PROFILE=anhnv-stg aws backup stop-backup-job --backup-job-id <id> --region ap-southeast-1
  AWS_PROFILE=anhnv-stg aws backup describe-copy-job --copy-job-id <id> --region ap-southeast-1 --query 'CopyJob.State' --output text
  AWS_PROFILE=anhnv-stg aws backup describe-restore-job --restore-job-id <id> --region ap-southeast-1 --query Status --output text
  ```

### Destroy tay một root (không qua script)

Khi cần `terraform destroy` trần ở root env (đọc plan từng bước, kiểm một lỗi): sau `pre-destroy.sh stg`, destroy
`aws/gitops/stg`, `aws/scripts/restore-drill.sh stg cleanup`, rồi root này, rồi lệnh quét tài nguyên sót. Script `tf.sh` vẫn là
đường chính: nó chặn destroy khi thiếu mốc `gitops-destroy-end` hay `backup-drained`, còn lệnh trần thì không.

```sh
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_log_archive_account_id="$SVP_AWS_LOG_ACCOUNT_ID" \
  TF_VAR_backup_account_id="$SVP_AWS_BACKUP_ACCOUNT_ID" terraform destroy -var-file=stg.tfvars
```

Instance, launch template và instance profile do Karpenter tạo nằm ngoài state: `pre-destroy.sh` gỡ chúng khi controller còn chạy,
`sweep.sh stg` tìm phần sót. `destroy` gỡ cả plan Malware Protection (GuardDuty gỡ theo rule EventBridge
`DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3*` nó quản), endpoint `guardduty-data` và cấu hình log của web ACL; `sweep.sh
stg` liệt kê plan và endpoint còn sót của một `destroy` dở. Distribution CloudFront tắt mất nhiều phút trước khi xoá được; ENI và
security group `CloudFront-VPCOrigins-Service-SG` do CloudFront tạo cho VPC origin nằm ngoài state và giữ subnet edge, VPC tới khi
chúng mất (mục "Thứ tự gỡ" của [README module `edge`](../../aws/modules/edge/README.md)).

## 28–29. Root account: đóng tính năng của buổi

Loại: `lõi`. Như bước 3–5: với `managed_grafana` `off` hai lệnh in `ok no session feature of stg …`.

```sh
aws/scripts/tf.sh stg account plan --close
aws/scripts/tf.sh stg account apply
```

`plan --close` plan với `-var session_open=false`, ghi `aws/accounts/stg/stg.account-close.tfplan` (xoá plan mở cũ nếu còn) và bản
text `stg-account-close-plan.txt`. Nó từ chối khi root env chưa destroy xong trong buổi này: mốc cuối trong `env-apply-start`,
`env-destroy-start`, `env-destroy-end` không phải `env-destroy-end` (`FAIL root env of stg is not destroyed in this session …`),
vì cluster còn đọc workspace. Buổi chưa apply root env (bỏ buổi trước bước 9) thì nhận ngay. Mọi đường gỡ, cả khi bỏ buổi giữa
chừng (`--no-cluster` của mục [23–27](#2327-gỡ-root-env)), đi qua hai bước này sau destroy root env và trước quét sót: workspace
bỏ quên tính tiền mỗi tháng nó còn ([ADR-0071
§3](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0071-paid-features.md#3-managed_grafana)), và `sweep.sh stg` in
nó cùng tham số SSM là sót.

- **Kiểm:** **đọc file text đó trước khi apply**: `Plan: 0 to add, 0 to change, 7 to destroy`, đúng bảy tài nguyên của bước 3–5;
  có `destroy` khác dưới `aws/accounts/stg` thì dừng, dán plan cho AI.
- **Mong đợi:** `apply` ghi mốc `account-close-applied`. Data source, dashboard trong workspace mất cùng nó; Grafana Operator dựng
  lại chúng ở buổi sau.

## 30–31. Quét sót

Loại: `lõi`.

```sh
aws/scripts/sweep.sh stg
aws/scripts/sweep.sh mgmt
```

Chỉ đọc, chạy được cả khi state mất hay destroy dở; mỗi lượt với profile của account đó. Liệt kê mọi tài nguyên tag `Project=svp`
hay tag Kubernetes đặt (`kubernetes.io/cluster/svp-*`, `elbv2.k8s.aws/cluster`, `ebs.csi.aws.com/cluster`,
`cluster.k8s.amazonaws.com/name`, `karpenter.sh/nodepool`, `karpenter.k8s.aws/cluster`) hay mang tên `svp-*`: EKS, EC2 (cả
instance của Karpenter), launch template (Karpenter tạo một cái cho mỗi EC2NodeClass), instance profile của Karpenter (ngoài
state, path `/karpenter/<region>/svp-…`; còn thì IAM không xoá được role node), hàng đợi SQS và rule EventBridge `Karpenter*` của
nó, CloudWatch alarm `svp-*` (cả alarm target tracking mà autoscaling storage của MSK tạo), EBS và snapshot, VPC, NAT, EIP, ENI,
security group, ELBv2 và target group, RDS (instance, snapshot, backup tự động giữ lại), MSK (cluster, rồi configuration),
ElastiCache (replication group, rồi user group, user, subnet group, parameter group; user `default` và nhóm `default.*` của AWS
không tính), S3, gói CloudFront flat-rate (loại `CloudFront pricing plan subscriptions`, `us-east-1`, đọc trước distribution),
CloudFront (distribution, OAC, response headers policy; key group `svp-<env>-media` rồi public key `svp-<env>-media-*` mà
distribution media tin cho URL ký `premium/*`), web ACL WAF của CloudFront (`us-east-1`), log group (cả log group EKS, RDS tự tạo
ngoài state và log broker `/aws/msk/svp-*`), Secrets Manager (cả secret đang chờ xoá và secret SCRAM `AmazonMSK_svp-*`), KMS key,
bản ghi của zone của account ngoài `NS`, `SOA`, `CAA` ở đỉnh và ngoài mọi `NS` dưới đỉnh (uỷ quyền zone con của baseline). Mỗi
loại in theo thứ tự AWS cho xoá (cluster trước configuration, replication group trước user group, user group trước user).

Nền tảng managed thêm các loại: endpoint interface `svp-<env>-<dịch vụ>` và security group `svp-<env>-endpoints` (của
root env, sót là lỗi); rule groups namespace của AMP (ACK tạo mỗi buổi, `pre-destroy.sh` xoá; sót là ruler còn đánh giá
và tính tiền); workspace AMP, workspace Grafana, repo ECR, rule pull-through cache cùng repo do cache tạo (không tag),
IAM OIDC provider và role `svp-ci-*` của root `aws/accounts/<env>`: in là `kept` khi account giữ `Stack=baseline`.
Workspace Grafana `svp-<env>` và tham số SSM `/svp/<env>/grafana-workspace-id` theo cờ `managed_grafana` của env
(`sweep.sh` đọc `aws/paid-features.json`): `always` thì `kept`, `session` thì sót (bước 28–29 chưa chạy hay đỏ: chạy lại
hai bước đó thay cho lệnh `delete:`, để state của root khớp account), `off` thì sót (cờ đổi về `off` mà
`aws/accounts/<env>` chưa áp: áp theo [`paid-features.md`](paid-features.md#awsaccountsenv)).

Transcode thêm các loại: queue MediaConvert `svp-<env>` (queue `Default` của account không tính); hàng đợi SQS
`svp-<env>-transcode-events` và `-dlq` (loại SQS có sẵn); rule EventBridge `svp-<env>-mediaconvert-job-state`: loại `EventBridge
rule targets` (chỉ rule còn đích) in trước loại `EventBridge rules`, rule `svp-*` mang tag `Stack` được giữ (rule `svp-security-*`
của `aws/baseline`) là `kept`; role `svp-<env>-mediaconvert` (`us-east-1`): loại `IAM inline policies of MediaConvert roles` in
trước `IAM roles of MediaConvert`; alarm `svp-<env>-transcode-events-dlq` và endpoint interface `svp-<env>-mediaconvert` (loại
alarm, endpoint có sẵn). Sót là lỗi: mọi thứ đó ở root env.

Backup thêm các loại (ADR-0067, **Quét backup**): job backup, copy, restore chưa kết thúc (`AWS Backup … jobs not ended`; backup
job dừng được, copy và restore job thì chờ rồi quét lại); recovery point trong mọi vault `svp-*` (luôn là sót: bước 25 xoá
recovery point của buổi; snapshot RDS `awsbackup:*` là recovery point, loại `RDS snapshots` không đếm nó lần nữa); vault lock rồi
vault `svp-*` không mang `Stack` được giữ (vault `svp-<env>` của `aws/accounts/<env>` mang `Stack=baseline`, là `kept`); plan cục
bộ `svp-probe*` (plan `svp-stg`, `svp-prd` của Backup policy không tính: account không xoá được chúng); role `svp-*-backup`
(`us-east-1`; role `svp-<env>-backup` của `aws/accounts/<env>` là `kept`), in sau policy inline và managed policy gắn vào nó.
Instance `svp-<env>-pitr` của diễn tập nằm trong loại `RDS instances`; snapshot tự động của instance vừa xoá nằm trong loại `RDS
automated snapshots` (RDS tự gỡ sau vài phút: quét lại). Bản copy ở account `svp-backup` không thuộc lượt quét nào: nó sống theo
retention.

Edge thêm các loại: cert ACM tag `Project=svp` (region nhà và `us-east-1`), VPC origin CloudFront, security group
`CloudFront-VPCOrigins-Service-SG` trong VPC của lab (loại riêng: xoá tay chỉ khi không còn VPC origin), delivery, delivery source
và delivery destination của CloudWatch Logs (`us-east-1`), topic SNS `svp-*`; alarm, log group, topic SNS, KMS key và alias ở
`us-east-1` (cái mang tag `Stack=baseline` của baseline prd là `kept`). Distribution được nhận theo comment `svp-` hay origin
`svp-*`; ALB, target group và web ACL của edge theo bộ lọc ELBv2, WAF có sẵn.

Được giữ, in thành dòng riêng, không đếm: tài nguyên tag `Stack=baseline` ở account stg (bucket state, KMS key state, zone
`stg.aws.<domain>` với `NS`, `SOA`, `CAA` ở đỉnh; registry ECR, AMP, OIDC provider, role CI, AMG khi cờ `managed_grafana` là
`always`; vault `svp-stg`, role `svp-stg-backup` và key của vault) và ở account prd (thêm, ở `us-east-1`: key KMS DNSSEC, hai
alarm DNSSEC, log group query log, topic `svp-prd-dns-alarms` và key của nó) và `Stack=bootstrap|org` ở management (bucket state,
bucket và KMS key của trail; management không có hosted zone) là `kept`, gói đã có lịch huỷ (`scheduledChange.changeType`
`CANCELLATION`, chỉ gói trả phí; gói Free huỷ ngay) cũng là `kept`; KMS key ở trạng thái `PendingDeletion` (key của root env sau
destroy: RDS, MSK, alarm, Secrets của EKS; tối thiểu 7 ngày) là `pending deletion`.

- **Mong đợi:** `ok nothing left in account … but what it keeps` (exit 0) ở **cả hai lượt**. **Buổi chỉ xong khi hai lượt cùng exit 0.**
- **Bẫy:** có dòng `FAIL <loại>: N left`: dưới mỗi tài nguyên sót là dòng `delete:` với lệnh xoá đủ profile và region (hay trỏ mục
  [Lệnh xoá tay theo loại](session-stg.md#lệnh-xoá-tay-theo-loại) khi một lệnh không đủ); chạy, rồi chạy lại lượt đó tới khi sạch.

## Gỡ

Bước 20–31 là chính phần gỡ của buổi. Destroy kẹt: [Destroy kẹt](session-stg.md#destroy-kẹt); xoá tay theo loại:
[Lệnh xoá tay theo loại](session-stg.md#lệnh-xoá-tay-theo-loại); kết thúc buổi (số đo, thứ còn lại giữa các buổi):
[Kết thúc buổi](session-stg.md#kết-thúc-buổi).

## Khi một bước đỏ

Đọc dòng `FAIL`, sửa nguyên nhân, chạy lại **đúng bước đó** (mọi script chạy lại được); không đi tiếp qua một bước đỏ. Lỗi riêng
của từng bước ở nhãn **Bẫy** của nó; destroy kẹt ở [Destroy kẹt](session-stg.md#destroy-kẹt).
