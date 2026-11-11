# Values of the GitOps bootstrap of stg. Committed; it holds no personal value. Every plan, apply and destroy of this
# root passes it, with the tunnel of aws/envs/stg open (README.md of aws/gitops).

# Graviton nodes: system_node_instance_type of aws/modules/eks and the arm64 NodePool of chart svp-cluster.
node_arch = "arm64"

# stg bootstraps at main as the plan sees it: its envs/stg/charts.yaml never holds gitopsRevision.
require_pinned_revision = false

# The API's public endpoint is off: the providers reach the private endpoint through the SSM tunnel of aws/envs/stg
# (api_tunnel_command, local port 6444); the TLS server name is still the host of cluster_endpoint.
api_server_url = "https://127.0.0.1:6444"
