# Security groups come from the EKS module: one for the control plane's network interfaces (the cluster security
# group) and one shared by every node (the node security group). With the VPC CNI, pods take secondary addresses of
# the node's network interfaces, so the node security group also filters traffic to pods; Kubernetes NetworkPolicy
# (the network policy agent of the VPC CNI) narrows it further per pod.
#
# Always on, from the module:
#   cluster <- node          TCP 443    nodes and pods to the Kubernetes API
#   node    <- cluster       TCP 443    API server to webhooks on 443
#   node    <- cluster       TCP 10250  kubelet; also the webhook port of cert-manager and of the Prometheus operator
#   node    <- node          TCP/UDP 53 CoreDNS
#
# The recommended rules, kept on below:
#   node    <- cluster       TCP 10251  metrics-server of the EKS add-on (the API server calls it for the metrics API)
#   node    <- cluster       TCP 4443   metrics-server of older releases
#   node    <- cluster       TCP 6443   KEDA's metrics API server
#   node    <- cluster       TCP 8443   Karpenter's webhook
#   node    <- cluster       TCP 9443   webhooks of the AWS Load Balancer Controller, Kyverno and KEDA
#   node    <- node          TCP 1025-65535  pod to pod and node to node
#   node    -> anywhere      all        egress (image pulls through the NAT gateway, AWS APIs)
#
# A webhook or aggregated API on any other port would time out until a rule for it is added here. The AWS Load
# Balancer Controller adds the rules for the NLB's traffic and health checks itself, on the one security group of the
# node that carries the tag kubernetes.io/cluster/<name> (the node security group; the cluster primary security group
# that EKS creates is not attached to the nodes).
locals {
  node_security_group_enable_recommended_rules = true
}
