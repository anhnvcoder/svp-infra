#!/usr/bin/env bash
# What Kubernetes made in the account, removed while the controllers that made it still run, before tf.sh <env>
# destroy: the NLB and target groups (AWS Load Balancer Controller, from the Service of Envoy's Gateway), the EBS
# volumes of PVCs (EBS CSI driver) and the DNS records (ExternalDNS). Terraform knows none of them; left behind they
# block the destroy (ENIs, security groups) or stay billed (volumes). Every wait has a limit, and what is left is printed.
#   1. Root svp-root: its auto-sync (prune, self-heal) would make again every child deleted below. Its finalizers and
#      automated sync are cleared, then it is deleted alone (no finalizer: no cascade, the children stay). The
#      children's auto-sync is turned off too, so that svp-cluster does not make the Gateway again.
#   2. Workload Applications, highest sync wave first, one wave at a time (their finalizer deletes what each deployed):
#      every Application but svp-cluster and the platform controllers (those whose finalizers and webhooks the
#      workloads' objects need on deletion: KEDA, Kyverno, Argo Rollouts, External Secrets, cert-manager, Envoy
#      Gateway, LBC, ExternalDNS). Then Gateway svp of svp-edge (svp-cluster's, the source of Envoy's Service). Waits
#      until no Service of type LoadBalancer, no TargetGroupBinding, no load balancer of the cluster in ELBv2 and no
#      record of ExternalDNS in the lab zone are left, with LBC, ExternalDNS and Envoy Gateway still running.
#   3. Every PVC of every namespace (volumeClaimTemplates: Argo CD never prunes them), with the EBS CSI driver (an EKS
#      add-on) running and svp-cluster's namespaces and StorageClass still there. Waits until no PVC, no PV of the
#      driver and no EBS volume the driver made for the cluster are left.
#   4. svp-cluster and the platform Applications, highest wave first. Waits a few minutes per wave and only notes
#      what is left: nothing of them is billed outside the cluster, which terraform destroy deletes.
# A cluster without Argo CD (make eks-gitops-up stopped before installing it, at its release checks say) has no
# Application to delete: steps 1, 2 and 4 skip them, and the waits of steps 2 and 3 still check that nothing of
# Kubernetes is left in the account.
# Needs no step but the apply that made the cluster: it writes the kubeconfig context itself and reads the lab zone's id
# from the root's tfvars, not from the files of bootstrap-argocd.sh. So it also runs after an apply that failed once EKS
# existed (its outputs were not stored, so bootstrap-argocd.sh cannot run), and from a new session directory.
# Records pre-destroy-done in the timeline, which tf.sh <env> plan --destroy requires. Run it again after a failure: each
# step finds what is left.
#
# Usage: aws/scripts/pre-destroy.sh [--print] stg
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] stg"
env_arg "$1"
session_dir

# Applications that stay until step 4: svp-cluster, then the controllers the objects of the workloads need while they
# are deleted (a ScaledObject's finalizer needs KEDA, Kyverno's webhooks see every write of svp, ...), and the three of
# step 2's waits.
platform_apps=" svp-cluster cert-manager envoy-gateway external-secrets aws-load-balancer-controller external-dns keda argo-rollouts kyverno svp-policy "
wave_limit=600
platform_wave_limit=300

# The zone ExternalDNS writes into: hosted_zone_id of the root's personal tfvars, the value output cluster_values
# passes to the cluster as hostedZoneId.
tfvars=$root_dir/$env_name.auto.tfvars
if printing; then
  zone_id="<hosted_zone_id of aws/envs/$env_name/$env_name.auto.tfvars>"
  zone='<lab zone>'
else
  [ -f "$tfvars" ] || fail "no $tfvars: the file tf.sh $env_name plan read, with the hosted_zone_id of the lab zone"
  zone_id=$(sed -n 's/^[[:space:]]*hosted_zone_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tfvars" | head -n 1)
  [[ $zone_id =~ ^Z[A-Z0-9]{1,31}$ ]] ||
    fail "hosted_zone_id of $tfvars is '$zone_id', not a hosted zone id such as Z0123456789ABCDEFGHIJ"
  lab_zone
fi

step "pre-destroy.sh: account and cluster $context"
check_account
aws_ eks update-kubeconfig --name "$cluster" --alias "$context" ||
  fail "aws eks update-kubeconfig for cluster $cluster (no such cluster in the account? then nothing ever ran on one: aws/scripts/tf.sh $env_name plan --destroy --no-cluster, which checks that the state holds none)"
ok "context $context in the kubeconfig"
# The CRD rather than namespace argocd: make eks-gitops-up makes the namespace just before helm installs Argo CD.
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

# Records of the lab zone but NS and SOA at its apex and the TXT of an ACME challenge (cert-manager's, which the
# sweep reports): ExternalDNS's A and TXT records of the cluster's names.
dns_records() {
  local out
  out=$(aws_ route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json) || return 1
  printing && return 0
  jq -r --arg apex "$zone." '.ResourceRecordSets[]
    | select((.Name == $apex and (.Type == "NS" or .Type == "SOA")) | not)
    | select((.Type == "TXT" and (.Name | startswith("_acme-challenge."))) | not)
    | "\(.Name) \(.Type)"' <<<"$out"
}
dns_gone() {
  local left
  left=$(dns_records) || return 1
  [ -z "$left" ]
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

step "pre-destroy.sh 1/4: root svp-root"
root=
if [ -n "$argocd" ]; then
  root=$(kc -n argocd get application svp-root --ignore-not-found -o name) || fail "read Application svp-root"
fi
if [ -z "$argocd" ]; then
  ok "no Application (no Argo CD)"
elif printing || [ -n "$root" ]; then
  kc -n argocd patch application svp-root --type merge \
    -p '{"metadata":{"finalizers":null},"spec":{"syncPolicy":{"automated":null}}}' >/dev/null ||
    fail "clear the finalizers and the auto-sync of svp-root"
  kc -n argocd delete application svp-root --wait=true --timeout=120s >/dev/null || fail "delete svp-root"
  ok "svp-root deleted alone; its children stay"
else
  ok "svp-root already gone"
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

step "pre-destroy.sh 2/4: workload Applications, then Gateway svp, while LBC, ExternalDNS and Envoy Gateway run"
left_apps=
if [ -n "$argocd" ]; then
  delete_apps "$wave_limit" workload ||
    fail "Application(s)$left_apps not gone after $wave_limit s: kubectl --context $context -n argocd get application <name> -o yaml (status.operationState, finalizers)"
  ok "every workload Application deleted"
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
  wait_until "no TargetGroupBinding is left" "$wave_limit" gone targetgroupbindings.elbv2.k8s.aws -A ||
    fail "a TargetGroupBinding is left: kubectl --context $context get targetgroupbindings.elbv2.k8s.aws -A"
  ok "no TargetGroupBinding"
else
  ok "no TargetGroupBinding (LBC's CRD is not installed)"
fi
wait_until "no load balancer or target group of $cluster is left in ELBv2" "$wave_limit" elb_gone ||
  fail "ELBv2 still holds a load balancer or target group tagged elbv2.k8s.aws/cluster=$cluster (aws/scripts/sweep.sh lists it)"
ok "no load balancer or target group of $cluster in ELBv2"
if ! wait_until "no record of ExternalDNS is left in $zone" "$wave_limit" dns_gone; then
  fail "records left in $zone: $(dns_records | oneline); ExternalDNS's log: kubectl --context $context -n external-dns logs deploy/external-dns"
fi
ok "no record of ExternalDNS in $zone"
mark pre-destroy-workloads

step "pre-destroy.sh 3/4: every PVC, while the EBS CSI driver runs"
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
  fail "EBS volumes left: $(csi_volumes | oneline) (aws/scripts/sweep.sh lists them; the runbook has the delete command)"
fi
ok "no EBS volume of the EBS CSI driver"
mark pre-destroy-volumes

step "pre-destroy.sh 4/4: svp-cluster and the platform Applications"
left_apps=
if [ -z "$argocd" ]; then
  ok "no Application (no Argo CD)"
elif delete_apps "$platform_wave_limit" platform; then
  ok "every Application deleted"
else
  note "Application(s)$left_apps not gone after $platform_wave_limit s; terraform destroy deletes the cluster with them (steps 2 and 3 left nothing billed outside it)"
fi
mark pre-destroy-done
ok "ready for: aws/scripts/tf.sh $env_name plan --destroy"
