# `aws/gitops/<env>`: bootstrap GitOps của cluster EKS

Hai root `stg/`, `prd/` cài lên cluster của root env [`aws/envs/<env>`](../envs/stg/README.md) đúng những gì phải có trước khi Argo CD tự dựng
phần còn lại từ `svp-gitops` (ADR-0048 §6, mẫu GitOps Bridge của ADR-0050 §1): namespace có Pod Security, Argo CD, AppProject, cluster Secret
mang metadata của cluster, và ApplicationSet `svp-bootstrap` tạo Application gốc `svp-root`. Giá trị tính ở module
[`gitops-bridge`](../modules/gitops-bridge/README.md); root chỉ đọc nguồn và áp.

Root riêng, không gộp vào root env: provider `kubernetes` khuyên dựng cluster và tài nguyên Kubernetes trong hai lần apply riêng,
`kubernetes_manifest` cần API server ngay lúc plan, và API của cả hai env chỉ tới được qua tunnel, nên plan của root env không bao giờ cần
tunnel.

## Áp gì, theo thứ tự nào

`depends_on` giữ thứ tự: namespace → Argo CD → AppProject → cluster Secret → root.

| Resource | Nguồn |
| --- | --- |
| `kubernetes_manifest.namespace` | `argocd`, namespace của dự án và của chart nền tảng, render `templates/namespaces.yaml` của chart `svp-cluster` (`data "helm_template"`) với values Application `svp-cluster` đọc, theo thứ tự Argo CD đọc: `platforms/eks/svp-cluster.yaml` ở B, `envs/<env>/svp-cluster.yaml` ở `main` khi file có (overlay theo env: capacity type, `limits`, ngân sách disruption của NodePool Karpenter), cuối cùng `valuesObject` (mẫu `platforms/eks/svp-cluster.values.tpl` ở B render trên `cluster_values` bằng chart `platform-values` của module); server-side apply, field manager `svp-pod-security` |
| `helm_release.argocd` | repo, chart, version, namespace của `argocd/bootstrap.json` ở B; values file nó nêu rồi `platforms/eks/argo-cd.yaml` ở B. Argo CD không tự quản: đổi version hay values tới cluster ở lần apply sau |
| `helm_release.app_projects` | `argocd/project.yaml` ở B, nguyên văn, qua chart `resources` của module, `take_ownership` (argocd-server đã tạo AppProject `default`) |
| `kubernetes_secret_v1.cluster` | `argocd/in-cluster`: label env, platform, kiến trúc node; annotation `svp.io/cluster-values` (output `cluster_values` của root env) và chat Telegram |
| `helm_release.root` | ApplicationSet `svp-bootstrap` qua chart `resources` |

B là commit bootstrap: `gitopsRevision` của `envs/<env>/charts.yaml` ở `main`, không có khoá thì commit của `main` lúc plan (GitHub REST API).
Root đọc `svp-gitops` qua HTTPS không credential (repo public), luôn ở commit cố định. CRD của Argo CD có sau release Argo CD trong cùng lần apply,
nên AppProject và ApplicationSet đi qua `helm_release`, không qua `kubernetes_manifest`. Helm render cả chart `svp-cluster` rồi `show_only` mới
lọc `templates/namespaces.yaml`, nên render namespace cần đủ values mọi template của chart bắt buộc (CIDR health check của Envoy, email ACME…):
thiếu `valuesObject` thì plan dừng ở đó.

## stg và prd

Các file `*.tf` của hai root giống hệt nhau trừ dòng `env` của `locals` trong `main.tf`; `example.auto.tfvars.example` cũng giống hệt. Khác biệt
ở `<env>.tfvars`:

| Biến | stg | prd | Vì sao |
| --- | --- | --- | --- |
| `node_arch` | `arm64` | `arm64` | node Graviton của cả hai env |
| `require_pinned_revision` | `false` | `true` | prd chỉ bootstrap ở commit stg đã chạy (`gitopsRevision`, PR promote ghi); khoá vắng thì plan dừng |
| `api_server_url` | `https://127.0.0.1:6444` | `https://127.0.0.1:6443` | endpoint công khai của API tắt ở cả hai env: hai provider đi qua tunnel SSM của root `aws/envs/<env>`, mỗi env một cổng local (`api_tunnel_port` của root env) |

TLS server name luôn là host của `cluster_endpoint` (state root env), cả khi đi qua tunnel; không nằm trong file commit nào.

| Mục | Giá trị |
| --- | --- |
| Profile, biến account | `anhnv-<env>`, `SVP_AWS_<ENV>_ACCOUNT_ID`, như root env; `allowed_account_ids = [var.account_id]` |
| Backend | `../../backend-<env>.hcl`, key `aws/gitops/<env>/terraform.tfstate` truyền bằng `-backend-config` thứ hai; `backend "s3" {}` trống |
| State root env | `terraform_remote_state`: bucket `svp-tfstate-<account>-<region>`, key `aws/<env>/terraform.tfstate` |
| Token | `aws eks get-token --cluster-name <cluster> --region <region>` với `AWS_PROFILE=anhnv-<env>` (exec của hai provider) |
| `<env>.auto.tfvars` | **không commit**: `telegram_chat_id`, chép từ `example.auto.tfvars.example` |
| `TF_VAR_svp_cluster_chart` | thư mục chart `svp-cluster` giải nén ở mục dưới, đặt ngay trong lệnh |

## Trong buổi

**Người học chạy mọi lệnh dưới đây** (AI chỉ chạy `make check`, `make lock`). Lệnh ví dụ cho stg; prd thay `stg` → `prd`, `STG` → `PRD`.
Trình tự cả buổi ở runbook buổi của `docs/runbooks/`.

1. Apply root `aws/envs/<env>` (README của nó).
2. Ghi giá trị secret: `AWS_PROFILE=anhnv-stg make eks-secrets CONTEXT=svp-stg` ở repo code.
3. Mở tunnel ở một terminal riêng (`eval "$(AWS_PROFILE=anhnv-stg terraform -chdir=../../envs/stg output -raw api_tunnel_command)"`)
   và giữ nó chạy tới khi gỡ xong root này. Chỉ prd: PR promote đặt `gitopsRevision` của `envs/prd/charts.yaml` đã merge trước plan.
4. Giải nén chart `svp-cluster` (mục dưới), rồi init, plan, apply root này (mục "Lệnh").
5. Chờ Application `svp-observability` Healthy, chạy `make eks-glitchtip-init CONTEXT=svp-stg` ở repo code, rồi chờ `svp-root`:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd wait applications.argoproj.io/svp-observability --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd wait applications.argoproj.io/svp-root --for=jsonpath='{.status.sync.status}'=Synced --timeout=30m
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n argocd wait applications.argoproj.io/svp-root --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m
```

Plan đầu tiên của buổi chạy sau apply root env: provider đọc output `cluster_endpoint`, `cluster_values` từ state đó, root env chưa apply thì
plan lỗi ở `terraform_remote_state`.

### Chart `svp-cluster`

Namespace render từ chart `svp-cluster` của repo code ở `revision` của `envs/<env>/charts.yaml` (chart mà Application `svp-cluster` sẽ cài),
giải nén bằng `git archive` ra thư mục ngoài repo. Chạy từ `infra/aws/gitops/stg`, bản clone `backend`, `gitops` cạnh `infra`:

```sh
ws="$(git rev-parse --show-toplevel)/.."
git -C "$ws/gitops" fetch origin && git -C "$ws/backend" fetch origin
rev=$(git -C "$ws/gitops" show origin/main:envs/stg/charts.yaml | sed -n 's/^revision: //p')
rm -rf /tmp/svp-cluster-stg && mkdir -p /tmp/svp-cluster-stg
git -C "$ws/backend" archive "$rev" deploy/helm/svp-cluster | tar -x -C /tmp/svp-cluster-stg
```

### Lệnh

Kiểm account trước (cột `Account` phải bằng `$SVP_AWS_STG_ACCOUNT_ID`; khác thì dừng):

```sh
cd infra/aws/gitops/stg
AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region ap-southeast-1 --query '{Account:Account,Arn:Arn}' --output table
echo "$SVP_AWS_STG_ACCOUNT_ID"
```

Dựng (đọc plan trước khi apply: tạo mới namespace, ba release, Secret `in-cluster`; B in ở output `bootstrap_revision`):

```sh
cp example.auto.tfvars.example stg.auto.tfvars          # rồi sửa telegram_chat_id nếu có
AWS_PROFILE=anhnv-stg terraform init -reconfigure -backend-config=../../backend-stg.hcl -backend-config=key=aws/gitops/stg/terraform.tfstate
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_svp_cluster_chart=/tmp/svp-cluster-stg/deploy/helm/svp-cluster \
  terraform plan -var-file=stg.tfvars -out=stg.tfplan
AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" terraform apply stg.tfplan
```

## Gỡ

Root này gỡ **trước** root env (tunnel vẫn mở), theo thứ tự:

1. `aws/scripts/pre-destroy.sh stg`: xoá ApplicationSet `svp-bootstrap` (`svp-root` không finalizer nên không xoá dây chuyền), rồi Application
   workload, chờ NLB, TargetGroupBinding, bản ghi DNS, PVC gỡ khi controller còn chạy; rồi NodePool và EC2NodeClass, chờ hết node của
   Karpenter; rồi controller nền tảng.
2. Destroy root này:

   ```sh
   AWS_PROFILE=anhnv-stg TF_VAR_account_id="$SVP_AWS_STG_ACCOUNT_ID" TF_VAR_svp_cluster_chart=/tmp/svp-cluster-stg/deploy/helm/svp-cluster \
     terraform destroy -var-file=stg.tfvars
   ```

3. Destroy root `aws/envs/stg` (prd với `teardown.tfvars`), rồi lệnh quét tài nguyên sót: `aws/scripts/sweep.sh stg`, `aws/scripts/sweep.sh mgmt`.
