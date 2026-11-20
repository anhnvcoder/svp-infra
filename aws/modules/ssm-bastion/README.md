# Module `ssm-bastion`

Đường của máy người học tới endpoint private của API Kubernetes: một instance `t4g.nano` trong subnet private, không cổng vào, không khoá
SSH, không IP công khai, role chỉ có `AmazonSSMManagedInstanceCore`; Session Manager chuyển `127.0.0.1:<local_port>` tới host của
endpoint, cổng 443. Module thêm rule cho security group của API nhận 443 từ bastion và xuất hai lệnh viết sẵn `tunnel_command`,
`kubeconfig_command`. Root `aws/envs/<env>` gọi module ở `ssm-bastion.tf`; cách dùng, phí và lý do ở chương
[09. Env và mạng](../../../docs/handbook/09-envs-network.md); test: `make test DIRS=aws/modules/ssm-bastion`.

## Ví dụ

Lời gọi trong `aws/envs/stg/ssm-bastion.tf`, giá trị là placeholder:

```hcl
module "ssm_bastion" {
  source = "../../modules/ssm-bastion"

  name                  = "svp-stg"
  account_id            = "000000000000"
  region                = "ap-southeast-1"
  aws_profile           = "anhnv-stg"
  vpc_id                = "vpc-<id>"
  subnet_id             = "subnet-<a>"
  cluster_name          = "svp-stg"
  cluster_endpoint      = "https://<id>.gr7.ap-southeast-1.eks.amazonaws.com"
  api_security_group_id = "sg-<cluster>"
  local_port            = 6444
}
```

## Tham chiếu

- [09. Env và mạng](../../../docs/handbook/09-envs-network.md): kịch bản mở tunnel rồi `kubectl`, mục Session Manager, vì sao không
  endpoint công khai.
- [ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md): API qua SSM port forwarding.

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
