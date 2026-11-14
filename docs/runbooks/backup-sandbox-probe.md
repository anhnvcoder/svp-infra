# Thử AWS Backup ở account sandbox

Hướng dẫn này dựng ở account management (account sandbox, profile `anhnv-sso`) một bản thu nhỏ của thiết kế backup: vault mã hoá bằng CMK,
vault khoá governance, role AWS Backup với đúng các managed policy của role `svp-<env>-backup`, một instance RDS và một bucket mang tag backup,
một backup plan cục bộ cùng dạng Backup policy của Organizations. Rồi nó chạy từng phép thử mà buổi stg, prd dựa vào: job theo lịch, job
on-demand, restore item-level một object S3, restore point-in-time của RDS, copy vào vault khoá rồi xoá trong đó. Output thô (đã thay định danh
thật) thành fixture của test script diễn tập: phần "Thử sandbox" của mục "Xác nhận" ở
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md#xác-nhận). Giá trị mà lần thử đối chiếu (managed
policy, khoá opt-in, cú pháp selection, metadata restore S3) ở
[phụ lục ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md) (§3, §4, §7, §10). Copy chéo account
không thử ở đây (cần account đích): buổi stg kiểm nó.

**Người học chạy mọi lệnh ở đây.** AI không chạy lệnh nào chạm account, kể cả lệnh chỉ đọc; AI đọc output dán lại và nhắc tới khi gỡ, kiểm
sạch và quét sót đều đã chạy. Mọi lệnh chạy từ gốc repo này (`infra/`), ghi profile và region ngay trong lệnh: `ap-southeast-1` cho AWS Backup,
KMS, RDS, S3, EC2, STS; `us-east-1` cho IAM. Đồng hồ: lệnh `date -u -v…` là cú pháp `date` của macOS.

Chi phí: trần $1. Theo bảng giá ở mục "Chi phí" của phụ lục ADR-0067: hai instance `db.t4g.micro` (rẻ hơn `db.t4g.small` $0,051 mỗi giờ)
khoảng hai giờ, gp3 20 GB của chúng, CMK tính theo giờ (chờ xoá không tính), recovery point và restore vài MB, item Config của tài nguyên tạm;
cộng dưới $0,4. Lần thử kéo dài khoảng 90 phút, phần lớn là chờ RDS và job theo lịch. Bắt đầu rồi thì kết thúc bằng mục "Gỡ", "Kiểm sạch" và
"Quét sót" trong cùng ngày, kể cả khi một bước lỗi.

## Trước khi bắt đầu

- AWS CLI v2 có lệnh `backup` (`AWS_PROFILE=anhnv-sso aws backup describe-region-settings help --region ap-southeast-1` in trang trợ giúp),
  `jq` 1.6 trở lên, `shasum`.
- Phiên SSO của `anhnv-sso` và 12 số của account management.

Tài nguyên tạm, mọi tên mang tiền tố `svp-probe`, tag `Project=svp`, không tag `Stack`:

| Tài nguyên | Tên | Ghi chú |
| --- | --- | --- |
| CMK | `alias/svp-probe` | Mã hoá instance, bucket, hai vault |
| Vault | `svp-probe` | Đích của job theo lịch và on-demand |
| Vault khoá governance | `svp-probe-locked` | Min 1, max 7 ngày; đích của copy |
| Role AWS Backup | `svp-probe-backup` | Trust và managed policy như role `svp-<env>-backup` |
| Instance RDS | `svp-probe` | PostgreSQL `db.t4g.micro`, một AZ, VPC mặc định, tag `Backup=daily` |
| Instance khôi phục | `svp-probe-pitr` | Restore point-in-time của `svp-probe` |
| Bucket | `svp-probe-<account>-ap-southeast-1` | Versioning, SSE-KMS với Bucket Key, ACL tắt, tag `Backup=daily` |
| Backup plan cục bộ | `svp-probe`, selection `svp-probe-tagged` | Cùng dạng plan của Backup policy, cron khoảng 15 phút sau lúc tạo |

## 1. Mở terminal

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>        # never written to a file: the repo is public
export SVP_SESSION_DIR="$PWD/.session/backup-probe-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SVP_SESSION_DIR"; d=$SVP_SESSION_DIR
b=svp-probe-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws ec2 describe-vpcs --filters Name=is-default,Values=true --region ap-southeast-1 --query 'Vpcs[].VpcId' --output text
```

Tìm: `ok    account <12 số> of mgmt, …` với đúng account management, rồi một id `vpc-…` (VPC mặc định, nơi instance tạm nằm). `FAIL` hay không có
VPC mặc định: dừng, không chạy gì nữa, dán output cho AI. Mọi bước sau chạy trong **cùng terminal này**; các id tạo ra được ghi vào
`$d/ids.sh`. Mở lại terminal giữa chừng: đặt lại các biến trên với `SVP_SESSION_DIR` là thư mục cũ, rồi `. "$d/ids.sh"`.

## 2. Đọc và bật opt-in loại tài nguyên

Selection của plan cục bộ (bước 6) ghi rõ mẫu ARN của RDS và S3, nên nó chọn hai loại đó kể cả khi khoá opt-in là `false`: AWS chỉ áp opt-in
cho selection chọn thuần theo tag
([UpdateRegionSettings](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_UpdateRegionSettings.html)). Bước này vẫn đọc map để
đối chiếu khoá với phụ lục §3 và bật hai khoá như account env. Lệnh đầu chỉ đọc; nếu `RDS` hay `S3` là `false`, lệnh ghi bật đúng hai khoá đó,
mục "Gỡ" trả lại map như file `region-settings-before.json`:

```sh
AWS_PROFILE=anhnv-sso aws backup describe-region-settings --region ap-southeast-1 --output json | tee "$d/region-settings-before.json"
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws backup update-region-settings --region ap-southeast-1 --resource-type-opt-in-preference RDS=true,S3=true
AWS_PROFILE=anhnv-sso aws backup describe-region-settings --region ap-southeast-1 --output json | tee "$d/region-settings.json"
jq -r '.ResourceTypeOptInPreference | "RDS=\(.RDS) S3=\(.S3)"' "$d/region-settings.json"
```

Bỏ hai lệnh giữa khi file đầu đã có `"RDS": true` và `"S3": true`. Tìm: dòng cuối `RDS=true S3=true`. Khoá của map đối chiếu danh sách ở phụ
lục §3: khoá API trả mà danh sách thiếu, hay khoá trong danh sách mà API không trả, là phát hiện cho AI.

## 3. Tạo CMK, role, hai vault

Lệnh ghi. CMK giữ key policy mặc định (account có `kms:*`, quyền đi qua IAM). Trust của role như role `svp-<env>-backup`:
`backup.amazonaws.com` với `aws:SourceAccount` là account; bốn managed policy là danh sách của phụ lục §7, ARN tra theo tên:

```sh
aws/scripts/check-account.sh mgmt
key_arn=$(AWS_PROFILE=anhnv-sso aws kms create-key --region ap-southeast-1 --description "svp-probe AWS Backup sandbox probe" \
  --tags TagKey=Project,TagValue=svp --query KeyMetadata.Arn --output text)
AWS_PROFILE=anhnv-sso aws kms create-alias --region ap-southeast-1 --alias-name alias/svp-probe --target-key-id "$key_arn"
jq -n --arg acc "$SVP_AWS_MGMT_ACCOUNT_ID" '{Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Service: "backup.amazonaws.com"}, Action: "sts:AssumeRole",
  Condition: {StringEquals: {"aws:SourceAccount": $acc}}}]}' > "$d/trust.json"
role_arn=$(AWS_PROFILE=anhnv-sso aws iam create-role --role-name svp-probe-backup --region us-east-1 \
  --assume-role-policy-document "file://$d/trust.json" --tags Key=Project,Value=svp --query Role.Arn --output text)
for p in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForRestores \
  AWSBackupServiceRolePolicyForS3Backup AWSBackupServiceRolePolicyForS3Restore; do
  arn=$(AWS_PROFILE=anhnv-sso aws iam list-policies --scope AWS --region us-east-1 --query "Policies[?PolicyName=='$p'].Arn" --output text)
  echo "$arn"
  AWS_PROFILE=anhnv-sso aws iam attach-role-policy --role-name svp-probe-backup --policy-arn "$arn" --region us-east-1
done
for v in svp-probe svp-probe-locked; do
  AWS_PROFILE=anhnv-sso aws backup create-backup-vault --backup-vault-name "$v" --region ap-southeast-1 \
    --encryption-key-arn "$key_arn" --backup-vault-tags Project=svp --query BackupVaultArn --output text
done
AWS_PROFILE=anhnv-sso aws backup put-backup-vault-lock-configuration --backup-vault-name svp-probe-locked --region ap-southeast-1 \
  --min-retention-days 1 --max-retention-days 7
printf 'key_arn=%s\nrole_arn=%s\n' "$key_arn" "$role_arn" | tee -a "$d/ids.sh"
```

Tìm: bốn ARN `arn:aws:iam::aws:policy/…AWSBackupServiceRolePolicyFor…`, hai ARN vault `…:backup-vault:svp-probe` và
`…:backup-vault:svp-probe-locked`, rồi `key_arn`, `role_arn`. Một ARN policy rỗng: tên ở phụ lục §7 không còn đúng, dừng, dán output cho AI,
sang "Gỡ". Lỗi `AlreadyExistsException`, `EntityAlreadyExists` (sót của lần chạy trước): sang "Gỡ", rồi chạy lại từ bước 2.

## 4. Tạo instance và bucket

Lệnh ghi. Instance mã hoá bằng CMK, giữ backup tự động 1 ngày (PITR cần nó), không public, không deletion protection. Maintenance window đặt 12
giờ sau, backup window của RDS 6 giờ sau: job RDS của AWS Backup không bắt đầu được trong giờ trước hay trong maintenance window. Bucket bật
versioning (backup S3 cần), SSE-KMS mặc định với Bucket Key, ACL tắt như bucket của module `media`; vài object, có một `.m3u8`:

```sh
aws/scripts/check-account.sh mgmt
mw="$(LC_ALL=C date -u -v+12H +%a:%H:%M | tr A-Z a-z)-$(LC_ALL=C date -u -v+12H -v+30M +%a:%H:%M | tr A-Z a-z)"
bw="$(date -u -v+6H +%H:%M)-$(date -u -v+6H -v+30M +%H:%M)"
AWS_PROFILE=anhnv-sso aws rds create-db-instance --db-instance-identifier svp-probe --region ap-southeast-1 \
  --engine postgres --db-instance-class db.t4g.micro --allocated-storage 20 --storage-type gp3 --no-multi-az \
  --master-username svp_probe --manage-master-user-password --storage-encrypted --kms-key-id "$key_arn" \
  --no-publicly-accessible --no-deletion-protection --backup-retention-period 1 --copy-tags-to-snapshot \
  --preferred-maintenance-window "$mw" --preferred-backup-window "$bw" \
  --tags Key=Project,Value=svp Key=Backup,Value=daily --query DBInstance.DBInstanceArn --output text
AWS_PROFILE=anhnv-sso aws s3api create-bucket --bucket "$b" --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1 --query Location --output text
AWS_PROFILE=anhnv-sso aws s3api put-bucket-ownership-controls --bucket "$b" --region ap-southeast-1 \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
AWS_PROFILE=anhnv-sso aws s3api put-bucket-versioning --bucket "$b" --region ap-southeast-1 --versioning-configuration Status=Enabled
jq -n --arg k "$key_arn" '{Rules: [{ApplyServerSideEncryptionByDefault: {SSEAlgorithm: "aws:kms", KMSMasterKeyID: $k},
  BucketKeyEnabled: true}]}' > "$d/bucket-encryption.json"
AWS_PROFILE=anhnv-sso aws s3api put-bucket-encryption --bucket "$b" --region ap-southeast-1 \
  --server-side-encryption-configuration "file://$d/bucket-encryption.json"
AWS_PROFILE=anhnv-sso aws s3api put-bucket-tagging --bucket "$b" --region ap-southeast-1 \
  --tagging 'TagSet=[{Key=Project,Value=svp},{Key=Backup,Value=daily}]'
mkdir -p "$d/objects"
printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n' > "$d/objects/index.m3u8"
head -c 65536 /dev/urandom > "$d/objects/seg0.ts"
head -c 4096 /dev/urandom > "$d/objects/source"
AWS_PROFILE=anhnv-sso aws s3 cp "$d/objects/index.m3u8" "s3://$b/media/probe/index.m3u8" --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws s3 cp "$d/objects/seg0.ts" "s3://$b/media/probe/seg0.ts" --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws s3 cp "$d/objects/source" "s3://$b/uploads/probe/source" --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws s3api head-object --bucket "$b" --key media/probe/index.m3u8 --region ap-southeast-1 \
  --query '[ServerSideEncryption, BucketKeyEnabled]' --output text
```

Tìm: ARN `arn:aws:rds:ap-southeast-1:<12 số>:db:svp-probe`, dòng `Location` của bucket, ba dòng `upload:`, rồi `aws:kms True`. Lỗi
`InvalidParameterCombination` ở `create-db-instance` (lớp hay gp3 không có cho version mặc định): dán lỗi cho AI, sang "Gỡ".

## 5. Chờ instance `available`

Instance mới mất khoảng 10–15 phút, gồm bản backup tự động đầu tiên:

```sh
AWS_PROFILE=anhnv-sso aws rds wait db-instance-available --db-instance-identifier svp-probe --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws rds describe-db-instances --db-instance-identifier svp-probe --region ap-southeast-1 \
  --query 'DBInstances[0].[DBInstanceStatus, LatestRestorableTime]' --output text
```

Tìm: `available` và một thời điểm UTC. Waiter hết hạn (30 phút) mà chưa `available`: chạy lại lệnh đầu một lần, vẫn không thì dán output cho AI,
sang "Gỡ".

## 6. Tạo backup plan cục bộ

Lệnh ghi. Rule `daily` cùng dạng **Lịch và retention** của ADR-0067 (start window 60 phút, completion window 180 phút, không continuous backup),
trừ cron đặt khoảng 15 phút sau lúc này và retention 2 ngày. Selection cùng dạng selection `svp-<env>-tagged` của Backup policy (phụ lục §4):
đúng hai mẫu ARN, instance RDS và bucket S3, cùng điều kiện tag `aws:ResourceTag/Backup` = `daily`; không `ListOfTags` (nó cộng thêm tài
nguyên theo phép OR):

```sh
aws/scripts/check-account.sh mgmt
cron=$(date -u -v+15M '+cron(%M %H * * ? *)'); echo "$cron"
jq -n --arg c "$cron" '{BackupPlanName: "svp-probe", Rules: [{RuleName: "daily", TargetBackupVaultName: "svp-probe",
  ScheduleExpression: $c, StartWindowMinutes: 60, CompletionWindowMinutes: 180, Lifecycle: {DeleteAfterDays: 2}}]}' > "$d/plan.json"
plan_id=$(AWS_PROFILE=anhnv-sso aws backup create-backup-plan --region ap-southeast-1 --backup-plan "file://$d/plan.json" \
  --backup-plan-tags Project=svp --query BackupPlanId --output text)
jq -n --arg r "$role_arn" '{SelectionName: "svp-probe-tagged", IamRoleArn: $r,
  Resources: ["arn:aws:rds:*:*:db:*", "arn:aws:s3:::*"],
  Conditions: {StringEquals: [{ConditionKey: "aws:ResourceTag/Backup", ConditionValue: "daily"}]}}' > "$d/selection.json"
selection_id=$(AWS_PROFILE=anhnv-sso aws backup create-backup-selection --region ap-southeast-1 --backup-plan-id "$plan_id" \
  --backup-selection "file://$d/selection.json" --query SelectionId --output text)
printf 'plan_id=%s\nselection_id=%s\n' "$plan_id" "$selection_id" | tee -a "$d/ids.sh"
AWS_PROFILE=anhnv-sso aws backup get-backup-plan --backup-plan-id "$plan_id" --region ap-southeast-1 --output json > "$d/get-backup-plan.json"
AWS_PROFILE=anhnv-sso aws backup get-backup-selection --backup-plan-id "$plan_id" --selection-id "$selection_id" --region ap-southeast-1 \
  --output json > "$d/get-backup-selection.json"
jq -r '.BackupPlan.Rules[0] | [.RuleName, .ScheduleExpression, .StartWindowMinutes, .CompletionWindowMinutes] | @tsv' "$d/get-backup-plan.json"
```

Tìm: dòng `cron(<phút> <giờ> * * ? *)`, `plan_id`, `selection_id`, rồi `daily  cron(…)  60  180`. Lỗi tham số ở `create-backup-selection`: dán
lỗi và `$d/selection.json` cho AI, sang "Gỡ".

## 7. Bắt đầu restore point-in-time

Lệnh ghi. Không client nào ghi vào instance tạm, nên thời điểm khôi phục `T_r` là lúc này làm tròn lên giây kế; lệnh chờ tới khi
`LatestRestorableTime` (LRT) ≥ `T_r` (RDS đẩy log giao dịch mỗi 5 phút), đọc LRT ngay trước khi gọi restore (T0). Bản khôi phục dùng subnet group,
security group, parameter group, lớp của nguồn, một AZ, không public, chỉ tag `Project=svp` (không `Backup`, để plan không chọn nó). Lệnh này chạy
trong lúc chờ job theo lịch (bước 8):

```sh
tr=$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ); echo "T_r $tr"
for i in $(seq 1 25); do
  lrt=$(AWS_PROFILE=anhnv-sso aws rds describe-db-instances --db-instance-identifier svp-probe --region ap-southeast-1 \
    --query 'DBInstances[0].LatestRestorableTime' --output text)
  echo "$(date -u +%H:%M:%S) LRT $lrt"
  if [[ "$lrt" == 2* ]] && ! [[ "${lrt:0:19}" < "${tr:0:19}" ]]; then break; fi
  sleep 60
done
AWS_PROFILE=anhnv-sso aws rds describe-db-instances --db-instance-identifier svp-probe --region ap-southeast-1 --output json > "$d/db-source.json"
aws/scripts/check-account.sh mgmt
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AWS_PROFILE=anhnv-sso aws rds restore-db-instance-to-point-in-time --region ap-southeast-1 \
  --source-db-instance-identifier svp-probe --target-db-instance-identifier svp-probe-pitr --restore-time "$tr" \
  --db-instance-class "$(jq -r '.DBInstances[0].DBInstanceClass' "$d/db-source.json")" \
  --db-subnet-group-name "$(jq -r '.DBInstances[0].DBSubnetGroup.DBSubnetGroupName' "$d/db-source.json")" \
  --vpc-security-group-ids "$(jq -r '.DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' "$d/db-source.json")" \
  --db-parameter-group-name "$(jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName' "$d/db-source.json")" \
  --no-multi-az --no-publicly-accessible --no-deletion-protection --tags Key=Project,Value=svp \
  --query 'DBInstance.[DBInstanceStatus, TagList]' --output json
printf 'tr=%s\nlrt=%s\nt0=%s\n' "$tr" "$(jq -r '.DBInstances[0].LatestRestorableTime' "$d/db-source.json")" "$t0" \
  | tee "$d/pitr-times.txt" | sed 's/^/export /' >> "$d/ids.sh"
for i in $(seq 1 120); do
  st=$(AWS_PROFILE=anhnv-sso aws rds describe-db-instances --db-instance-identifier svp-probe-pitr --region ap-southeast-1 \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  echo "$(date -u +%H:%M:%S) $st"
  [ "$st" = available ] && break
  sleep 30
done
echo "t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$d/pitr-times.txt"
```

Tìm: các dòng `LRT` tăng tới lúc ≥ `T_r` (tối đa 25 phút; hết hạn mà LRT vẫn nhỏ hơn thì dán output cho AI, sang "Gỡ"), rồi `"creating"` và
`TagList` chỉ có `Project=svp`. `TagList` có `Backup`: gỡ tag đó ngay
(`AWS_PROFILE=anhnv-sso aws rds remove-tags-from-resource --resource-name <ARN svp-probe-pitr> --tag-keys Backup --region ap-southeast-1`) và
báo AI. Rồi các dòng trạng thái tới `available` và dòng `t1=…`: lúc bản khôi phục dùng được, đo trước khi chờ job theo lịch (tối đa 60 phút;
hết hạn mà chưa `available` thì `t1` không phải số đo: dán output cho AI, vẫn sang bước 8).

## 8. Chờ job theo lịch

Job theo lịch bắt đầu trong start window (60 phút sau giờ cron) và chạy vài phút. Lệnh chờ tới khi plan đã tạo đủ hai job (instance và bucket)
và cả hai ở trạng thái kết thúc, tối đa 110 phút:

```sh
for i in $(seq 1 110); do
  AWS_PROFILE=anhnv-sso aws backup list-backup-jobs --by-backup-vault-name svp-probe --region ap-southeast-1 --output json \
    > "$d/list-backup-jobs-scheduled.json"
  st=$(jq -r --arg p "$plan_id" '[.BackupJobs[] | select(.CreatedBy.BackupPlanId == $p) | .State]
    | "\(length >= 2 and all(IN("COMPLETED", "FAILED", "ABORTED", "EXPIRED", "PARTIAL"))) \(length) \(join(","))"' \
    "$d/list-backup-jobs-scheduled.json")
  echo "$(date -u +%H:%M:%S) $st"
  case $st in true\ *) break ;; esac
  sleep 60
done
jq -r --arg p "$plan_id" '.BackupJobs[] | select(.CreatedBy.BackupPlanId == $p) | [.ResourceType, .ResourceArn, .State] | @tsv' \
  "$d/list-backup-jobs-scheduled.json"
```

Dòng chờ in `<xong> <số job> <trạng thái>`. Tìm: hai dòng `COMPLETED`, đúng `arn:aws:rds:ap-southeast-1:<12 số>:db:svp-probe` và
`arn:aws:s3:::svp-probe-<12 số>-ap-southeast-1`; không
dòng nào là snapshot (`…:snapshot:…`) hay `svp-probe-pitr`. Một job `FAILED`, `EXPIRED`, `ABORTED`, hay hết hạn chờ: dán
`$d/list-backup-jobs-scheduled.json` cho AI, rồi vẫn chạy tiếp bước 9 trở đi (mỗi bước đo một việc riêng).

## 9. Đọc bản khôi phục

```sh
AWS_PROFILE=anhnv-sso aws rds describe-db-instances --db-instance-identifier svp-probe-pitr --region ap-southeast-1 --output json \
  > "$d/db-pitr.json"
jq -r '.DBInstances[0] | [.DBInstanceStatus, .DBInstanceClass, .MultiAZ, .PubliclyAccessible, .DBSubnetGroup.DBSubnetGroupName,
  .KmsKeyId] | map(tostring) | @tsv' "$d/db-pitr.json"
cat "$d/pitr-times.txt"
```

Tìm: `available  db.t4g.micro  false  false  default  <ARN key svp-probe>`, rồi `tr`, `lrt`, `t0`, `t1`: `t0 − lrt` là RPO, `t1 − t0` là thời gian
dựng instance khôi phục của lần thử.

## 10. Job on-demand

Lệnh ghi: một job cho instance, một cho bucket, vào `svp-probe` bằng role `svp-probe-backup`, như lệnh `backup` của script diễn tập. Chờ tới khi
cả hai kết thúc (tối đa 60 phút), rồi đọc job, recovery point và metadata restore của từng cái:

```sh
aws/scripts/check-account.sh mgmt
for r in rds s3; do
  case $r in rds) arn=arn:aws:rds:ap-southeast-1:$SVP_AWS_MGMT_ACCOUNT_ID:db:svp-probe ;; s3) arn=arn:aws:s3:::$b ;; esac
  job=$(AWS_PROFILE=anhnv-sso aws backup start-backup-job --region ap-southeast-1 --backup-vault-name svp-probe --resource-arn "$arn" \
    --iam-role-arn "$role_arn" --lifecycle DeleteAfterDays=2 --query BackupJobId --output text)
  echo "job_$r=$job" | tee -a "$d/ids.sh"
done
. "$d/ids.sh"
for r in rds s3; do
  job=$(eval echo "\$job_$r")
  for i in $(seq 1 60); do
    AWS_PROFILE=anhnv-sso aws backup describe-backup-job --backup-job-id "$job" --region ap-southeast-1 --output json \
      > "$d/describe-backup-job-$r.json"
    st=$(jq -r .State "$d/describe-backup-job-$r.json"); echo "$(date -u +%H:%M:%S) $r $st"
    case $st in CREATED | PENDING | RUNNING | ABORTING) sleep 60 ;; *) break ;; esac
  done
  rp=$(jq -r .RecoveryPointArn "$d/describe-backup-job-$r.json"); echo "rp_$r=$rp" | tee -a "$d/ids.sh"
  AWS_PROFILE=anhnv-sso aws backup describe-recovery-point --region ap-southeast-1 --backup-vault-name svp-probe \
    --recovery-point-arn "$rp" --output json > "$d/describe-recovery-point-$r.json"
  AWS_PROFILE=anhnv-sso aws backup get-recovery-point-restore-metadata --region ap-southeast-1 --backup-vault-name svp-probe \
    --recovery-point-arn "$rp" --output json > "$d/restore-metadata-$r.json"
done
. "$d/ids.sh"
jq -r '[.ResourceType, .State, .RecoveryPointArn] | @tsv' "$d"/describe-backup-job-*.json
jq -r '[.ResourceType, .Status, .CreationDate, .EncryptionKeyArn] | map(tostring) | @tsv' "$d"/describe-recovery-point-*.json
```

Tìm: hai job `COMPLETED`, recovery point RDS dạng `arn:aws:rds:…:snapshot:awsbackup:job-…`, S3 dạng `arn:aws:backup:…:recovery-point:…`,
cả hai `COMPLETED`. Một job không `COMPLETED`: dán `$d/describe-backup-job-<rds|s3>.json` cho AI; bước 11 cần job S3, bước 12 cần cả hai.

## 11. Restore item-level một object S3

Như **Diễn tập object S3** của ADR-0067: ghi độ dài và SHA-256 của `media/probe/index.m3u8`, xoá nó (versioning để lại delete marker), restore
đúng key đó vào chính bucket từ recovery point S3 của bước 10 bằng role Backup, rồi so lại. Metadata là bốn khoá của phụ lục §10 (`RestoreACLs`
`false` vì bucket tắt ACL); `ItemsToRestore` là chuỗi JSON của danh sách S3 URI:

```sh
k=media/probe/index.m3u8
AWS_PROFILE=anhnv-sso aws s3api head-object --bucket "$b" --key "$k" --region ap-southeast-1 --output json > "$d/head-before.json"
AWS_PROFILE=anhnv-sso aws s3api get-object --bucket "$b" --key "$k" --region ap-southeast-1 "$d/before.m3u8" > /dev/null
aws/scripts/check-account.sh mgmt
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AWS_PROFILE=anhnv-sso aws s3api delete-object --bucket "$b" --key "$k" --region ap-southeast-1 --output json
jq -n --arg rp "$rp_s3" --arg r "$role_arn" --arg b "$b" --arg k "$k" '{RecoveryPointArn: $rp, IamRoleArn: $r, ResourceType: "S3",
  Metadata: {DestinationBucketName: $b, ItemsToRestore: (["s3://\($b)/\($k)"] | tojson), EncryptionType: "original",
  RestoreACLs: "false"}}' > "$d/start-restore-job-input.json"
AWS_PROFILE=anhnv-sso aws backup start-restore-job --region ap-southeast-1 --cli-input-json "file://$d/start-restore-job-input.json" \
  --output json | tee "$d/start-restore-job.json"
restore=$(jq -r .RestoreJobId "$d/start-restore-job.json")
for i in $(seq 1 30); do
  AWS_PROFILE=anhnv-sso aws backup describe-restore-job --restore-job-id "$restore" --region ap-southeast-1 --output json \
    > "$d/describe-restore-job.json"
  st=$(jq -r .Status "$d/describe-restore-job.json"); echo "$(date -u +%H:%M:%S) $st"
  case $st in PENDING | RUNNING) sleep 30 ;; *) break ;; esac
done
AWS_PROFILE=anhnv-sso aws s3api get-object --bucket "$b" --key "$k" --region ap-southeast-1 "$d/after.m3u8" > /dev/null
t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AWS_PROFILE=anhnv-sso aws s3api head-object --bucket "$b" --key "$k" --region ap-southeast-1 --output json > "$d/head-after.json"
{ echo "t0=$t0 t1=$t1"; for f in before after; do
  echo "$f $(wc -c < "$d/$f.m3u8" | tr -d ' ') $(shasum -a 256 "$d/$f.m3u8" | cut -d' ' -f1) $(jq -r .ETag "$d/head-$f.json")"
done; } | tee "$d/s3-check.txt"
```

Tìm: `delete-object` trả `"DeleteMarker": true`, restore job `COMPLETED` (tối đa 15 phút), rồi hai dòng `before`, `after` cùng độ dài, cùng
SHA-256; ETag có thể khác (AWS Backup không giữ ETag). `start-restore-job` lỗi tham số hay job `FAILED`: dán lỗi,
`$d/start-restore-job-input.json`, `$d/describe-restore-job.json` và `$d/restore-metadata-s3.json` cho AI.

## 12. Copy vào vault khoá rồi xoá trong đó

Lệnh ghi. Copy cùng account hai recovery point của bước 10 vào `svp-probe-locked` (retention 2 ngày, trong [min 1, max 7] của lock), chờ cả hai
kết thúc (tối đa 60 phút), rồi xoá một bản copy: lock governance phải từ chối:

```sh
aws/scripts/check-account.sh mgmt
locked=$(AWS_PROFILE=anhnv-sso aws backup describe-backup-vault --backup-vault-name svp-probe-locked --region ap-southeast-1 \
  --output json | tee "$d/describe-backup-vault-locked.json" | jq -r .BackupVaultArn)
for rp in "$rp_rds" "$rp_s3"; do
  AWS_PROFILE=anhnv-sso aws backup start-copy-job --region ap-southeast-1 --recovery-point-arn "$rp" --source-backup-vault-name svp-probe \
    --destination-backup-vault-arn "$locked" --iam-role-arn "$role_arn" --lifecycle DeleteAfterDays=2 --query CopyJobId --output text
done
for i in $(seq 1 60); do
  AWS_PROFILE=anhnv-sso aws backup list-copy-jobs --by-destination-vault-arn "$locked" --region ap-southeast-1 --output json \
    > "$d/list-copy-jobs.json"
  st=$(jq -r '[.CopyJobs[].State] | join(",")' "$d/list-copy-jobs.json"); echo "$(date -u +%H:%M:%S) $st"
  case $st in *CREATED* | *RUNNING* | "") sleep 60 ;; *) break ;; esac
done
copy=$(jq -r '[.CopyJobs[] | select(.State == "COMPLETED") | .DestinationRecoveryPointArn][0] // ""' "$d/list-copy-jobs.json")
AWS_PROFILE=anhnv-sso aws backup delete-recovery-point --region ap-southeast-1 --backup-vault-name svp-probe-locked \
  --recovery-point-arn "$copy" 2> "$d/delete-locked.err"; echo "exit $?"
cat "$d/delete-locked.err"
jq -r '[.Locked, .MinRetentionDays, .MaxRetentionDays] | map(tostring) | @tsv' "$d/describe-backup-vault-locked.json"
```

Tìm: hai copy job `COMPLETED`, `exit` khác 0 với một lỗi nhắc vault lock, rồi `true  1  7`. `exit 0` (bản copy bị xoá được): phát hiện, báo AI.
`copy` rỗng (không copy nào `COMPLETED`): dán `$d/list-copy-jobs.json`.

## 13. Thay định danh thật và dán output

Các file chứa account, tên bucket, endpoint RDS thật. Lệnh dưới chép chúng vào `$d/paste/` với account thành `000000000000`, tên phiên SSO
thành `learner`, phần ngẫu nhiên của endpoint RDS thành `example`; lệnh cuối không in gì khi không còn account thật:

```sh
mkdir -p "$d/paste"
for f in region-settings-before.json region-settings.json get-backup-plan.json get-backup-selection.json list-backup-jobs-scheduled.json \
  db-source.json db-pitr.json pitr-times.txt describe-backup-job-rds.json describe-backup-job-s3.json describe-recovery-point-rds.json \
  describe-recovery-point-s3.json restore-metadata-rds.json restore-metadata-s3.json start-restore-job-input.json start-restore-job.json \
  describe-restore-job.json head-before.json head-after.json s3-check.txt list-copy-jobs.json describe-backup-vault-locked.json \
  delete-locked.err; do
  [ -f "$d/$f" ] || { echo "missing $f"; continue; }
  sed -E -e "s/$SVP_AWS_MGMT_ACCOUNT_ID/000000000000/g" -e 's#(assumed-role/[^/]+/)[^ "]+#\1learner#g' \
    -e 's/\.[a-z0-9]{12}\.ap-southeast-1\.rds\.amazonaws\.com/.example.ap-southeast-1.rds.amazonaws.com/g' "$d/$f" > "$d/paste/$f"
done
grep -rl "$SVP_AWS_MGMT_ACCOUNT_ID" "$d/paste"
```

Dán lại nguyên các file trong `$d/paste/`, mỗi file sinh ra ở:

| File | Lệnh | Bước |
| --- | --- | --- |
| `region-settings-before.json`, `region-settings.json` | `backup describe-region-settings` trước và sau khi bật | 2 |
| `get-backup-plan.json`, `get-backup-selection.json` | `backup get-backup-plan`, `backup get-backup-selection` | 6 |
| `db-source.json`, `pitr-times.txt` | `rds describe-db-instances` của `svp-probe` ngay trước restore; `T_r`, LRT, T0 | 7 |
| `list-backup-jobs-scheduled.json` | `backup list-backup-jobs` của vault `svp-probe`, gồm job theo lịch | 8 |
| `db-pitr.json`, `pitr-times.txt` | `rds describe-db-instances` của `svp-probe-pitr`; T1 | 9 |
| `describe-backup-job-{rds,s3}.json` | `backup describe-backup-job` của job on-demand | 10 |
| `describe-recovery-point-{rds,s3}.json` | `backup describe-recovery-point` | 10 |
| `restore-metadata-{rds,s3}.json` | `backup get-recovery-point-restore-metadata` | 10 |
| `start-restore-job-input.json`, `start-restore-job.json` | Đầu vào và output của `backup start-restore-job` (S3) | 11 |
| `describe-restore-job.json` | `backup describe-restore-job` (S3) | 11 |
| `head-before.json`, `head-after.json`, `s3-check.txt` | `s3api head-object`; độ dài, SHA-256, ETag trước và sau | 11 |
| `list-copy-jobs.json` | `backup list-copy-jobs` của vault `svp-probe-locked` | 12 |
| `describe-backup-vault-locked.json`, `delete-locked.err` | `backup describe-backup-vault`; lỗi của `backup delete-recovery-point` dưới lock | 12 |

Dòng `missing <file>`: bước sinh ra file đó chưa chạy hay đã lỗi; nói rõ khi dán. `grep` in một đường dẫn: file đó còn account thật, không dán,
báo AI. Thư mục `.session/` git bỏ qua.

## Gỡ

Lệnh ghi. Mục này đọc được từ đầu và chạy được dù bước nào đã lỗi hay chưa chạy tới: mỗi lệnh tìm tài nguyên theo tên `svp-probe*`, không dựa
vào biến của các bước trên. Một lệnh lỗi `NotFound`, `ResourceNotFoundException`, `DBInstanceNotFound`, `NoSuchBucket`, `NoSuchEntity`: phần
đó đã gỡ hay chưa từng tạo, chạy tiếp lệnh sau. Chạy theo thứ tự.

### G1. Mở terminal

Trong terminal của các bước trên thì chỉ cần các biến đã có. Terminal mới: `SVP_SESSION_DIR` là thư mục của lần thử (nơi có
`region-settings-before.json`); không
còn thư mục đó thì đặt một thư mục mới:

```sh
cd infra
AWS_PROFILE=anhnv-sso aws sso login --region us-east-1
export SVP_AWS_MGMT_ACCOUNT_ID=<12 số của account management>
export SVP_SESSION_DIR=<thư mục .session/backup-probe-… của lần thử>; mkdir -p "$SVP_SESSION_DIR"; d=$SVP_SESSION_DIR
b=svp-probe-$SVP_AWS_MGMT_ACCOUNT_ID-ap-southeast-1
aws/scripts/check-account.sh mgmt
```

### G2. Dừng job và chờ job chưa kết thúc

Backup job dừng được; copy job, restore job thì chờ. Vòng chờ in số job chưa kết thúc (backup, copy, restore) của account, tối đa 30 phút:

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws backup list-backup-jobs --region ap-southeast-1 --output json \
  | jq -r '.BackupJobs[] | select(.BackupVaultName | startswith("svp-probe")) | select(.State | IN("CREATED", "PENDING", "RUNNING"))
    | .BackupJobId' \
  | while read -r j; do AWS_PROFILE=anhnv-sso aws backup stop-backup-job --backup-job-id "$j" --region ap-southeast-1; done
for i in $(seq 1 30); do
  n=$( { AWS_PROFILE=anhnv-sso aws backup list-backup-jobs --region ap-southeast-1 --output json \
      | jq '[.BackupJobs[] | select(.State | IN("CREATED", "PENDING", "RUNNING", "ABORTING"))] | length'
    AWS_PROFILE=anhnv-sso aws backup list-copy-jobs --region ap-southeast-1 --output json \
      | jq '[.CopyJobs[] | select(.State | IN("CREATED", "RUNNING"))] | length'
    AWS_PROFILE=anhnv-sso aws backup list-restore-jobs --region ap-southeast-1 --output json \
      | jq '[.RestoreJobs[] | select(.Status | IN("PENDING", "RUNNING"))] | length'; } | paste -sd' ' -)
  echo "$(date -u +%H:%M:%S) unfinished backup copy restore: $n"
  [ "$n" = "0 0 0" ] && break
  sleep 60
done
```

Tìm: `unfinished backup copy restore: 0 0 0`. Hết 30 phút mà chưa: dán output cho AI, chạy lại khối này sau.

### G3. Xoá backup plan

Xoá selection trước, rồi plan:

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws backup list-backup-plans --region ap-southeast-1 --output json \
  | jq -r '.BackupPlansList[] | select(.BackupPlanName | startswith("svp-probe")) | .BackupPlanId' \
  | while read -r p; do
    AWS_PROFILE=anhnv-sso aws backup list-backup-selections --backup-plan-id "$p" --region ap-southeast-1 --output json \
      | jq -r '.BackupSelectionsList[].SelectionId' \
      | while read -r s; do
        AWS_PROFILE=anhnv-sso aws backup delete-backup-selection --backup-plan-id "$p" --selection-id "$s" --region ap-southeast-1
      done
    AWS_PROFILE=anhnv-sso aws backup delete-backup-plan --backup-plan-id "$p" --region ap-southeast-1 --output json
  done
```

### G4. Xoá hai instance

Không snapshot cuối, kèm backup tự động; chờ tới khi xoá xong (khoảng 5–10 phút):

```sh
aws/scripts/check-account.sh mgmt
for db in svp-probe-pitr svp-probe; do
  AWS_PROFILE=anhnv-sso aws rds delete-db-instance --db-instance-identifier "$db" --region ap-southeast-1 \
    --skip-final-snapshot --delete-automated-backups --query DBInstance.DBInstanceStatus --output text
done
for db in svp-probe-pitr svp-probe; do
  AWS_PROFILE=anhnv-sso aws rds wait db-instance-deleted --db-instance-identifier "$db" --region ap-southeast-1
done
```

Lỗi `InvalidDBInstanceState` (instance đang `creating`, `modifying`): chờ vài phút rồi chạy lại khối này.

### G5. Bỏ lock, xoá recovery point và hai vault

Bỏ lock governance (quyền IAM của `anhnv-sso` đủ), xoá mọi recovery point của hai vault, chờ tới khi vault rỗng (snapshot RDS xoá mất vài phút,
tối đa 20 phút), rồi xoá vault:

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws backup delete-backup-vault-lock-configuration --backup-vault-name svp-probe-locked --region ap-southeast-1
for v in svp-probe-locked svp-probe; do
  AWS_PROFILE=anhnv-sso aws backup list-recovery-points-by-backup-vault --backup-vault-name "$v" --region ap-southeast-1 --output json \
    | jq -r '.RecoveryPoints[] | select(.Status != "DELETING") | .RecoveryPointArn' \
    | while read -r rp; do
      AWS_PROFILE=anhnv-sso aws backup delete-recovery-point --backup-vault-name "$v" --recovery-point-arn "$rp" --region ap-southeast-1
    done
done
for i in $(seq 1 20); do
  n=$(for v in svp-probe-locked svp-probe; do
    { AWS_PROFILE=anhnv-sso aws backup list-recovery-points-by-backup-vault --backup-vault-name "$v" --region ap-southeast-1 \
      --output json || echo '{"RecoveryPoints": []}'; } | jq '.RecoveryPoints | length'
  done | paste -sd' ' -)
  echo "$(date -u +%H:%M:%S) recovery points left (locked, probe): $n"
  [ "$n" = "0 0" ] && break
  sleep 60
done
for v in svp-probe-locked svp-probe; do
  AWS_PROFILE=anhnv-sso aws backup delete-backup-vault --backup-vault-name "$v" --region ap-southeast-1
done
```

Tìm: `recovery points left (locked, probe): 0 0`. Vault đã xoá hay chưa từng tạo đếm là `0` (lệnh đọc in lỗi `ResourceNotFoundException`).
`delete-recovery-point`
lỗi vì lock: lệnh bỏ lock đầu khối chưa chạy được, dán lỗi cho AI.

### G6. Xoá bucket

Bucket có versioning: xoá mọi version và delete marker, rồi bucket:

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws s3api list-object-versions --bucket "$b" --region ap-southeast-1 --output json \
  | jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}' > "$d/delete-versions.json"
jq '.Objects | length' "$d/delete-versions.json"
AWS_PROFILE=anhnv-sso aws s3api delete-objects --bucket "$b" --region ap-southeast-1 --delete "file://$d/delete-versions.json"
AWS_PROFILE=anhnv-sso aws s3api delete-bucket --bucket "$b" --region ap-southeast-1
```

Số đếm `0`: bỏ `delete-objects` (nó lỗi với danh sách rỗng).

### G7. Xoá role

```sh
aws/scripts/check-account.sh mgmt
AWS_PROFILE=anhnv-sso aws iam list-attached-role-policies --role-name svp-probe-backup --region us-east-1 --output json \
  | jq -r '.AttachedPolicies[].PolicyArn' \
  | while read -r p; do
    AWS_PROFILE=anhnv-sso aws iam detach-role-policy --role-name svp-probe-backup --policy-arn "$p" --region us-east-1
  done
AWS_PROFILE=anhnv-sso aws iam delete-role --role-name svp-probe-backup --region us-east-1
```

### G8. Lên lịch xoá CMK

Sau G4, G5, G6: không còn gì dùng key. Chờ xoá 7 ngày (key chờ xoá không tính phí); alias xoá cùng:

```sh
aws/scripts/check-account.sh mgmt
kid=$(AWS_PROFILE=anhnv-sso aws kms describe-key --key-id alias/svp-probe --region ap-southeast-1 --query KeyMetadata.KeyId --output text)
AWS_PROFILE=anhnv-sso aws kms schedule-key-deletion --key-id "$kid" --pending-window-in-days 7 --region ap-southeast-1
AWS_PROFILE=anhnv-sso aws kms delete-alias --alias-name alias/svp-probe --region ap-southeast-1
```

`describe-key` lỗi `NotFoundException` (alias đã xoá) mà key còn: `sweep.sh mgmt` ở mục "Quét sót" in nó kèm lệnh xoá.

### G9. Trả lại opt-in

Chỉ khi bước 2 đã ghi `region-settings-before.json`: ghi lại nguyên map đã đọc lúc đầu:

```sh
aws/scripts/check-account.sh mgmt
jq '{ResourceTypeOptInPreference}' "$d/region-settings-before.json" > "$d/region-settings-restore.json"
AWS_PROFILE=anhnv-sso aws backup update-region-settings --region ap-southeast-1 --cli-input-json "file://$d/region-settings-restore.json"
```

## Kiểm sạch

Chỉ đọc. Phủ phần mà `sweep.sh` không đọc: vault, recovery point (nằm trong vault), plan, job chưa kết thúc, role, opt-in:

```sh
AWS_PROFILE=anhnv-sso aws backup list-backup-vaults --region ap-southeast-1 --output json \
  | jq -r '.BackupVaultList[] | select(.BackupVaultName | startswith("svp-probe")) | "LEFT vault \(.BackupVaultName) \(.NumberOfRecoveryPoints)"'
AWS_PROFILE=anhnv-sso aws backup list-backup-plans --region ap-southeast-1 --output json \
  | jq -r '.BackupPlansList[] | select(.BackupPlanName | startswith("svp-probe")) | "LEFT plan \(.BackupPlanName)"'
AWS_PROFILE=anhnv-sso aws backup list-backup-jobs --region ap-southeast-1 --output json \
  | jq -r '.BackupJobs[] | select(.State | IN("CREATED", "PENDING", "RUNNING", "ABORTING")) | "LEFT backup job \(.BackupJobId)"'
AWS_PROFILE=anhnv-sso aws backup list-copy-jobs --region ap-southeast-1 --output json \
  | jq -r '.CopyJobs[] | select(.State | IN("CREATED", "RUNNING")) | "LEFT copy job \(.CopyJobId)"'
AWS_PROFILE=anhnv-sso aws backup list-restore-jobs --region ap-southeast-1 --output json \
  | jq -r '.RestoreJobs[] | select(.Status | IN("PENDING", "RUNNING")) | "LEFT restore job \(.RestoreJobId)"'
AWS_PROFILE=anhnv-sso aws iam get-role --role-name svp-probe-backup --region us-east-1 --query Role.RoleName --output text \
  2>&1 | sed 's/^/role: /'
AWS_PROFILE=anhnv-sso aws backup describe-region-settings --region ap-southeast-1 --output json \
  | jq -S .ResourceTypeOptInPreference > "$d/region-settings-after.json"
jq -S .ResourceTypeOptInPreference "$d/region-settings-before.json" | diff - "$d/region-settings-after.json" && echo "opt-in as before"
```

Tìm: không dòng `LEFT` nào, dòng `role:` nhắc `NoSuchEntity`, rồi `opt-in as before`. Có dòng `LEFT` hay role còn: chạy lại mục con tương ứng
của "Gỡ" (G2–G7), rồi khối này. Opt-in khác: chạy lại G9 (không có `region-settings-before.json` thì dán output cho AI).

## Quét sót

```sh
aws/scripts/sweep.sh mgmt
```

Lượt quét phủ instance RDS, snapshot, backup tự động, bucket và CMK (key chờ xoá in là `pending deletion`, không tính). Tìm:
`ok nothing left in account … but what it keeps` (exit 0), không dòng nào nhắc `svp-probe` ngoài dòng `pending deletion` của key. Có dòng
`FAIL <loại>: N left`: chạy lệnh `delete:` in dưới mỗi tài nguyên, rồi chạy lại tới khi sạch. Dán lại toàn bộ output của "Kiểm sạch" và lượt
quét này. **Lần thử chỉ xong khi "Kiểm sạch" không còn dòng `LEFT` và lượt quét exit 0.**
