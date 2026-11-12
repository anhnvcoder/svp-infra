# Module `org-policies`

Mọi policy của AWS Organizations: sáu service control policy (SCP), một resource control policy (RCP), một declarative policy EC2 và một tag
policy. Root `aws/org` truyền ba id: root của org (`root_id`), OU `Prod` (`prod_ou_id`) và id tổ chức (`organization_id`, cho RCP). Mỗi policy
gắn đúng một đích: `svp-prod-guardrails` ở OU `Prod`, mọi policy khác ở root. Thiết kế và statement đủ:
[ADR-0059](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0059-org-structure-guardrails.md) và
[phụ lục](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0059-org-structure-guardrails.md).

| Policy | Loại | Đích | Chặn hay đặt | Vì sao |
| --- | --- | --- | --- | --- |
| `svp-deny-leave-organization` | SCP | root | `organizations:LeaveOrganization` | account rời org thì thoát mọi policy và organization trail |
| `svp-protect-cloudtrail` | SCP | root | `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`, `PutInsightSelectors` | không account thành viên nào tắt hay đổi được trail, kể cả trail của riêng nó |
| `svp-deny-other-regions` | SCP | root | mọi action ngoài danh sách dịch vụ toàn cục (`NotAction`) khi `aws:RequestedRegion` không phải `ap-southeast-1`, `us-east-1` | tài nguyên ở region không ai xem thì tốn tiền mà không thấy; script quét sót của buổi chỉ đọc hai region này |
| `svp-protect-baseline` | SCP | root | đổi S3 Block Public Access cấp account, EBS mã hoá mặc định và key mặc định, Config, GuardDuty, Security Hub, Access Analyzer, rule EventBridge và role `svp-security-*`, IAM của `OrganizationAccountAccessRole`, CMK EBS (tag `Stack=security-baseline`, alias `alias/svp-ebs`) | baseline bảo mật chỉ đổi qua Terraform chạy từ management; miễn đúng `OrganizationAccountAccessRole` |
| `svp-deny-iam-users` | SCP | root | `iam:CreateUser`, `CreateAccessKey`, `CreateLoginProfile`, `UpdateLoginProfile` trên `arn:aws:iam::*:user/*` | người vào account qua IAM Identity Center, không qua IAM user hay access key dài hạn |
| `svp-prod-guardrails` | SCP | OU `Prod` | Spot qua `ec2:RunInstances` (`ec2:InstanceMarketType` = `spot`), `RequestSpotInstances`, `RequestSpotFleet` | prd chạy on-demand |
| `svp-data-perimeter` | RCP | root | S3, SQS, KMS, Secrets Manager, STS: principal ngoài org, dịch vụ AWS thay tài nguyên ngoài org, request không TLS | dữ liệu và credential không tới được ai ngoài org |
| `svp-ec2-baseline` | declarative EC2 | root | IMDSv2 bắt buộc (hop 1), chặn chia sẻ public AMI mới và mọi snapshot EBS public, tắt serial console | thiết lập EC2 an toàn không phụ thuộc từng launch template |
| `svp-tags` | tag policy | root | hoa thường và giá trị được phép của `Project`, `Env`, `ManagedBy`, `Stack`; enforce cho `ec2`, `eks`, `kms` | tag phân bổ chi phí và điều kiện theo tag (`ProtectEbsKey`) chỉ đúng khi tag đúng |

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
- **RCP** theo mẫu identity perimeter của AWS
  ([data-perimeter-policy-examples](https://github.com/aws-samples/data-perimeter-policy-examples/tree/main/resource_control_policies)):
  principal dịch vụ AWS được miễn ở statement principal; statement dịch vụ chỉ xét khi request có `aws:SourceAccount`; không ngoại lệ riêng
  nào khác. Đăng nhập liên kết (`AssumeRoleWithSAML` của Identity Center, `AssumeRoleWithWebIdentity`) và `sts:AssumeRoot` không nằm trong
  statement principal. RCP không đổi quyền của service-linked role. Bảng đối chiếu từng luồng ở phụ lục ADR-0059.
- **Không chặn** tạo, xoá plan Malware Protection, flow log, logging WAF: buổi tạo và gỡ chúng. Test kiểm không SCP nào chặn chúng.
- **Danh sách dịch vụ toàn cục** chép nguyên văn `NotAction` của mẫu AWS "Deny access to AWS based on the requested AWS Region"
  ([Control Tower: Region deny](https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html)): IAM,
  Organizations, STS, Route 53, CloudFront, WAF, Budgets, Support, IAM Identity Center (`sso:*`)… gọi qua endpoint `us-east-1` hay toàn cục dù
  người gọi làm ở region nào. AWS thêm dịch vụ toàn cục mới thì cập nhật danh sách từ trang đó.
- **`us-east-1` được phép** vì AWS chỉ phục vụ ở đó chứng chỉ ACM và web ACL WAF của CloudFront, cùng IAM Identity Center của org.
- **Cỡ và số lượng** theo [AWS Organizations quotas](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html):
  policy viết bằng `jsonencode` (không khoảng trắng), test kiểm cỡ theo loại và số SCP, RCP mỗi đích.
- **Policy type** declarative EC2 và tag policy phải bật ở tổ chức trước (`enabled_policy_types` của `aws/org`); module không bật.
- **Đổi đích** là thay `aws_organizations_policy_attachment` (khoá `for_each` giữ nguyên), không tạo lại policy.

Test (`make test DIRS=aws/modules/org-policies`, provider giả) đọc lại JSON gửi lên Organizations: tập policy theo loại và đích, chỉ `Deny`,
cỡ, statement và action của từng SCP, miễn trừ đúng một role ở `svp-protect-baseline`, điều kiện của RCP, thiết lập declarative, khoá và giá trị
của tag policy, validation của ba id.

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
| organization\_id | The id of the organization (o-...), the only one whose principals and services the resource control policy lets reach member account resources. | `string` | n/a | yes |
| prod\_ou\_id | The organizational unit (ou-...) of the production accounts, which the production guardrails are attached to. | `string` | n/a | yes |
| root\_id | The root of the organization (r-...): every policy but the production guardrails is attached here, so it applies to every member account (and, for the declarative and tag policies, to the management account too). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| policy\_ids | Id of each policy of the organization, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions, protect-baseline, deny-iam-users, prod-guardrails, data-perimeter, ec2-baseline, tags). |
<!-- END_TF_DOCS -->
