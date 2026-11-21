# Plan of aws/gitops/<env> (stg and prd share this file) on the cluster aws/envs/<env> made, with nothing of the
# bootstrap in it yet. The state of the env root, the files of svp-gitops and the charts' renders are fakes: the
# namespaces are those of chart svp-cluster with platforms/eks/svp-cluster.yaml of svp-gitops (argocd first).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000004"
    }
  }
}

mock_provider "helm" {}
mock_provider "http" {}
mock_provider "kubernetes" {}

override_data {
  target = data.terraform_remote_state.env
  values = {
    outputs = {
      cluster_name                       = "svp-env"
      cluster_endpoint                   = "https://0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"
      cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg=="
      cluster_values = {
        name               = "svp-stg"
        region             = "ap-southeast-1"
        vpcId              = "vpc-00000000000000000"
        vpcCidr            = "10.0.0.0/16"
        serviceCidr        = "172.20.0.0/16"
        dbCidrs            = ["10.0.192.0/22", "10.0.196.0/22"]
        edgeCidrs          = ["10.0.240.0/23", "10.0.242.0/23"]
        edgeTargetGroupArn = "arn:aws:elasticloadbalancing:ap-southeast-1:000000000004:targetgroup/svp-stg-envoy/0123456789abcdef"
        domain             = "stg.aws.svp.example"
        rdsAddress         = "svp-stg.000000000000.ap-southeast-1.rds.amazonaws.com"
        kafkaBrokers       = "b-1.svpstg.abc123.c2.kafka.ap-southeast-1.amazonaws.com:9096,b-2.svpstg.abc123.c2.kafka.ap-southeast-1.amazonaws.com:9096"
        valkeyHost         = "master.svp-stg.abc123.apse1.cache.amazonaws.com"
        uploadsBucket      = "svp-stg-uploads-000000000004-ap-southeast-1"
        mediaBucket        = "svp-stg-media-000000000004-ap-southeast-1"
        mediaDomain        = "d000000000000.cloudfront.net"
        s3Cidrs            = ["198.51.100.0/24", "203.0.113.0/24"]
        externalSecretsRoles = {
          svp      = "arn:aws:iam::000000000004:role/svp-stg-external-secrets-svp"
          svp-data = "arn:aws:iam::000000000004:role/svp-stg-external-secrets-svp-data"
          svp-obs  = "arn:aws:iam::000000000004:role/svp-stg-external-secrets-svp-obs"
          keda     = "arn:aws:iam::000000000004:role/svp-stg-external-secrets-keda"
          argocd   = "arn:aws:iam::000000000004:role/svp-stg-external-secrets-argocd"
        }
        ecrRegistry    = "000000000004.dkr.ecr.ap-southeast-1.amazonaws.com"
        ampWorkspaceId = "ws-12345678-abcd-4ef0-9876-0123456789ab"
        ampEndpoint    = "https://aps-workspaces.ap-southeast-1.amazonaws.com/workspaces/ws-12345678-abcd-4ef0-9876-0123456789ab/"
        logGroup       = "/svp/stg/otel"
        grafanaUrl     = "https://g-abc123def4.grafana-workspace.ap-southeast-1.amazonaws.com"
        alarmTopicArn  = "arn:aws:sns:ap-southeast-1:000000000004:svp-stg-alarms"

        mediaconvertQueueArn    = "arn:aws:mediaconvert:ap-southeast-1:000000000004:queues/svp-stg"
        mediaconvertRoleArn     = "arn:aws:iam::000000000004:role/svp-stg-mediaconvert"
        transcodeEventsQueueUrl = "https://sqs.ap-southeast-1.amazonaws.com/000000000004/svp-stg-transcode-events"
      }
    }
  }
}

override_data {
  target = data.http.gitops_main
  values = {
    status_code   = 200
    response_body = "1111111111111111111111111111111111111111"
  }
}

override_data {
  target = data.http.env_charts
  values = {
    status_code   = 200
    response_body = "revision: 2222222222222222222222222222222222222222\ngitopsRevision: 3333333333333333333333333333333333333333\npodSecurityVersion: v1.36\n"
  }
}

override_data {
  target = data.http.env_overlay
  values = {
    status_code   = 404
    response_body = ""
  }
}

override_data {
  target = data.http.bootstrap_file["argocd/bootstrap.json"]
  values = {
    status_code   = 200
    response_body = "{\"name\":\"argocd\",\"namespace\":\"argocd\",\"repo\":\"https://argoproj.github.io/argo-helm\",\"chart\":\"argo-cd\",\"version\":\"10.10.5\",\"values\":\"base/argo-cd.yaml\"}"
  }
}

override_data {
  target = data.http.bootstrap_file["argocd/project.yaml"]
  values = {
    status_code   = 200
    response_body = "apiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: svp\n  namespace: argocd\n---\napiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: default\n  namespace: argocd\n"
  }
}

override_data {
  target = data.http.bootstrap_file["platforms/eks/argo-cd.yaml"]
  values = {
    status_code   = 200
    response_body = "notifications:\n  enabled: true\n"
  }
}

override_data {
  target = data.http.bootstrap_file["platforms/eks/svp-cluster.yaml"]
  values = {
    status_code   = 200
    response_body = "platformNamespaces: []\n"
  }
}

override_data {
  target = data.http.bootstrap_file["platforms/eks/svp-cluster.values.tpl"]
  values = {
    status_code   = 200
    response_body = "nodeSubnet: 10.0.0.0/16\n"
  }
}

override_data {
  target = data.http.argocd_values
  values = {
    status_code   = 200
    response_body = "dex:\n  enabled: false\n"
  }
}

override_data {
  target = data.helm_template.argocd_namespace
  values = {
    manifest = "---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: argocd\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n"
  }
}

override_data {
  target = data.helm_template.svp_cluster_platform_values
  values = {
    manifest = "nodeSubnet: 10.0.0.0/16\n"
  }
}

override_data {
  target = data.helm_template.project_namespaces
  values = {
    manifest = "---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp-data\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp-obs\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp-edge\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: svp-mesh\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: istio-system\n  labels:\n    pod-security.kubernetes.io/enforce: privileged\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: privileged\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: privileged\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: argo-rollouts\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: keda\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: kyverno\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: reloader\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n    pod-security.kubernetes.io/enforce-version: v1.36\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/warn-version: v1.36\n    pod-security.kubernetes.io/audit: restricted\n    pod-security.kubernetes.io/audit-version: v1.36\n"
  }
}

variables {
  account_id        = "000000000004"
  svp_cluster_chart = "/nonexistent/svp-cluster"
}

run "inventory" {
  command = plan
}
