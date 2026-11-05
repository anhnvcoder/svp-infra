output "bootstrap_revision" {
  description = "Commit of svp-gitops Argo CD, its values and the AppProjects were read at (gitopsRevision of envs/<env>/charts.yaml, or main at plan time)."
  value       = module.gitops_bridge.bootstrap_revision
}
