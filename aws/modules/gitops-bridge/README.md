# Module `gitops-bridge`

Giá trị của bootstrap GitOps trên một cluster EKS theo mẫu GitOps Bridge: Terraform cài Argo CD và đưa metadata của cluster vào label,
annotation của cluster Secret của Argo CD; ApplicationSet `svp-bootstrap` đọc Secret đó và tạo Application gốc `svp-root`. Module không có
resource hay data source của provider nào: nó chỉ tính những gì root [`aws/gitops/<env>`](../../gitops/README.md) áp vào cluster, nên
`terraform test` kiểm được mọi giá trị với mock provider, không cần cluster.

## Đầu vào và đầu ra

| Đầu vào (root đọc) | Đầu ra (root áp) |
| --- | --- |
| `env`, `node_arch`, `cluster_values` (output của root env), `telegram_chat_id` | `cluster_secret`, `cluster_secret_annotations`: Secret `argocd/in-cluster` |
| `cluster_endpoint`, `api_server_url` | `kubernetes_host`, `tls_server_name`: địa chỉ API của hai provider `helm`, `kubernetes` |
| `main_commit`, `env_charts` (`envs/<env>/charts.yaml` ở `main`), `require_pinned_revision` | `bootstrap_revision`: commit bootstrap B |
| `argocd_bootstrap` (`argocd/bootstrap.json` ở B), `argocd_values` | `argocd_release`: release Argo CD |
| `app_projects` (`argocd/project.yaml` ở B) | `app_projects_release`: AppProject `svp`, `default` |
| `svp_cluster_values_template` (`platforms/eks/svp-cluster.values.tpl` ở B), `cluster_values` | `svp_cluster_platform_values`, `platform_values_chart`: `valuesObject` của Application `svp-cluster` |
| `namespace_manifests` (render `templates/namespaces.yaml` của chart `svp-cluster`) | `namespaces`, `argocd_namespace_values` |
| | `root_release`: ApplicationSet `svp-bootstrap`; `resources_chart`, `gitops_repository` |

- **Commit bootstrap B:** `gitopsRevision` của `envs/<env>/charts.yaml` khi có, không thì `main_commit` (commit của `main` lúc plan).
  `require_pinned_revision = true` (prd) làm plan dừng khi khoá vắng. Chỉ Argo CD, values của nó và AppProject đọc ở B; `svp-root` luôn theo
  dõi `refs/heads/main`.
- **Cluster Secret** `in-cluster` (namespace `argocd`, server `https://kubernetes.default.svc`): label `argocd.argoproj.io/secret-type: cluster`,
  `svp.io/env`, `svp.io/platform: eks`, `svp.io/node-arch`; annotation `svp.io/cluster-values` (JSON của `cluster_values`) và
  `svp.io/telegram-chat-id`.
- **`cluster_values`** phải có đúng các khoá của hợp đồng `cluster.*` (output `cluster_values` của hai root env), mỗi khoá đúng loại: chuỗi,
  `dbCidrs`, `edgeCidrs`, `s3Cidrs` là danh sách chuỗi, `externalSecretsRoles` là map chuỗi của đúng năm namespace `svp`, `svp-data`,
  `svp-obs`, `keda`, `argocd`; `kafkaBrokers` là một chuỗi `host:9096,host:9096,…` như MSK trả, không phải danh sách. Sáu khoá còn phải
  đúng dạng (biểu thức chính quy khớp cả chuỗi trong `variables.tf`): `ecrRegistry` là host registry ECR private
  `<account>.dkr.ecr.<region>.amazonaws.com`, `ampWorkspaceId` là `ws-<id>`, `ampEndpoint` là `prometheus_endpoint` của workspace AMP (kết thúc
  bằng `/`), `logGroup` là `/svp/<env>/otel`, `grafanaUrl` là `https://` + endpoint của workspace AMG (không `/` cuối), `alarmTopicArn` là ARN
  topic `svp-<env>-alarms`. Giá trị sai dạng dừng plan, thay vì chỉ lộ ra trong cluster thành lỗi kéo image, ghi metric hay gửi cảnh báo.
  Biến không khai kiểu object: đổi sang kiểu object sẽ âm thầm bỏ khoá thừa và báo khoá thiếu bằng lỗi kiểu thay vì luật kiểm.
- **ApplicationSet `svp-bootstrap`:** cluster generator chọn Secret có label `svp.io/env`, `goTemplate` với `missingkey=error`; tạo
  `svp-root` (project `svp`, label `svp.io/notify: root`, annotation `argocd.argoproj.io/compare-options: ServerSideDiff=false`, chart
  `argocd/root` của `svp-gitops` ở `refs/heads/main`); `templatePatch` đặt `env`, `platform`, `nodeArch` từ label, `cluster` từ annotation,
  và đăng ký Telegram khi có chat. `syncPolicy.preserveResourcesOnDeletion: true` để controller ApplicationSet không gắn finalizer vào
  `svp-root`: xoá ApplicationSet không xoá dây chuyền.
- **Namespace:** mỗi namespace phải có nhãn Pod Security `restricted` cho `enforce`, `audit`, `warn` với version `v1.<minor>`, và phải có
  `argocd`; nếu không thì output `namespaces` dừng ở precondition.
- **Chart `charts/resources`:** in nguyên văn danh sách manifest của value `resources`, như chart cùng tên của GitOps Bridge. AppProject và
  ApplicationSet đi qua `helm_release` của chart này vì CRD của Argo CD chỉ có sau release Argo CD trong cùng lần apply: Helm chỉ cần CRD lúc
  áp, `kubernetes_manifest` cần ngay lúc plan.
- **Chart `charts/platform-values`:** render mẫu `platforms/eks/<tên>.values.tpl` của `svp-gitops` trên value `cluster` bằng `tpl`, như chart
  `argocd/apps` ở đó render thành `valuesObject` của Application (render không ra map YAML thì fail). Root đặt kết quả sau mọi values file
  của render namespace, đúng thứ tự Argo CD đọc.
- **Provider `aws`** chỉ được khai trong `required_providers`, không dùng: `make test` bắt mỗi file test có `mock_provider "aws"`, và
  Terraform chỉ nạp mock cho provider module có khai.

## Test

`tests/bridge.tftest.hcl` (mock provider, chỉ `plan`) dùng fixture viết ngay trong file, đủ khoá của hợp đồng `cluster.*`. Run `stg` kiểm
label, annotation, data của cluster Secret, ApplicationSet và tên `svp-root`, host và TLS server name khi không tunnel, nhãn Pod Security của
namespace `argocd` và namespace dự án, values của chart `platform-values` (mẫu nguyên văn, đủ khoá `cluster_values`), release Argo CD,
AppProject, B là `main_commit`. Run `prd` kiểm host loopback qua tunnel, TLS server
name vẫn là host của endpoint, B là `gitopsRevision`, chat Telegram. Mỗi luật còn lại có một run với giá trị chỉ luật đó từ chối (env, kiến
trúc, khoá thiếu, khoá thừa như `hostedZoneId`, sai loại, thiếu role namespace, URL không phải loopback, khoá ghim vắng hay không phải commit,
namespace `baseline`, thiếu `argocd`, chart Argo CD lạ, thiếu AppProject); mỗi khoá trong sáu khoá có dạng có ba run: thiếu, sai loại,
sai dạng.

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
| namespace\_manifests | Namespaces rendered from templates/namespaces.yaml of chart svp-cluster (helm template output, one or more documents each): namespace argocd, and the namespaces of the project and of the platform charts. Each must enforce, audit and warn Pod Security restricted. | `list(string)` | n/a | yes |
| node\_arch | Architecture of the nodes: label svp.io/node-arch of the cluster Secret, value nodeArch of the root Application. | `string` | n/a | yes |
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
| namespaces | Namespace manifests by name, before Argo CD: argocd and those of the project and the platform charts, each with Pod Security restricted. |
| platform\_values\_chart | Path of chart platform-values of this module, which prints what a template of platforms/eks/ of svp-gitops renders on value cluster, as chart argocd/apps renders it into the valuesObject of an Application. |
| resources\_chart | Path of chart resources of this module, which prints the manifests of value resources: the chart of app\_projects\_release and root\_release. |
| root\_release | Release of chart resources holding ApplicationSet svp-bootstrap, which makes Application svp-root. |
| svp\_cluster\_platform\_values | Values for chart platform-values: platforms/eks/svp-cluster.values.tpl and cluster\_values. What it prints is the valuesObject of Application svp-cluster, which Argo CD reads after its values files. |
| tls\_server\_name | Name the providers check the certificate of the API server against: the host of cluster\_endpoint, also through a tunnel. |
<!-- END_TF_DOCS -->
