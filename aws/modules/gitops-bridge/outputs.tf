################################################################################
# What the root reads before it applies anything
################################################################################

output "gitops_repository" {
  description = "GitHub repository of svp-gitops (owner/name), from which the root fetches the files of the bootstrap."
  value       = local.gitops_repository
}

output "bootstrap_revision" {
  description = "Commit of svp-gitops the bootstrap reads Argo CD, its values and the AppProjects at: gitopsRevision of the charts.yaml of the env under envs/, or main_commit without it."
  value       = local.bootstrap_revision
}

output "kubernetes_host" {
  description = "Address of the Kubernetes API for the helm and kubernetes providers: api_server_url, or cluster_endpoint without it."
  value       = coalesce(var.api_server_url, var.cluster_endpoint)
}

output "tls_server_name" {
  description = "Name the providers check the certificate of the API server against: the host of cluster_endpoint, also through a tunnel."
  value       = local.api_host
}

output "argocd_namespace_values" {
  description = "Values for a render of templates/namespaces.yaml of chart svp-cluster that yields namespace argocd alone."
  value = yamlencode({
    namespaces         = []
    platformNamespaces = [{ name = local.argocd_namespace }]
  })
}

output "platform_values_chart" {
  description = "Path of chart platform-values of this module, which prints what a template of platforms/eks/ of svp-gitops renders on value cluster, as chart argocd/apps renders it into the valuesObject of an Application."
  value       = "${path.module}/charts/platform-values"
}

output "svp_cluster_platform_values" {
  description = "Values for chart platform-values: platforms/eks/svp-cluster.values.tpl and cluster_values. What it prints is the valuesObject of Application svp-cluster, which Argo CD reads after its values files. Sensitive: cluster_values holds acmeEmail."
  value       = yamlencode({ template = var.svp_cluster_values_template, cluster = var.cluster_values })
  sensitive   = true
}

################################################################################
# What the root applies, in this order
################################################################################

output "namespaces" {
  description = "Namespace manifests by name, before Argo CD: argocd and those of the project and the platform charts, each with Pod Security restricted."
  value       = local.namespaces

  precondition {
    condition     = alltrue([for n in local.namespace_docs : n.apiVersion == "v1" && n.kind == "Namespace"])
    error_message = "namespace_manifests must hold Namespace manifests only (show_only templates/namespaces.yaml)."
  }

  precondition {
    condition     = contains(keys(local.namespaces), local.argocd_namespace)
    error_message = "namespace_manifests must hold namespace argocd."
  }

  precondition {
    condition = alltrue([for n in local.namespace_docs : alltrue([for m in local.pod_security_modes :
      try(n.metadata.labels["pod-security.kubernetes.io/${m}"] == "restricted", false) &&
      can(regex("^v1\\.[0-9]+$", n.metadata.labels["pod-security.kubernetes.io/${m}-version"]))
    ])])
    error_message = "Every namespace must enforce, audit and warn Pod Security restricted at a version v1.<minor>."
  }
}

output "argocd_release" {
  description = "Release of Argo CD: repository, chart, version and namespace of argocd/bootstrap.json, values of argocd_values in order."
  value = {
    name       = local.argocd_bootstrap.name
    namespace  = local.argocd_bootstrap.namespace
    repository = local.argocd_bootstrap.repo
    chart      = local.argocd_bootstrap.chart
    version    = local.argocd_bootstrap.version
    values     = var.argocd_values
  }

  precondition {
    condition = (
      try(local.argocd_bootstrap.repo, "") == "https://argoproj.github.io/argo-helm" &&
      try(local.argocd_bootstrap.chart, "") == "argo-cd" &&
      try(local.argocd_bootstrap.namespace, "") == local.argocd_namespace &&
      can(regex("^[a-z0-9-]+$", local.argocd_bootstrap.name)) &&
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", local.argocd_bootstrap.version))
    )
    error_message = "argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm at an exact version, in namespace argocd."
  }
}

output "resources_chart" {
  description = "Path of chart resources of this module, which prints the manifests of value resources: the chart of app_projects_release and root_release."
  value       = "${path.module}/charts/resources"
}

output "app_projects_release" {
  description = "Release of chart resources holding AppProject svp and the emptied AppProject default as argocd/project.yaml writes them. Applied with take_ownership: argocd-server creates AppProject default at its start."
  value = {
    name      = "svp-app-projects"
    namespace = local.argocd_namespace
    values    = [yamlencode({ resources = local.project_docs })]
  }

  precondition {
    condition = (
      toset([for p in local.project_docs : try(p.metadata.name, "")]) == toset(["svp", "default"]) &&
      length(local.project_docs) == 2 &&
      alltrue([for p in local.project_docs : p.kind == "AppProject" && try(p.metadata.namespace, "") == local.argocd_namespace])
    )
    error_message = "app_projects must hold exactly AppProjects svp and default, in namespace argocd."
  }
}

output "cluster_secret" {
  description = "Name, namespace, labels and data of the cluster Secret of Argo CD (its annotations: cluster_secret_annotations)."
  value       = local.cluster_secret
}

output "cluster_secret_annotations" {
  description = "Annotations of the cluster Secret: svp.io/cluster-values (JSON of cluster_values) and svp.io/telegram-chat-id. Sensitive: cluster_values holds acmeEmail."
  value       = local.cluster_secret_annotations
  sensitive   = true
}

output "root_release" {
  description = "Release of chart resources holding ApplicationSet svp-bootstrap, which makes Application svp-root."
  value = {
    name      = "svp-bootstrap"
    namespace = local.argocd_namespace
    values    = [yamlencode({ resources = [local.root] })]
  }
}
