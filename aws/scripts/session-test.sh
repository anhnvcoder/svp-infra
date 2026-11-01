#!/usr/bin/env bash
# Self-test of the session scripts of this directory, with fake aws, kubectl, helm, terraform, make and dig on PATH
# (and git repositories made here as the clones of the code repository and of svp-gitops): no account, cluster or
# network is reached. Runs on the Mac (bash 3.2) and on Linux; needs git and jq.
#   - --print of the whole session (session.sh) calls no command at all, lists the steps in the order of the
#     runbook's table, deletes root svp-root before any child, every PVC before the platform Applications, and
#     every PVC before terraform destroy
#   - check-account.sh stops on another account or none exported; check-dns.sh on name servers that differ or none
#   - bootstrap-argocd.sh checks the account first; calls make eks-gitops-up with the context, the values file and the
#     svp-gitops SHA, the RDS master password in make's environment only; the secret reaches jq through a pipe, never a
#     file; never helm; no fake secret in any output or file; a password in make's output deletes the log and fails
#   - pre-destroy.sh against a fake cluster: root first, workloads by wave, Gateway, PVCs, platform last; on a cluster
#     without Argo CD, no Application call and still the waits; after an apply that failed once EKS existed (no
#     cluster-values.json, EKS in the state), it writes the context itself, reads the zone id from the tfvars, and
#     destroy runs after it; it stops before kubectl when the account has no such cluster
#   - measure.sh checks the account first; a level that fails ends the ladder; a node lost makes the level interrupted
#     (exit 3); a failed poll of the Job is waited past, not taken for its end; a Job never read again is a tooling
#     error (exit 1), not a failed level, and is not deleted
#   - tf.sh destroy refuses before pre-destroy; --no-cluster only with no cluster-values.json and no EKS cluster in the
#     state; sweep.sh reads only, works with no state, fails on a leftover volume or a secret scheduled for deletion,
#     passes on the bootstrap's resources alone
#
# Usage: aws/scripts/session-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
runbook=$(cd "$src/../.." && pwd)/docs/runbooks/session-stg.md
command -v jq >/dev/null || {
  echo "FAIL  jq not found" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd)
bin=$work/bin state=$work/state log=$work/calls.log
mkdir -p "$bin" "$state"

# The scripts run from a copy in a tree of their own, $work/infra: the session directories they write and the
# personal tfvars they read are there, so the test writes nothing in this repository and never reads or removes the
# learner's own files (stg.auto.tfvars, a plan file, a session).
infra_root=$work/infra
here=$infra_root/aws/scripts
mkdir -p "$here" "$infra_root/aws/envs/stg"
cp "$src"/*.sh "$here"/
printf '%s\n' 'hosted_zone_id = "Z0TFVARS"' 'domain         = "stg.aws.svp.example"' >"$infra_root/aws/envs/stg/stg.auto.tfvars"
password=fake-Rds-Master-9f3c27e1
failures=0

pass() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}
# expect NAME CMD...: CMD exits 0.
expect() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else bad "$name"; fi
}

# --- fakes -------------------------------------------------------------------------------------------------------
# Each fake logs its call to $FAKE_LOG; aws and terraform check the profile, aws the region.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "${AWS_PROFILE:-}" = anhnv-sso ] || { echo "fake aws: AWS_PROFILE is '${AWS_PROFILE:-}'" >&2; exit 97; }
case " $* " in *" --region ap-southeast-1 "*) ;; *) echo "fake aws: no --region ap-southeast-1" >&2; exit 97 ;; esac
left=${FAKE_LEFTOVER:-}
case "$1 $2" in
  "sts get-caller-identity") echo '{"Account":"000000000000","Arn":"arn:aws:sts::000000000000:assumed-role/learner/session"}' ;;
  # FAKE_NO_CLUSTER: an account where the cluster was never made.
  "eks update-kubeconfig")
    [ -z "${FAKE_NO_CLUSTER:-}" ] || { echo "fake aws: ResourceNotFoundException: No cluster found for name: svp-stg." >&2; exit 254; }
    echo "Added new context svp-stg" ;;
  "eks list-clusters") echo '{"clusters":[]}' ;;
  "secretsmanager get-secret-value") printf '{"username":"postgres","password":"%s"}\n' "$FAKE_PASSWORD" ;;
  "secretsmanager list-secrets")
    if [ "$left" = secret ]; then
      echo '{"SecretList":[{"Name":"svp-stg-old","DeletedDate":"2026-10-30T10:00:00Z","Tags":[{"Key":"Project","Value":"svp"}]}]}'
    else
      echo '{"SecretList":[{"Name":"other-project","Tags":[]}]}'
    fi ;;
  "route53 list-hosted-zones-by-name") echo '{"HostedZones":[{"Id":"/hostedzone/Z0FAKE","Name":"aws.svp.example."}]}' ;;
  "route53 list-resource-record-sets")
    echo '{"ResourceRecordSets":[{"Name":"aws.svp.example.","Type":"NS"},{"Name":"aws.svp.example.","Type":"SOA"}]}' ;;
  "resourcegroupstaggingapi get-resources") echo '{"ResourceTagMappingList":[]}' ;;
  "ec2 describe-volumes")
    if [ "$left" = volume ] && [[ "$*" == *tag:Project* ]]; then
      echo '{"Volumes":[{"VolumeId":"vol-0fake","State":"available","Size":10,"Tags":[{"Key":"kubernetes.io/created-for/pvc/name","Value":"data-redpanda-0"}]}]}'
    else
      echo '{"Volumes":[]}'
    fi ;;
  "ec2 describe-instances") echo '{"Reservations":[]}' ;;
  "ec2 describe-snapshots") echo '{"Snapshots":[]}' ;;
  "ec2 describe-vpcs") echo '{"Vpcs":[]}' ;;
  "ec2 describe-nat-gateways") echo '{"NatGateways":[]}' ;;
  "ec2 describe-addresses") echo '{"Addresses":[]}' ;;
  "ec2 describe-network-interfaces") echo '{"NetworkInterfaces":[]}' ;;
  "ec2 describe-security-groups") echo '{"SecurityGroups":[]}' ;;
  "elbv2 describe-load-balancers") echo '{"LoadBalancers":[]}' ;;
  "elbv2 describe-target-groups") echo '{"TargetGroups":[]}' ;;
  "rds describe-db-instances") echo '{"DBInstances":[]}' ;;
  "rds describe-db-snapshots") echo '{"DBSnapshots":[]}' ;;
  "rds describe-db-instance-automated-backups") echo '{"DBInstanceAutomatedBackups":[]}' ;;
  "s3api list-buckets") echo '{"Buckets":[{"Name":"svp-tfstate-000000000000-ap-southeast-1"},{"Name":"someone-else"}]}' ;;
  "s3api get-bucket-tagging") echo '{"TagSet":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"bootstrap"}]}' ;;
  "cloudfront list-distributions") echo '{"DistributionList":{"Items":[]}}' ;;
  "cloudfront list-origin-access-controls") echo '{"OriginAccessControlList":{"Items":[]}}' ;;
  "cloudfront list-response-headers-policies") echo '{"ResponseHeadersPolicyList":{"Items":[]}}' ;;
  "logs describe-log-groups") echo '{"logGroups":[]}' ;;
  "kms list-aliases") echo '{"Aliases":[{"AliasName":"alias/aws/ebs"}]}' ;;
  *) echo "fake aws: unexpected $1 $2" >&2; exit 98 ;;
esac
EOF

cat >"$bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"$FAKE_LOG"
[ "${AWS_PROFILE:-}" = anhnv-sso ] || { echo "fake terraform: AWS_PROFILE is '${AWS_PROFILE:-}'" >&2; exit 97; }
args="$*"
case "${args#-chdir=* }" in
  "output -json name_servers")
    echo '["ns-1.awsdns-01.org","ns-2.awsdns-02.co.uk","ns-3.awsdns-03.com","ns-4.awsdns-04.net"]' ;;
  "output -json cluster_values")
    echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE","acmeEmail":"you@svp.example"}' ;;
  "output -raw rds_master_user_secret_arn") printf 'arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:rds!db-fake' ;;
  # FAKE_TF_STATE: eks, a state with the cluster (and a data source of it); fail, no readable state; else, no cluster.
  "state list")
    case ${FAKE_TF_STATE:-} in
      eks) printf '%s\n' 'module.eks.module.eks.data.aws_eks_cluster.this[0]' 'module.eks.module.eks.aws_eks_cluster.this[0]' \
        'module.network.module.vpc.aws_vpc.this[0]' ;;
      fail) echo "fake terraform: No state file was found!" >&2; exit 1 ;;
      *) printf '%s\n' 'module.eks.module.eks.data.aws_eks_cluster.this[0]' 'module.network.module.vpc.aws_vpc.this[0]' ;;
    esac ;;
  *) ;;
esac
EOF

cat >"$bin/dig" <<'EOF'
#!/usr/bin/env bash
echo "dig $*" >>"$FAKE_LOG"
case ${FAKE_DIG:-same} in
  same) printf '%s\n' NS-4.awsdns-04.net. ns-3.awsdns-03.com. ns-2.awsdns-02.co.uk. ns-1.awsdns-01.org. ;;
  other) printf '%s\n' renan.ns.cloudflare.com. serenity.ns.cloudflare.com. ;;
  empty) ;;
esac
EOF

cat >"$bin/make" <<'EOF'
#!/usr/bin/env bash
# Logs whether the password reached make's environment, never the value.
if [ "${SVP_RDS_MASTER_PASSWORD:-}" = "$FAKE_PASSWORD" ]; then pw=match; elif [ -n "${SVP_RDS_MASTER_PASSWORD:-}" ]; then pw=other; else pw=none; fi
echo "make $* password=$pw profile=${AWS_PROFILE:-}" >>"$FAKE_LOG"
echo "ok    every Application Synced and Healthy (fake make)"
# FAKE_MAKE_LEAK: a target that prints the password, which bootstrap-argocd.sh must catch in its log.
[ -z "${FAKE_MAKE_LEAK:-}" ] || echo "debug: password $SVP_RDS_MASTER_PASSWORD"
EOF

cat >"$bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
exit 1
EOF

# jq: the real one, but a call that reads a password field from a regular file is logged. bash 3.2 (the Mac's) makes
# a here-string a temporary file; bash 5.1 and later use a pipe for a short one, so on Linux this catches less.
real_jq=$(command -v jq)
cat >"$bin/jq" <<EOF
#!/usr/bin/env bash
case " \$* " in *password*) [ ! -f /dev/stdin ] || echo "jq \$* stdin=file" >>"\$FAKE_LOG" ;; esac
exec "$real_jq" "\$@"
EOF

# kubectl: a cluster in files of $FAKE_STATE (apps: "wave name", root, lb, pvcs: "namespace name", nodes); with
# FAKE_NO_ARGOCD, a cluster where make eks-gitops-up stopped before Argo CD (no CRD of Argo CD, Gateway API or LBC).
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
[ "${1:-} ${2:-}" = "--context svp-stg" ] || { echo "fake kubectl: not --context svp-stg: $*" >&2; exit 97; }
shift 2
s=$FAKE_STATE
items() { jq -s '{items: .}'; }
case "$*" in
  "get crd applications.argoproj.io --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io ;;
  "get crd gateways.gateway.networking.k8s.io --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io ;;
  "-n argocd get application svp-root --ignore-not-found -o name") [ ! -e "$s/root" ] || echo application.argoproj.io/svp-root ;;
  "-n argocd patch application "*) ;;
  "-n argocd delete application svp-root "*) rm -f "$s/root" ;;
  "-n argocd get applications -o json")
    while read -r w n; do [ -z "$n" ] || jq -n --arg w "$w" --arg n "$n" \
      '{metadata: {name: $n, annotations: {"argocd.argoproj.io/sync-wave": $w}}}'; done <"$s/apps" | items ;;
  "-n argocd delete application "*" --wait=false")
    name=$5; grep -v " $name\$" "$s/apps" >"$s/apps.new" || true; mv "$s/apps.new" "$s/apps" ;;
  "-n argocd get application "*" --ignore-not-found -o name") ! grep -q " $5\$" "$s/apps" || echo "application.argoproj.io/$5" ;;
  "-n svp-edge delete gateway svp "*) rm -f "$s/lb" ;;
  "get services -A -o json")
    if [ -e "$s/lb" ]; then echo '{"items":[{"spec":{"type":"LoadBalancer"}}]}'; else echo '{"items":[{"spec":{"type":"ClusterIP"}}]}'; fi ;;
  "get crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo customresourcedefinition.apiextensions.k8s.io/targetgroupbindings.elbv2.k8s.aws ;;
  "get targetgroupbindings.elbv2.k8s.aws -A -o json") if [ -e "$s/lb" ]; then echo '{"items":[{}]}'; else echo '{"items":[]}'; fi ;;
  "get pvc -A -o json")
    while read -r ns n; do [ -z "$n" ] || jq -n --arg ns "$ns" --arg n "$n" '{metadata: {namespace: $ns, name: $n}}'; done <"$s/pvcs" | items ;;
  "-n "*" delete pvc --all --wait=false") grep -v "^$2 " "$s/pvcs" >"$s/pvcs.new" || true; mv "$s/pvcs.new" "$s/pvcs" ;;
  "get pv -o json")
    while read -r ns n; do [ -z "$n" ] || jq -n '{spec: {csi: {driver: "ebs.csi.aws.com"}}}'; done <"$s/pvcs" | items ;;
  "get nodes -o json")
    c=$(( $(cat "$s/node-calls" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$s/node-calls"
    nodes="ip-10-0-1-1 ip-10-0-2-2 ip-10-0-3-3"
    if [ -n "${FAKE_NODE_LOST:-}" ] && [ "$c" -ge 2 ]; then nodes="ip-10-0-2-2 ip-10-0-3-3"; fi
    for n in $nodes; do jq -n --arg n "$n" '{metadata: {name: $n}, status: {conditions: [{type: "Ready", status: "True"}]}}'; done | items ;;
  "top nodes --no-headers") echo "ip-10-0-1-1 250m 12% 2000Mi 30%" ;;
  "top pods -A --no-headers") echo "svp gateway-abc 50m 80Mi" ;;
  "-n svp-load get job svp-k6 --ignore-not-found -o json")
    # FAKE_JOB_FLAKY: the first read of the Job fails, as with Wi-Fi gone for a moment; FAKE_JOB_DOWN: every read
    # fails, as with an expired SSO session.
    c=$(( $(cat "$s/job-calls" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$s/job-calls"
    if [ -n "${FAKE_JOB_FLAKY:-}" ] && [ "$c" = 1 ]; then echo "fake kubectl: connection refused" >&2; exit 1; fi
    if [ -n "${FAKE_JOB_DOWN:-}" ]; then echo "fake kubectl: the SSO session has expired" >&2; exit 1; fi
    echo '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}' ;;
  "get events -A --field-selector involvedObject.kind=Node -o json") echo '{"items":[]}' ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 98 ;;
esac
EOF
chmod +x "$bin"/*

# The clones: the code repository with a fake run.sh of the k6 Job, and svp-gitops, each with an origin.
git_() { git -c user.name=test -c user.email=test@svp.example -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
make_clone() {
  local dir=$1
  git_ init -q --bare "$dir.origin.git"
  git_ init -q "$dir"
  mkdir -p "$dir/deploy/k6/cloud"
  cat >"$dir/deploy/k6/cloud/run.sh" <<'EOF'
#!/usr/bin/env bash
# Fake of the k6 Job's script: start records the pods, logs writes their summaries, failing from FAKE_K6_FAIL_AT pods.
echo "run.sh $*" >>"$FAKE_LOG"
pods= cmd=
while [ $# -gt 0 ]; do case $1 in --pods) pods=$2; shift 2 ;; --context|--domain|--ramp|--hold) shift 2 ;; *) cmd=$1; shift ;; esac; done
repo=$(cd "$(dirname "$0")/../../.." && pwd)
case $cmd in
  start) echo "$pods" >"$FAKE_STATE/k6-pods" ;;
  logs)
    n=$(cat "$FAKE_STATE/k6-pods"); out=.k6/cloud-$n-$$; mkdir -p "$repo/$out"
    ok=true; [ -z "${FAKE_K6_FAIL_AT:-}" ] || [ "$n" -lt "$FAKE_K6_FAIL_AT" ] || ok=false
    i=0; while [ "$i" -lt "$n" ]; do
      jq -n --argjson ok "$ok" '{thresholds_ok: $ok, dropped_iterations: 0, routes: [{route: "/feed/explore", rate_limited: 0, p99_ms: 120}]}' >"$repo/$out/pod-$i.json"
      i=$((i + 1)); done
    echo "summaries in $out" ;;
  delete) ;;
esac
EOF
  chmod +x "$dir/deploy/k6/cloud/run.sh"
  git_ -C "$dir" add -A
  git_ -C "$dir" commit -q -m init
  git_ -C "$dir" remote add origin "$dir.origin.git"
  git_ -C "$dir" push -q origin main
  git_ -C "$dir" fetch -q origin
}
make_clone "$work/backend"
make_clone "$work/gitops"
gitops_sha=$(git -C "$work/gitops" rev-parse refs/remotes/origin/main)

export PATH="$bin:$PATH" FAKE_LOG=$log FAKE_STATE=$state FAKE_PASSWORD=$password
export SVP_BACKEND_DIR=$work/backend SVP_GITOPS_DIR=$work/gitops SVP_SESSION_POLL=0 SVP_ZONE_NAME=aws.svp.example
export SVP_AWS_ACCOUNT_ID=000000000000
unset SVP_SESSION_DIR

# new_session: a fresh session directory under .session/ of the copy.
new_session() {
  SVP_SESSION_DIR=$infra_root/.session/test-$$-$RANDOM
  export SVP_SESSION_DIR
  mkdir -p "$SVP_SESSION_DIR"
  : >"$log"
}

# has_mark EVENT: the session's timeline holds EVENT.
has_mark() { awk -F '\t' -v e="$1" '$3 == e { found = 1 } END { exit !found }' "$SVP_SESSION_DIR/timeline.tsv"; }
no_mark() { ! has_mark "$1"; }

# index FILE PATTERN: the number of the first line of FILE matching PATTERN (grep -E), 0 when none.
index() { grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1 || true; }
before() {
  local a b
  a=$(index "$1" "$2")
  b=$(index "$1" "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# --- --print ----------------------------------------------------------------------------------------------------
: >"$log"
bash "$here/session.sh" --print stg >"$work/print.out" 2>&1 || bad "session.sh --print stg exits 0"
expect "--print calls no aws, kubectl, helm, terraform, make, dig" test ! -s "$log"
sed -n 's/^### step [0-9]*: aws\/scripts\///p' "$work/print.out" >"$work/order.print"
sed -n 's/^| [0-9]* | `aws\/scripts\/\([^`]*\)`.*/\1/p' "$runbook" >"$work/order.runbook"
expect "the steps of --print are the runbook's table, in order" diff "$work/order.runbook" "$work/order.print"
expect "the runbook's table has the ten steps" test "$(grep -c . "$work/order.runbook")" = 10
expect "--print: root svp-root deleted before any child Application" \
  before "$work/print.out" 'delete application svp-root' "delete application '<each workload"
expect "--print: root's auto-sync and finalizers cleared before it is deleted" \
  before "$work/print.out" 'patch application svp-root' 'delete application svp-root'
expect "--print: workloads, then Gateway svp" before "$work/print.out" "delete application '<each workload" 'delete gateway svp'
expect "--print: every PVC deleted before svp-cluster and the platform Applications" \
  before "$work/print.out" 'delete pvc --all' "delete application '<each platform"
expect "--print: every PVC deleted before terraform destroy" before "$work/print.out" 'delete pvc --all' 'terraform .* destroy'
expect "--print: pre-destroy before terraform destroy, sweep last" before "$work/print.out" 'step 8: aws/scripts/pre-destroy.sh' 'destroy -var-file'
expect "--print: plan saved to a file, apply of that file" before "$work/print.out" 'plan .*-out=stg.tfplan' 'apply -input=false stg.tfplan'
expect "--print: an eks-rl-reset before each of the four k6 levels" test "$(grep -c 'make .* eks-rl-reset CONTEXT=svp-stg' "$work/print.out")" = 4
expect "--print: every aws command names profile and region" \
  test -z "$(grep -E '^\+ .* aws ' "$work/print.out" | grep -vE '^\+ AWS_PROFILE=anhnv-sso aws .*--region ap-southeast-1')"

# --- check-account.sh -------------------------------------------------------------------------------------------
new_session
expect "check-account.sh passes on the exported account" bash "$here/check-account.sh" >"$work/out" 2>&1
expect "check-account.sh prints the ARN" grep -q 'arn:aws:sts::000000000000:assumed-role/learner/session' "$work/out"
expect "check-account.sh starts the timeline" has_mark session-start
expect "check-account.sh stops on another account" \
  sh -c '! SVP_AWS_ACCOUNT_ID=111111111111 bash "$1/check-account.sh" >"$2" 2>&1 && grep -q "not SVP_AWS_ACCOUNT_ID" "$2"' _ "$here" "$work/out"
expect "check-account.sh stops when no account is exported" \
  sh -c '! env -u SVP_AWS_ACCOUNT_ID bash "$1/check-account.sh" >/dev/null 2>&1' _ "$here"

# --- check-dns.sh -----------------------------------------------------------------------------------------------
: >"$log"
expect "check-dns.sh passes when both resolvers answer the zone's name servers" bash "$here/check-dns.sh" >/dev/null
expect "check-dns.sh asks two public resolvers" test "$(grep -cE '^dig NS aws.svp.example .*@(1.1.1.1|8.8.8.8)$' "$log")" -ge 2
expect "check-dns.sh stops on other name servers" sh -c '! FAKE_DIG=other bash "$1/check-dns.sh" >/dev/null 2>&1' _ "$here"
expect "check-dns.sh stops on no answer" sh -c '! FAKE_DIG=empty bash "$1/check-dns.sh" >/dev/null 2>&1' _ "$here"
expect "check-dns.sh calls no AWS API" test -z "$(grep '^aws ' "$log")"

# --- tf.sh --------------------------------------------------------------------------------------------------------
new_session
bash "$here/check-account.sh" >/dev/null
expect "tf.sh destroy refuses before pre-destroy.sh" sh -c '! bash "$1/tf.sh" stg destroy >/dev/null 2>&1' _ "$here"
expect "tf.sh destroy did not run terraform" test -z "$(grep '^terraform .* destroy' "$log")"
expect "tf.sh destroy --no-cluster runs with no cluster-values.json and no EKS cluster in the state" \
  bash "$here/tf.sh" stg destroy --no-cluster >/dev/null
expect "tf.sh destroy --no-cluster read the state before destroying" before "$log" 'terraform .* state list' 'terraform .* destroy'
: >"$log"
expect "tf.sh destroy --no-cluster refuses when the state holds an EKS cluster, and says which" \
  sh -c '! FAKE_TF_STATE=eks bash "$1/tf.sh" stg destroy --no-cluster >"$2" 2>&1 && grep -qF "state holds EKS cluster module.eks.module.eks.aws_eks_cluster.this[0]: run aws/scripts/pre-destroy.sh stg first" "$2"' _ "$here" "$work/out"
expect "tf.sh destroy --no-cluster refuses when the state cannot be read" \
  sh -c '! FAKE_TF_STATE=fail bash "$1/tf.sh" stg destroy --no-cluster >/dev/null 2>&1' _ "$here"
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
expect "tf.sh destroy --no-cluster refuses when the session has cluster-values.json" \
  sh -c '! bash "$1/tf.sh" stg destroy --no-cluster >"$2" 2>&1 && grep -q "cluster-values.json exists" "$2"' _ "$here" "$work/out"
expect "tf.sh destroy --no-cluster refused: terraform destroy never ran" test -z "$(grep '^terraform .* destroy' "$log")"
expect "tf.sh apply refuses without a plan file" sh -c '! bash "$1/tf.sh" stg apply >/dev/null 2>&1' _ "$here"

# --- bootstrap-argocd.sh -----------------------------------------------------------------------------------------
new_session
bash "$here/bootstrap-argocd.sh" stg >"$work/boot.out" 2>&1 || bad "bootstrap-argocd.sh stg exits 0 ($(tail -n 3 "$work/boot.out"))"
values=$SVP_SESSION_DIR/cluster-values.json
expect "bootstrap-argocd.sh writes the kubeconfig context svp-stg" grep -qE '^aws eks update-kubeconfig --name svp-stg --alias svp-stg' "$log"
expect "bootstrap-argocd.sh writes the cluster values" sh -c 'jq -e ".name == \"svp-stg\"" "$1" >/dev/null' _ "$values"
expect "cluster-values.json is readable by its owner only" test -n "$(find "$values" -perm 0600)"
expect "bootstrap-argocd.sh calls make eks-gitops-up with the context, the file and the svp-gitops SHA" \
  grep -qF "make -C $work/backend eks-gitops-up CONTEXT=svp-stg CLUSTER_VALUES=$values GITOPS_REV=$gitops_sha password=match profile=anhnv-sso" "$log"
expect "bootstrap-argocd.sh never calls helm" test -z "$(grep '^helm ' "$log")"
expect "bootstrap-argocd.sh: the password is in no output, log or session file" \
  sh -c '! grep -rqF -- "$1" "$2" "$3" "$4"' _ "$password" "$work/boot.out" "$log" "$SVP_SESSION_DIR"
expect "bootstrap-argocd.sh marks Argo CD healthy" has_mark argocd-healthy
expect "bootstrap-argocd.sh: the RDS secret reaches jq through a pipe, never a file" test -z "$(grep 'stdin=file' "$log")"
: >"$log"
expect "bootstrap-argocd.sh stops on another account before any other command" \
  sh -c '! SVP_AWS_ACCOUNT_ID=111111111111 bash "$1/bootstrap-argocd.sh" stg >/dev/null 2>&1 && [ -s "$2" ] && ! grep -qv "^aws sts get-caller-identity " "$2"' _ "$here" "$log"
new_session
expect "bootstrap-argocd.sh fails when make's output holds the password" \
  sh -c '! FAKE_MAKE_LEAK=1 bash "$1/bootstrap-argocd.sh" stg >"$2" 2>&1 && grep -q "held the RDS master password" "$2"' _ "$here" "$work/leak.out"
expect "bootstrap-argocd.sh deletes a log that holds the password" test ! -e "$SVP_SESSION_DIR/eks-gitops-up.log"
expect "bootstrap-argocd.sh: no session file holds the password after a leak" sh -c '! grep -rqF -- "$1" "$2"' _ "$password" "$SVP_SESSION_DIR"
git_ -C "$work/backend" switch -q -c feature
expect "bootstrap-argocd.sh stops when the code repository is not on main" \
  sh -c '! bash "$1/bootstrap-argocd.sh" stg >/dev/null 2>&1' _ "$here"
git_ -C "$work/backend" switch -q main

# --- pre-destroy.sh ----------------------------------------------------------------------------------------------
new_session
cp "$values" "$SVP_SESSION_DIR/cluster-values.json" 2>/dev/null ||
  echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\n' "0 cert-manager" "0 envoy-gateway" "0 external-secrets" "1 svp-cluster" "1 aws-load-balancer-controller" \
  "2 keda" "2 external-dns" "2 argo-rollouts" "2 kyverno" "2 kube-prometheus-stack" "3 svp-policy" "3 redpanda" "3 loki" \
  "4 svp-data" "5 svp-observability" "6 otel-collector" "7 gateway" "7 web" >"$state/apps"
touch "$state/root" "$state/lb"
printf '%s\n' "svp-data data-redpanda-0" "svp-obs prometheus-db-0" >"$state/pvcs"
bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 || bad "pre-destroy.sh stg exits 0 ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh: root's sync and finalizers cleared, then root deleted, before any child" \
  sh -c '[ "$(grep -E -- "-n argocd (patch|delete) application" "$1" | head -n 2 | grep -c " application svp-root ")" = 2 ]' _ "$log"
expect "pre-destroy.sh: auto-sync of svp-cluster off before the first child is deleted" \
  before "$log" 'patch application svp-cluster .*automated' 'delete application [a-z-]+ --wait=false'
expect "pre-destroy.sh: wave 7 before wave 3, workloads before the Gateway" \
  sh -c 'grep -q . "$1" && [ "$(grep -n "delete application gateway " "$1" | cut -d: -f1)" -lt "$(grep -n "delete application redpanda " "$1" | cut -d: -f1)" ]' _ "$log"
expect "pre-destroy.sh: last workload (kube-prometheus-stack) before the Gateway" \
  before "$log" 'delete application kube-prometheus-stack ' 'delete gateway svp'
expect "pre-destroy.sh: Gateway before the PVCs" before "$log" 'delete gateway svp' 'delete pvc --all'
expect "pre-destroy.sh: PVCs before svp-cluster" before "$log" 'delete pvc --all' 'delete application svp-cluster '
expect "pre-destroy.sh: PVCs before every platform Application" before "$log" 'delete pvc --all' 'delete application (keda|kyverno|external-dns|aws-load-balancer-controller) '
expect "pre-destroy.sh: the PVCs of both namespaces" test "$(grep -c 'delete pvc --all' "$log")" = 2
expect "pre-destroy.sh leaves no Application" test -z "$(grep . "$state/apps")"
expect "pre-destroy.sh marks pre-destroy-done" has_mark pre-destroy-done
expect "tf.sh destroy runs after pre-destroy.sh" bash "$here/tf.sh" stg destroy >/dev/null

new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
: >"$state/apps"
: >"$state/pvcs"
rm -f "$state/root" "$state/lb"
FAKE_NO_ARGOCD=1 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 ||
  bad "pre-destroy.sh stg exits 0 on a cluster without Argo CD ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh without Argo CD says so" grep -q '^note  no Argo CD on svp-stg' "$work/pre.out"
expect "pre-destroy.sh without Argo CD calls nothing of Argo CD or the Gateway" test -z "$(grep -E -- '-n argocd |delete gateway' "$log")"
expect "pre-destroy.sh without Argo CD still waits on load balancers, records and volumes" \
  sh -c 'grep -q "get services -A" "$1" && grep -q "route53 list-resource-record-sets" "$1" && grep -q "ec2 describe-volumes" "$1"' _ "$log"
expect "pre-destroy.sh without Argo CD marks pre-destroy-done" has_mark pre-destroy-done

# An apply that failed once EKS existed (RDS or CloudFront failed, so output cluster_values was never stored and
# bootstrap-argocd.sh cannot run): no cluster-values.json, EKS in the state. pre-destroy.sh is the way out.
new_session
expect "--no-cluster with EKS in the state points to pre-destroy.sh" \
  sh -c '! FAKE_TF_STATE=eks bash "$1/tf.sh" stg destroy --no-cluster >"$2" 2>&1 && grep -q "run aws/scripts/pre-destroy.sh stg first" "$2"' _ "$here" "$work/out"
FAKE_NO_ARGOCD=1 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 ||
  bad "pre-destroy.sh stg exits 0 with no cluster-values.json ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh writes the context svp-stg itself, before its first kubectl" \
  before "$log" '^aws eks update-kubeconfig --name svp-stg --alias svp-stg ' '^kubectl '
expect "pre-destroy.sh reads the zone id from stg.auto.tfvars" grep -q 'route53 list-resource-record-sets --hosted-zone-id Z0TFVARS ' "$log"
expect "pre-destroy.sh with no cluster-values.json marks pre-destroy-done" has_mark pre-destroy-done
expect "tf.sh destroy runs after it, with EKS in the state" sh -c 'FAKE_TF_STATE=eks bash "$1/tf.sh" stg destroy >/dev/null' _ "$here"
expect "tf.sh destroy ran terraform destroy" grep -q '^terraform .* destroy -var-file=stg.tfvars' "$log"
: >"$log"
expect "pre-destroy.sh on an account without the cluster stops before kubectl and points to --no-cluster" \
  sh -c '! FAKE_NO_CLUSTER=1 bash "$1/pre-destroy.sh" stg >"$2" 2>&1 && grep -q "destroy --no-cluster" "$2" && ! grep -q "^kubectl " "$3"' _ "$here" "$work/out" "$log"
mv "$infra_root/aws/envs/stg/stg.auto.tfvars" "$work/tfvars.aside"
: >"$log"
expect "pre-destroy.sh without stg.auto.tfvars stops before any command, and names the file" \
  sh -c '! bash "$1/pre-destroy.sh" stg >"$2" 2>&1 && grep -q "stg.auto.tfvars" "$2" && [ ! -s "$3" ]' _ "$here" "$work/out" "$log"
mv "$work/tfvars.aside" "$infra_root/aws/envs/stg/stg.auto.tfvars"

# --- measure.sh ---------------------------------------------------------------------------------------------------
new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "$(date +%s)" session-start >"$SVP_SESSION_DIR/timeline.tsv"
rm -f "$state/node-calls"
FAKE_K6_FAIL_AT=2 bash "$here/measure.sh" stg >"$work/measure.out" 2>&1 || bad "measure.sh stg exits 0 with a failed level ($(tail -n 3 "$work/measure.out"))"
expect "measure.sh: smoke and seed with the domain" grep -q 'make .* eks-seed CONTEXT=svp-stg DOMAIN=stg.aws.svp.example' "$log"
expect "measure.sh: level 1 passes, level 2 fails" \
  test "$(cut -f1,2 "$SVP_SESSION_DIR/k6-levels.tsv" | tr '\t\n' ': ')" = "1:pass 2:fail "
expect "measure.sh: no level after the failed one" test -z "$(grep -- '--pods 4' "$log")"
expect "measure.sh: eks-rl-reset before each level's start" before "$log" 'eks-rl-reset' 'run.sh .*--pods 1 .*start'
expect "measure.sh: summaries copied into the session" test -s "$SVP_SESSION_DIR/k6-1/summaries/pod-0.json"
expect "measure.sh: nodes and kubectl top sampled" test -s "$SVP_SESSION_DIR/k6-1/top-nodes.tsv"

new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "$(date +%s)" session-start >"$SVP_SESSION_DIR/timeline.tsv"
rm -f "$state/node-calls"
rc=0
FAKE_NODE_LOST=1 bash "$here/measure.sh" stg --from 2 >"$work/measure.out" 2>&1 || rc=$?
expect "measure.sh: a node lost during a level exits 3" test "$rc" = 3
expect "measure.sh: that level is interrupted, not failed" test "$(cut -f2 "$SVP_SESSION_DIR/k6-levels.tsv")" = interrupted
expect "measure.sh --from 2: no smoke, no seed, no level 1" test -z "$(grep -E 'eks-smoke|eks-seed|--pods 1 ' "$log")"
expect "measure.sh: the lost node is named" grep -q 'ip-10-0-1-1' "$SVP_SESSION_DIR/k6-2/lost"
rm -f "$state/node-calls"
FAKE_K6_FAIL_AT=4 bash "$here/measure.sh" stg --from 2 >"$work/measure.out" 2>&1 || bad "measure.sh --from 2 again exits 0"
expect "measure.sh --from 2 again: level 2 passes, level 4 fails" \
  test "$(tail -n 2 "$SVP_SESSION_DIR/k6-levels.tsv" | cut -f1,2 | tr '\t\n' ': ')" = "2:pass 4:fail "
expect "measure.sh --from 2 again: the interrupted try kept aside, not read again" \
  sh -c 'ls -d "$1"/k6-2.* >/dev/null 2>&1 && [ ! -e "$1/k6-2/lost" ] && [ "$(ls "$1/k6-2/summaries")" = "pod-0.json
pod-1.json" ]' _ "$SVP_SESSION_DIR"

new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "$(($(date +%s) - 10000))" session-start >"$SVP_SESSION_DIR/timeline.tsv"
bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 || bad "measure.sh past 3 hours exits 0"
expect "measure.sh: no level starts that would end past 3 hours" test -z "$(grep 'run.sh .* start' "$log")"

new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "$(date +%s)" session-start >"$SVP_SESSION_DIR/timeline.tsv"
rm -f "$state/node-calls" "$state/job-calls"
FAKE_JOB_FLAKY=1 FAKE_K6_FAIL_AT=2 bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 ||
  bad "measure.sh with a failed poll of the Job exits 0 ($(tail -n 3 "$work/measure.out"))"
expect "measure.sh: a failed poll of the Job is noted" grep -q 'kubectl get job svp-load/svp-k6 failed .*waiting on' "$work/measure.out"
expect "measure.sh: after a failed poll it polls again before reading the logs" \
  test "$(awk '/get job svp-k6/ { n++ } /run\.sh .*logs/ { print n; exit }' "$log")" = 2
expect "measure.sh: the level with a failed poll still passes" test "$(head -n 1 "$SVP_SESSION_DIR/k6-levels.tsv" | cut -f1,2 | tr '\t' ':')" = 1:pass
new_session
echo '{"name":"svp-stg","domain":"stg.aws.svp.example","hostedZoneId":"Z0FAKE"}' >"$SVP_SESSION_DIR/cluster-values.json"
printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "$(date +%s)" session-start >"$SVP_SESSION_DIR/timeline.tsv"
rm -f "$state/node-calls" "$state/job-calls"
rc=0
FAKE_JOB_DOWN=1 SVP_MEASURE_LEVEL_LIMIT=1 bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 || rc=$?
expect "measure.sh: a Job no read reaches exits 1" test "$rc" = 1
expect "measure.sh: that level is a tooling error, not a failed level" \
  test "$(cut -f1,2 "$SVP_SESSION_DIR/k6-levels.tsv" | tr '\t\n' ': ')" = "1:error "
expect "measure.sh: the error says the Job could not be read and how to go on" \
  sh -c 'grep -q "^FAIL  level 1: Job svp-load/svp-k6 could not be read" "$1" && grep -q "measure.sh stg --from 1" "$1"' _ "$work/measure.out"
expect "measure.sh: the unread Job is not deleted (one delete, before the level's start)" \
  sh -c '[ "$(grep -c "^run\.sh .* delete$" "$1")" = 1 ] && [ "$(grep -n "^run\.sh " "$1" | tail -n 1 | grep -c -- "--pods 1 .*start$")" = 1 ]' _ "$log"
expect "measure.sh: no logs read and no level after the error" test -z "$(grep -E 'run\.sh .* logs$|--pods 2 ' "$log")"
expect "measure.sh: the error is in the timeline" has_mark k6-1-error
expect "measure.sh: no measure-end after the error" no_mark measure-end
: >"$log"
expect "measure.sh stops on another account before any other command" \
  sh -c '! SVP_AWS_ACCOUNT_ID=111111111111 bash "$1/measure.sh" stg >/dev/null 2>&1 && [ -s "$2" ] && ! grep -qv "^aws sts get-caller-identity " "$2"' _ "$here" "$log"

# --- sweep.sh -----------------------------------------------------------------------------------------------------
unset SVP_SESSION_DIR
: >"$log"
expect "sweep.sh passes with the bootstrap's resources alone" bash "$here/sweep.sh" >"$work/sweep.out" 2>&1
expect "sweep.sh prints the state bucket as kept" grep -q '^kept  svp-tfstate-000000000000-ap-southeast-1' "$work/sweep.out"
expect "sweep.sh prints the zone as kept" grep -q '^kept  hosted zone aws.svp.example' "$work/sweep.out"
expect "sweep.sh needs no Terraform state" test -z "$(grep '^terraform ' "$log")"
expect "sweep.sh only reads (describe, list, get)" \
  test -z "$(grep '^aws ' "$log" | awk '{ print $3 }' | grep -vE '^(describe|list|get)-' || true)"
: >"$log"
expect "sweep.sh fails on a leftover EBS volume, and names it" \
  sh -c '! FAKE_LEFTOVER=volume bash "$1/sweep.sh" >"$2" 2>&1 && grep -q "vol-0fake available 10 GiB data-redpanda-0" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh fails on a secret scheduled for deletion, and says so" \
  sh -c '! FAKE_LEFTOVER=secret bash "$1/sweep.sh" >"$2" 2>&1 && grep -q "svp-stg-old (scheduled for deletion since" "$2"' _ "$here" "$work/sweep.out"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
