# Module `ssm-bastion`

Đường của máy người học tới endpoint private của API Kubernetes khi endpoint công khai tắt (env prd): AWS Systems Manager Session Manager
chuyển một cổng `127.0.0.1:<local_port>` của máy tới host của endpoint, cổng 443 (document `AWS-StartPortForwardingSessionToRemoteHost`), qua
một instance nhỏ trong subnet private. SSM agent trên instance tự mở kết nối ra ngoài (tới endpoint công khai của Systems Manager qua NAT
gateway), nên instance không nhận kết nối vào nào, không có khoá SSH, không có địa chỉ công khai; ai được mở phiên do IAM quyết, mỗi lần mở
phiên nằm trong CloudTrail. Token Kubernetes đi trong tunnel là của người học (`aws eks get-token`), không phải của role instance.

| Phần | Cấu hình |
| --- | --- |
| Instance | `t4g.nano` (Graviton), AMI Amazon Linux 2023 arm64 mới nhất lấy từ SSM parameter public `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` (image có sẵn SSM agent), không key pair, không IP công khai |
| Metadata | chỉ IMDSv2 (`http_tokens = required`), hop limit 1 |
| Đĩa | gp3 mã hoá (key mặc định `aws/ebs`) |
| Role | `<name>-ssm-bastion`, chỉ EC2 assume, chỉ managed policy `AmazonSSMManagedInstanceCore` |
| Security group | `<name>-ssm-bastion`: không luật vào; ra chỉ TCP 443 (Systems Manager, API). DNS của VPC, metadata, đồng bộ giờ đi tới địa chỉ link-local mà security group không lọc |
| Security group của API | thêm luật vào TCP 443 từ security group của bastion (`api_security_group_id`, output `cluster_security_group_id` của module `eks`) |

Ngoại lệ trivy `AWS-0104` (ra 443 tới mọi địa chỉ): endpoint công khai của Systems Manager (`ssm`, `ssmmessages`, `ec2messages`) không có
prefix list do AWS công bố; interface endpoint của ba dịch vụ giữ traffic trong VPC nhưng tính phí theo giờ mỗi dịch vụ mỗi AZ.
`Scope: every environment`.

## Dùng

Máy người học cần AWS CLI và Session Manager plugin. Hai output là lệnh viết sẵn (có profile và region), chạy bằng `eval`:

- `tunnel_command`: mở tunnel, chạy tới khi dừng (Ctrl-C); để nó chạy trong một terminal riêng.
- `kubeconfig_command`: `aws eks update-kubeconfig` (context `<cluster_name>`), rồi `kubectl config set-cluster` đổi server của cluster đó thành
  `https://127.0.0.1:<local_port>` và `tls-server-name` thành host của endpoint, nên `kubectl` vẫn kiểm chứng chỉ của API server theo tên thật.
  `kubectl` chạy được khi tunnel đang mở.

Cổng mặc định `6443` không trùng cluster k3d cục bộ (`6550`, `8443`); root GitOps của env dùng cùng cổng.

## Chi phí

`t4g.nano` theo giờ khi env chạy, cộng đĩa gp3 của AMI; Session Manager không tính phí. Số cụ thể ở phụ lục ADR của môi trường prd.

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
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.ssm_core](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.api_from_bastion](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account of the env (12 digits), part of the ARN of the cluster in kubeconfig\_command. | `string` | n/a | yes |
| api\_security\_group\_id | Security group on the network interfaces of the private endpoint of the Kubernetes API (output cluster\_security\_group\_id of the eks module). The module adds to it a rule that lets the instance in on 443. | `string` | n/a | yes |
| aws\_profile | AWS profile of the env's account on the learner's machine (anhnv-prd), written into the commands of the outputs. | `string` | n/a | yes |
| cluster\_endpoint | URL of the Kubernetes API server (output cluster\_endpoint of the eks module). With the public endpoint off, its host resolves inside the VPC to the private endpoint, which the instance forwards the tunnel to. | `string` | n/a | yes |
| cluster\_name | Name of the EKS cluster (output cluster\_name of the eks module): name and context of the kubeconfig entry. | `string` | n/a | yes |
| local\_port | Port on 127.0.0.1 of the learner's machine where the tunnel listens; the server of the kubeconfig entry and api\_server\_url of the GitOps root of the env use the same port. 6443 stays clear of the local k3d cluster (6550 and 8443). | `number` | `6443` | no |
| name | Name of the env's cluster (svp-prd): prefix of the names of the instance, its security group, IAM role and instance profile. | `string` | n/a | yes |
| region | Region of the env, written into the commands of the outputs. | `string` | n/a | yes |
| subnet\_id | Private subnet of the instance, one of output private\_subnet\_ids of the network module: it reaches Systems Manager through the NAT gateway of its zone and has no public address. | `string` | n/a | yes |
| vpc\_id | VPC of the cluster (output vpc\_id of the network module). | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| instance\_id | ID of the instance, the --target of an SSM session. |
| kubeconfig\_command | Command that adds the cluster to the kubeconfig under the context <cluster\_name>, served through the tunnel on 127.0.0.1:<local\_port> with the endpoint's host as TLS server name. Run it with eval; kubectl works while tunnel\_command runs. |
| security\_group\_id | Security group of the instance, which the API's security group lets in on 443. |
| tunnel\_command | Command that opens the tunnel: 127.0.0.1:<local\_port> of the learner's machine to the private endpoint of the Kubernetes API on 443, until it is stopped (Ctrl-C). Needs the Session Manager plugin of the AWS CLI. |
<!-- END_TF_DOCS -->
