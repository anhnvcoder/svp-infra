# What the GitOps bootstrap root applies, from inputs written here: the cluster Secret (labels, annotations), the root
# ApplicationSet, the release of Argo CD, the AppProjects, the namespaces with their Pod Security labels and the
# address of the API; then one plan per rule with a value that only that rule rejects. The module holds no resource of
# any provider; the mock AWS provider is there because make test requires one in every test file.
#
# cluster_values below holds every key of the cluster.* contract (the output cluster_values of the env roots), written
# here on purpose rather than read from another repository: a key added to the contract is added here too.

mock_provider "aws" {}

variables {
  env              = "stg"
  node_arch        = "arm64"
  cluster_endpoint = "https://0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"

  cluster_values = {
    name          = "svp-stg"
    region        = "ap-southeast-1"
    vpcId         = "vpc-00000000000000000"
    vpcCidr       = "10.0.0.0/16"
    serviceCidr   = "172.20.0.0/16"
    dbCidrs       = ["10.0.48.0/24", "10.0.49.0/24"]
    domain        = "stg.aws.svp.example"
    hostedZoneId  = "Z0123456789ABCDEFGHIJ"
    acmeEmail     = "acme@svp.example"
    rdsAddress    = "svp-stg.000000000000.ap-southeast-1.rds.amazonaws.com"
    uploadsBucket = "svp-stg-uploads-111111111111-ap-southeast-1"
    mediaBucket   = "svp-stg-media-111111111111-ap-southeast-1"
    mediaDomain   = "d000000000000.cloudfront.net"
    s3Cidrs       = ["198.51.100.0/24", "203.0.113.0/24"]
    externalSecretsRoles = {
      svp      = "arn:aws:iam::111111111111:role/svp-stg-external-secrets-svp"
      svp-data = "arn:aws:iam::111111111111:role/svp-stg-external-secrets-svp-data"
      svp-obs  = "arn:aws:iam::111111111111:role/svp-stg-external-secrets-svp-obs"
      keda     = "arn:aws:iam::111111111111:role/svp-stg-external-secrets-keda"
      argocd   = "arn:aws:iam::111111111111:role/svp-stg-external-secrets-argocd"
    }
  }

  main_commit             = "1111111111111111111111111111111111111111"
  env_charts              = "revision: 2222222222222222222222222222222222222222\npodSecurityVersion: v1.36\n"
  require_pinned_revision = false

  argocd_bootstrap = "{\"name\":\"argocd\",\"namespace\":\"argocd\",\"repo\":\"https://argoproj.github.io/argo-helm\",\"chart\":\"argo-cd\",\"version\":\"10.10.5\",\"values\":\"base/argo-cd.yaml\"}"
  argocd_values    = ["dex:\n  enabled: false\n", "notifications:\n  enabled: true\n"]

  app_projects = "# AppProject svp.\napiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: svp\n  namespace: argocd\nspec:\n  sourceRepos:\n    - https://github.com/anhnvcoder/svp-gitops.git\n---\n# AppProject default, emptied.\napiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: default\n  namespace: argocd\nspec:\n  sourceRepos: []\n"

  # Two lines of platforms/eks/svp-cluster.values.tpl, a Go template the root renders with Helm.
  svp_cluster_values_template = "{{- $c := .Values.cluster }}\nnodeSubnet: {{ $c.vpcCidr | quote }}\n"

  # helm template output of templates/namespaces.yaml: namespace argocd alone, then the project's and a platform's.
  namespace_manifests = [
    join("\n", [
      "---",
      "# Source: svp-cluster/templates/namespaces.yaml",
      "apiVersion: v1",
      "kind: Namespace",
      "metadata:",
      "  name: argocd",
      "  labels:",
      "    pod-security.kubernetes.io/enforce: restricted",
      "    pod-security.kubernetes.io/enforce-version: v1.36",
      "    pod-security.kubernetes.io/warn: restricted",
      "    pod-security.kubernetes.io/warn-version: v1.36",
      "    pod-security.kubernetes.io/audit: restricted",
      "    pod-security.kubernetes.io/audit-version: v1.36",
      "",
    ]),
    join("\n", [
      "---",
      "# Source: svp-cluster/templates/namespaces.yaml",
      "apiVersion: v1",
      "kind: Namespace",
      "metadata:",
      "  name: svp",
      "  labels:",
      "    pod-security.kubernetes.io/enforce: restricted",
      "    pod-security.kubernetes.io/enforce-version: v1.36",
      "    pod-security.kubernetes.io/warn: restricted",
      "    pod-security.kubernetes.io/warn-version: v1.36",
      "    pod-security.kubernetes.io/audit: restricted",
      "    pod-security.kubernetes.io/audit-version: v1.36",
      "    svp-gateway-routes: \"true\"",
      "---",
      "# Source: svp-cluster/templates/namespaces.yaml",
      "apiVersion: v1",
      "kind: Namespace",
      "metadata:",
      "  name: keda",
      "  labels:",
      "    pod-security.kubernetes.io/enforce: restricted",
      "    pod-security.kubernetes.io/enforce-version: v1.36",
      "    pod-security.kubernetes.io/warn: restricted",
      "    pod-security.kubernetes.io/warn-version: v1.36",
      "    pod-security.kubernetes.io/audit: restricted",
      "    pod-security.kubernetes.io/audit-version: v1.36",
      "",
    ]),
  ]

  # Same as the second document above, enforcing baseline.
  baseline_namespace = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp\n  labels:\n    pod-security.kubernetes.io/enforce: baseline\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n"
}

run "stg" {
  command = plan

  # Cluster Secret: what the cluster generator selects and reads.
  assert {
    condition     = output.cluster_secret.name == "in-cluster" && output.cluster_secret.namespace == "argocd"
    error_message = "The cluster Secret must be argocd/in-cluster."
  }

  assert {
    condition = output.cluster_secret.labels == {
      "argocd.argoproj.io/secret-type" = "cluster"
      "svp.io/env"                     = "stg"
      "svp.io/platform"                = "eks"
      "svp.io/node-arch"               = "arm64"
    }
    error_message = "The cluster Secret must carry the labels secret-type cluster, svp.io/env, svp.io/platform eks and svp.io/node-arch, nothing else."
  }

  assert {
    condition     = output.cluster_secret.data.server == "https://kubernetes.default.svc" && jsondecode(output.cluster_secret.data.config) == { tlsClientConfig = { insecure = false } }
    error_message = "The cluster Secret must name the in-cluster API server and check its certificate."
  }

  assert {
    condition     = output.cluster_secret_annotations["svp.io/cluster-values"] == jsonencode(var.cluster_values)
    error_message = "Annotation svp.io/cluster-values must be the JSON of cluster_values, every key of the contract."
  }

  assert {
    condition     = jsondecode(output.cluster_secret_annotations["svp.io/cluster-values"]).externalSecretsRoles.argocd == "arn:aws:iam::111111111111:role/svp-stg-external-secrets-argocd"
    error_message = "Annotation svp.io/cluster-values must carry externalSecretsRoles."
  }

  assert {
    condition     = output.cluster_secret_annotations["svp.io/telegram-chat-id"] == ""
    error_message = "Without telegram_chat_id, annotation svp.io/telegram-chat-id must be empty (commit status only)."
  }

  # Root: ApplicationSet svp-bootstrap making svp-root.
  assert {
    condition     = output.root_release.name == "svp-bootstrap" && output.root_release.namespace == "argocd"
    error_message = "The root release must be argocd/svp-bootstrap."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].kind == "ApplicationSet" && yamldecode(output.root_release.values[0]).resources[0].metadata.name == "svp-bootstrap"
    error_message = "The root release must hold ApplicationSet svp-bootstrap."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].spec.template.metadata.name == "svp-root"
    error_message = "The ApplicationSet must make Application svp-root."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].spec.template.metadata.labels == { "svp.io/notify" = "root" }
    error_message = "svp-root must carry label svp.io/notify=root, which the subscriptions of Argo CD Notifications select."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].spec.template.spec.source == { repoURL = "https://github.com/anhnvcoder/svp-gitops.git", targetRevision = "refs/heads/main", path = "argocd/root" }
    error_message = "svp-root must read chart argocd/root of svp-gitops at refs/heads/main."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].spec.generators[0].clusters.selector.matchExpressions == [{ key = "svp.io/env", operator = "Exists" }]
    error_message = "The cluster generator must select the cluster Secrets that carry label svp.io/env."
  }

  assert {
    condition     = yamldecode(output.root_release.values[0]).resources[0].spec.syncPolicy.preserveResourcesOnDeletion == true && !can(yamldecode(output.root_release.values[0]).resources[0].spec.template.metadata.finalizers)
    error_message = "svp-root must get no finalizer, so deleting the ApplicationSet does not cascade."
  }

  assert {
    condition     = strcontains(yamldecode(output.root_release.values[0]).resources[0].spec.templatePatch, "cluster: {{ index .metadata.annotations \"svp.io/cluster-values\" | fromYaml | toJson }}")
    error_message = "The template patch must give svp-root value cluster from annotation svp.io/cluster-values."
  }

  # The API: the endpoint itself.
  assert {
    condition     = output.kubernetes_host == var.cluster_endpoint
    error_message = "Without api_server_url the providers must reach cluster_endpoint."
  }

  assert {
    condition     = output.tls_server_name == "0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"
    error_message = "The TLS server name must be the host of cluster_endpoint."
  }

  # Namespaces before Argo CD, each with Pod Security restricted.
  assert {
    condition     = toset(keys(output.namespaces)) == toset(["argocd", "svp", "keda"])
    error_message = "Every rendered namespace must be applied: argocd, the project's, the platform's."
  }

  assert {
    condition = alltrue([for n in ["argocd", "svp"] : alltrue([for m in ["enforce", "audit", "warn"] :
      output.namespaces[n].metadata.labels["pod-security.kubernetes.io/${m}"] == "restricted" &&
      output.namespaces[n].metadata.labels["pod-security.kubernetes.io/${m}-version"] == "v1.36"
    ])])
    error_message = "Namespace argocd and the project's namespace must enforce, audit and warn Pod Security restricted v1.36."
  }

  assert {
    condition     = yamldecode(output.argocd_namespace_values) == { namespaces = [], platformNamespaces = [{ name = "argocd" }] }
    error_message = "The render of namespace argocd must name argocd alone."
  }

  # The values of the render of the project's namespaces end with the valuesObject of Application svp-cluster: its
  # platform template rendered on every key of cluster_values.
  assert {
    condition     = yamldecode(output.svp_cluster_platform_values).template == var.svp_cluster_values_template
    error_message = "Chart platform-values must get platforms/eks/svp-cluster.values.tpl as it is."
  }

  assert {
    condition     = yamldecode(output.svp_cluster_platform_values).cluster == yamldecode(jsonencode(var.cluster_values))
    error_message = "Chart platform-values must get value cluster with every key of cluster_values."
  }

  assert {
    condition     = endswith(output.platform_values_chart, "/charts/platform-values")
    error_message = "The platform template must be rendered with chart platform-values of the module."
  }

  # Argo CD and the AppProjects, at main as the plan sees it.
  assert {
    condition     = output.bootstrap_revision == "1111111111111111111111111111111111111111"
    error_message = "Without gitopsRevision the bootstrap commit must be main_commit."
  }

  assert {
    condition = (
      output.argocd_release.repository == "https://argoproj.github.io/argo-helm" && output.argocd_release.chart == "argo-cd" &&
      output.argocd_release.version == "10.10.5" && output.argocd_release.namespace == "argocd" && output.argocd_release.name == "argocd" &&
      output.argocd_release.values == var.argocd_values
    )
    error_message = "The release of Argo CD must take repository, chart, version and namespace from argocd/bootstrap.json and the values files in order."
  }

  assert {
    condition     = [for p in yamldecode(output.app_projects_release.values[0]).resources : p.metadata.name] == ["svp", "default"]
    error_message = "The AppProjects must be svp and default, in the order of argocd/project.yaml."
  }

  assert {
    condition     = yamldecode(output.app_projects_release.values[0]).resources[1].spec == { sourceRepos = [] }
    error_message = "AppProject default must be applied as argocd/project.yaml writes it."
  }
}

run "prd" {
  command = plan

  variables {
    env                     = "prd"
    api_server_url          = "https://127.0.0.1:6443"
    env_charts              = "revision: 2222222222222222222222222222222222222222\npodSecurityVersion: v1.36\ngitopsRevision: 3333333333333333333333333333333333333333\n"
    require_pinned_revision = true
    telegram_chat_id        = "-1001234567890"
  }

  assert {
    condition     = output.kubernetes_host == "https://127.0.0.1:6443"
    error_message = "With api_server_url the providers must reach the local end of the tunnel."
  }

  assert {
    condition     = output.tls_server_name == "0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"
    error_message = "Through the tunnel the TLS server name must still be the host of cluster_endpoint."
  }

  assert {
    condition     = output.bootstrap_revision == "3333333333333333333333333333333333333333"
    error_message = "With gitopsRevision the bootstrap commit must be that commit, not main."
  }

  assert {
    condition     = output.cluster_secret.labels["svp.io/env"] == "prd"
    error_message = "Label svp.io/env must be the environment."
  }

  assert {
    condition     = output.cluster_secret_annotations["svp.io/telegram-chat-id"] == "-1001234567890"
    error_message = "Annotation svp.io/telegram-chat-id must be telegram_chat_id."
  }
}

run "unknown_env" {
  command = plan

  variables {
    env = "dev"
  }

  expect_failures = [var.env]
}

run "unknown_node_arch" {
  command = plan

  variables {
    node_arch = "x86_64"
  }

  expect_failures = [var.node_arch]
}

run "cluster_value_missing" {
  command = plan

  variables {
    cluster_values = { for k, v in var.cluster_values : k => v if k != "externalSecretsRoles" }
  }

  expect_failures = [var.cluster_values]
}

run "cluster_value_extra" {
  command = plan

  variables {
    cluster_values = merge(var.cluster_values, { extra = "x" })
  }

  expect_failures = [var.cluster_values]
}

run "cluster_value_wrong_kind" {
  command = plan

  variables {
    cluster_values = merge(var.cluster_values, { dbCidrs = "10.0.48.0/24" })
  }

  expect_failures = [var.cluster_values]
}

run "cluster_value_number" {
  command = plan

  variables {
    cluster_values = merge(var.cluster_values, { region = 1 })
  }

  expect_failures = [var.cluster_values]
}

run "external_secrets_role_missing" {
  command = plan

  variables {
    cluster_values = merge(var.cluster_values, { externalSecretsRoles = { for k, v in var.cluster_values.externalSecretsRoles : k => v if k != "argocd" } })
  }

  expect_failures = [var.cluster_values]
}

run "api_server_not_loopback" {
  command = plan

  variables {
    api_server_url = "https://10.0.0.10:443"
  }

  expect_failures = [var.api_server_url]
}

run "pinned_revision_missing" {
  command = plan

  variables {
    require_pinned_revision = true
  }

  expect_failures = [var.env_charts]
}

run "pinned_revision_not_a_commit" {
  command = plan

  variables {
    env_charts = "revision: 2222222222222222222222222222222222222222\ngitopsRevision: main\n"
  }

  expect_failures = [var.env_charts]
}

run "main_commit_not_a_commit" {
  command = plan

  variables {
    main_commit = "main"
  }

  expect_failures = [var.main_commit]
}

run "telegram_chat_not_a_number" {
  command = plan

  variables {
    telegram_chat_id = "@svp"
  }

  expect_failures = [var.telegram_chat_id]
}

run "namespace_not_restricted" {
  command = plan

  variables {
    namespace_manifests = [var.namespace_manifests[0], var.baseline_namespace]
  }

  expect_failures = [output.namespaces]
}

run "argocd_namespace_missing" {
  command = plan

  variables {
    namespace_manifests = [var.namespace_manifests[1]]
  }

  expect_failures = [output.namespaces]
}

run "argocd_from_another_chart" {
  command = plan

  variables {
    argocd_bootstrap = "{\"name\":\"argocd\",\"namespace\":\"argocd\",\"repo\":\"https://charts.svp.example\",\"chart\":\"argo-cd\",\"version\":\"10.10.5\",\"values\":\"base/argo-cd.yaml\"}"
  }

  expect_failures = [output.argocd_release]
}

run "app_project_missing" {
  command = plan

  variables {
    app_projects = "apiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: svp\n  namespace: argocd\n"
  }

  expect_failures = [output.app_projects_release]
}
