output "cluster_name" {
  description = "Name of the EKS cluster: clusterName of the AWS Load Balancer Controller, txtOwnerId of ExternalDNS, aws eks update-kubeconfig --name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
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
