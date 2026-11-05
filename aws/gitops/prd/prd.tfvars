# Values of the GitOps bootstrap of prd. Committed; it holds no personal value. Every plan, apply and destroy of this
# root passes it, with the tunnel of aws/envs/prd open (README.md of aws/gitops).

# Graviton nodes (node_instance_types of aws/envs/prd/prd.tfvars).
node_arch = "arm64"

# prd bootstraps only at the commit of svp-gitops stg has run: gitopsRevision of envs/prd/charts.yaml, which the
# promote pull request writes. Without it the plan stops.
require_pinned_revision = true

# The API's public endpoint is off: the providers reach the private endpoint through the SSM tunnel of aws/envs/prd
# (api_tunnel_command, local port 6443); the TLS server name is still the host of cluster_endpoint.
api_server_url = "https://127.0.0.1:6443"
