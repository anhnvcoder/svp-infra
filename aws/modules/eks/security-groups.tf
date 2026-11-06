# Security groups come from the EKS module: the cluster security group and the node security group shared by every node.
# With the VPC CNI, pods take secondary addresses of the node's network interfaces, so the node security group also
# filters traffic to pods; NetworkPolicy (the network policy agent of the VPC CNI) narrows it further per pod.

# Always on, from the module: TCP 443 between node and cluster (both ways), TCP 10250 from the cluster (kubelet; also
# the webhook port of cert-manager and of the Prometheus operator), TCP/UDP 53 between nodes (CoreDNS).

# The recommended rules stay on: from the cluster TCP 10251 (metrics-server of the EKS add-on), 4443 (metrics-server of
# older releases), 6443 (KEDA), 8443 (Karpenter webhook) and 9443 (webhooks of the AWS Load Balancer Controller, Kyverno
# and KEDA); between nodes TCP 1025-65535; all egress (image pulls through the NAT gateway, AWS APIs). A webhook or
# aggregated API on a port outside both lists would time out until a rule for it is added here.

# Design notes: aws/modules/eks/README.md.
locals {
  node_security_group_enable_recommended_rules = true
}
