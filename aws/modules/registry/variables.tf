variable "env" {
  description = "Environment of the account (stg, prd): names the KMS key alias/svp-<env>-ecr and the role svp-<env>-ecr-template."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "ci_roles" {
  description = "IAM roles GitHub Actions assumes through OIDC to copy releases into this registry, by role name. subject is the one sub claim the trust accepts (repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/<branch> or :environment:<name>); repositories are release repositories (svp-backend/gateway) or a whole group of them (svp-backend/*); delete adds ecr:BatchDeleteImage on them."
  type = map(object({
    subject      = string
    repositories = list(string)
    delete       = bool
  }))

  validation {
    condition     = alltrue([for name in keys(var.ci_roles) : can(regex("^svp-ci-ecr-[a-z0-9]+(-[a-z0-9]+)*$", name)) && length(name) <= 64])
    error_message = "Each key of ci_roles must be a role name svp-ci-ecr-<purpose> of lowercase letters, digits and dashes, at most 64 characters."
  }

  # One exact claim per role: no wildcard, and nothing but a branch ref or an environment after the repository.
  validation {
    condition = alltrue([for r in values(var.ci_roles) :
      can(regex("^repo:[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?:(ref:refs/heads/[A-Za-z0-9._/-]+|environment:[A-Za-z0-9._-]+)$", r.subject))
    ])
    error_message = "Each subject of ci_roles must be one GitHub OIDC sub claim without wildcards: repo:<owner>[@<id>]/<repo>[@<id>]:ref:refs/heads/<branch> or :environment:<name>."
  }

  validation {
    condition = alltrue([for r in values(var.ci_roles) :
      length(r.repositories) > 0 && length(distinct(r.repositories)) == length(r.repositories) &&
      alltrue([for repo in r.repositories : contains(local.ci_repository_choices, repo)])
    ])
    error_message = "Each repositories list of ci_roles must hold distinct release repositories of the module (e.g. svp-frontend/web) or groups of them (e.g. svp-backend/*), at least one."
  }
}
