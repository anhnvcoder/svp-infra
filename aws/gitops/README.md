# `aws/gitops/<env>`: cài Argo CD và giao cluster của buổi cho `svp-gitops` (bootstrap GitOps)

**Account** `svp-<env>` · **region** `ap-southeast-1` · **profile** `anhnv-<env>` · **state** bucket của `aws/accounts/<env>`
(`../../backend-<env>.hcl`), key `aws/gitops/<env>/terraform.tfstate`

Giải thích: [13. GitOps](../../docs/handbook/13-gitops.md).

## Dựng gì

Mọi tài nguyên nằm trong cluster `svp-<env>` của root [`aws/envs/<env>`](../envs/stg/README.md); root không tạo tài nguyên AWS nào. Giá
trị do module [`gitops-bridge`](../modules/gitops-bridge/README.md) tính; `depends_on` giữ thứ tự của bảng.

| Tài nguyên | Account, region | Một câu |
| --- | --- | --- |
| `kubernetes_manifest.namespace` | cluster `svp-<env>` | `argocd` và namespace dự án với nhãn Pod Security `restricted`, render từ `templates/namespaces.yaml` của chart `svp-cluster`; server-side apply, field manager `svp-pod-security` |
| `helm_release.argocd` | cluster `svp-<env>` | Argo CD theo `argocd/bootstrap.json` ở commit bootstrap B; values file nó nêu, rồi `platforms/eks/argo-cd.yaml` |
| `helm_release.app_projects` | cluster `svp-<env>` | AppProject `svp`, `default` nguyên văn `argocd/project.yaml` ở B, `take_ownership` |
| `kubernetes_secret_v1.cluster` | cluster `svp-<env>` | Secret `argocd/in-cluster`: nhãn env, platform, kiến trúc node; annotation `svp.io/cluster-values`, chat Telegram |
| `helm_release.root` | cluster `svp-<env>` | ApplicationSet `svp-bootstrap`, tạo Application `svp-root` |

Root đọc: state của root env (`terraform_remote_state`: `cluster_name`, `cluster_endpoint`, CA, `cluster_values`), commit của `main`
của `svp-gitops` (GitHub REST API) và file ở commit đó hay ở B (`raw.githubusercontent.com`, không credential). Output
`bootstrap_revision` là B. Hai thư mục `stg/`, `prd/` giống hệt nhau trừ `env` trong `locals` của `main.tf`; khác biệt nằm ở
`<env>.tfvars` (`require_pinned_revision`, `api_server_url`, `node_arch`). Giá trị cá nhân duy nhất, `telegram_chat_id`, không vào
file commit: `tf.sh` đặt `TF_VAR_telegram_chat_id` từ `SVP_ALERT_TELEGRAM_CHAT_ID` của `.env` repo code (rỗng thì chỉ commit status).

## Chạy

Người học chạy mọi lệnh qua `aws/scripts/tf.sh <env> gitops`; AI không chạy lệnh nào chạm account.

- Mỗi buổi, sau root env và `bootstrap.sh <env> secrets`, khi tunnel đang mở: init, plan, apply ở bước 12–14 của
  [`session-stg-deploy.md`](../../docs/runbooks/session-stg-deploy.md), rồi chờ Argo CD ở bước 15; prd theo
  [`session-prd-deploy.md`](../../docs/runbooks/session-prd-deploy.md), sau khi PR promote prd đã merge.
- Đổi version hay values của Argo CD, hay AppProject ở `svp-gitops` giữa buổi: plan và apply lại root này (Argo CD không tự quản).
- Gỡ cuối buổi, sau `pre-destroy.sh <env>` và **trước** root env, tunnel còn mở: bước 21–22 của
  [`session-stg-teardown.md`](../../docs/runbooks/session-stg-teardown.md).
- Giữa các buổi: không có gì để chạy; state trống sau destroy.

## Chart `svp-cluster` (`TF_VAR_svp_cluster_chart`)

Namespace render từ chart `svp-cluster` của `svp-backend` ở `revision` của `envs/<env>/charts.yaml` trên `main` của `svp-gitops`: đúng
chart mà Application `svp-cluster` sẽ cài. Biến `svp_cluster_chart` là thư mục chart đã giải nén, không nằm trong file commit nào và
đặt bằng `TF_VAR_svp_cluster_chart` trong lệnh. `tf.sh <env> gitops plan` làm việc này trước mỗi plan: fetch hai bản clone `backend`,
`gitops` cạnh `infra`, đọc `revision`, giải nén `deploy/helm/svp-cluster` bằng `git archive` vào thư mục của buổi, đặt biến, rồi in
dòng `ok chart svp-cluster at <sha>`. Mọi `plan` và `destroy` của root này cần biến đó.

## Tunnel khi áp

Endpoint công khai của API tắt ở cả hai env. Mọi lệnh của root này trừ `init` (`plan`, `apply`, `destroy`) cần tunnel SSM của root
`aws/envs/<env>` đang mở (output `api_tunnel_command`, mục "Tunnel tới API" của runbook buổi): `api_server_url` của `<env>.tfvars` là
đầu local của tunnel, stg `https://127.0.0.1:6444`, prd `https://127.0.0.1:6443`. TLS server name vẫn là host của `cluster_endpoint`
(state root env), nên cert của API khớp dù đi qua tunnel. Giữ tunnel tới khi destroy root này xong.

## Tham chiếu

- [13. GitOps](../../docs/handbook/13-gitops.md): ranh giới Terraform và Argo CD, commit bootstrap, vì sao root riêng.
- [Module `gitops-bridge`](../modules/gitops-bridge/README.md): giá trị của bootstrap, luật của `cluster_values`.
- [README của `svp-gitops`](https://github.com/anhnvcoder/svp-gitops#root-hai-tầng-và-bootstrap): root hai tầng, hợp đồng `cluster`.
- [ADR-0048](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0048-prd-aws.md) §6: bootstrap EKS.
