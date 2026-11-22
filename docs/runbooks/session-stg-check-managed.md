# Runbook: phép kiểm dịch vụ managed của buổi stg (bước 16)

← [Phép kiểm edge và media](session-stg-check-edge-media.md) · [Mục lục](README.md) · [Diễn tập khôi phục](session-stg-drills.md) →

> **Tóm tắt**
>
> - **Làm gì:** kiểm Kafka (MSK), Valkey (ElastiCache) và nền tảng managed (registry, observability, endpoint): image từ ECR, mạng riêng,
>   telemetry, luật cảnh báo trên AMP, canary và cảnh báo `page`, dữ liệu còn sau destroy. `lõi`: luật cảnh báo trên AMP; `chuẩn ngành`:
>   các phép còn lại. Cờ cần bật: `inspector_ecr` `always` cho đoạn Inspector của (a); `managed_grafana` `session` cho (e) của Kafka và
>   Valkey và đoạn AMG của (c).
> - **Khi nào và bao lâu:** sau bước 15, tunnel mở; (d) canary cần PR ở `svp-gitops` mở trước buổi và thang k6 đang giữ tải; (e) cần khoảng
>   ghi ít nhất 10 phút trước bước 20.
> - **Phí trong lúc chạy:** truy vấn AMP và Logs Insights; phần Inspector và AMG là khoản thêm ghi ở dòng `Loại:` của từng mục.

Thiết kế: [ADR-0062](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0062-ecr-registry-ci-oidc.md) (image kéo từ ECR của
account, pull-through cache làm nóng mỗi buổi, Inspector);
[ADR-0063](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0063-managed-observability.md) (metric vào AMP, log vào CloudWatch
Logs, trace vào X-Ray, luật trên AMP tới SNS, dashboard trên Amazon Managed Grafana khi cờ của nó không `off`, canary hỏi AMP);
[ADR-0064](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0064-interface-endpoints.md) (API AWS qua endpoint interface có
private DNS).

## Điều kiện trước

- [ ] **Bước 1–15 xong**: apply root env và root gitops thành công, `bootstrap.sh stg wait` (bước 15) báo mọi Application `Healthy`
  ([`session-stg-deploy.md`](session-stg-deploy.md#15-chờ-argo-cd)).
- [ ] **Tunnel tới API còn mở** ([Tunnel tới API](session-stg-deploy.md#tunnel-tới-api-sau-bước-9-trước-bước-11), giữ tới hết bước 22).
- [ ] **Terminal của buổi** ([Mở terminal](session-stg.md#mở-terminal)): cùng `SVP_SESSION_DIR` với các bước trước.
- [ ] **Hàm dùng chung đã nạp** ([Hàm dùng chung của phép đo](session-stg.md#hàm-dùng-chung-của-phép-đo)): `amp_get`, `promql`, `insights`
  nằm ở trang chủ, chạy khối đó một lần trong terminal (mở lại terminal thì chạy lại).
- [ ] **Thang k6 đang giữ tải** cho mục Nền tảng managed (d): canary và cảnh báo page; **PR ở `svp-gitops`** mở trước buổi
  ([Seed và thang k6](session-stg-check-release.md#seed-và-thang-k6)).

## Mở terminal

Dùng đúng terminal của buổi: mục [Mở terminal](session-stg.md#mở-terminal) của trang chủ (mở lại giữa buổi: cùng mục đó, với
`SVP_SESSION_DIR` là thư mục của buổi đang dở). Lệnh chạy từ gốc repo (`infra/`).
Trang này cần `SVP_SESSION_DIR`, `SVP_AWS_STG_ACCOUNT_ID`, rồi `E`, `ecr`, `ws` của
[hàm dùng chung](session-stg.md#hàm-dùng-chung-của-phép-đo).

## Kafka và Valkey managed

Loại: `chuẩn ngành`, không cần cờ; (e) cần `managed_grafana` `session` (AMG $18 mỗi buổi stg, mục [Dashboard SLO khi giữ
tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)) và thang k6 đang giữ tải. Thêm: lệnh chỉ đọc qua `svp-ops`, một topic thử
tạo rồi xoá; ADR không có số thời gian.

Phép kiểm (a)–(e) của mục "Xác nhận" của
[ADR-0053](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0053-msk-elasticache-valkey.md#xác-nhận); (b) là smoke của
`measure.sh` (service ghi, đọc Kafka qua SASL/SCRAM-SHA-512 trên TLS), (f) là hai lượt `sweep.sh` cuối buổi. Lệnh và output có thời điểm UTC
vào phụ lục, một dòng kết luận mỗi env vào "Xác nhận". Buổi prd chạy đúng các lệnh này với `anhnv-prd`, `svp-prd`.

Mọi lệnh chạm Kafka, Valkey đi qua CLI vận hành (ADR-0053 §13): `svp-kafka` (đăng nhập `svp-admin`), `svp-valkey` (đăng nhập `svp-ops`)
trong Deployment `svp-data/svp-ops`, không `kubectl run`, không công cụ trên máy. Thử quyền của một user thường: `SVP_AS_USER=<user>`, mật
khẩu là dòng đầu của stdin, lấy từ Secret của chính client đó (`svp/<service>-env`), không qua đối số, không in ra.

(a) MSK `ACTIVE` với cấu hình của ADR-0053 §2, ElastiCache `available`; phút dựng là hai dòng `Creation complete after …` của bước 9, phút
gỡ là hai dòng `Destruction complete after …` của bước 27; plan lần hai `No changes` là phép (c) của mục [Gói Free của
media](session-stg-check-edge-media.md#gói-free-của-media):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --output text \
  --query 'ClusterInfoList[].[State,Provisioned.CurrentBrokerSoftwareInfo.KafkaVersion,Provisioned.BrokerNodeGroupInfo.InstanceType,Provisioned.NumberOfBrokerNodes]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager kafka list-clusters-v2 --cluster-name-filter svp-stg --region ap-southeast-1 --output text \
  --query 'ClusterInfoList[].Provisioned.[ClientAuthentication.Sasl.Scram.Enabled,ClientAuthentication.Sasl.Iam.Enabled,EncryptionInfo.EncryptionInTransit.ClientBroker]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache describe-replication-groups --replication-group-id svp-stg --region ap-southeast-1 --output text \
  --query 'ReplicationGroups[].[Status,TransitEncryptionMode,AtRestEncryptionEnabled,length(MemberClusters)]'
AWS_PROFILE=anhnv-stg aws --no-cli-pager elasticache describe-users --region ap-southeast-1 --output text \
  --query "Users[?starts_with(UserId, 'svp-stg-')].[UserName,Status,AccessString]"
```

Mong `ACTIVE`, `4.1.x.kraft`, `kafka.t3.small`, `2`; `True`, `False`, `TLS`; `available`, `required`, `True`, `1`; bốn user `active` với
access string đúng nguyên văn ADR-0053 §9 (ElastiCache viết lại một chuỗi là mục "Xem lại khi" của ADR: dán cho AI). Dán lại cả bốn output.

(c) Topic, ACL, và một service bị từ chối trên topic không có ACL của nó. Topic thử `svp-acl-check` tạo bằng `svp-admin` rồi xoá ngay:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --list --exclude-internal
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka acls --list --principal User:svp-feed-service
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --create --topic svp-acl-check --partitions 1
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret feed-service-env -o jsonpath='{.data.KAFKA_SASL_PASSWORD}' | base64 --decode)
printf '%s\nprobe\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c kafka -- \
  env SVP_AS_USER=svp-feed-service /opt/svp/bin/svp-kafka console-producer --topic svp-acl-check --producer-property max.block.ms=15000 2>&1 |
  grep -m 1 -oE '(TopicAuthorization|SaslAuthentication)Exception[^\[]*(\[[^]]*\])?'
unset pw
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --delete --topic svp-acl-check
```

Mong tám topic (`video.lifecycle.v1`, `media.transcodes.v1`, `user.follows.v1`, `engagement.views.v1` và bốn topic `.dlq` của chúng); ACL
của `svp-feed-service` chỉ Read trên `user.follows.v1`, `video.lifecycle.v1`, Write trên `user.follows.v1.dlq`, `video.lifecycle.v1.dlq`,
Read trên group `feed-service`; dòng `TopicAuthorizationException: Not authorized to access topics: [svp-acl-check]`.
`SaslAuthenticationException` là mật khẩu của Secret không khớp secret `AmazonMSK_svp-stg-svp-feed-service` (MSK đồng bộ tới 10 phút sau
apply): đọc lại sau 10 phút, còn thì dán cho AI.

(d) ACL Valkey chặn db và tiền tố khoá của service khác (mật khẩu là phần giữa `:` và `@` của `REDIS_URL` trong Secret của service):

```sh
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret feed-service-env -o jsonpath='{.data.REDIS_URL}' | base64 --decode |
  sed -E 's#^rediss://[^:]+:([A-Za-z0-9]+)@.*#\1#')
printf '%s\nSELECT 10\nSELECT 14\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c valkey -- \
  env SVP_AS_USER=svp-feed-service /opt/svp/bin/svp-valkey
pw=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get secret gateway-env -o jsonpath='{.data.REDIS_URL}' | base64 --decode |
  sed -E 's#^rediss://[^:]+:([A-Za-z0-9]+)@.*#\1#')
printf '%s\nGET svp:feed:explore:check\nGET svp:gw:check\n' "$pw" | AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec -i deploy/svp-ops -c valkey -- \
  env SVP_AS_USER=svp-gateway /opt/svp/bin/svp-valkey -n 10
unset pw
```

Mong, theo thứ tự: một dòng `NOPERM …` (`svp-feed-service` không vào db 10) rồi `OK` (db 14 của nó); một dòng `NOPERM …` (`svp-gateway`
không đọc `svp:feed:*`) rồi một dòng trống (khoá `svp:gw:check` không có, đọc được). `WRONGPASS` hay lỗi TLS: dán cho AI.

(e) Lag hiện trên dashboard: trong lúc giữ tải, AMG (mục [Dashboard SLO khi giữ
tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)) dashboard "SVP — Kafka and pipeline", panel "Consumer lag by group (max over
partitions)" có đường của bốn group `video-service`, `engagement-service`, `feed-service`, `media-worker` (receiver `kafkametrics` của
Collector, user `svp-otelcol`). Đối chiếu với broker:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka consumer-groups --describe --all-groups
```

Mong cột `LAG` của mỗi group cùng cỡ với panel. Panel trống: dán lỗi của receiver
(`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/otel-collector --tail=50 | grep -i kafka`) cho AI.

## Phép kiểm nền tảng managed

Loại: `lõi` ([luật cảnh báo trên AMP](#nền-tảng-managed-d-luật-cảnh-báo-trên-amp), dùng hàm của mục [Hàm dùng chung của phép
đo](session-stg.md#hàm-dùng-chung-của-phép-đo)); mỗi phép (a)–(e) là một mục có dòng `Loại:` riêng, (f) là bước 30–31.

Phép kiểm buổi của mục "Xác nhận" của ADR-0062 (registry), ADR-0063 (observability), ADR-0064 (endpoint): image kéo từ ECR, mạng riêng,
telemetry, cảnh báo, canary, dữ liệu còn sau destroy. Làm trong bước 16, tunnel mở; lệnh và output có thời điểm UTC vào một file của
`$SVP_SESSION_DIR`, một dòng kết luận mỗi phép vào "Xác nhận" của ADR tương ứng. Buổi prd chạy (a), (b), (c), (e) và phần luật của (d) với
`anhnv-prd`, `--context svp-prd`, `svp-prd` (mục cùng tên của
[`session-prd-checks.md`](session-prd-checks.md#phép-kiểm-nền-tảng-managed)).

(f) Quét sót: `sweep.sh stg` và `sweep.sh mgmt` sạch ở bước 30–31, cùng các loại mới (endpoint interface, rule groups
namespace của AMP) và dòng `kept` của registry, observability.

Hàm `amp_get`, `promql`, `insights` và biến `E`, `ws`, `amp`, `ecr` định nghĩa một lần ở mục [Hàm dùng chung của phép
đo](session-stg.md#hàm-dùng-chung-của-phép-đo) của trang chủ buổi (chạy khối đó trước).

## Nền tảng managed (a): image từ ECR

Loại: `chuẩn ngành`, không cần cờ; đoạn Inspector cần `inspector_ecr` `always` của `stg`. Thêm: Inspector 0 khi không có digest bên thứ ba
mới, tới $6,8 ở buổi đầu, tới $9 ở buổi cách buổi trước một tháng (dòng `inspector_ecr` của [phụ lục ADR-0071,
Cờ](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/appendix/0071-paid-features.md#cờ)); phần còn lại chỉ đọc.

(a) Image (ADR-0062): pod kéo image từ ECR của account (policy `svp-registry-mirror` đổi tham chiếu lúc tạo pod, IVP `svp-images` xác minh ở
ECR bằng Pod Identity của Kyverno); host image theo namespace:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get pods -A -o json |
  jq -r '.items[] | .metadata.namespace as $n | ((.spec.initContainers // [])[], .spec.containers[]) | "\($n) \(.image | split("/")[0])"' |
  sort | uniq -c | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/g"
```

Mong mọi namespace chỉ có host `<account>.dkr.ecr.ap-southeast-1.amazonaws.com`, trừ `kube-system` (Kyverno không nhận request của
namespace này: Karpenter, Load Balancer Controller, add-on EKS kéo upstream hay ECR của AWS), `kyverno` (policy loại trừ) và `argocd`
(Terraform cài trước khi policy có; pod tạo trước policy kéo upstream tới lần tạo lại). Namespace khác có host `ghcr.io`, `docker.io`,
`quay.io`, `registry.k8s.io`, `public.ecr.aws`: dán output. Chữ ký và attestation đi theo bản ECR (đăng nhập ECR vào một `DOCKER_CONFIG`
tạm, mật khẩu qua stdin):

```sh
img=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get pods -o json |
  jq -r '[.items[].spec.containers[].image | select(contains("/svp-backend/gateway@"))][0]')
echo "$img" | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/"
export DOCKER_CONFIG=$(mktemp -d)
AWS_PROFILE=anhnv-stg aws --no-cli-pager ecr get-login-password --region ap-southeast-1 | cosign login "$ecr" -u AWS --password-stdin
ident=(--certificate-oidc-issuer https://token.actions.githubusercontent.com
  --certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
cosign verify "${ident[@]}" "$img" >/dev/null 2>&1 && echo "signature verified"
for t in vuln slsaprovenance1; do cosign verify-attestation --type "$t" "${ident[@]}" "$img" >/dev/null 2>&1 && echo "$t verified"; done
rm -rf "$DOCKER_CONFIG"; unset DOCKER_CONFIG
```

Mong `<account>.dkr.ecr…/svp-backend/gateway@sha256:…` rồi ba dòng `verified`. Thiếu dòng: chạy lại lệnh đó không có `>/dev/null 2>&1`,
dán lỗi. Cờ `inspector_ecr` của env là `off` (mục [Cờ chi phí của buổi](session-stg.md#cờ-chi-phí-của-buổi)): registry dùng quét cơ bản
khi push, không Inspector; đọc cấu hình quét thay cho hai lệnh Inspector dưới, mong `BASIC SCAN_ON_PUSH` (digest ghim chỉ có quét cơ bản
tới buổi prd, khi prd chạy với `inspector_ecr` `always` và Inspector của prd quét nó;
[ADR-0078](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0078-paid-features-lean-defaults.md) §7):

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager ecr get-registry-scanning-configuration --region ap-southeast-1 --output text \
  --query 'scanningConfiguration.[scanType,rules[0].scanFrequency]'
```

Cờ `always`: Inspector quét repo cache (image bên thứ ba vừa làm nóng; vài phút sau khi image vào cache), không quét repo phát hành:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager inspector2 list-coverage --region ap-southeast-1 --output text \
  --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_ECR_CONTAINER_IMAGE"}]}' \
  --query 'coveredResources[].scanStatus.statusCode' | tr '\t' '\n' | sort | uniq -c
AWS_PROFILE=anhnv-stg aws --no-cli-pager inspector2 list-findings --region ap-southeast-1 --max-results 10 --output text \
  --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_ECR_CONTAINER_IMAGE"}],"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' \
  --sort-criteria field=SEVERITY,sortOrder=DESC --query 'findings[].[severity,resources[0].details.awsEcrContainerImage.repositoryName,title]'
```

Mong phần lớn image `ACTIVE` (đang được quét liên tục); ít nhất một finding, repo của nó bắt đầu bằng `ghcr/`, `docker-hub/`, `quay/`,
`k8s/` hay `ecr-public/`, không repo `svp-backend/`, `svp-frontend/`. Rỗng: đọc lại cuối bước 16; vẫn rỗng thì dán cả hai output. Finding
cũng vào Security Hub của `svp-security` (`ProductName` Inspector), không gửi email.

## Nền tảng managed (b): mạng riêng

Loại: `chuẩn ngành`, không cần cờ. Thêm: lệnh chỉ đọc; ADR không có số thời gian.

(b) Mạng riêng (ADR-0064): endpoint interface có private DNS ở subnet private (stg một AZ), tên API AWS phân giải ra IP trong VPC từ một
pod, Kyverno và External Secrets vẫn gọi được API qua đó:

```sh
jq -r .vpcCidr "$values"
AWS_PROFILE=anhnv-stg aws --no-cli-pager ec2 describe-vpc-endpoints --region ap-southeast-1 --output text \
  --filters "Name=vpc-id,Values=$(jq -r .vpcId "$values")" Name=vpc-endpoint-type,Values=Interface \
  --query 'VpcEndpoints[].[ServiceName,State,PrivateDnsEnabled,length(SubnetIds)]' | sort
for n in sts secretsmanager logs api.ecr "$ecr" aps-workspaces aps xray ssm ec2 elasticloadbalancing sqs eks-auth; do
  case $n in *.amazonaws.com) h=$n ;; eks-auth) h=eks-auth.ap-southeast-1.api.aws ;; *) h=$n.ap-southeast-1.amazonaws.com ;; esac
  printf '%s ' "$h" | sed "s/$SVP_AWS_STG_ACCOUNT_ID/<account>/"
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-data exec deploy/svp-ops -c valkey -- nslookup "$h" 2>/dev/null |
    awk '/^Address/ && !/:53$/ { printf "%s ", $NF } END { print "" }'
done
```

Mong: CIDR của VPC; 15 dòng của ADR-0064 §1 (`com.amazonaws.ap-southeast-1.sts`, `eks-auth`, `secretsmanager`, `logs`, `ssm`,
`ssmmessages`, `ec2messages`, `ecr.api`, `ecr.dkr`, `ec2`, `elasticloadbalancing`, `aps-workspaces`, `aps`, `xray`, `sqs`) cộng
`guardduty-data`, mỗi dòng `available True 1` (prd `3`); mỗi tên in ít nhất một IP trong CIDR đó, không IP công khai (`nslookup` của
BusyBox trong container `valkey` của `svp-ops`). Tên ra IP công khai: private DNS của endpoint đó chưa bật hay endpoint thiếu: dán output.
Rồi Kyverno, External Secrets và Pod Identity:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n kyverno get pods
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n external-secrets get pods
AWS_PROFILE=anhnv-stg kubectl --context svp-stg get externalsecrets.external-secrets.io -A -o json |
  jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
    | "\(.metadata.namespace)/\(.metadata.name)"] as $bad | "\(.items | length) ExternalSecrets, not Ready: \($bad | if length == 0 then "none" else join(" ") end)"'
AWS_PROFILE=anhnv-stg aws --no-cli-pager eks list-pod-identity-associations --cluster-name svp-stg --region ap-southeast-1 \
  --query 'associations[].[namespace,serviceAccount]' --output text | sort
```

Mong mọi pod `Running` và `READY` đủ; dòng `<N> ExternalSecrets, not Ready: none`; association có đủ danh tính của
module `eks` (`local.pod_identity_roles` ở `aws/modules/eks/iam.tf`) cạnh các danh tính có sẵn. ExternalSecret không
Ready hay pod Kyverno không Ready: NetworkPolicy chưa mở 443 tới CIDR của VPC (value `awsEndpointCidrs`); dán output và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n external-secrets logs deploy/external-secrets --tail=30`.

## Nền tảng managed (c): telemetry

Loại: `chuẩn ngành`, không cần cờ; đoạn AMG (Explore, dashboard, Grafana Operator) cần `managed_grafana` `session` (AMG $18 mỗi buổi stg,
mục [Dashboard SLO khi giữ tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)). Thêm: truy vấn AMP và Logs Insights; số đo đầy
đủ cần thang k6 đang giữ tải.

(c) Telemetry (ADR-0063): metric ở AMP (agent và Collector), log ở `/svp/stg/otel`, span ở `aws/spans`, series service graph do Collector
sinh; trong lúc k6 giữ tải:

```sh
promql 'count by (job) (up{cluster="svp-stg"})'
promql 'count by (service_name) ({__name__=~"svp_.+"})'
promql 'sum by (client, server) (traces_service_graph_request_total)'
insights /svp/stg/otel "$(( $(date +%s) - 900 ))" "$(date +%s)" 'stats count(*) as records'
insights aws/spans "$(( $(date +%s) - 900 ))" "$(date +%s)" 'stats count(*) as spans, count_distinct(traceId) as traces'
```

Mong: mỗi job mà agent scrape một dòng (cluster `svp-stg`); mỗi service của lab đang nhận tải một dòng (metric OTLP của Collector, tên như
trên Prometheus); cặp `client`, `server` của các lời gọi gateway → service; `records`, `spans`, `traces` lớn hơn 0. Rỗng: dán output và
`AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs logs deploy/otel-collector --tail=50` (lỗi SigV4, 403, timeout tới endpoint).
Trễ remote write của agent (số đo cho ADR-0063 §8, giây; tiêu chí ≤ 30):

```sh
promql 'max(max_over_time((prometheus_remote_storage_highest_timestamp_in_seconds - ignoring(remote_name, url) group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds)[30m:30s]))'
```

Cờ `managed_grafana` khác `off`, trên AMG (mục [Dashboard SLO khi giữ tải](session-stg-check-release.md#dashboard-slo-khi-giữ-tải)):
**Explore** → data source `prometheus` → `up{cluster="svp-stg"}` có kết quả (metric qua AMG); **Dashboards**: mọi dashboard "SVP — …" của
repo code (mỗi file của `deploy/observability/grafana/dashboards` một cái), mỗi cái khung 1 giờ gần nhất, ghi tên mọi panel "No data".
Panel của "SVP — Web vitals (RUM)" chỉ có dữ liệu khi trình duyệt mở web (phép (d) của mục [Gói Free của
media](session-stg-check-edge-media.md#gói-free-của-media)); hai panel Tempo (TraceQL, service map) không có trên eks. Grafana Operator đã
đồng bộ:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs get \
  grafanas.grafana.integreatly.org,grafanadatasources.grafana.integreatly.org,grafanadashboards.grafana.integreatly.org -o json |
  jq -r '.items[] | "\(.kind) \(.metadata.name) \(.status.stage // "") \([.status.conditions[]? | "\(.type)=\(.status)"] | join(","))"'
```

Mong một `Grafana` (`stage` hoàn tất), hai `GrafanaDatasource`, mỗi dashboard một `GrafanaDashboard`, mọi điều kiện `…=True`.
Dán danh sách panel trống theo dashboard (rỗng là đạt).

## Nền tảng managed (d): luật cảnh báo trên AMP

Loại: `lõi`.

(d) Cảnh báo và canary (ADR-0063 §5, §8,
[ADR-0080](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0080-amp-rule-interval-stg.md)).
Luật của chart ở AMP, chu kỳ 30 s của overlay stg (quota mặc định, bước (8) của
[`platform-setup.md`](platform-setup.md#bước-8-quota-chu-kỳ-luật-amp)), Alertmanager của AMP gửi SNS:

```sh
AWS_PROFILE=anhnv-stg aws --no-cli-pager amp list-rule-groups-namespaces --workspace-id "$ws" --region ap-southeast-1 \
  --query 'ruleGroupsNamespaces[].[name,status.statusCode]' --output text
AWS_PROFILE=anhnv-stg aws --no-cli-pager amp describe-alert-manager-definition --workspace-id "$ws" --region ap-southeast-1 \
  --query 'alertManagerDefinition.status.statusCode' --output text
amp_get api/v1/rules | jq -r '.data.groups[] | "\(.name) \(.interval) \(.rules | length)"'
```

Mong hai namespace `svp-alerts`, `slo-generated` `ACTIVE`; `ACTIVE`; mỗi nhóm luật một dòng chu kỳ `30`. Namespace `CREATION_FAILED` (chu
kỳ dưới quota) hay thiếu: dán output và `AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp-obs describe
rulegroupsnamespaces.prometheusservice.services.k8s.aws`.

## Nền tảng managed (d): canary và cảnh báo page

Loại: `chuẩn ngành`, không cần cờ; cần PR ở `svp-gitops` mở trước buổi và thang k6 đang giữ tải (mục [Seed và thang
k6](session-stg-check-release.md#seed-và-thang-k6)). Thêm: chờ cảnh báo khoảng 12 phút sau abort, canary chạy lại khoảng 3–4 phút (số của
mục này).

Canary thật của gateway và một cảnh báo `page` dùng chung một revision mới: một PR ở `svp-gitops` thêm vào `envs/stg/gateway.yaml` một
annotation của pod template (cùng image, revision mới, nên Argo Rollouts chạy canary; cách diễn tập canary của lab), mở và chờ check xanh
**trước buổi**, chưa merge:

```yaml
podAnnotations:
  svp-session-canary: "<UTC của buổi, vd 2026-11-20T03:00Z>"
```

Đường lỗi trước: một policy inline tạm chặn `aps:QueryMetrics` của role Pod Identity `svp-stg-argo-rollouts` (IAM xét policy ở mỗi
request, nên credential đang có của controller bị chặn ngay; không sửa code), rồi merge PR. AnalysisRun nền lỗi ba lần liên tiếp thì
Rollout bị abort, Application `gateway` thành Degraded, và sau 10 phút luật `ArgoCDApplicationDegraded` (`page`) cháy:

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam put-role-policy --role-name svp-stg-argo-rollouts --policy-name svp-session-deny-query --region us-east-1 \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"aps:QueryMetrics","Resource":"*"}]}'
date -u +%Y-%m-%dT%H:%M:%SZ | tee "$SVP_SESSION_DIR/canary-deny-start"
```

Merge PR, rồi đọc mỗi phút (Argo CD sync trong vài phút; AnalysisRun nền đo từ giây 60 của canary):

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get rollout gateway -o jsonpath='{.status.phase} {.status.abort} {.status.message}{"\n"}'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io --sort-by=.metadata.creationTimestamp -o json |
  jq -r '.items[-2:][] | "\(.metadata.name) \(.status.phase) \([.status.metricResults[]? | "\(.name): \(.measurements[-1] | "\(.phase) \(.value // "") \(.message // "")")"] | join("; "))"'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get httproute api -o jsonpath='{.spec.rules[0].backendRefs[*].weight}{"\n"}'
```

Mong: AnalysisRun mới nhất `gateway-…` `Error`, measurement `Error` nêu `AccessDenied` hay `403`; Rollout `Degraded true` với message
`RolloutAborted…`; trọng số `100 0` (canary không được promote, bản stable nhận mọi request). Rồi chờ cảnh báo (khoảng 12 phút sau abort:
`for` 10 phút, `rule_query_offset` 60 s, chu kỳ đánh giá):

```sh
amp_get api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.labels.name // "-") \(.labels.severity) \(.state) \(.activeAt)"'
```

Mong dòng `ArgoCDApplicationDegraded gateway page firing` (Application cha có thể có dòng của mình); vài phút sau một thư SNS của topic
`svp-stg-alarms` tới `alarm_email` mang `ArgoCDApplicationDegraded`, `severity` `page` và `runbook_url`
`…/docs/runbooks/argocd-application-degraded.md`. Dán dòng `firing`, tiêu đề và giờ nhận thư, nguyên văn phần thân (che account). Không
thư: đọc lại subscription (mục [6–10](session-stg-deploy.md#610-root-env-init-khoá-ký-plan-lưu-file-đọc-apply-file-đó-kích-hoạt-khoá-ký)),
rồi dán output của `amp_get api/v1/alerts`.

Trả lại, rồi canary đi tiếp **trong lúc k6 giữ tải** (canary cần ít nhất 30 response không 4xx mỗi phút: chờ mốc `k6-<n>-start` của một bậc
trong `timeline.tsv` cộng 2 phút lên tải; còn ≥ 6 phút giữ tải):

```sh
aws/scripts/check-account.sh stg
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam delete-role-policy --role-name svp-stg-argo-rollouts --policy-name svp-session-deny-query --region us-east-1
AWS_PROFILE=anhnv-stg aws --no-cli-pager iam list-role-policies --role-name svp-stg-argo-rollouts --region us-east-1 --query PolicyNames --output text
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp patch rollout gateway --subresource=status --type=merge -p '{"status":{"abort":false}}'
```

Dòng `list-role-policies` không còn `svp-session-deny-query`. Lệnh `patch` là "retry" của Argo Rollouts (gỡ cờ abort): canary chạy lại từ
25 %, khoảng 3–4 phút. Đọc lại bằng khối đọc ở trên, rồi giá trị mọi lần đo của hai AnalysisRun mới nhất:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io --sort-by=.metadata.creationTimestamp -o json |
  jq -r '.items[-2:][] | "\(.metadata.name) \(.status.phase) \([.status.metricResults[]? | "\(.name)=\([.measurements[].value] | join(","))"] | join("; "))"'
```

Mong Rollout `Healthy` (cờ abort `false`), trọng số `100 0` sau khi promote xong, hai AnalysisRun (nền và `…-gate`) `Successful`, mọi
giá trị ≥ 0 (không `-1`: số đo thật từ AMP). `Inconclusive` với `-1`: canary thiếu tải hay mẫu tới AMP trễ (trễ remote write ở (c));
`Error` sau khi gỡ policy: chờ một phút rồi retry lại; còn thì dán output. Annotation ở lại trong `envs/stg/gateway.yaml` (không đổi gì
ngoài pod template); bỏ nó là một revision mới, tức một canary nữa.

Hai AnalysisRun thủ công, cùng metric `canary-5xx-ratio` của template `gateway-canary-gate` đọc từ cluster: một cái điều kiện thất bại
luôn đúng (`result[0] >= -1`, mong `Failed`), một cái trỏ workspace không có (mong `Error`); không Rollout nào dùng chúng:

```sh
tpl=$(AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysistemplate gateway-canary-gate -o json)
jq '{apiVersion: "argoproj.io/v1alpha1", kind: "AnalysisRun",
  metadata: {generateName: "session-check-failed-", namespace: "svp", labels: {"svp-session-check": "true"}},
  spec: {metrics: [.spec.metrics[0] | del(.successCondition) | .failureCondition = "result[0] >= -1"]}}' <<<"$tpl" |
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg create -f -
jq '{apiVersion: "argoproj.io/v1alpha1", kind: "AnalysisRun",
  metadata: {generateName: "session-check-error-", namespace: "svp", labels: {"svp-session-check": "true"}},
  spec: {metrics: [.spec.metrics[0] | .provider.prometheus.address |= sub("ws-[0-9a-f-]+"; "ws-00000000-0000-0000-0000-000000000000")]}}' <<<"$tpl" |
  AWS_PROFILE=anhnv-stg kubectl --context svp-stg create -f -
```

Một phút sau, đọc rồi xoá:

```sh
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp get analysisruns.argoproj.io -l svp-session-check=true -o json |
  jq -r '.items[] | "\(.metadata.name) \(.status.phase) \(.status.metricResults[0].measurements[-1] | "\(.phase) \(.value // "") \(.message // "")")"'
AWS_PROFILE=anhnv-stg kubectl --context svp-stg -n svp delete analysisruns.argoproj.io -l svp-session-check=true
```

Mong `session-check-failed-… Failed Failed <số ≥ -1>` và `session-check-error-… Error Error … 404` (hay thông điệp không tìm thấy
workspace).

## Nền tảng managed (e): dữ liệu còn sau destroy

Loại: `chuẩn ngành`, không cần cờ. Thêm: khoảng ghi ít nhất 10 phút trước bước 20, truy vấn AMP và Logs Insights chạy
lại sau bước 31 và ở buổi kế.

(e) Dữ liệu còn sau destroy (ADR-0063, "Xác nhận"): metric, log và trace của buổi nằm ở account, không ở cluster. Ghi lại **trước bước
20**, sau khi k6 xong, một khoảng thời gian tuyệt đối trong buổi và một trace của khoảng đó; rồi chạy lại đúng các truy vấn sau bước 31
(cùng ngày) và ở buổi kế. Kết quả nằm ở `.session/persist-stg/` (git bỏ qua, không commit; giữ qua các buổi, như thư mục buổi). `end` cách
lúc ghi ít nhất 10 phút, để mẫu, log, span đến trễ đã tới:

```sh
d=.session/persist-$E; mkdir -p "$d"
printf 'start=%s\nend=%s\n' '<UTC đầu khoảng, sau mốc svp-root-healthy, vd 2026-11-20T03:30:00Z>' '<UTC cuối khoảng>' >"$d/window.env"
. "$d/window.env"
insights aws/spans "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$start" +%s)" "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$end" +%s)" \
  'stats count(*) as spans by traceId | sort spans desc | limit 1'
printf 'trace=%s\n' '<traceId vừa in>' >>"$d/window.env"
```

Rồi định nghĩa `persist` (mở terminal mới thì chạy lại riêng khối này) và đo lần đầu:

```sh
# persist: đúng các truy vấn được so; đọc khoảng và trace từ window.env
d=.session/persist-$E
persist() {
  local s e
  . "$d/window.env"
  s=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$start" +%s); e=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$end" +%s)
  echo "== $start $end"
  echo "== series per job"; promql "count by (job) (count_over_time(up{cluster=\"svp-$E\"}[$((e - s))s]))" "$e"
  echo "== samples per job"; promql "sum by (job) (count_over_time(up{cluster=\"svp-$E\"}[$((e - s))s]))" "$e"
  echo "== log records"; insights "/svp/$E/otel" "$s" "$e" 'stats count(*) as records' || echo "query failed"
  echo "== spans of trace $trace"
  insights aws/spans "$s" "$e" "filter traceId = \"$trace\" | stats count(*) as spans" || echo "query failed"
}
```

```sh
persist | tee "$d/before.txt"
```

Mong mỗi phần có dòng (series, số mẫu mỗi job, `records`, `spans` lớn hơn 0), không dòng `query failed`. Dán `window.env` (không có giá
trị bí mật) và `before.txt`. Sau bước 31 cùng ngày (mục [Kết thúc buổi](session-stg.md#kết-thúc-buổi)) và ở buổi kế (trước bước 1,
terminal có biến và hàm của khối dùng chung, `E`, `d=.session/persist-$E` và hàm `persist` của khối định nghĩa ở trên):

```sh
# buổi kế: next-session.txt
persist | tee "$d/after-destroy.txt"; diff "$d/before.txt" "$d/after-destroy.txt" && echo same
```

Tiêu chí: `same`, tức metric bằng hệt (cùng series, cùng số), log và trace còn đủ. Khác: dán `diff`; ghi chênh lệch vào "Xác nhận". Buổi
kế còn trong retention của workspace AMP, nhưng log ứng dụng và `aws/spans` giữ ngắn hơn (`log_retention_days`, `span_retention_days` ở
`locals` của `aws/accounts/<env>`, ADR-0063 §10): quá hạn đó thì hai phần log, trace rỗng là đúng retention, ghi "ngoài retention", chỉ so
metric. Dòng `query failed` là truy vấn hỏng, không phải dữ liệu mất: lỗi nằm trên terminal (stderr không vào file); sửa nguyên nhân (như
`AWS_PROFILE=anhnv-sso aws --no-cli-pager sso login --region us-east-1` khi phiên SSO hết hạn) rồi chạy lại `persist`.

## Gỡ

Các phép kiểm ở trang này không để lại tài nguyên của buổi ngoài những thứ nó tự nêu (pod, tệp trong `$SVP_SESSION_DIR`); gỡ cuối buổi ở
[`session-stg-teardown.md`](session-stg-teardown.md) (bước 20–31).

## Khi một bước đỏ

Phép kiểm đỏ thì ghi kết quả, dán output cho AI rồi sang phép kế: bước 16 là bước duy nhất của bảng
[Thứ tự](session-stg.md#thứ-tự) được đi tiếp khi đo hỏng. Lỗi riêng của từng phép ở nhãn **Bẫy** hay phần **Mong** của nó; destroy kẹt:
[Destroy kẹt](session-stg.md#destroy-kẹt).
