# Values of the GitOps bootstrap of an EKS cluster after the GitOps Bridge pattern: Terraform installs Argo CD and hands
# it the cluster's metadata as labels and annotations of a cluster Secret, from which an ApplicationSet makes the root
# Application. This module holds no resource of any provider: it computes what the root aws/gitops/<env> applies
# (namespaces, the release of Argo CD, AppProjects, the cluster Secret, the ApplicationSet), so terraform test checks
# every value of it with a mock provider and no cluster.

locals {
  platform = "eks"

  gitops_repository = "anhnvcoder/svp-gitops"
  # Read over HTTPS without credentials, as sourceRepos of AppProject svp names it.
  gitops_repo_url  = "https://github.com/${local.gitops_repository}.git"
  argocd_namespace = "argocd"

  # The bootstrap commit: what Argo CD, its values and the AppProjects are read at. A pinned environment takes the
  # commit its promote pull request wrote; any other takes main as the plan sees it.
  pinned_revision    = lookup(yamldecode(var.env_charts), "gitopsRevision", null)
  bootstrap_revision = coalesce(local.pinned_revision, trimspace(var.main_commit))

  # The providers reach the API at api_server_url when it is set (the local end of a tunnel), and check the server
  # certificate against the endpoint's host, which the certificate names, in both cases.
  api_host = trimprefix(var.cluster_endpoint, "https://")

  # yamldecode reads one document and refuses an empty one: documents without a line of YAML (blank lines and comments
  # only, such as what comes before the first ---) are left out.
  namespace_docs = [
    for d in flatten([for m in var.namespace_manifests : split("\n---", "\n${m}")]) : yamldecode(d)
    if length(regexall("(?m)^[^#\\s]", d)) > 0
  ]
  namespaces = { for n in local.namespace_docs : n.metadata.name => n }

  project_docs = [for d in split("\n---", "\n${var.app_projects}") : yamldecode(d) if length(regexall("(?m)^[^#\\s]", d)) > 0]

  argocd_bootstrap = jsondecode(var.argocd_bootstrap)

  # Pod Security labels every namespace must carry, as chart svp-cluster writes them.
  pod_security_modes = ["enforce", "audit", "warn"]
}

################################################################################
# Cluster Secret: the cluster's metadata, read by the cluster generator of the ApplicationSet
################################################################################

locals {
  cluster_secret = {
    name      = "in-cluster"
    namespace = local.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "svp.io/env"                     = var.env
      "svp.io/platform"                = local.platform
      "svp.io/node-arch"               = var.node_arch
    }
    # The cluster Argo CD runs in, through its in-cluster service account.
    data = {
      name   = "in-cluster"
      server = "https://kubernetes.default.svc"
      config = jsonencode({ tlsClientConfig = { insecure = false } })
    }
  }

  # JSON is YAML: the ApplicationSet reads it back with fromYaml.
  cluster_secret_annotations = {
    "svp.io/cluster-values"   = jsonencode(var.cluster_values)
    "svp.io/telegram-chat-id" = var.telegram_chat_id
  }
}

################################################################################
# Root: ApplicationSet svp-bootstrap, which makes Application svp-root from the cluster Secret
################################################################################

locals {
  # Go template of the ApplicationSet controller, merged into the template below: values env, platform, nodeArch from
  # the labels of the cluster Secret, cluster from its annotation, and the Telegram subscriptions of Argo CD
  # Notifications only when the Secret names a chat.
  template_patch = <<-EOT
    {{- $chat := index .metadata.annotations "svp.io/telegram-chat-id" }}
    {{- if $chat }}
    metadata:
      annotations:
        notifications.argoproj.io/subscribe.on-sync-failed.telegram: {{ $chat | toJson }}
        notifications.argoproj.io/subscribe.on-health-degraded.telegram: {{ $chat | toJson }}
    {{- end }}
    spec:
      source:
        helm:
          valuesObject:
            env: {{ index .metadata.labels "svp.io/env" | toJson }}
            platform: {{ index .metadata.labels "svp.io/platform" | toJson }}
            nodeArch: {{ index .metadata.labels "svp.io/node-arch" | toJson }}
            cluster: {{ index .metadata.annotations "svp.io/cluster-values" | fromYaml | toJson }}
  EOT

  root = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ApplicationSet"
    metadata = {
      name      = "svp-bootstrap"
      namespace = local.argocd_namespace
    }
    spec = {
      goTemplate        = true
      goTemplateOptions = ["missingkey=error"]
      # Every cluster Secret that carries an environment: the one of this cluster.
      generators = [{
        clusters = {
          selector = {
            matchExpressions = [{ key = "svp.io/env", operator = "Exists" }]
          }
        }
      }]
      # No finalizer on svp-root: deleting the ApplicationSet at the end of a session deletes svp-root without
      # cascading to what it made.
      syncPolicy = {
        preserveResourcesOnDeletion = true
      }
      template = {
        metadata = {
          name = "svp-root"
          # What the subscriptions of Argo CD Notifications select: the root alone reports one commit status per commit.
          labels = { "svp.io/notify" = "root" }
          # The root applies its child Applications client-side; a server-side dry run would not see a field deleted
          # from them.
          annotations = { "argocd.argoproj.io/compare-options" = "ServerSideDiff=false" }
        }
        spec = {
          project = "svp"
          source = {
            repoURL        = local.gitops_repo_url
            targetRevision = "refs/heads/main"
            path           = "argocd/root"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = local.argocd_namespace
          }
          syncPolicy = {
            automated = { prune = true, selfHeal = true }
            retry = {
              limit   = 10
              backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
            }
          }
        }
      }
      templatePatch = local.template_patch
    }
  }
}
