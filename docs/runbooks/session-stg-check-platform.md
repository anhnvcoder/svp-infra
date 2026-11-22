# Runbook: phép kiểm nền tảng của buổi stg (bước 16)

← [Phép kiểm release](session-stg-check-release.md) · [Mục lục](README.md) · [Phép kiểm bảo mật](session-stg-check-security.md) →

> **Tóm tắt**
>
> - **Làm gì:** đo nền tảng EKS của buổi: EKS và TLS Postgres, service mesh (trạng thái và danh tính lạ bị từ chối), độ trễ mesh, chi phí
>   theo namespace, vận hành pod, trải zone và chạy thử DLQ, chặn quá tải và pool khi giữ tải, canary gRPC theo request. `lõi`: trạng
>   thái service mesh; `chuẩn ngành`: các phép còn lại. Cờ cần bật: `managed_grafana` `session` chỉ cho đoạn dashboard của chi phí theo
>   namespace; phép kiểm không cần cờ khác.
> - **Khi nào và bao lâu:** sau bước 15, tunnel mở. Ba phép cần thang k6 đang giữ tải (độ trễ mesh, chặn quá tải, canary gRPC) chạy sau hay
>   trong lúc chờ bậc k6 của [trang release](session-stg-check-release.md#seed-và-thang-k6); chi phí theo namespace sau ít nhất 30 phút.
> - **Phí trong lúc chạy:** phép chỉ đọc không tốn thêm; phép tạo pod hay tắt một instance Spot ghi khoản thêm ở dòng `Loại:` của nó.

Thiết kế: [ADR-0055](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0055-environment-matrix.md) (stg chạy cùng cấu hình, xác
thực, mã hoá và giám sát với prd, kể cả API qua tunnel SSM);
[ADR-0056](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0056-eks-platform-ha.md) (Karpenter trên nhóm node hệ thống, Envoy
và Kyverno HA); [ADR-0057](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0057-postgres17-verify-full.md) (PostgreSQL 17,
`verify-full`).

## Điều kiện trước

- [ ] **Bước 1–15 xong**: apply root env và root gitops thành công, `bootstrap.sh stg wait` (bước 15) báo mọi Application `Healthy`
  ([`session-stg-deploy.md`](session-stg-deploy.md#15-chờ-argo-cd)).
- [ ] **Tunnel tới API còn mở** ([Tunnel tới API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11), giữ tới hết bước 22).
- [ ] **Terminal của buổi** ([Mở terminal](session-stg.md#mở-terminal)): cùng `SVP_SESSION_DIR` với các bước trước.
- [ ] **Hàm dùng chung đã nạp** ([Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo)): `amp_get`, `promql`, `insights`
  nằm ở trang chủ, chạy khối đó một lần trong terminal (mở lại terminal thì chạy lại).
- [ ] **Thang k6 đã chạy hay đang giữ tải** ([Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6)) cho các phép ghi
  "cần thang k6" ở dòng `Loại:`; phép không ghi vậy không cần.
- [ ] **Bản `svp-gitops` của buổi** có `dlq-replay` và `zoneSpread` cho mục Trải zone và chạy thử DLQ, và một release gRPC có
  `canary: true` cho mục Canary gRPC theo request; thiếu thì bỏ hai mục đó (mỗi mục nêu điều kiện của nó).

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ (mở lại giữa buổi: cùng mục đó, với
`SVP_SESSION_DIR` là thư mục của buổi đang dở). Lệnh chạy từ gốc repo (`infra/`).
Trang này cần `SVP_SESSION_DIR`, `SVP_AWS_STG_ACCOUNT_ID`.

## Nền tảng EKS và TLS Postgres

Loại: `chuẩn ngành`, không cần cờ. Thêm: chỉ đọc, trừ (b) tắt một instance Spot và chờ node thay; ADR không có số thời gian.

Phép kiểm buổi stg của mục "Xác nhận" của ADR-0055…0057, làm sau smoke (trong lúc chờ bậc k6 khi thang đo chạy), tunnel
mở. Lệnh và output có thời điểm UTC vào một file của `$SVP_SESSION_DIR`, một dòng kết luận mỗi phép vào "Xác nhận" của
ADR tương ứng. Buổi prd chạy đúng các lệnh này với `anhnv-prd`, `--context svp-prd`, tên `svp-prd`.

(a) Node: nhóm hệ thống on-demand mỗi AZ một node, node Karpenter cho pod còn lại (stg `spot`, ADR-0056 §2), NodeClaim khớp node:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes \
  -L topology.kubernetes.io/zone,eks.amazonaws.com/nodegroup,karpenter.sh/nodepool,karpenter.sh/capacity-type
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system get deploy karpenter
AWS_PROFILE=anhnv-stg kubectl --context svp-stg describe nodes -l eks.amazonaws.com/nodegroup=system | grep -A 8 'Allocated resources'
```

Mong: hai node `nodegroup=system` ở hai zone, không giá trị ở cột `nodepool`; mọi node khác có `nodepool=default`, `capacity-type=spot`, mỗi
cái một NodeClaim `Ready`; Deployment `karpenter` `2/2`. Request của nhóm hệ thống (khối `Allocated resources`) so với bảng tính ở phụ lục
§3 của ADR-0056 (mục "Xem lại khi": quá 80 % allocatable). Dán cả bốn output.

(b) Interruption đi qua hàng đợi: tắt một instance Karpenter; EventBridge chuyển sự kiện đổi trạng thái vào SQS `svp-stg-karpenter`,
Karpenter đọc nó, drain node và dựng node thay:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get node -l karpenter.sh/nodepool=default \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.providerID}{"\n"}{end}'
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 terminate-instances --instance-ids <i-… của một dòng trên> --region ap-southeast-1 \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kube-system logs deploy/karpenter --since=10m | grep -i -E 'interruption|disrupt' | head -n 5
# NodeClaim mới Ready, Ctrl-C
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodeclaims.karpenter.sh -w
```

Mong `shutting-down`, một dòng log của Karpenter nêu NodeClaim của instance đó, rồi một NodeClaim mới `Ready` (ghi thời gian từ lệnh tắt
tới đó). Không dòng log nào: dán log và số tin còn trong hàng đợi cho AI:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages --region ap-southeast-1 \
  --queue-url "$(AWS_PROFILE=anhnv-stg aws --no-cli-pager sqs get-queue-url --queue-name svp-stg-karpenter --region ap-southeast-1 --query QueueUrl --output text)"
```

(c) Envoy và Kyverno HA, trải zone (ADR-0056 §4–§6): Envoy hai replica có HPA và PDB, Kyverno ba replica có PDB, pod nằm trên node của
nhiều zone (cột `NODE` so với cột zone của (a)):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system get hpa,pdb
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=svp -o wide
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pdb
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide
```

Mong HPA từ `2` tới `4`, PDB của Envoy `MIN AVAILABLE 1`, PDB của Kyverno `MAX UNAVAILABLE 1`; hai pod Envoy trên node ở hai zone khác nhau,
ba pod Kyverno trên node của cả hai zone (stg có hai AZ). Hai pod Envoy chung một zone khi zone kia còn chỗ: dán output cho AI.

(d) TLS Postgres (ADR-0057): chuỗi kết nối của service đi `verify-full` tới địa chỉ RDS, và RDS ghi mỗi kết nối là TLS (`log_connections`
của parameter group, log `postgresql` export ra CloudWatch Logs). Lệnh đầu chỉ in host và phần sau `?` của URL (không có user, mật khẩu);
lệnh sau đọc các dòng `connection authorized` của 30 phút gần nhất, trừ user nội bộ `rdsadmin` của RDS (nối qua socket local, không TLS):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret user-service-env -o jsonpath='{.data.DATABASE_URL}' | base64 --decode |
  sed -E 's#^[^@]*@([^/]*)/[^?]*#\1 #'; echo
AWS_PROFILE=anhnv-stg aws --no-cli-pager logs filter-log-events --log-group-name /aws/rds/instance/svp-stg/postgresql --region ap-southeast-1 \
  --start-time "$(( ($(date +%s) - 1800) * 1000 ))" --filter-pattern '"connection authorized" -rdsadmin' --max-items 10 --query 'events[].message' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager rds describe-db-instances --db-instance-identifier svp-stg --region ap-southeast-1 --output text \
  --query 'DBInstances[0].[DBInstanceClass,EngineVersion,CACertificateIdentifier,StorageEncrypted,MaxAllocatedStorage]'
```

Mong: dòng đầu là `<địa chỉ RDS>:5432 ?sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt…`; mọi dòng log có `SSL enabled
(protocol=TLSv1.3` (hay `TLSv1.2`); `db.t4g.small`, `17.<minor RDS chọn>`, `rds-ca-rsa2048-g1`, `True`, trần storage của `stg.tfvars`. Pod
của service `Running` cùng các dòng đó chứng minh client kiểm được cert theo tên: với `verify-full`, tên sai thì client không nối được.
Dòng log câu lệnh chậm (`duration:` từ 1 s, ADR-0057 §6) không được kèm dòng `Parameters:`; mong `0`:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager logs filter-log-events --log-group-name /aws/rds/instance/svp-stg/postgresql --region ap-southeast-1 \
  --start-time "$(( ($(date +%s) - 3600) * 1000 ))" --filter-pattern '"Parameters:"' --query 'length(events)' --output text
```

(e) Log control plane, mã hoá Secret, endpoint, autoscaling storage MSK, slow-log Valkey (ADR-0055 §2, ADR-0056 §7, ADR-0058 §4, §5):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager eks describe-cluster --name svp-stg --region ap-southeast-1 --output json \
  --query 'cluster.[logging.clusterLogging[?enabled].types[], encryptionConfig[].resources[], resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess]]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager application-autoscaling describe-scaling-policies --service-namespace kafka --region ap-southeast-1 --output text \
  --query 'ScalingPolicies[].[PolicyName,TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,TargetTrackingScalingPolicyConfiguration.TargetValue]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache describe-replication-groups --replication-group-id svp-stg --region ap-southeast-1 --output text \
  --query 'ReplicationGroups[0].LogDeliveryConfigurations[].[LogType,DestinationType,LogFormat,Status]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager logs describe-log-streams --log-group-name /aws/elasticache/svp-stg/slow-log --region ap-southeast-1 --max-items 1 \
  --query 'logStreams[].logStreamName' --output text
```

Mong năm loại log `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`; `secrets`; `false`, `true`; một policy
`KafkaBrokerStorageUtilization` ở mức của ADR-0058 §4 (API từ chối `kafka.t3.small` thì apply đã đỏ ở bước 9: dán lỗi cho AI);
`slow-log cloudwatch-logs json active`; một log stream (chưa có lệnh chậm nào thì rỗng: ghi lại, không là trượt).

## Service mesh

Loại: `lõi`.

Istio ambient chạy trên mọi node, bắt mọi pod của `svp` và pod Envoy; mỗi release có PeerAuthentication `STRICT` và
AuthorizationPolicy ([ADR-0075](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0075-service-mesh.md);
thành phần trên EKS ở `docs/reference/eks.md` của repo code). Chỉ đọc, tunnel mở, sau bước 15, trước thang k6:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.taints[*].key}{"\n"}{end}' | grep -c cni.istio.io/not-ready
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n istio-system get deploy,daemonset
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-mesh get deploy,pdb waypoint
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods --field-selector=status.phase=Running \
  -o custom-columns=NAME:.metadata.name,REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n envoy-gateway-system get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=svp \
  -o custom-columns=NAME:.metadata.name,REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get peerauthentications.security.istio.io \
  -o custom-columns=NAME:.metadata.name,MODE:.spec.mtls.mode
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get authorizationpolicies.security.istio.io
```

Mong, theo thứ tự: node của nhóm hệ thống (cột `nodepool` trống) và node Karpenter; `0` (istiod gỡ taint khởi động của node Karpenter khi
istio-cni và ztunnel Ready trên node đó; node còn taint là mesh chưa sẵn sàng ở đó); Deployment `istiod` `2/2`, DaemonSet `istio-cni-node`
và `ztunnel` có `DESIRED`, `READY` bằng số node của lệnh đầu; waypoint `2/2` và PDB `MIN AVAILABLE 1`; mọi pod `Running` của `svp` và hai
pod Envoy có `enabled`; mỗi release một PeerAuthentication `STRICT`; mỗi release một AuthorizationPolicy, bốn release gRPC thêm
`<release>-waypoint`. Dán cả tám output. Khác mong đợi: không chạy thang k6, theo runbook
[`mesh-traffic-denied.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/mesh-traffic-denied.md) của repo code và dán
output cho AI.

## Service mesh: danh tính lạ bị từ chối

Loại: `chuẩn ngành`, không cần cờ; tạo rồi xoá một ServiceAccount và hai pod trong `svp`. Thêm: khoảng 3 phút, hai pod
nhỏ trên node có sẵn; chi phí của mesh chưa có số ([phụ lục ADR-0075, Số
đo](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0075-service-mesh.md#số-đo)).

Ca M-2 của drill mesh (`deploy/k8s/drills/mesh/m-2/` của repo code, Chainsaw chỉ chạy trên k3d) làm tay trên EKS: pod mang nhãn của
gateway, trong mesh, dưới một ServiceAccount không policy nào nêu, gọi gRPC health của bốn service gRPC qua Service; waypoint từ chối. Đối
chứng: pod giống hệt dưới ServiceAccount `gateway` được trả lời, nên lời từ chối là của danh tính, không của mạng. Hai pod chạy image của
một pod web đang chạy, theo digest (Kyverno của `svp` chỉ nhận bản phát hành đã ký), không bao giờ Ready (readiness gate không ai đặt, nên
Service của gateway không gửi request tới chúng), và chạy probe `deploy/k8s/drills/templates/ambient-probe.js` của bản clone repo code
(điều kiện 2). Khối dưới xoá mọi thứ nó tạo khi kết thúc, cả khi một lệnh lỗi hay bị Ctrl-C:

```sh
js=$(cat ../backend/deploy/k8s/drills/templates/ambient-probe.js)
img=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods -l app.kubernetes.io/name=web,app.kubernetes.io/component=server \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].spec.containers[?(@.name=="web")].image}')
echo "$img" | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/"
mesh_pod() {          # pod $1 under ServiceAccount $2, labelled as the gateway so its NetworkPolicies apply
  cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: svp
  labels:
    app.kubernetes.io/name: gateway
    app.kubernetes.io/component: server
    app.kubernetes.io/managed-by: svp-session-mesh
    istio.io/dataplane-mode: ambient
spec:
  serviceAccountName: $2
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  activeDeadlineSeconds: 900
  readinessGates:
    - conditionType: session.svp/not-a-backend
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $img
      command: [/nodejs/bin/node, -e, "setTimeout(() => {}, 900000)"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 200m, memory: 128Mi}
EOF
}
(
  trap 'AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp delete pods,serviceaccounts \
    -l app.kubernetes.io/managed-by=svp-session-mesh --grace-period=1' EXIT
  trap 'exit 130' INT TERM
  { printf '%s\n' 'apiVersion: v1' 'kind: ServiceAccount' 'metadata:' '  name: session-mesh-stranger' '  namespace: svp' \
      '  labels:' '    app.kubernetes.io/managed-by: svp-session-mesh' 'automountServiceAccountToken: false'
    mesh_pod session-mesh-stranger session-mesh-stranger
    mesh_pod session-mesh-gateway gateway
  } | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp create -f - || exit 1
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp wait pods -l app.kubernetes.io/managed-by=svp-session-mesh \
    --for=condition=ContainersReady --timeout=120s || exit 1
  sleep 5
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods -l app.kubernetes.io/managed-by=svp-session-mesh \
    -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection'
  for from in session-mesh-stranger session-mesh-gateway; do
    for t in user-service:9101 video-service:9102 engagement-service:9103 feed-service:9104; do
      printf '%s %s: ' "$from" "${t%%:*}"
      AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp exec "pod/$from" -c probe -- \
        /nodejs/bin/node -e "$js" grpc "${t%%:*}.svp.svc.cluster.local:${t##*:}" </dev/null
    done
  done
)
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods,serviceaccounts -l app.kubernetes.io/managed-by=svp-session-mesh
```

Mong: một ref `<account>.dkr.ecr…@sha256:…`; hai pod cột `REDIRECTION` `enabled`; bốn dòng `session-mesh-stranger …: dns answered http=200
grpc=7` (`PERMISSION_DENIED`, lời từ chối RBAC của waypoint cho request gRPC; `http=403 grpc=` cũng đạt); bốn dòng `session-mesh-gateway
…: dns answered http=200 grpc=0`; dòng cuối `No resources found in svp namespace.` Pod lạ được trả lời `grpc=0`: AuthorizationPolicy
`<release>-waypoint` không chặn, dừng, dán output cho AI. Pod `gateway` nhận `refused` hay `silent`: đường mesh hỏng, theo runbook
`mesh-traffic-denied.md` (mục trên). `create` bị từ chối (Kyverno nêu `image not allowed …`, hay `AlreadyExists` của một lượt bị ngắt):
dán dòng lỗi; khối đã xoá thứ nó tạo, chạy lại khối. Dòng cuối còn tài nguyên: chạy lại đúng lệnh `delete` của `trap` rồi lệnh cuối, để
bước 20 không gặp chúng.

## Độ trễ mesh khi giữ tải

Loại: `chuẩn ngành`, không cần cờ; cần thang k6 đang giữ tải (mục [Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6)).
Thêm: truy vấn AMP và `kubectl top`, chỉ đọc; chi phí của mesh chưa có số ([phụ lục ADR-0075, Số
đo](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0075-service-mesh.md#số-đo)).

Độ trễ mesh là p99 của `rpc.client.call.duration` ở gateway trừ p99 của `rpc.server.call.duration` ở service, cùng
method, cửa sổ 5 phút dưới tải ([ADR-0075](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0075-service-mesh.md),
Hệ quả); cùng lúc đọc request mỗi giây của từng pod (waypoint cân tải theo request, không theo kết nối) và RAM, CPU của mesh.
Chạy khi một bậc k6 đang giữ tải: mốc `k6-<n>-start` của `timeline.tsv` cộng 2 phút lên tải, còn ≥ 5 phút giữ. Terminal có
khối [Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo):

```sh
c='histogram_quantile(0.99, sum by (le, rpc_method) (rate(rpc_client_call_duration_seconds_bucket{service_name="gateway"}[5m])))'
s='histogram_quantile(0.99, sum by (le, rpc_method) (rate(rpc_server_call_duration_seconds_bucket{service_name!="gateway"}[5m])))'
echo "== p99 gateway, client (s)"; promql "$c"
echo "== p99 service, server (s)"; promql "$s"
echo "== p99 mesh (s)"; promql "$c - on (rpc_method) $s"
echo "== requests per second per pod"
promql 'sum by (service_name, k8s_pod_name) (rate(rpc_server_call_duration_seconds_count{k8s_namespace_name="svp"}[5m]))'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n istio-system top pods
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-mesh top pods
```

Mong: mỗi method gRPC mà gateway gọi một dòng ở ba truy vấn đầu, dòng mesh là số đo (giây; giá trị âm nhỏ là sai số ước
lượng của histogram, ghi như đo); với service nhiều replica, request mỗi giây của các pod cùng `service_name` xấp xỉ
nhau (cân theo kết nối thì một pod nhận gần hết); RAM, CPU của từng pod `istiod`, `istio-cni-node`, `ztunnel`, waypoint.
Dán cả sáu output và số của bậc k6 lúc đo; số vào mục "Số đo" của phụ lục ADR-0075. Truy vấn rỗng: dán output và log của
Collector (lệnh cuối của mục [Nền tảng managed (c)](session-stg-check-managed.md#nền-tảng-managed-c-telemetry)).

## Chi phí theo namespace

Loại: `chuẩn ngành`, không cần cờ; đoạn dashboard cần `managed_grafana` `session` (AMG $18 mỗi buổi stg, mục [Dashboard SLO khi giữ
tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)). Thêm: truy vấn AMP, một port-forward, chỉ đọc; OpenCost chạy ở mọi buổi,
phần của nó ~$0,07–0,16 mỗi buổi stg ([phụ lục ADR-0074
§11](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0074-cost-uptime.md#mỗi-buổi-4-giờ-mỗi-env)).

OpenCost tính chi phí CPU, RAM được cấp phát theo namespace và service bằng giá on-demand công khai, đọc AMP qua sidecar
`sigv4proxy`; nhóm luật `svp-cost` ở ruler AMP ghi ba recording rule
([ADR-0074](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0074-cost-uptime.md); nghĩa và giới hạn của
số ở `docs/explanation/cost-and-uptime.md` của repo code: node Spot của stg tính theo giá on-demand, nên số stg là trần).
Sau ít nhất 30 phút chạy, terminal có khối dùng chung của mục [Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs get pods -l app.kubernetes.io/instance=opencost
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/opencost -c opencost --since=15m |
  grep -i -E 'pricing|error' | tail -n 20
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/opencost -c sigv4proxy --tail=20
promql 'namespace:svp_compute_cost_usd_per_hour:sum'
promql 'service:svp_compute_cost_usd_per_hour:sum'
promql 'cluster:svp_node_cost_usd_per_hour:sum'
```

Mong: pod `Running`, `READY` đủ; log `opencost` có dòng tải giá AWS xong, không dòng lỗi lặp lại (lời gọi
`DescribeSpotPriceHistory` bị từ chối trên stg là chủ ý, mục "Vì sao không Spot Data Feed" của trang giải thích); log
`sigv4proxy` không có `403`; mỗi namespace có pod một dòng USD mỗi giờ lớn hơn 0 (`svp`, `svp-obs`, `istio-system`…), mỗi
service của `svp` một dòng, tổng cluster lớn hơn tổng các namespace (phần chưa cấp phát). Dán cả sáu output.

API Allocation đọc thẳng OpenCost, đối chiếu với recording rule. Proxy của API server không dùng được: lời gọi tới pod từ
control plane, mà NetworkPolicy của OpenCost chỉ mở cổng 9003 cho Prometheus; `port-forward` vào thẳng network namespace
của pod. Cùng terminal, port-forward chạy nền rồi dừng ngay sau `curl`:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs port-forward svc/opencost 9003:9003 >/dev/null & pf=$!
sleep 3
curl -s -m 30 'http://127.0.0.1:9003/allocation/compute?window=1h&aggregate=namespace' | jq '.data[0] | map_values(.totalCost)'
kill "$pf"
```

Mong mỗi namespace một số USD của giờ qua, cùng cỡ với dòng của namespace đó ở `namespace:svp_compute_cost_usd_per_hour:sum`
(một giờ); `__idle__` bỏ qua (OpenCost tính phần capacity, idle sai khi tắt metric kube-state-metrics v1, như trang giải
thích ghi). `curl` không in gì: port-forward chưa lên sau 3 s, chạy lại khối; `kill` báo không có tiến trình là port-forward
đã chết sớm, dán lỗi của nó (chạy lại lệnh đầu không có `>/dev/null &`). Dán JSON.

Cờ `managed_grafana` khác `off`, trên AMG (mục [Dashboard SLO khi giữ tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)):
dashboard `svp-cost` và `svp-uptime`, khung 1 giờ gần nhất; chụp màn hình (che domain, account) hay ghi số đọc được của mỗi panel.

## Vận hành pod: timeout, grace, zone, DLQ

Loại: `chuẩn ngành`, không cần cờ. Thêm: lệnh chỉ đọc qua `svp-ops` và một truy vấn AMP, vài phút; ADR không có số thời gian.

Phép kiểm buổi không cần tải của mục "Xác nhận" của
[ADR-0072](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0072-pod-operations.md#xác-nhận): timeout của role app, cỡ pool,
preStop và startupProbe của gateway, grace của media-worker, ACL của user Kafka `svp-dlq-replay`. Trải zone và chạy thử phát lại DLQ ở mục
[Trải zone và chạy thử DLQ](#trải-zone-và-chạy-thử-dlq); kết nối RDS và chặn quá tải dưới tải ở mục [Chặn quá tải và pool khi giữ
tải](#chặn-quá-tải-và-pool-khi-giữ-tải). Sau bước 15, tunnel mở, terminal có khối dùng chung của mục [Hàm dùng chung của phép
đo](session-stg.md#hàm-dùng-chung-của-phép-đo).

(a) Timeout của role app trên RDS, đọc bằng `svp-pg` (role app, phiên chỉ đọc):

```sh
for s in video engagement feed; do
  for v in statement_timeout idle_in_transaction_session_timeout; do
    printf '%s %s ' "$s" "$v"
    AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c postgres -- \
      /opt/svp/bin/svp-pg "$s" -c "SHOW $v"
  done
done
```

Mong mỗi database `statement_timeout 5s` và `idle_in_transaction_session_timeout 30s`. Giá trị `0`: role chưa có
timeout (bootstrap Postgres của chart `svp-data` chưa chạy bản mới); dán output cho AI.

(b) Cỡ tối đa của pool mỗi service (`pgxpool_max_connections`), so với `DATABASE_MAX_CONNS` mà `svp-gitops` đặt cho stg:

```sh
promql 'max by (service_name, db_client_connection_pool_name) (pgxpool_max_connections)'
for r in user-service video-service engagement-service feed-service; do
  printf '%s ' "$r"; git -C ../gitops show "origin/main:envs/stg/$r.yaml" | sed -n 's/^ *DATABASE_MAX_CONNS: *"*\([0-9]*\)"*/\1/p'
done
```

Mong `user-service`, `video-service`, `feed-service` mỗi service một dòng bằng giá trị của `svp-gitops`;
`engagement-service` hai dòng (pool đọc, pool ghi) cộng lại bằng giá trị đó. Thiếu service: dán output và log của
Collector (lệnh cuối của mục [Nền tảng managed (c)](session-stg-check-managed.md#nền-tảng-managed-c-telemetry)).

(c) Pod spec: preStop và startupProbe của gateway, grace của media-worker:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout gateway -o jsonpath=\
'{.spec.template.spec.containers[0].lifecycle.preStop}{"\n"}{.spec.template.spec.containers[0].startupProbe}{"\n"}'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get deploy media-worker \
  -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
```

Mong `{"sleep":{"seconds":5}}`; startupProbe `httpGet` path `/healthz`, `periodSeconds` 2, `failureThreshold` 30; `570`
(hạn drain 540 s của media-worker cộng 30 s, dưới `terminationGracePeriod` 10 phút của NodePool Karpenter).

(d) ACL của `svp-dlq-replay` trên MSK:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- \
  /opt/svp/bin/svp-kafka acls --list --principal User:svp-dlq-replay
```

Mong `Read` trên bốn topic `.dlq` (`video.lifecycle.v1.dlq`, `media.transcodes.v1.dlq`, `user.follows.v1.dlq`, `engagement.views.v1.dlq`),
`Write` trên bốn topic gốc của chúng; không group, không quyền cluster. Rỗng hay thừa: dán output cho AI. Dán output của cả bốn phép.

## Trải zone và chạy thử DLQ

Loại: `chuẩn ngành`, không cần cờ; khi `svp-gitops` có `dlq-replay` trong `argocd/apps/components.json` và `zoneSpread` ở `platforms/eks`,
sau lượt sync của bản đó. Thêm: lệnh chỉ đọc và bốn lượt phát lại `--dry-run` không ghi gì; ADR không có số thời gian.

Phép kiểm buổi của [ADR-0072](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0072-pod-operations.md#xác-nhận) §1, §9: pod
của mỗi release trải trên các zone, lệnh phát lại DLQ đọc được bốn DLQ bằng user của nó. Tunnel mở. Điều kiện của mục (hai số lớn hơn 0;
`0` thì bỏ mục, ghi `chưa có`):

```sh
git -C ../gitops fetch origin
git -C ../gitops show origin/main:argocd/apps/components.json | grep -c '"dlq-replay"'
git -C ../gitops grep -l zoneSpread origin/main -- platforms/eks | grep -c .
```

(a) Trải zone: pod của mỗi release nằm ở ít nhất `min(số pod, số AZ)` zone khác nhau. stg trải pod trên `az_count` = 2
zone (`aws/envs/stg/stg.tfvars`; RDS và endpoint interface một zone không mang pod), nên mong `min(số pod, 2)`. Mỗi
release một dòng: số pod, zone của chúng, ràng buộc zone của pod (`<whenUnsatisfiable>/<minDomains>`), phase:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes -L topology.kubernetes.io/zone,karpenter.sh/nodepool
z=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg get nodes -o json |
  jq -c '[.items[] | {key: .metadata.name, value: .metadata.labels["topology.kubernetes.io/zone"]}] | from_entries')
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods -l app.kubernetes.io/component=server -o json |
  jq -r --argjson z "$z" '[.items[] | {r: .metadata.labels["app.kubernetes.io/name"], phase: .status.phase,
      zone: ($z[.spec.nodeName // ""] // "-"),
      spread: ([.spec.topologySpreadConstraints[]? | select(.topologyKey == "topology.kubernetes.io/zone")
        | "\(.whenUnsatisfiable)/\(.minDomains // "-")"] | first // "-")}]
    | group_by(.r)[] | "\(.[0].r) pods=\(length) zones=\([.[].zone] | unique | join(","))"
      + " spread=\([.[].spread] | unique | join(",")) \([.[].phase] | unique | join(","))"'
```

Mong release nhiều pod (`gateway`, `web`, `feed-service`…) có `zones=` hai zone và `spread=DoNotSchedule/2`, mọi pod
`Running`. Pod `Pending` vì zone (Karpenter chưa mở node ở zone thiếu): chờ vài phút, đọc lại; còn thì dán lý do của nó:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp describe pods --field-selector=status.phase=Pending | grep -A 8 '^Events:'
```

(b) Phát lại DLQ chỉ chạy thử (`--dry-run`: đọc và lọc, không produce): mỗi DLQ một lượt, log vào thư mục buổi. Log mỗi record chỉ có
partition, offset, topic đích, số byte của key, tên header; lệnh in dòng tổng và tên trường của các dòng record, không in log:

```sh
for t in video.lifecycle.v1.dlq media.transcodes.v1.dlq user.follows.v1.dlq engagement.views.v1.dlq; do
  f=$SVP_SESSION_DIR/dlq-dry-run-$t.log
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp exec deploy/dlq-replay -- /app replay --from "$t" --dry-run >"$f" 2>&1
  echo "== $t exit $?"
  grep -E '"dlq replay (finished|stopped)"' "$f"
  grep '"dlq record"' "$f" | jq -r 'keys_unsorted | join(",")' | sort -u
done
```

Mong mỗi DLQ `exit 0` và một dòng `"msg":"dlq replay finished"` có `"replayed":0`, `"dry_run"` bằng số record của DLQ (cluster mới mỗi
buổi: thường 0); DLQ có record thì thêm dòng tên trường, không trường `key` hay `value`. DLQ có record ở đây chỉ chạy thử: phát lại thật
theo runbook [`kafka-dlq-records.md`](https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/kafka-dlq-records.md) của repo
code khi người trực quyết. `exit 1` với dòng `dlq replay stopped`, hay `exit 2` (sai cờ): dán dòng đó cho AI. Dán output của (a) và (b).

## Chặn quá tải và pool khi giữ tải

Loại: `chuẩn ngành`, không cần cờ; cần thang k6 (mục [Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6)) đã chạy. Thêm:
truy vấn AMP và CloudWatch sau thang đo, chỉ đọc; ADR không có số thời gian.

Gateway trả ngay `503` khi số request đang xử lý trong một pod vượt `MAX_IN_FLIGHT`, và đếm chúng ở `svp.gateway.requests.shed`
(`svp_gateway_requests_shed_total` trên AMP); kết nối tới RDS phải dưới 80 % `max_connections`
([ADR-0072](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0072-pod-operations.md) §3, §5; trần của mỗi env ở [phụ
lục ADR-0072
§5](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0072-pod-operations.md#5-ngân-sách-kết-nối)). Sau
`measure.sh stg`, trước bước 20, terminal có khối dùng chung của mục [Hàm dùng chung của phép
đo](session-stg.md#hàm-dùng-chung-của-phép-đo). Mỗi bậc k6 một dòng: số request bị chặn trong bậc, số 5xx và p99 lớn nhất (ms) của
summary k6, số kết nối RDS lớn nhất (CloudWatch `DatabaseConnections`, Maximum mỗi phút):

```sh
at() { awk -F '\t' -v m="$1" -v c="$2" '$3 == m { t = $c } END { print t }' "$SVP_SESSION_DIR/timeline.tsv"; }
cut -f1 "$SVP_SESSION_DIR/k6-levels.tsv" | while read -r n; do
  [ -d "$SVP_SESSION_DIR/k6-$n/summaries" ] || continue
  s=$(at "k6-$n-start" 2) e=$(at "k6-$n-end" 2)
  shed=$(promql "sum(increase(svp_gateway_requests_shed_total[$((e - s))s]))" "$e" | awk '{ print $NF }')
  k6=$(cat "$SVP_SESSION_DIR/k6-$n"/summaries/pod-*.json | jq -s -r \
    '[.[].routes[]] | "5xx=\(map((.requests // 0) * (.failed_rate // 0)) | add | round) p99_ms=\(map(.p99_ms // 0) | max)"')
  rds=$(AWS_PROFILE=anhnv-stg aws --no-cli-pager cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
    --dimensions Name=DBInstanceIdentifier,Value=svp-stg --start-time "$(at "k6-$n-start" 1)" --end-time "$(at "k6-$n-end" 1)" \
    --period 60 --statistics Maximum --region ap-southeast-1 --query 'max(Datapoints[].Maximum)' --output text)
  printf '%s\tshed=%s\t%s\trds_max=%s\n' "$n" "${shed:-0}" "$k6" "$rds"
done
```

Mong mỗi bậc `shed=0` (mọi bậc của thang dưới mục tiêu tải của thiết kế 20 pod; series rỗng là chưa request nào bị chặn)
và `5xx=0`; `rds_max` dưới cột 80 % của dòng RDS stg ở bảng phụ lục đó. Khác thì ghi bậc, số và p99, không sửa trong buổi.
Dán bảng và `cat $SVP_SESSION_DIR/k6-levels.tsv`.

## Canary gRPC theo request

Loại: `chuẩn ngành`, không cần cờ; khi một release gRPC của `svp-gitops` có `canary: true` (`base/services/<release>.yaml`) và buổi phát
hành bản mới của nó (PR promote của `svp-gitops` merge giữa buổi) trong lúc thang k6 đang giữ tải. Thêm: một canary khoảng 3–4 phút (hai
bước chờ 60 s rồi gate, như canary của mục [Nền tảng managed (d): canary và cảnh báo
page](session-stg-check-managed.md#nền-tảng-managed-d-canary-và-cảnh-báo-page)); chi phí của mesh chưa có số ([phụ lục ADR-0075, Số
đo](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0075-service-mesh.md#số-đo)).

Release gRPC có `canary: true` là Rollout có `trafficRouting` qua plugin Gateway API của Argo Rollouts trên `GRPCRoute`
cùng tên: waypoint của mesh chia **từng lời gọi** giữa Service `<release>` (stable) và `<release>-canary` theo trọng số
của route, 25 % rồi 50 % rồi gate; AnalysisRun đo tỉ lệ lỗi và p99 trên pod canary
([ADR-0072](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0072-pod-operations.md) §8,
[ADR-0075](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0075-service-mesh.md)). Buổi không phát hành bản
mới nào của release gRPC: ghi `không có canary`. Release có canary và route của chúng (tunnel mở, terminal có khối dùng
chung của mục [Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo)):

```sh
git -C ../gitops fetch origin
git -C ../gitops grep -l '^canary: true' origin/main -- base/services | sed 's#.*/##; s#\.yaml$##'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get grpcroutes.gateway.networking.k8s.io
```

Mong release gRPC trong danh sách đầu (ngoài `gateway`, `web`) và một GRPCRoute cùng tên. Đặt `r` là release đó; khi một bậc k6 đã qua 2
phút lên tải (mốc `k6-<n>-start` của `timeline.tsv`), merge PR promote đổi image của nó. PR `bot/promote-stg` của `svp-backend` bật
auto-merge nên tự merge ngay khi `gitops-ok` xanh, không đợi bậc k6: khi PR mở, tắt nó bằng `gh pr merge <số PR> --repo
anhnvcoder/svp-gitops --disable-auto`, rồi merge tay (`gh pr merge <số PR> --repo anhnvcoder/svp-gitops --squash`) đúng lúc. Lượt chạy kế
của job bật lại auto-merge (`--auto`), nên tắt lại sau mỗi lượt. Sau đó đọc mỗi 15 giây tới khi Rollout `Healthy` (Ctrl-C):

```sh
r=<release gRPC>
while :; do
  printf '%s ' "$(date -u +%H:%M:%S)"
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout "$r" \
    -o jsonpath='{.status.phase} step={.status.currentStepIndex} canary={.status.canary.weights.canary.weight} '
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get grpcroute "$r" \
    -o jsonpath='route={.spec.rules[0].backendRefs[*].weight}{"\n"}'
  sleep 15
done | tee "$SVP_SESSION_DIR/canary-$r.txt"
```

Trong một bước chờ (trọng số 25 hay 50), terminal thứ hai đọc lời gọi mỗi giây của từng pod: pod mang hash canary nhận
phần gần bằng trọng số, dù gateway giữ kết nối lâu (chia theo request, không theo kết nối):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout "$r" \
  -o jsonpath='stable={.status.stableRS} canary={.status.currentPodHash}{"\n"}'
promql "sum by (k8s_pod_name) (rate(rpc_server_call_duration_seconds_count{k8s_namespace_name=\"svp\",service_name=\"$r\"}[1m]))"
```

Rollout xong, giá trị của hai AnalysisRun mới nhất của release:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io --sort-by=.metadata.creationTimestamp -o json |
  jq -r --arg r "$r-" '[.items[] | select(.metadata.name | startswith($r))][-2:][]
    | "\(.metadata.name) \(.status.phase) \([.status.metricResults[]? | "\(.name)=\([.measurements[].value] | join(","))"] | join("; "))"'
```

Mong: file `canary-$r.txt` có `canary=25 … route=75 25`, rồi `canary=50 … route=50 50`, cuối cùng `Healthy` với `route=100
0`; phần lời gọi của pod canary gần 25 % rồi 50 %; hai AnalysisRun (nền, gate) `Successful`, mọi giá trị ≥ 0.
`Inconclusive` với `-1` (canary dưới 30 lời gọi một phút): Rollout dừng chờ người, ghi số lời gọi của release
(`promql "sum(increase(rpc_server_call_duration_seconds_count{k8s_namespace_name=\"svp\",service_name=\"$r\"}[1m]))"`) và
dán output cho AI. `Degraded` (canary bị abort, bản stable nhận mọi lời gọi, `route=100 0`): dán file, AnalysisRun và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout "$r" -o jsonpath='{.status.message}{"\n"}'`.

## Gỡ

Các phép kiểm ở trang này không để lại tài nguyên của buổi ngoài những thứ nó tự nêu (pod, tệp trong `$SVP_SESSION_DIR`); gỡ cuối buổi ở
[`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31).

## Khi một bước đỏ

Phép kiểm đỏ thì ghi kết quả, dán output cho AI rồi sang phép kế: bước 16 là bước duy nhất của bảng
[Thứ tự](session-stg.md#thứ-tự) được đi tiếp khi đo hỏng. Lỗi riêng của từng phép ở nhãn **Bẫy** hay phần **Mong** của nó; destroy kẹt:
[Destroy kẹt](session-stg.md#destroy-kẹt).
