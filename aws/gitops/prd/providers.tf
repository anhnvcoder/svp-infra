provider "aws" {
  region = var.region

  # The provider refuses to touch any other account; data.aws_caller_identity (main.tf) makes it check before the
  # state of the env root is read. The account is the env's own: profile anhnv-<env>, and TF_VAR_account_id set in the
  # command from SVP_AWS_<ENV>_ACCOUNT_ID.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      Env       = local.env
      ManagedBy = "terraform"
      Stack     = local.env
    }
  }
}

# Both providers reach the API at the same host and check its certificate against the same name, from the module:
# cluster_endpoint, or api_server_url (the tunnel) when it is set, with the endpoint's host as TLS server name. The token
# comes from aws eks get-token with the profile of the env, fetched again whenever it expires.
locals {
  cluster_ca = base64decode(data.terraform_remote_state.env.outputs.cluster_certificate_authority_data)
  get_token = [
    "eks", "get-token", "--cluster-name", data.terraform_remote_state.env.outputs.cluster_name,
    "--region", var.region, "--output", "json",
  ]
}

provider "kubernetes" {
  host                   = module.gitops_bridge.kubernetes_host
  tls_server_name        = module.gitops_bridge.tls_server_name
  cluster_ca_certificate = local.cluster_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.get_token
    env         = { AWS_PROFILE = local.aws_profile }
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.gitops_bridge.kubernetes_host
    tls_server_name        = module.gitops_bridge.tls_server_name
    cluster_ca_certificate = local.cluster_ca

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.get_token
      env         = { AWS_PROFILE = local.aws_profile }
    }
  }
}
