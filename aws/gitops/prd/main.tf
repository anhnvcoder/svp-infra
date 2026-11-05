locals {
  # Identity of this root, the only line of code the prd root changes: values differ in <env>.tfvars, the backend key
  # is given at init.
  env         = "prd"
  aws_profile = "anhnv-${local.env}"
}

# The account the provider checked against allowed_account_ids, whose state bucket holds the env root.
data "aws_caller_identity" "current" {}

# The cluster of the env root aws/envs/<env>, applied before this one.
data "terraform_remote_state" "env" {
  backend = "s3"

  config = {
    bucket = "svp-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
    key    = "aws/${local.env}/terraform.tfstate"
    region = var.region
  }
}

################################################################################
# svp-gitops, read over HTTPS at fixed commits (the repository is public)
################################################################################

locals {
  gitops_raw = "https://raw.githubusercontent.com/${module.gitops_bridge.gitops_repository}"
  main       = trimspace(data.http.gitops_main.response_body)
  bootstrap  = module.gitops_bridge.bootstrap_revision
}

# Commit of main when the plan runs; envs/<env>/ is read at it.
data "http" "gitops_main" {
  url             = "https://api.github.com/repos/${module.gitops_bridge.gitops_repository}/commits/main"
  request_headers = { Accept = "application/vnd.github.sha" }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GitHub did not return the commit of main of svp-gitops."
    }
  }
}

data "http" "env_file" {
  for_each = toset(["charts.yaml", "svp-cluster.yaml"])
  url      = "${local.gitops_raw}/${local.main}/envs/${local.env}/${each.key}"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "svp-gitops holds no ${self.url}."
    }
  }
}

# The bootstrap commit: gitopsRevision of envs/<env>/charts.yaml, or main without it.
data "http" "bootstrap_file" {
  for_each = toset([
    "argocd/bootstrap.json", "argocd/project.yaml", "platforms/eks/argo-cd.yaml", "platforms/eks/svp-cluster.yaml",
    "platforms/eks/svp-cluster.values.tpl",
  ])
  url = "${local.gitops_raw}/${local.bootstrap}/${each.key}"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "svp-gitops holds no ${self.url}."
    }
  }
}

# The values file argocd/bootstrap.json names.
data "http" "argocd_values" {
  url = "${local.gitops_raw}/${local.bootstrap}/${jsondecode(data.http.bootstrap_file["argocd/bootstrap.json"].response_body).values}"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "svp-gitops holds no ${self.url}."
    }
  }
}

################################################################################
# Namespaces with Pod Security restricted, from templates/namespaces.yaml of chart svp-cluster
################################################################################

# argocd alone, for Argo CD's first pod.
data "helm_template" "argocd_namespace" {
  name      = "svp-cluster"
  chart     = var.svp_cluster_chart
  show_only = ["templates/namespaces.yaml"]
  values    = [module.gitops_bridge.argocd_namespace_values]
}

# The valuesObject chart argocd/apps gives Application svp-cluster: platforms/eks/svp-cluster.values.tpl at the bootstrap
# commit rendered on cluster_values with Helm, as tpl renders it there.
data "helm_template" "svp_cluster_platform_values" {
  name   = "svp-cluster"
  chart  = module.gitops_bridge.platform_values_chart
  values = [module.gitops_bridge.svp_cluster_platform_values]
}

# The project's and the platform charts', with the values Application svp-cluster reads in the order Argo CD reads
# them (platforms/eks/ at the bootstrap commit, envs/<env>/ at main, the valuesObject last), so the first pods of wave 0
# already meet Pod Security. Helm renders the whole chart before show_only keeps one template, so every value a template
# of the chart requires must be there.
data "helm_template" "project_namespaces" {
  name      = "svp-cluster"
  chart     = var.svp_cluster_chart
  show_only = ["templates/namespaces.yaml"]
  values = [
    data.http.bootstrap_file["platforms/eks/svp-cluster.yaml"].response_body,
    data.http.env_file["svp-cluster.yaml"].response_body,
    # Holds acmeEmail of cluster_values.
    sensitive(data.helm_template.svp_cluster_platform_values.manifest),
  ]
}

module "gitops_bridge" {
  source = "../../modules/gitops-bridge"

  env                         = local.env
  node_arch                   = var.node_arch
  cluster_values              = data.terraform_remote_state.env.outputs.cluster_values
  cluster_endpoint            = data.terraform_remote_state.env.outputs.cluster_endpoint
  api_server_url              = var.api_server_url
  telegram_chat_id            = var.telegram_chat_id
  main_commit                 = local.main
  env_charts                  = data.http.env_file["charts.yaml"].response_body
  require_pinned_revision     = var.require_pinned_revision
  argocd_bootstrap            = data.http.bootstrap_file["argocd/bootstrap.json"].response_body
  argocd_values               = [data.http.argocd_values.response_body, data.http.bootstrap_file["platforms/eks/argo-cd.yaml"].response_body]
  app_projects                = data.http.bootstrap_file["argocd/project.yaml"].response_body
  svp_cluster_values_template = data.http.bootstrap_file["platforms/eks/svp-cluster.values.tpl"].response_body
  namespace_manifests         = [data.helm_template.argocd_namespace.manifest, data.helm_template.project_namespaces.manifest]
}

################################################################################
# Applied in this order: namespaces, Argo CD, AppProjects, cluster Secret, root
################################################################################

# Server-side apply under the field manager the bootstrap of the lab cluster uses: chart svp-cluster, synced by Argo CD
# later, applies the same labels to the project's namespaces and takes them over without a conflict.
resource "kubernetes_manifest" "namespace" {
  for_each = module.gitops_bridge.namespaces
  manifest = each.value

  field_manager {
    name = "svp-pod-security"
  }
}

# Argo CD does not manage itself: a change of version or values in svp-gitops reaches the cluster at the next apply.
resource "helm_release" "argocd" {
  name       = module.gitops_bridge.argocd_release.name
  namespace  = module.gitops_bridge.argocd_release.namespace
  repository = module.gitops_bridge.argocd_release.repository
  chart      = module.gitops_bridge.argocd_release.chart
  version    = module.gitops_bridge.argocd_release.version
  values     = module.gitops_bridge.argocd_release.values
  timeout    = 600

  depends_on = [kubernetes_manifest.namespace]
}

# The CRDs come with Argo CD above, so the AppProjects and the ApplicationSet go through Helm, which needs them only
# when it applies, not through kubernetes_manifest, which needs them at plan time.
resource "helm_release" "app_projects" {
  name      = module.gitops_bridge.app_projects_release.name
  namespace = module.gitops_bridge.app_projects_release.namespace
  chart     = module.gitops_bridge.resources_chart
  values    = module.gitops_bridge.app_projects_release.values
  # argocd-server has made the open AppProject default at its start.
  take_ownership = true

  depends_on = [helm_release.argocd]
}

resource "kubernetes_secret_v1" "cluster" {
  metadata {
    name        = module.gitops_bridge.cluster_secret.name
    namespace   = module.gitops_bridge.cluster_secret.namespace
    labels      = module.gitops_bridge.cluster_secret.labels
    annotations = module.gitops_bridge.cluster_secret_annotations
  }

  data = module.gitops_bridge.cluster_secret.data

  depends_on = [helm_release.app_projects]
}

resource "helm_release" "root" {
  name      = module.gitops_bridge.root_release.name
  namespace = module.gitops_bridge.root_release.namespace
  chart     = module.gitops_bridge.resources_chart
  values    = module.gitops_bridge.root_release.values

  depends_on = [kubernetes_secret_v1.cluster]
}
