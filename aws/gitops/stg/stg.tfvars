# Values of the GitOps bootstrap of stg. Committed; it holds no personal value. Every plan, apply and destroy of this
# root passes it (README.md of aws/gitops).

# Graviton nodes (node_instance_types of aws/envs/stg/stg.tfvars).
node_arch = "arm64"

# stg bootstraps at main as the plan sees it: its envs/stg/charts.yaml never holds gitopsRevision.
require_pinned_revision = false

# The API's public endpoint is open to the learner's address: no tunnel, api_server_url stays null.
