# Module `org-policies`

Mọi policy của AWS Organizations: service control policy (SCP), resource control policy (RCP), declarative policy EC2, tag policy và Backup
policy. Root `aws/org` truyền root của org (`root_id`), OU `Prod` (`prod_ou_id`), OU `NonProd` (`nonprod_ou_id`), id tổ chức
(`organization_id`, cho RCP) và id account `svp-backup` (`backup_account_id`, đích copy của Backup policy). Mỗi policy gắn đúng một đích:
`svp-prod-guardrails` và `svp-backup-prd` ở OU `Prod`, `svp-backup-stg` ở OU `NonProd`, mọi policy khác ở root. Thiết kế và statement đủ:
[ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) và
[phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0059-org-structure-guardrails.md); Backup policy:
[ADR-0067](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0067-backup-dr.md) §4 và
[phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0067-backup-dr.md#4-backup-policy).

| Policy | Loại | Đích | Chặn hay đặt | Vì sao |
| --- | --- | --- | --- | --- |
| `svp-deny-leave-organization` | SCP | root | `organizations:LeaveOrganization` | account rời org thì thoát mọi policy và organization trail |
| `svp-protect-cloudtrail` | SCP | root | `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`, `PutInsightSelectors` | không account thành viên nào tắt hay đổi được trail, kể cả trail của riêng nó |
| `svp-deny-other-regions` | SCP | root | mọi action ngoài danh sách dịch vụ toàn cục (`NotAction`) khi `aws:RequestedRegion` không phải `ap-southeast-1`, `us-east-1` | tài nguyên ở region không ai xem thì tốn tiền mà không thấy; script quét sót của buổi chỉ đọc hai region này |
| `svp-protect-baseline` | SCP | root | đổi S3 Block Public Access cấp account, EBS mã hoá mặc định và key mặc định, Config, GuardDuty, Security Hub, bật, tắt Inspector (trừ request ECR gọi thay người gọi), Access Analyzer (cả tạo analyzer), rule EventBridge và role `svp-security-*`, IAM của `OrganizationAccountAccessRole`, CMK EBS (tag `Stack=security-baseline`, alias `alias/svp-ebs`); bật Macie, Detective, Security Lake, Audit Manager, đăng ký Shield Advanced | baseline bảo mật chỉ đổi qua Terraform chạy từ management, dịch vụ bảo mật tính tiền mà lab không dùng không bật được bằng một cú bấm; miễn đúng `OrganizationAccountAccessRole` |
| `svp-deny-iam-users` | SCP | root | `iam:CreateUser`, `CreateAccessKey`, `CreateLoginProfile`, `UpdateLoginProfile` trên `arn:aws:iam::*:user/*` | người vào account qua IAM Identity Center, không qua IAM user hay access key dài hạn |
| `svp-prod-guardrails` | SCP | OU `Prod` | Spot qua `ec2:RunInstances` (`ec2:InstanceMarketType` = `spot`), `RequestSpotInstances`, `RequestSpotFleet` | prd chạy on-demand |
| `svp-data-perimeter` | RCP | root | S3, SQS, KMS, Secrets Manager, STS: principal ngoài org, dịch vụ AWS thay tài nguyên ngoài org, request không TLS | dữ liệu và credential không tới được ai ngoài org |
| `svp-ec2-baseline` | declarative EC2 | root | IMDSv2 bắt buộc (hop 1), không đọc tag qua metadata, chặn chia sẻ public AMI mới và mọi snapshot EBS public, tắt serial console | thiết lập EC2 an toàn không phụ thuộc từng launch template |
| `svp-tags` | tag policy | root | hoa thường và giá trị được phép của `Project`, `Env`, `ManagedBy`, `Stack`, `Backup`; enforce cho `ec2`, `eks`, `kms` | tag phân bổ chi phí, điều kiện theo tag (`ProtectEbsKey`) và selection của Backup policy chỉ đúng khi tag đúng |
| `svp-backup-prd`, `svp-backup-stg` | Backup policy | OU `Prod`, OU `NonProd` | plan `svp-<env>` ở `ap-southeast-1`, rule `daily` vào vault `svp-<env>`, copy sang vault `svp-<env>-copy` của `svp-backup`, selection theo tag `Backup=daily` | admin của account env đọc được plan, không sửa, không xoá được; bản copy nằm ngoài account env |

- **Chỉ `Deny` ở SCP và RCP:** `FullAWSAccess`, `RCPFullAWSAccess` AWS gắn sẵn vẫn cho phép những gì IAM cho; hai loại này chỉ lấy bớt. Cả
  hai không áp lên management account
  ([AWS: loại policy](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies.html)); declarative và tag policy có áp,
  nên management cũng không launch được IMDSv1 hay gắn bốn khoá tag với giá trị khác.
- **Miễn trừ:** chỉ `svp-protect-baseline` miễn một principal, `OrganizationAccountAccessRole` (chỉ management assume được, root
  `aws/baseline` áp qua nó). SCP khác không miễn principal nào: việc cần làm ngoài guardrail thì làm từ management, nơi SCP không áp.
- **`svp-deny-iam-users` không phủ root user:** task `IAMCreateRootUserPassword` của `sts:AssumeRoot` cần `iam:CreateLoginProfile` trên
  `arn:aws:iam::<id>:root`, ARN này không khớp `user/*`.
- **Spot qua Karpenter:** `ec2:CreateFleet` không có khoá `ec2:InstanceMarketType` cho instance, nên SCP không chặn được; chặn đó là NodePool prd
  on-demand.
- **Declarative EC2** theo
  [EC2 policy syntax](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ec2_syntax.html) (đọc
  2026-11-19): khoá, giá trị là chuỗi của trang đó, `instance_metadata_defaults` đặt đủ năm trường như ví dụ đầy đủ của trang.
  Hop limit `1`, dưới mức 2 trang đó khuyên cho container đọc IMDS: pod lấy credential qua EKS Pod Identity chứ không qua role của node,
  nên không cần với tới IMDS; node EKS, Karpenter và bastion cũng đặt `1`.
- **RCP** theo mẫu identity perimeter của AWS
  ([data-perimeter-policy-examples](https://github.com/aws-samples/data-perimeter-policy-examples/tree/main/resource_control_policies)):
  principal dịch vụ AWS được miễn ở statement principal; statement dịch vụ chỉ xét khi request có `aws:SourceAccount`; không ngoại lệ riêng
  nào khác. Đăng nhập liên kết (`AssumeRoleWithSAML` của Identity Center, `AssumeRoleWithWebIdentity`) và `sts:AssumeRoot` không nằm trong
  statement principal. RCP không đổi quyền của service-linked role. Bảng đối chiếu từng luồng ở phụ lục ADR-0059.
- **Inspector** (statement `ProtectInspector`: `inspector2:Enable`, `inspector2:Disable`, trừ request có `aws:ViaAWSService` `true`): bấm
  "Get started" ở console của account thành viên là bật Inspector cho riêng account đó, tính tiền, ngoài Terraform (account có
  `inspector_ecr` `off` hay region `us-east-1`). Hai đường Terraform không bị chặn. Một: root `aws/accounts/<env>` (module `registry`) đổi
  cấu hình quét của registry giữa Enhanced và Basic bằng role admin của env, và ECR gọi `Enable`, `Disable` của Inspector bằng quyền của
  người gọi ([ECR: quyền IAM của enhanced
  scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning-enhanced-iam.html), đọc 2026-11-19: principal bật quét
  phải được gọi API Inspector), tức request forward access session, luôn có `aws:ViaAWSService` `true`
  ([IAM: FAS](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_forward_access_sessions.html), đọc 2026-11-19). Cái giá: theo
  principal không tách được đường này khỏi nút bật Enhanced ở console ECR, nên nút đó cũng qua; nó chỉ bật quét ECR, và plan của
  `aws/accounts/<env>` thấy cấu hình lệch. Hai: root `aws/security` gọi `Enable`, `Disable` cho thành viên từ `svp-security` (delegated
  admin) bằng `OrganizationAccountAccessRole` của account đó, principal được miễn; SCP chỉ xét principal của account gắn nó, không xét
  account đích của lời gọi. Bật cho account mới vào tổ chức do chính Inspector làm, qua service-linked role, mà SCP không áp
  ([Organizations: SCP](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html), đọc 2026-11-19:
  "SCPs do not affect any service-linked role"). Thành viên đã liên kết thì chỉ delegated admin tắt được Inspector
  ([Inspector: delegated admin và thành viên](https://docs.aws.amazon.com/inspector/latest/user/admin-member-relationship.html), đọc
  2026-11-19); `Disable` vẫn chặn cho account chưa liên kết và cho chính `svp-security`.
- **Dịch vụ bảo mật lab không dùng** (statement `DenyUnusedSecurityServices`): lệnh mà nút bật trên console gọi, mỗi dịch vụ tính tiền
  cho cả account khi đã bật: `macie2:EnableMacie` (Macie), `detective:CreateGraph` (Detective), `securitylake:CreateDataLake` (Security
  Lake), `auditmanager:RegisterAccount` (Audit Manager), `shield:CreateSubscription` (Shield Advanced: phí tháng từ $3 000, cam kết một
  năm, tự gia hạn; [Shield pricing](https://aws.amazon.com/shield/pricing/), đọc 2026-11-19). Không chặn thêm: `guardduty:CreateDetector`
  (delegated admin đã bật detector ở cả hai region được phép, mỗi region một detector, `DeleteDetector` đã chặn),
  `securityhub:EnableSecurityHub` (cấu hình tập trung của delegated admin giữ trạng thái), Config (`PutConfigurationRecorder` đã chặn),
  Firewall Manager (chỉ management chỉ định được admin, SCP không áp lên management).
- **Access Analyzer** (statement `ProtectAccessAnalyzer`): chặn cả `CreateAnalyzer`. Analyzer unused access tính tiền theo mỗi IAM role,
  user mỗi tháng, analyzer external access miễn phí ([Access Analyzer pricing](https://aws.amazon.com/iam/access-analyzer/pricing/), đọc
  2026-11-19), nhưng `CreateAnalyzer` không có khoá điều kiện theo loại analyzer, nên chặn mọi loại. Analyzer `ORGANIZATION` do root
  `aws/security` tạo từ `svp-security` bằng `OrganizationAccountAccessRole`, principal được miễn.
- **Không chặn** tạo, xoá plan Malware Protection, flow log, logging WAF: buổi tạo và gỡ chúng. Test kiểm không SCP nào chặn chúng.
- **Danh sách dịch vụ toàn cục** chép nguyên văn `NotAction` của mẫu AWS "Deny access to AWS based on the requested AWS Region"
  ([Control Tower: Region deny](https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html)): IAM,
  Organizations, STS, Route 53, CloudFront, WAF, Budgets, Support, IAM Identity Center (`sso:*`)… gọi qua endpoint `us-east-1` hay toàn cục dù
  người gọi làm ở region nào. AWS thêm dịch vụ toàn cục mới thì cập nhật danh sách từ trang đó.
- **`us-east-1` được phép** vì AWS chỉ phục vụ ở đó chứng chỉ ACM và web ACL WAF của CloudFront, cùng IAM Identity Center của org.
- **Cỡ và số lượng** theo [AWS Organizations quotas](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html):
  policy viết bằng `jsonencode` (không khoảng trắng), test kiểm cỡ theo loại và số SCP, RCP mỗi đích.
- **Backup policy:** mỗi policy một plan `svp-<env>`, một rule `daily` (`cron(0 18 * * ? *)` UTC, start window 60 phút, completion window
  180 phút, không continuous backup), một selection `svp-<env>-tagged` và một `copy_actions`. Retention (ngày) ở `local.backup_retention_days`,
  vault env và bản copy: prd 35 và 35, stg 2 và 2. Mọi retention ≥ 2 ngày: bản trước còn tới khi bản kế tiếp hoàn tất muộn nhất (24 giờ cộng hai
  cửa sổ, 28 giờ), nên lúc nào cũng có một bản hoàn tất; test kiểm retention × 24 ≥ 24 + (hai cửa sổ) / 60 cho cả hai env, cả vault env lẫn
  bản copy.
- **Selection** nhận đúng hai mẫu ARN, DB instance RDS (`arn:aws:rds:*:*:db:*`) và bucket S3 (`arn:aws:s3:::*`), có tag `Backup=daily`:
  snapshot RDS kế thừa tag qua `copy_tags_to_snapshot` nhưng ARN `…:snapshot:…` không khớp. Role là
  `arn:aws:iam::$account:role/svp-<env>-backup`: `$account` là account thành viên chạy plan. Đích copy chéo account phải ghi id thật, nên module nhận `backup_account_id`.
- **Policy type** declarative EC2, tag policy và Backup policy phải bật ở tổ chức trước (`enabled_policy_types` của `aws/org`); module không bật.
- **Đổi đích** là thay `aws_organizations_policy_attachment` (khoá `for_each` giữ nguyên), không tạo lại policy.

Test (`make test DIRS=aws/modules/org-policies`, provider giả) đọc lại JSON gửi lên Organizations: tập policy theo loại và đích, chỉ `Deny`,
cỡ, statement và action của từng SCP, miễn trừ đúng một role ở `svp-protect-baseline` (thêm request dịch vụ AWS gọi thay ở
`ProtectInspector`), điều kiện của RCP, thiết lập declarative, khoá và giá trị của tag policy; plan, rule, lịch, hai cửa sổ, retention và
bất đẳng thức retention, vault, copy, selection của hai Backup policy; validation của các id.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_organizations_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy) | resource |
| [aws_organizations_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| backup\_account\_id | The account svp-backup (12 digits), whose vaults svp-<env>-copy receive the copy of every recovery point of the backup policies. | `string` | n/a | yes |
| nonprod\_ou\_id | The organizational unit (ou-...) of the non-production accounts, which the backup policy of stg is attached to. | `string` | n/a | yes |
| organization\_id | The id of the organization (o-...), the only one whose principals and services the resource control policy lets reach member account resources. | `string` | n/a | yes |
| prod\_ou\_id | The organizational unit (ou-...) of the production accounts, which the production guardrails are attached to. | `string` | n/a | yes |
| root\_id | The root of the organization (r-...): every policy but the production guardrails is attached here, so it applies to every member account (and, for the declarative and tag policies, to the management account too). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| policy\_ids | Id of each policy of the organization, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions, protect-baseline, deny-iam-users, prod-guardrails, data-perimeter, ec2-baseline, tags, backup-prd, backup-stg). |
<!-- END_TF_DOCS -->
