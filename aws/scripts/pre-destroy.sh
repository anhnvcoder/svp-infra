#!/usr/bin/env bash
# What Kubernetes made in the account, removed while the controllers that made it still run, before tf.sh <env> gitops
# destroy: Envoy's targets in the edge's target group (TargetGroupBinding of AWS Load Balancer Controller), PVCs' EBS
# volumes (EBS CSI driver) and Karpenter's nodes. Terraform knows none of them; left behind they block the destroy
# (ENIs, security groups) or stay billed (volumes, instances). Every wait has a limit, and what is left is printed.

# Design notes: README.md.

# 1. The root of GitOps: ApplicationSet svp-bootstrap would make svp-root again, and the auto-sync (prune, self-heal) of
#    svp-root and svp-apps would make again every child deleted below. Their finalizers and automated sync are cleared,
#    then the ApplicationSet and both are deleted alone (no cascade: the children stay). The children's auto-sync is
#    turned off too, so that svp-cluster does not make the Gateway again.

# 2. The rules and alerting of AMP first (ACK's RuleGroupsNamespaces and AlertManagerDefinition), while ACK runs: it
#    deletes them in AMP. With no ACK pod, or past the limit, their finalizers are cleared and what is left in AMP is
#    printed with its delete commands, for the learner: it blocks nothing of the destroy.

#    Then workload Applications, highest wave first, one wave at a time (their finalizer deletes what each deployed):
#    all but svp-cluster and the platform controllers, whose finalizers and webhooks the workloads' objects need. Then
#    Gateway svp of svp-edge and svp-cluster's TargetGroupBinding svp-envoy. Waits, with LBC and Envoy Gateway running,
#    until no LoadBalancer Service, TargetGroupBinding or LBC load balancer is left (DNS records are root env's).

#    Between the workloads and the Gateway, with media-worker gone (no new job), every job of MediaConvert queue
#    svp-<env> still SUBMITTED or PROGRESSING is cancelled, and it waits until none is: such a job blocks the queue's
#    delete and writes into the media bucket the destroy empties. Prints how many it cancelled.

# 3. Every PVC of every namespace (volumeClaimTemplates: Argo CD never prunes them), with the EBS CSI driver running and
#    svp-cluster's namespaces and StorageClass still there. Waits until no PVC, no PV of the driver and no EBS volume
#    the driver made for the cluster are left.

# 4. Every NodePool, then every EC2NodeClass, while Karpenter runs (svp-cluster, which renders them, no longer syncs
#    since step 1). Waits until no NodeClaim and no EC2 instance Karpenter made for the cluster are left; the limit
#    exceeds the terminationGracePeriod of the NodePool, after which Karpenter ends a node whatever blocks its drain.

# 5. svp-cluster and the platform Applications, highest wave first. Waits a few minutes per wave and only notes what is
#    left: nothing of them is billed outside the cluster, which terraform destroy deletes.

# A cluster without Argo CD has no Application to delete: steps 1, 2 and 5 skip them, one without Karpenter has no
# NodePool: step 4 skips them; the waits of steps 2 to 4 still check that nothing of Kubernetes is left in the account.

# Records pre-destroy-start in the timeline once the account is checked, and pre-destroy-done at the end, which tf.sh
# <env> gitops plan --destroy requires. Run it again after a failure: each step finds what is left. When the session's
# time is up and step 2, 3 or 4 is still red, tf.sh <env> gitops plan --destroy --leftovers (it needs
# pre-destroy-start) is the way out.

# Usage: aws/scripts/pre-destroy.sh [--print] stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] $(env_names session)"
env_arg "$1"
session_dir

# Applications that stay until step 4: svp-cluster, then the controllers the objects of the workloads need while they
# are deleted (a ScaledObject's finalizer needs KEDA, Kyverno's webhooks see every write of svp, ...), and the two of
# step 2's waits, and Karpenter, which ends its nodes in step 4.
platform_apps=" svp-cluster cert-manager envoy-gateway external-secrets aws-load-balancer-controller keda argo-rollouts kyverno svp-policy karpenter "
wave_limit=600
platform_wave_limit=300
ack_limit=300
# The terminationGracePeriod of the NodePool (10 minutes) plus the time EC2 takes to end an instance.
karpenter_limit=${SVP_KARPENTER_LIMIT:-900}
mc_queue=svp-$env_name
mc_limit=300

step "pre-destroy.sh: account and cluster $context"
check_account
mark pre-destroy-start
kubeconfig ||
  fail "kubeconfig context $context of cluster $cluster (no such cluster in the account? then nothing ever ran on one: aws/scripts/tf.sh $env_name env plan --destroy --no-cluster, which checks that the state holds none)"
ok "context $context in the kubeconfig"
need_tunnel
# The CRD rather than namespace argocd: root gitops makes the namespace before Argo CD.
argocd=$(kc get crd applications.argoproj.io --ignore-not-found -o name) ||
  fail "cannot reach the cluster on context $context (error above)"
if printing || [ -n "$argocd" ]; then
  argocd=1
else
  note "no Argo CD on $context (no CRD applications.argoproj.io): no Application to delete; what Kubernetes may have made in the account is still checked"
fi

# apps: "wave name" of every Application in argocd, highest wave first. With --print, one placeholder line.
apps() {
  local out
  out=$(kc -n argocd get applications -o json) || return 1
  if printing; then
    echo "7 <Application>"
    return 0
  fi
  jq -r '.items[] | "\(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0") \(.metadata.name)"' <<<"$out" |
    sort -k1,1nr -k2,2
}

is_platform() { case $platform_apps in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# gone KIND [ARGS...]: true when kubectl lists no object of KIND (all namespaces unless ARGS say otherwise).
gone() {
  local out
  out=$(kc get "$@" -o json 2>/dev/null) || return 1
  printing && return 0
  [ "$(jq '.items | length' <<<"$out")" = 0 ]
}

lb_services_gone() {
  local out
  out=$(kc get services -A -o json) || return 1
  printing && return 0
  [ "$(jq '[.items[] | select(.spec.type == "LoadBalancer")] | length' <<<"$out")" = 0 ]
}

# The load balancers and target groups LBC made carry tag elbv2.k8s.aws/cluster=<cluster>.
elb_gone() {
  local out
  out=$(aws_ resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer \
    elasticloadbalancing:targetgroup --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$cluster" --output json) || return 1
  printing && return 0
  [ "$(jq '.ResourceTagMappingList | length' <<<"$out")" = 0 ]
}

pv_gone() {
  local out
  out=$(kc get pv -o json) || return 1
  printing && return 0
  [ "$(jq '[.items[] | select(.spec.csi.driver == "ebs.csi.aws.com")] | length' <<<"$out")" = 0 ]
}

# The EBS CSI driver tags its volumes ebs.csi.aws.com/cluster=true, and Project=svp through the add-on's
# extraVolumeTags; node root volumes carry Project=svp only.
csi_volumes() {
  local out
  out=$(aws_ ec2 describe-volumes --filters Name=tag:ebs.csi.aws.com/cluster,Values=true Name=tag:Project,Values=svp \
    --output json) || return 1
  printing && return 0
  jq -r '.Volumes[] | "\(.VolumeId) \(.State) \(.Size) GiB \((.Tags // []) | map(select(.Key == "kubernetes.io/created-for/pvc/name")) | .[0].Value // "")"' <<<"$out"
}
volumes_gone() {
  local left
  left=$(csi_volumes) || return 1
  [ -z "$left" ]
}

nodeclaims() {
  local out
  out=$(kc get nodeclaims.karpenter.sh -o json) || return 1
  printing && return 0
  jq -r '.items[] | "\(.metadata.name) \(.status.nodeName // "-")"' <<<"$out"
}
nodeclaims_gone() {
  local left
  left=$(nodeclaims) || return 1
  [ -z "$left" ]
}

# Karpenter tags its instances kubernetes.io/cluster/<cluster>=owned and karpenter.sh/nodepool=<NodePool>; the nodes of
# the system node group carry no karpenter.sh/nodepool.
karpenter_instances() {
  local out
  out=$(aws_ ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/$cluster,Values=owned" \
    Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
    --output json) || return 1
  printing && return 0
  jq -r '.Reservations[].Instances[] | "\(.InstanceId) \(.State.Name) \(.InstanceType) \((.Tags // []) | map(select(.Key == "karpenter.sh/nodepool")) | .[0].Value // "")"' <<<"$out"
}
karpenter_instances_gone() {
  local left
  left=$(karpenter_instances) || return 1
  [ -z "$left" ]
}

ack_kinds=rulegroupsnamespaces.prometheusservice.services.k8s.aws,alertmanagerdefinitions.prometheusservice.services.k8s.aws
# ack_left: "resource namespace name workspace AMP-name" of each ACK resource of AMP left in the cluster.
ack_left() {
  local out
  out=$(kc get "$ack_kinds" -A -o json) || return 1
  printing && return 0
  jq -r '.items[] | "\(.kind | ascii_downcase)s.prometheusservice.services.k8s.aws \(.metadata.namespace) \(.metadata.name) \(.spec.workspaceID // "-") \(.spec.name // "-")"' <<<"$out"
}
ack_gone() {
  local left
  left=$(ack_left) || return 1
  [ -z "$left" ]
}
# ack_running: a Ready pod of ACK's controller (its ServiceAccount is the one its Pod Identity names).
ack_running() {
  local out
  out=$(kc get pods -A -o json) || return 1
  printing && return 0
  jq -e 'any(.items[]; .spec.serviceAccountName == "ack-prometheusservice-controller"
    and any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<<"$out" >/dev/null
}

# mc_jobs: "id status" of each job of MediaConvert queue $mc_queue still SUBMITTED or PROGRESSING. An error of
# MediaConvert (no permission, throttled) is a FAIL that names the call, never an empty answer read as no job.
mc_jobs() {
  local s out
  for s in SUBMITTED PROGRESSING; do
    out=$(aws_ mediaconvert list-jobs --queue "$mc_queue" --status "$s" --output json) ||
      fail "list the $s jobs of MediaConvert queue $mc_queue (error above)"
    printing || jq -r '.Jobs[]? | "\(.Id) \(.Status)"' <<<"$out"
  done
}
# Run in the script's shell by wait_until, so that the FAIL of mc_jobs ends the script rather than the wait.
mc_jobs_gone() {
  local left
  left=$(mc_jobs) || exit 1
  [ -z "$left" ]
}

app_gone() {
  local out
  out=$(kc -n argocd get application "$1" --ignore-not-found -o name) || return 1
  [ -z "$out" ]
}

# delete_wave LIMIT NAME...: deletes the Applications (their finalizer cascades), waits until they are gone.
delete_wave() {
  local limit=$1 a
  shift
  for a in "$@"; do
    kc -n argocd delete application "$a" --wait=false >/dev/null || return 1
  done
  for a in "$@"; do
    wait_until "Application $a is deleted with what it deployed" "$limit" app_gone "$a" || return 1
  done
}

# delete_apps LIMIT platform|workload: the Applications of that group, one wave at a time, highest first. Returns 1
# with the names left when a wave is not gone in LIMIT seconds.
delete_apps() {
  local limit=$1 group=$2 list w names wave name
  list=$(apps) || return 1
  for w in $(awk '{ print $1 }' <<<"$list" | uniq); do
    if printing; then
      delete_wave "$limit" "<each $group Application, one sync wave at a time, highest first>"
      continue
    fi
    names=
    while read -r wave name; do
      [ "$wave" = "$w" ] || continue
      if is_platform "$name"; then
        [ "$group" = platform ] || continue
      else
        [ "$group" = workload ] || continue
      fi
      names="$names $name"
    done <<<"$list"
    [ -n "$names" ] || continue
    # shellcheck disable=SC2086 # one word per Application name
    if ! delete_wave "$limit" $names; then
      left_apps="$names"
      return 1
    fi
    ok "wave $w deleted:$names"
  done
}

step "pre-destroy.sh 1/5: ApplicationSet svp-bootstrap, Applications svp-root and svp-apps"
if [ -z "$argocd" ]; then
  ok "no Application (no Argo CD)"
else
  for root in svp-root svp-apps; do
    found=$(kc -n argocd get application "$root" --ignore-not-found -o name) || fail "read Application $root"
    if printing || [ -n "$found" ]; then
      kc -n argocd patch application "$root" --type merge \
        -p '{"metadata":{"finalizers":null},"spec":{"syncPolicy":{"automated":null}}}' >/dev/null ||
        fail "clear the finalizers and the auto-sync of $root"
    fi
  done
  appset=$(kc get crd applicationsets.argoproj.io --ignore-not-found -o name) || fail "read the CRDs"
  if printing || [ -n "$appset" ]; then
    kc -n argocd delete applicationset svp-bootstrap --ignore-not-found --wait=true --timeout=120s >/dev/null ||
      fail "delete ApplicationSet svp-bootstrap"
  fi
  for root in svp-root svp-apps; do
    kc -n argocd delete application "$root" --ignore-not-found --wait=true --timeout=120s >/dev/null || fail "delete $root"
  done
  ok "svp-bootstrap, svp-root and svp-apps deleted alone; their children stay"
fi
if [ -n "$argocd" ]; then
  list=$(apps) || fail "list the Applications of argocd"
  while read -r _ name; do
    [ -n "$name" ] || continue
    kc -n argocd patch application "$name" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null ||
      fail "turn the auto-sync of Application $name off"
  done <<<"$list"
  ok "auto-sync off on every Application left: $(awk '{ print $2 }' <<<"$list" | oneline)"
fi
mark pre-destroy-root

# way_out STATUS: after a FAIL of step 2, 3 or 4, the two ways on: fix and run again, or, out of time, destroy with what
# is left.
way_out() {
  [ "$1" = 0 ] ||
    printf 'note  %s\n' "fix what the FAIL above names, then aws/scripts/pre-destroy.sh $env_name again; once the session's time is up and step 2, 3 or 4 is still red: aws/scripts/tf.sh $env_name gitops plan --destroy --leftovers, and on with the teardown (docs/runbooks/session-stg.md, stuck-destroy section)" >&2
}
trap 'way_out $?' EXIT

step "pre-destroy.sh 2/5: the rules and alerting of AMP while ACK runs, workload Applications, jobs of MediaConvert, then Gateway svp, while LBC and Envoy Gateway run"
ack_crd=$(kc get crd rulegroupsnamespaces.prometheusservice.services.k8s.aws --ignore-not-found -o name) || fail "read the CRDs"
if printing || [ -n "$ack_crd" ]; then
  ack_up=
  if ack_running; then ack_up=1; fi
  kc delete "$ack_kinds" -A --all --wait=false >/dev/null || fail "delete the ACK resources of AMP"
  if [ -n "$ack_up" ] && wait_until "ACK has deleted every rule groups namespace and alert manager definition in AMP" \
    "$ack_limit" ack_gone; then
    ok "rules and alerting of AMP deleted by ACK"
  else
    left=$(ack_left) || fail "list the ACK resources of AMP"
    if [ -n "$left" ]; then
      [ -n "$ack_up" ] || note "no Ready pod of ACK's controller: it deletes nothing in AMP"
      while read -r kind ns name ws amp_name; do
        # Their finalizer waits for ACK: cleared, so that the Application that made them can go.
        kc -n "$ns" patch "$kind" "$name" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null ||
          fail "clear the finalizer of $kind $ns/$name"
        case $kind in
          rulegroupsnamespaces.*) what="rule groups namespace $amp_name"
            cmd="aws amp delete-rule-groups-namespace --workspace-id $ws --name $amp_name" ;;
          *) what="alert manager definition" cmd="aws amp delete-alert-manager-definition --workspace-id $ws" ;;
        esac
        note "left in AMP: $what of workspace $ws; delete it: AWS_PROFILE=$profile $cmd --region $region"
      done <<<"$left"
    fi
    ok "ACK resources of AMP gone from the cluster; what is left in AMP is listed above (aws/scripts/sweep.sh $env_name lists it too)"
  fi
else
  ok "no ACK resource of AMP (ACK's CRDs are not installed)"
fi
mark pre-destroy-amp-rules
left_apps=
if [ -n "$argocd" ]; then
  delete_apps "$wave_limit" workload ||
    fail "Application(s)$left_apps not gone after $wave_limit s: kubectl --context $context -n argocd get application <name> -o yaml (status.operationState, finalizers)"
  ok "every workload Application deleted"
fi
queues=$(aws_ mediaconvert list-queues --output json) || fail "list the queues of MediaConvert (error above)"
if printing || jq -e --arg q "$mc_queue" 'any(.Queues[]?; .Name == $q)' <<<"$queues" >/dev/null; then
  jobs=$(mc_jobs) || exit 1
  printing && jobs='<each-job-above> <its-status>'
  cancelled=0
  while read -r id _; do
    [ -n "$id" ] || continue
    if ! aws_ mediaconvert cancel-job --id "$id" >/dev/null; then
      # A job may end between the list and its cancel: that one is not a failure.
      job=$(aws_ mediaconvert get-job --id "$id" --output json) || fail "read job $id of MediaConvert queue $mc_queue (error above)"
      st=$(jq -r '.Job.Status' <<<"$job")
      case $st in
        SUBMITTED | PROGRESSING) fail "cancel job $id of MediaConvert queue $mc_queue, still $st (error above)" ;;
      esac
      note "job $id of MediaConvert queue $mc_queue ended $st before its cancel"
      continue
    fi
    cancelled=$((cancelled + 1))
  done <<<"$jobs"
  wait_until "no job of MediaConvert queue $mc_queue is SUBMITTED or PROGRESSING" "$mc_limit" mc_jobs_gone ||
    fail "jobs of MediaConvert queue $mc_queue still in flight after $mc_limit s: $(mc_jobs | oneline)"
  ok "$cancelled job(s) of MediaConvert queue $mc_queue cancelled, none in flight"
else
  ok "no MediaConvert queue $mc_queue: no job to cancel"
fi
gw_crd=$(kc get crd gateways.gateway.networking.k8s.io --ignore-not-found -o name) || fail "read the CRDs"
if printing || [ -n "$gw_crd" ]; then
  kc -n svp-edge delete gateway svp --ignore-not-found --wait=true --timeout=300s >/dev/null || fail "delete Gateway svp-edge/svp"
  ok "Gateway svp-edge/svp deleted"
else
  ok "no Gateway (the Gateway API CRDs are not installed)"
fi
wait_until "no Service of type LoadBalancer is left" "$wave_limit" lb_services_gone ||
  fail "a Service of type LoadBalancer is left: kubectl --context $context get services -A --field-selector spec.type=LoadBalancer; LBC's log: kubectl --context $context -n kube-system logs deploy/aws-load-balancer-controller"
ok "no Service of type LoadBalancer"
crd=$(kc get crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found -o name) || fail "read the CRDs"
if printing || [ -n "$crd" ]; then
  # svp-cluster keeps it until step 5, so nothing deletes it with the Gateway; LBC takes Envoy's targets out of the
  # edge's target group (Terraform's) before it lets the binding go.
  kc -n envoy-gateway-system delete targetgroupbindings.elbv2.k8s.aws svp-envoy --ignore-not-found --wait=true \
    --timeout="${wave_limit}s" >/dev/null ||
    fail "TargetGroupBinding envoy-gateway-system/svp-envoy not deleted in $wave_limit s (error above): kubectl --context $context -n envoy-gateway-system get targetgroupbindings.elbv2.k8s.aws svp-envoy -o yaml (finalizers, status); LBC's log: kubectl --context $context -n kube-system logs deploy/aws-load-balancer-controller"
  ok "TargetGroupBinding envoy-gateway-system/svp-envoy deleted"
  wait_until "no TargetGroupBinding is left" "$wave_limit" gone targetgroupbindings.elbv2.k8s.aws -A ||
    fail "a TargetGroupBinding is left: kubectl --context $context get targetgroupbindings.elbv2.k8s.aws -A"
  ok "no TargetGroupBinding"
else
  ok "no TargetGroupBinding (LBC's CRD is not installed)"
fi
wait_until "no load balancer or target group of $cluster is left in ELBv2" "$wave_limit" elb_gone ||
  fail "ELBv2 still holds a load balancer or target group tagged elbv2.k8s.aws/cluster=$cluster (aws/scripts/sweep.sh $env_name lists it)"
ok "no load balancer or target group of $cluster in ELBv2"
mark pre-destroy-workloads

step "pre-destroy.sh 3/5: every PVC, while the EBS CSI driver runs"
out=$(kc get pvc -A -o json) || fail "list the PVCs"
if printing; then
  namespaces='<each-namespace-with-a-PVC>'
else
  namespaces=$(jq -r '.items[].metadata.namespace' <<<"$out" | LC_ALL=C sort -u)
fi
for ns in $namespaces; do
  kc -n "$ns" delete pvc --all --wait=false >/dev/null || fail "delete the PVCs of namespace $ns"
done
[ -z "$namespaces" ] || printing || ok "PVCs deleted in $(oneline <<<"$namespaces")"
wait_until "no PVC is left" "$wave_limit" gone pvc -A ||
  fail "a PVC is left (a pod still mounts it?): kubectl --context $context get pvc -A; kubectl --context $context get pods -A"
ok "no PVC"
wait_until "no PersistentVolume of the EBS CSI driver is left" "$wave_limit" pv_gone ||
  fail "a PersistentVolume of ebs.csi.aws.com is left: kubectl --context $context get pv (reclaim policy Retain?)"
ok "no PersistentVolume of the EBS CSI driver"
if ! wait_until "no EBS volume of the EBS CSI driver is left" "$wave_limit" volumes_gone; then
  fail "EBS volumes left: $(csi_volumes | oneline) (aws/scripts/sweep.sh $env_name lists them with the delete command)"
fi
ok "no EBS volume of the EBS CSI driver"
mark pre-destroy-volumes

step "pre-destroy.sh 4/5: every NodePool, then every EC2NodeClass, while Karpenter runs"
nodepool_crd=$(kc get crd nodepools.karpenter.sh --ignore-not-found -o name) || fail "read the CRDs"
if printing || [ -n "$nodepool_crd" ]; then
  kc delete nodepools.karpenter.sh --all --wait=false >/dev/null || fail "delete the NodePools"
  nodeclass_crd=$(kc get crd ec2nodeclasses.karpenter.k8s.aws --ignore-not-found -o name) || fail "read the CRDs"
  if printing || [ -n "$nodeclass_crd" ]; then
    kc delete ec2nodeclasses.karpenter.k8s.aws --all --wait=false >/dev/null || fail "delete the EC2NodeClasses"
  fi
  if ! wait_until "no NodeClaim is left" "$karpenter_limit" nodeclaims_gone; then
    fail "NodeClaims left after $karpenter_limit s: $(nodeclaims | oneline); Karpenter's log: kubectl --context $context -n kube-system logs deploy/karpenter"
  fi
  ok "NodePools and EC2NodeClasses deleted, no NodeClaim"
else
  note "no Karpenter on $context (no CRD nodepools.karpenter.sh): no NodePool to delete; its instances are still checked"
fi
if ! wait_until "no EC2 instance Karpenter made for $cluster is left" "$karpenter_limit" karpenter_instances_gone; then
  fail "instances of Karpenter left: $(karpenter_instances | oneline) (aws/scripts/sweep.sh $env_name lists them with the terminate command)"
fi
ok "no EC2 instance of Karpenter for $cluster"
mark pre-destroy-nodes
trap - EXIT

step "pre-destroy.sh 5/5: svp-cluster and the platform Applications"
left_apps=
if [ -z "$argocd" ]; then
  ok "no Application (no Argo CD)"
elif delete_apps "$platform_wave_limit" platform; then
  ok "every Application deleted"
else
  note "Application(s)$left_apps not gone after $platform_wave_limit s; terraform destroy deletes the cluster with them (steps 2 to 4 left nothing billed outside it)"
fi
mark pre-destroy-done
ok "ready for: aws/scripts/tf.sh $env_name gitops plan --destroy"
