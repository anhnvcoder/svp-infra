# Runbook: nâng một minor EKS

Nâng cluster EKS của cả hai env từ minor `1.N` lên `1.N+1`: control plane, add-on ghim, nhóm node hệ thống, alias AMI của EC2NodeClass,
stg trước prd. Thiết kế: [ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md) §8 (version ghim, vì
sao Renovate không nâng add-on và AMI), §10 (thứ tự nâng); [ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md)
§2 (stg và prd cùng minor, cùng add-on, cùng AMI). Thứ tự theo hướng dẫn nâng cluster của EKS Best Practices Guide
(<https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html>).

**Người học chạy mọi lệnh chạm account hay cluster.** AI soạn thay đổi code, chạy `make check`, đọc output người học dán lại. Mọi lệnh ghi
profile và region; trước lệnh ghi tay, `aws/scripts/check-account.sh stg` (hay `prd`).

## Version nằm ở đâu

| Thành phần | Chỗ giữ | Ghi chú |
| --- | --- | --- |
| Minor của control plane | `kubernetes_version` ở `aws/envs/stg/stg.tfvars` và `aws/envs/prd/prd.tfvars` | hai file cùng giá trị |
| Add-on EKS | `addon_version` của từng add-on ở `aws/modules/eks/addons.tf` | bản mới nhất tương thích minor |
| AMI của nhóm node hệ thống | `local.ami_release_version` ở `aws/modules/eks/nodes.tf` | `validation` của `kubernetes_version` đòi cùng minor |
| AMI của node Karpenter | `karpenter.amiAlias` (`al2023@v<ngày>`) ở `platforms/eks/svp-cluster.yaml` của `svp-gitops` | cùng bản phát hành AL2023 với nhóm hệ thống |
| Chart Karpenter | component `karpenter` của `argocd/apps/components.json` ở `svp-gitops` | Renovate mở PR như chart khác |

ADR-0056 §8 ghi các bản lúc quyết định; bản đang chạy là bản trong code.

## 1. Chọn minor và tra version (chỉ đọc)

Một lần nâng chỉ đi một minor: EKS không nhảy minor và không hạ minor. Đọc trạng thái hỗ trợ của minor mới, bản add-on mới nhất cho minor
đó, và bản phát hành AMI AL2023 arm64 khuyên dùng (thay `1.N+1` bằng số thật):

```sh
AWS_PROFILE=anhnv-stg aws eks describe-cluster-versions --region ap-southeast-1 --output text \
  --query 'clusterVersions[].[clusterVersion,status,endOfStandardSupportDate]'
for a in vpc-cni kube-proxy coredns eks-pod-identity-agent aws-ebs-csi-driver metrics-server; do
  printf '%s ' "$a"
  AWS_PROFILE=anhnv-stg aws eks describe-addon-versions --addon-name "$a" --kubernetes-version 1.N+1 --region ap-southeast-1 \
    --query 'addons[0].addonVersions[0].addonVersion' --output text
done
AWS_PROFILE=anhnv-stg aws ssm get-parameter --region ap-southeast-1 --query Parameter.Value --output text \
  --name /aws/service/eks/optimized-ami/1.N+1/amazon-linux-2023/arm64/standard/recommended/release_version
```

Mong minor mới `STANDARD_SUPPORT`; một dòng version mỗi add-on; một chuỗi `1.N+1.<patch>-<ngày>`. Dán lại cả ba output. Alias của EC2NodeClass
là `al2023@v<ngày>` của cùng chuỗi đó.

Karpenter phân giải alias theo minor mà control plane đang chạy (tên AMI `amazon-eks-node-al2023-arm64-standard-<minor>-v<ngày>`, trang
"Managing AMIs" của Karpenter: <https://karpenter.sh/docs/tasks/managing-amis/>), nên ngày mới phải có bản cho cả `1.N` lẫn `1.N+1`:

```sh
for m in 1.N 1.N+1; do
  AWS_PROFILE=anhnv-stg aws ssm get-parameter --region ap-southeast-1 --query Parameter.Value --output text \
    --name "/aws/service/eks/optimized-ami/$m/amazon-linux-2023/arm64/standard/amazon-eks-node-al2023-arm64-standard-$m-v<ngày>/image_id"
done
```

Mong hai AMI ID `ami-…`. `ParameterNotFound` ở một minor: chọn bản phát hành mới nhất có cho cả hai minor (danh sách ở
<https://github.com/awslabs/amazon-eks-ami/releases>) và đọc lại `release_version` của `1.N+1` cho ngày đó.

Rồi kiểm Karpenter: bảng tương thích (<https://karpenter.sh/docs/upgrading/compatibility/>) phải có minor mới cho bản chart đang ghim. Không có
thì nâng chart Karpenter trước (PR riêng ở `svp-gitops`, một buổi stg xanh), rồi mới tới các bước dưới.

## 2. API bị bỏ ở minor mới (cluster đang chạy, trong buổi stg)

Trong một buổi stg ở minor cũ (`session-stg.md`, tunnel mở), đọc upgrade insights của EKS và metric API deprecated của API server:

```sh
AWS_PROFILE=anhnv-stg aws eks list-insights --cluster-name svp-stg --region ap-southeast-1 --filter categories=UPGRADE_READINESS \
  --query 'insights[].[name,insightStatus.status,kubernetesVersion]' --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get --raw /metrics | grep '^apiserver_requested_deprecated_apis'
```

Mong mọi insight `PASSING` cho `1.N+1`, không dòng metric nào có `removed_release="1.N+1"`. Insight `ERROR`, `WARNING` hay dòng metric: insight
nêu resource và client; sửa manifest hay nâng chart chứa nó (repo code, `svp-gitops`) trước khi nâng, rồi đọc lại ở buổi sau. Dán lại cả hai
output.

## 3. Thay đổi code

Hai PR, bản số từ bước 1:

1. `svp-infra`: `kubernetes_version = "1.N+1"` ở cả hai `<env>.tfvars`; `addon_version` mới ở `aws/modules/eks/addons.tf`;
   `ami_release_version` mới ở `aws/modules/eks/nodes.tf`; các giá trị ghim của `aws/modules/eks/tests/validation.tftest.hcl` (minor của lời
   gọi module, `ami_release_version` mà assert của nhóm `system` so, và minor của run `kubernetes_version_not_ami_minor`, phải khác `1.N+1`).
   `make check` xanh (`make test` của `aws/modules/eks` đỏ khi minor và AMI lệch nhau).
2. `svp-gitops`: `karpenter.amiAlias` mới ở `platforms/eks/svp-cluster.yaml`. Merge PR này **trước** khi nâng control plane của env (bước 4):
   ngày mới có bản cho cả hai minor (bước 1), nên Karpenter thay node sang AMI `1.N` của ngày mới, và khi control plane lên `1.N+1` thì sang
   AMI `1.N+1` của cùng ngày. Alias cũ để lại qua lúc nâng control plane thì Karpenter tự drift node sang AMI `1.N+1` của ngày cũ (lệch nhóm
   `system`), hay, khi ngày cũ chưa có bản `1.N+1`, EC2NodeClass hết phân giải được AMI và không dựng node nào. Kubelet không bao giờ mới hơn
   API server: Karpenter chỉ chọn AMI của minor mà control plane đã báo.

## 4. Nâng stg trong một buổi

Buổi stg dựng env ở minor cũ (`main` của `svp-infra` trước PR 1, `main` của `svp-gitops` trước PR 2), tới bước 10 của `session-stg.md` xanh.
Rồi, cùng terminal của buổi, tunnel mở:

1. Merge PR 2 ở `svp-gitops`. Argo CD sync `svp-cluster`; EC2NodeClass đổi alias, Karpenter đánh dấu node cũ `Drifted` và thay từng node theo
   ngân sách disruption của NodePool (`envs/stg/svp-cluster.yaml`):

   ```sh
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get ec2nodeclasses.karpenter.k8s.aws default \
     -o jsonpath='{range .status.amis[*]}{.name}{"\t"}{.id}{"\n"}{end}'
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh \
     -o custom-columns='NAME:.metadata.name,DRIFTED:.status.conditions[?(@.type=="Drifted")].status,NODE:.status.nodeName'
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes -L karpenter.sh/nodepool -w                     # node mới, Ctrl-C
   ```

   Mong AMI của EC2NodeClass tên `amazon-eks-node-al2023-arm64-standard-1.N-v<ngày mới>`; sau vài chục phút mọi node Karpenter là node mới,
   cột `VERSION` vẫn `v1.N.*`, không NodeClaim nào `Drifted`.
2. Chuyển bản clone `svp-infra` sang nhánh PR 1, plan và đọc file text: chỉ `update in-place` trên `module.eks` (`aws_eks_cluster` đổi
   `version`, `aws_eks_addon` đổi `addon_version`, node group `system` đổi `version` và `release_version`), không `replace`, không `destroy`:

   ```sh
   git switch <nhánh PR 1>
   aws/scripts/tf.sh stg env plan
   aws/scripts/tf.sh stg env apply
   ```

   Terraform nâng control plane trước (add-on và node group phụ thuộc cluster), rồi add-on, rồi xoay node group `system` từng node (EKS drain
   node cũ theo PDB). Control plane mất ~10–15 phút; mỗi node hệ thống vài phút. Khi control plane báo minor mới, Karpenter đổi AMI của
   EC2NodeClass sang bản `1.N+1` của cùng ngày và thay node Karpenter lần nữa, theo cùng ngân sách disruption.
3. Đọc lại, sau khi apply xong và Karpenter thay hết node:

   ```sh
   AWS_PROFILE=anhnv-stg aws eks describe-cluster --name svp-stg --region ap-southeast-1 --query 'cluster.[version,status]' --output text
   AWS_PROFILE=anhnv-stg aws eks list-addons --cluster-name svp-stg --region ap-southeast-1 --query addons --output text
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes -L eks.amazonaws.com/nodegroup,karpenter.sh/nodepool
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get ec2nodeclasses.karpenter.k8s.aws default \
     -o jsonpath='{range .status.amis[*]}{.name}{"\t"}{.id}{"\n"}{end}'
   AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh \
     -o custom-columns='NAME:.metadata.name,DRIFTED:.status.conditions[?(@.type=="Drifted")].status,NODE:.status.nodeName'
   ```

   Mong `1.N+1 ACTIVE`; mọi node, `nodegroup=system` lẫn Karpenter, có cột `VERSION` `v1.N+1.*`; AMI của EC2NodeClass tên
   `amazon-eks-node-al2023-arm64-standard-1.N+1-v<ngày mới>`; không NodeClaim nào `Drifted`.
4. `make eks-smoke` như bước 11 của `session-stg.md`, rồi gỡ buổi như thường (bước 12–20). Kết quả (phút của mỗi phần, insight, smoke) vào PR 1.
   Merge PR 1 sau buổi xanh: từ đó mỗi buổi stg dựng thẳng ở minor mới.

## 5. prd

prd chạy minor mới ở buổi prd đầu tiên sau một buổi stg xanh với cả hai PR: root `aws/envs/prd` đọc `prd.tfvars` của `main`, và cổng promote
(`session-prd.md`) đưa commit `svp-gitops` đã chạy ở stg, cùng alias mới, lên prd. Env dựng mới mỗi buổi nên prd không cần nâng tại chỗ;
diễn tập nâng tại chỗ ở prd đi đúng bước 4 với `prd`, `anhnv-prd`, `--context svp-prd` (tunnel cổng 6443); ở prd, bước 4.1 là PR promote
đưa commit `svp-gitops` có alias mới lên prd (`gitopsRevision`), merge trước khi nâng control plane.

## Khi một bước đỏ

| Triệu chứng | Cách xử lý |
| --- | --- |
| Plan có `replace` trên `aws_eks_cluster` hay node group | không apply; dán plan cho AI (đối số khác ngoài version đổi trong PR) |
| Add-on `DEGRADED` sau apply | `AWS_PROFILE=anhnv-stg aws eks describe-addon --cluster-name svp-stg --addon-name <tên> --region ap-southeast-1 --query 'addon.health'`; dán cho AI; không hạ bản add-on bằng console |
| Node group kẹt ở `UPDATING` | PDB chặn drain: `AWS_PROFILE=anhnv-stg kubectl --context svp-stg get pdb -A`; dán cho AI |
| NodeClaim mới không `Ready` sau khi đổi alias (bước 4.1) | log Karpenter (`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --tail=50`): alias sai chuỗi hay AMI chưa có ở region; revert PR 2, node cũ vẫn chạy |
| EC2NodeClass không còn AMI nào (lệnh `status.amis` của bước 4.1 rỗng) sau khi nâng control plane | ngày của alias chưa có bản `1.N+1` (PR 2 chưa merge, hay ngày chọn sai ở bước 1): Karpenter không dựng node mới, node đang chạy giữ nguyên; merge PR 2 với ngày có cho `1.N+1` |
