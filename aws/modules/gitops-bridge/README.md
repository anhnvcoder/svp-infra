# Module `gitops-bridge`

Tính mọi giá trị của bootstrap GitOps trên một cluster EKS theo mẫu GitOps Bridge: cluster Secret của Argo CD, ApplicationSet
`svp-bootstrap`, release Argo CD, AppProject, namespace có Pod Security, địa chỉ API và commit bootstrap. Module không có resource hay
data source của provider nào: root [`aws/gitops/<env>`](../../gitops/README.md) đọc nguồn và áp, nên `terraform test` kiểm mọi giá trị
bằng mock provider, không cần cluster (`make test DIRS=aws/modules/gitops-bridge`). Lý do và luồng ở
[chương 13. GitOps](../../../docs/handbook/13-gitops.md).

## Pod Security của namespace

Output `namespaces` từ chối plan khi một namespace không mang đủ nhãn `enforce`, `audit`, `warn` kèm `-version` dạng `v1.<minor>`, hay
mang mức khác `restricted`; lỗi nêu tên namespace sai. Ngoại lệ duy nhất là các namespace của biến `privileged_namespaces` (mặc định
`istio-system`), được mang `privileged`: ztunnel và istio-cni của Istio ambient đổi mạng của node và pod (`NET_ADMIN`, `SYS_ADMIN`, chạy
root, `hostPath`), mức thấp hơn không nhận. Danh sách khớp các mục `podSecurity: privileged` dưới `platformNamespaces` của
[`platforms/eks/svp-cluster.yaml`](https://github.com/anhnvcoder/svp-gitops/blob/main/platforms/eks/svp-cluster.yaml) và chart
`svp-cluster`; thêm namespace vào đó thì thêm vào biến trong cùng thay đổi, không nới mức của namespace khác.

## Ví dụ

Lời gọi trong `aws/gitops/stg/main.tf` (nội dung file từ `data "http"`, namespace từ `data "helm_template"`), giá trị placeholder:

```hcl
module "gitops_bridge" {
  source = "../../modules/gitops-bridge"

  env                         = "stg"
  node_arch                   = "arm64"
  cluster_values              = { name = "svp-stg", region = "ap-southeast-1" } # every key of the cluster.* contract
  cluster_endpoint            = "https://<id>.gr7.ap-southeast-1.eks.amazonaws.com"
  api_server_url              = "https://127.0.0.1:6444"
  telegram_chat_id            = ""
  main_commit                 = "<sha of main of svp-gitops>"
  env_charts                  = "<envs/stg/charts.yaml>"
  require_pinned_revision     = false
  argocd_bootstrap            = "<argocd/bootstrap.json>"
  argocd_values               = ["<base/argo-cd.yaml>", "<platforms/eks/argo-cd.yaml>"]
  app_projects                = "<argocd/project.yaml>"
  svp_cluster_values_template = "<platforms/eks/svp-cluster.values.tpl>"
  namespace_manifests         = ["<namespace argocd>", "<namespaces of the project>"]
}
```

## Tham chiếu

- [Chương 13. GitOps](../../../docs/handbook/13-gitops.md): ranh giới Terraform và Argo CD, commit bootstrap, chart `resources` và
  `platform-values`.
- [README của `svp-gitops`](https://github.com/anhnvcoder/svp-gitops#hợp-đồng-giá-trị-cluster): bảng khoá của hợp đồng `cluster.*`.
- [ADR-0050](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0050-bash-to-standard-tools.md) §1: chọn GitOps Bridge.

<!-- markdownlint-disable MD033 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| api\_server\_url | Where the providers reach the API instead of cluster\_endpoint: the local end of a tunnel, https on 127.0.0.1 at the port of the tunnel. null reaches cluster\_endpoint itself. | `string` | `null` | no |
| app\_projects | Content of argocd/project.yaml of svp-gitops at the bootstrap commit: AppProject svp and the emptied AppProject default, applied as they are. | `string` | n/a | yes |
| argocd\_bootstrap | Content of argocd/bootstrap.json of svp-gitops at the bootstrap commit: repository, chart, version and namespace of the release of Argo CD. | `string` | n/a | yes |
| argocd\_values | Values files of the release of Argo CD at the bootstrap commit, in order: the file argocd\_bootstrap names, then platforms/eks/argo-cd.yaml. | `list(string)` | n/a | yes |
| cluster\_endpoint | URL of the Kubernetes API server (output cluster\_endpoint of the env root). Its host is the TLS server name either way. | `string` | n/a | yes |
| cluster\_values | Values of the cluster.* contract (output cluster\_values of the env root): annotation svp.io/cluster-values of the cluster Secret, value cluster of the root Application. Exactly the keys of the contract, each of its kind; externalSecretsRoles names the role of the SecretStore of each of five namespaces. | `any` | n/a | yes |
| env | Environment the cluster runs: label svp.io/env of the cluster Secret, value env of the root Application, its directory under envs/ of svp-gitops. | `string` | n/a | yes |
| env\_charts | Content of the charts.yaml of the env under envs/ of svp-gitops at main\_commit. Its optional key gitopsRevision is the bootstrap commit; without it the bootstrap commit is main\_commit. | `string` | n/a | yes |
| main\_commit | Commit of branch main of svp-gitops when the plan runs (GitHub REST API, media type application/vnd.github.sha). | `string` | n/a | yes |
| namespace\_manifests | Namespaces rendered from templates/namespaces.yaml of chart svp-cluster (helm template output, one or more documents each): namespace argocd, and the namespaces of the project and of the platform charts. Each must enforce, audit and warn Pod Security restricted, or privileged for a namespace of privileged\_namespaces. | `list(string)` | n/a | yes |
| node\_arch | Architecture of the nodes: label svp.io/node-arch of the cluster Secret, value nodeArch of the root Application. | `string` | n/a | yes |
| privileged\_namespaces | Namespaces that may enforce, audit and warn Pod Security privileged instead of restricted, as chart svp-cluster of svp-gitops names them with podSecurity: privileged. istio-system by default: ztunnel and istio-cni of Istio ambient change the network of the node and its pods. | `list(string)` | <pre>[<br/>  "istio-system"<br/>]</pre> | no |
| require\_pinned\_revision | Refuse to plan when the charts.yaml of the env under envs/ holds no gitopsRevision, instead of taking main\_commit. | `bool` | n/a | yes |
| svp\_cluster\_values\_template | Content of platforms/eks/svp-cluster.values.tpl of svp-gitops at the bootstrap commit: the template chart argocd/apps renders on value cluster into the valuesObject of Application svp-cluster. | `string` | n/a | yes |
| telegram\_chat\_id | Telegram chat that also gets the root's failed syncs and Degraded health (annotation svp.io/telegram-chat-id of the cluster Secret); empty sends the commit status only. Not in a committed file. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| app\_projects\_release | Release of chart resources holding AppProject svp and the emptied AppProject default as argocd/project.yaml writes them. Applied with take\_ownership: argocd-server creates AppProject default at its start. |
| argocd\_namespace\_values | Values for a render of templates/namespaces.yaml of chart svp-cluster that yields namespace argocd alone. |
| argocd\_release | Release of Argo CD: repository, chart, version and namespace of argocd/bootstrap.json, values of argocd\_values in order. |
| bootstrap\_revision | Commit of svp-gitops the bootstrap reads Argo CD, its values and the AppProjects at: gitopsRevision of the charts.yaml of the env under envs/, or main\_commit without it. |
| cluster\_secret | Name, namespace, labels and data of the cluster Secret of Argo CD (its annotations: cluster\_secret\_annotations). |
| cluster\_secret\_annotations | Annotations of the cluster Secret: svp.io/cluster-values (JSON of cluster\_values) and svp.io/telegram-chat-id. |
| gitops\_repository | GitHub repository of svp-gitops (owner/name), from which the root fetches the files of the bootstrap. |
| kubernetes\_host | Address of the Kubernetes API for the helm and kubernetes providers: api\_server\_url, or cluster\_endpoint without it. |
| namespaces | Namespace manifests by name, before Argo CD: argocd and those of the project and the platform charts, each with Pod Security restricted, or privileged for a namespace of privileged\_namespaces (istio-system, whose ztunnel and istio-cni change the network of the node). |
| platform\_values\_chart | Path of chart platform-values of this module, which prints what a template of platforms/eks/ of svp-gitops renders on value cluster, as chart argocd/apps renders it into the valuesObject of an Application. |
| resources\_chart | Path of chart resources of this module, which prints the manifests of value resources: the chart of app\_projects\_release and root\_release. |
| root\_release | Release of chart resources holding ApplicationSet svp-bootstrap, which makes Application svp-root. |
| svp\_cluster\_platform\_values | Values for chart platform-values: platforms/eks/svp-cluster.values.tpl and cluster\_values. What it prints is the valuesObject of Application svp-cluster, which Argo CD reads after its values files. |
| tls\_server\_name | Name the providers check the certificate of the API server against: the host of cluster\_endpoint, also through a tunnel. |
<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD033 -->
