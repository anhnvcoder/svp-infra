# Security groups come from the EKS module: the cluster security group and the node security group shared by every node.
# With the VPC CNI, pods take secondary addresses of the node's network interfaces, so the node security group also
# filters traffic to pods; NetworkPolicy (the network policy agent of the VPC CNI) narrows it further per pod.

# Always on, from the module: TCP 443 between node and cluster (both ways), TCP 10250 from the cluster (kubelet; also
# the webhook port of cert-manager and of the Prometheus operator), TCP/UDP 53 between nodes (CoreDNS).

# The recommended rules stay on: from the cluster TCP 10251 (metrics-server of the EKS add-on), 4443 (metrics-server of
# older releases), 6443 (KEDA), 8443 (Karpenter webhook) and 9443 (webhooks of the AWS Load Balancer Controller, Kyverno
# and KEDA); between nodes TCP 1025-65535; all egress (image pulls through the NAT gateway, AWS APIs). A webhook or
# aggregated API on a port outside these lists would time out until a rule for it is added here.

# Added here, from the cluster: TCP 15017 (istiod; its injection and validation webhooks call Service port 443, which
# targets 15017 on the pod). Mesh traffic between nodes (HBONE 15008, xDS 15012) already falls in 1025-65535.

# Design notes: docs/handbook/10-eks.md.
locals {
  node_security_group_enable_recommended_rules = true

  node_security_group_additional_rules = {
    ingress_cluster_istiod_webhook = {
      description                   = "Cluster API to istiod webhooks"
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      source_cluster_security_group = true
    }
  }
}
