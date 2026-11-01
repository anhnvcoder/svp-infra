################################################################################
# Values of Actions variables: an uncommitted github.auto.tfvars or TF_VAR_* (the repository is public)
################################################################################

variable "svp_gitops_app_client_id" {
  description = "Client ID of the GitHub App svp-gitops-promoter, read by the promote jobs of svp-backend as variable SVP_GITOPS_APP_CLIENT_ID of environment promote."
  type        = string
  # Not a credential, but the repository commits no value of a personal App; sensitive keeps it out of plan output.
  sensitive = true

  validation {
    condition     = trimspace(var.svp_gitops_app_client_id) != ""
    error_message = "svp_gitops_app_client_id must not be empty: write it from the variable on GitHub (gh api repos/anhnvcoder/svp-backend/environments/promote/variables/SVP_GITOPS_APP_CLIENT_ID --jq .value)."
  }
}

variable "svp_web_app_client_id" {
  description = "Client ID of the GitHub App svp-web-promoter, read by the promote job of svp-frontend as variable SVP_WEB_APP_CLIENT_ID of environment promote."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.svp_web_app_client_id) != ""
    error_message = "svp_web_app_client_id must not be empty: write it from the variable on GitHub (gh api repos/anhnvcoder/svp-frontend/environments/promote/variables/SVP_WEB_APP_CLIENT_ID --jq .value)."
  }
}
