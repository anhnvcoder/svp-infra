# The public endpoint of the Kubernetes API is off here: the learner's machine reaches the private endpoint through a
# port forwarding session of Systems Manager to a bastion in a private subnet, and the GitOps root of the env through
# the same tunnel.
module "ssm_bastion" {
  source = "../../modules/ssm-bastion"

  name                  = local.name
  account_id            = var.account_id
  region                = var.region
  aws_profile           = "anhnv-${local.env}"
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.private_subnet_ids[0]
  cluster_name          = module.eks.cluster_name
  cluster_endpoint      = module.eks.cluster_endpoint
  api_security_group_id = module.eks.cluster_security_group_id
}

output "api_tunnel_command" {
  description = "Command that opens the tunnel to the Kubernetes API (127.0.0.1:6443 to the private endpoint on 443) and runs until stopped; run it with eval in a terminal of its own. Needs the Session Manager plugin of the AWS CLI."
  value       = module.ssm_bastion.tunnel_command
}
