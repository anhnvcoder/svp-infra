# Values of the cluster.* contract: the GitOps bootstrap root aws/gitops/<env> reads this map from the state of this
# root and hands it to the root Application, from which the charts of the platform take what depends on the account
# or the session. A key added here is added to the templates of svp-gitops and to the fixture of the check as well.
# Sensitive because it carries acme_email; terraform output -json cluster_values prints it.
output "cluster_values" {
  description = "Values of the cluster.* contract of the GitOps root (read with terraform output -json cluster_values)."
  sensitive   = true

  value = {
    name          = module.eks.cluster_name
    region        = var.region
    vpcId         = module.network.vpc_id
    vpcCidr       = module.network.vpc_cidr
    serviceCidr   = module.eks.cluster_service_cidr
    dbCidrs       = module.network.private_subnet_cidrs
    domain        = var.domain
    hostedZoneId  = var.hosted_zone_id
    acmeEmail     = var.acme_email
    rdsAddress    = module.rds.address
    uploadsBucket = module.media.uploads_bucket
    mediaBucket   = module.media.media_bucket
    mediaDomain   = module.media.media_domain
    s3Cidrs       = sort(data.aws_ip_ranges.s3.cidr_blocks)
    # IAM role of the SecretStore of each namespace that reads Secrets Manager.
    externalSecretsRoles = module.external_secrets.roles
  }

  precondition {
    condition     = var.domain == local.zone_name || endswith(var.domain, ".${local.zone_name}")
    error_message = "domain must be the name of the zone given by hosted_zone_id (e.g. stg.aws.svp.example for stg, aws.svp.example for prd, the web at the apex) or a name inside it (e.g. www.stg.aws.svp.example)."
  }
}

locals {
  # Route 53 returns the zone name with its trailing dot.
  zone_name = trimsuffix(data.aws_route53_zone.env.name, ".")
}

output "rds_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret in which RDS keeps the master password. Not a secret itself: the session script reads the password from it right before it loads the pg-superuser source of the cluster."
  value       = module.rds.master_user_secret_arn
}

# Read by the GitOps bootstrap root aws/gitops/<env> through terraform_remote_state, for its helm and kubernetes
# providers.
output "cluster_name" {
  description = "Name of the EKS cluster (aws eks get-token --cluster-name)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Certificate authority of the Kubernetes API server, base64-encoded PEM."
  value       = module.eks.cluster_certificate_authority_data
}

output "kubeconfig_command" {
  description = "Command that adds the cluster to the kubeconfig under the context name the make targets of the code repository expect (CONTEXT=<name>). Run it with the AWS profile of the session."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}
