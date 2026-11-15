################################################################################
# Values of Actions variables: an uncommitted github.auto.tfvars or TF_VAR_* (the repository is public)
################################################################################

variable "svp_gitops_app_client_id" {
  description = "Client ID of the GitHub App svp-gitops-promoter, read by the promote jobs of svp-backend as variable SVP_GITOPS_APP_CLIENT_ID of environments promote and promote-prd."
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

variable "svp_release_app_client_id" {
  description = "Client ID of the GitHub App svp-release-please, read by the release job of svp-backend as variable SVP_RELEASE_APP_CLIENT_ID of environment release."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.svp_release_app_client_id) != ""
    error_message = "svp_release_app_client_id must not be empty: make github-app APP=svp-release-please writes it, or write it from the variable on GitHub (gh api repos/anhnvcoder/svp-backend/environments/release/variables/SVP_RELEASE_APP_CLIENT_ID --jq .value)."
  }
}

variable "terraform_plan_envs" {
  description = "Environments whose accounts plan.yml of svp-infra plans on pull requests (Actions variable SVP_TF_PLAN_ENVS, a JSON array). Add an environment only once its plan role is applied and its secrets of environment terraform-plan are set."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([for env in var.terraform_plan_envs : contains(["stg", "prd"], env)]) && (
      length(distinct(var.terraform_plan_envs)) == length(var.terraform_plan_envs)
    )
    error_message = "terraform_plan_envs holds only stg and prd, each at most once."
  }
}
