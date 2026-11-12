output "cluster_name" {
  description = "Name of the EKS cluster: clusterName of the AWS Load Balancer Controller, aws eks update-kubeconfig --name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Certificate authority of the Kubernetes API server, base64-encoded PEM: cluster.certificate-authority-data of a kubeconfig, cluster_ca_certificate (after base64decode) of the helm and kubernetes providers."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_service_cidr" {
  description = "IPv4 range of Kubernetes Services, chosen by EKS when the cluster is created; the API server's Service takes its first address."
  value       = module.eks.cluster_service_cidr
}

output "node_security_group_id" {
  description = "Security group of every node and, with the VPC CNI, of every pod: the source a database security group lets in."
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Security group the module adds to the control plane's network interfaces."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Security group EKS creates for the cluster and attaches to the control plane's network interfaces."
  value       = module.eks.cluster_primary_security_group_id
}

output "karpenter_node_iam_role_name" {
  description = "IAM role of the nodes Karpenter launches: spec.role of the EC2NodeClass (Karpenter makes the instance profile from it)."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS queue of the interruption events Karpenter handles (Spot interruption, rebalance, health, state change): settings.interruptionQueue of the Karpenter chart."
  value       = module.karpenter.queue_name
}
