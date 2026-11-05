# Module `org-policies`

Ba service control policy (SCP) của tổ chức, gắn vào một OU (root `aws/org` truyền OU `Workloads`, nơi có account `svp-stg`, `svp-prd`).
SCP không bao giờ áp lên management account
([AWS: SCP](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)), nên account workload nằm trong
OU này còn phần quản trị ở management.

| Policy | Chặn | Vì sao |
| --- | --- | --- |
| `svp-deny-leave-organization` | `organizations:LeaveOrganization` | account rời org thì thoát mọi SCP và organization trail |
| `svp-protect-cloudtrail` | `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`, `PutInsightSelectors` | không account workload nào tắt hay đổi được trail, kể cả trail của riêng nó |
| `svp-deny-other-regions` | mọi action ngoài danh sách dịch vụ toàn cục (`NotAction`) khi `aws:RequestedRegion` không phải `ap-southeast-1`, `us-east-1` | tài nguyên ở region không ai xem thì tốn tiền mà không thấy; script quét sót của buổi chỉ đọc hai region này |

- **Chỉ `Deny`:** policy `FullAWSAccess` AWS gắn sẵn vẫn cho phép những gì IAM cho; ba policy này chỉ lấy bớt. Test kiểm mọi statement là
  `Deny`.
- **Danh sách dịch vụ toàn cục** chép nguyên văn `NotAction` của mẫu AWS "Deny access to AWS based on the requested AWS Region"
  ([Control Tower: Region deny](https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html), đọc
  2026-11-05; cùng mẫu ở "Example SCPs: general" của AWS Organizations): IAM, Organizations, STS, Route 53, CloudFront, WAF, Budgets,
  Support, IAM Identity Center (`sso:*`)… gọi qua endpoint `us-east-1` hay toàn cục dù người gọi làm ở region nào, chặn theo region sẽ làm
  hỏng chúng. AWS thêm dịch vụ toàn cục mới thì cập nhật danh sách từ trang đó.
- **`us-east-1` được phép** vì AWS chỉ phục vụ ở đó chứng chỉ ACM và web ACL WAF của CloudFront, cùng IAM Identity Center của org.
- **Không miễn principal nào** (mẫu AWS có `ArnNotLike aws:PrincipalARN` cho role quản trị): việc cần làm ngoài hai region thì làm từ
  management account.
- Cỡ tối đa một SCP là 10.240 ký tự, mỗi OU gắn tối đa 10 SCP
  ([AWS Organizations quotas](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html), đọc 2026-11-05);
  policy viết bằng `jsonencode` (không khoảng trắng), test kiểm cỡ.

Test (`make test DIRS=aws/modules/org-policies`, provider giả) đọc lại JSON gửi lên Organizations: action bị chặn, hai region được phép, dịch
vụ toàn cục được lọt, không wildcard của dịch vụ theo region, không `Allow`, không điều kiện miễn principal, mọi policy gắn vào `target_id`.

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
| target\_id | The organizational unit (ou-...) every policy of this module is attached to. Service control policies never apply to the management account, so the workload accounts sit in this OU. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| policy\_ids | Id of each service control policy, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions). |
<!-- END_TF_DOCS -->
