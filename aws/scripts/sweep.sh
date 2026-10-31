#!/usr/bin/env bash
# Last step of every AWS session, after tf.sh <env> destroy: lists what is left in the region of the lab, from the AWS
# APIs alone, so it works when a destroy stopped half-way or the state is lost. Read only: no command here creates,
# changes or deletes anything; deleting a leftover is the learner's, with the commands of the session runbook.
# Looks for resources tagged Project=svp, or with a tag Kubernetes components put on what they make
# (kubernetes.io/cluster/svp-*, elbv2.k8s.aws/cluster, ebs.csi.aws.com/cluster, cluster.k8s.amazonaws.com/name), or
# named as the lab names them (svp-*):
#   EKS clusters; EC2 instances, EBS volumes and snapshots, VPCs, NAT gateways, Elastic IPs, network interfaces and
#   security groups (also any of a VPC of the lab); ELBv2 load balancers and target groups; RDS instances, snapshots and
#   retained automated backups; S3 buckets; CloudFront distributions, origin access controls and response headers
#   policies; CloudWatch log groups; Secrets Manager secrets, also those scheduled for deletion (they still hold their
#   name); KMS keys; records of the lab zone but NS and SOA at its apex.
# The resources of aws/bootstrap (state bucket and hosted zone, tagged Stack=bootstrap) are printed as kept.
# Exit 0 when nothing else is left, 1 when anything is left or a kind could not be read.
#
# Usage: aws/scripts/sweep.sh [--print]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
case "$*" in '' | --print) ;; *) fail "usage: $(basename "$0") [--print]" ;; esac

svp_tag=Name=tag:Project,Values=svp
k8s_tag='Name=tag-key,Values=kubernetes.io/cluster/svp-*'
leftovers=0
unread=

# q FILTER AWS-ARGS...: the lines jq's FILTER makes of the JSON answer of aws AWS-ARGS (nothing with --print).
q() {
  local filter=$1 out
  shift
  out=$(aws_ "$@" --output json) || return 1
  printing && return 0
  jq -r "$filter" <<<"$out"
}

# found KIND LINES: one line ok or FAIL for KIND, then the leftovers indented.
found() {
  local kind=$1 lines n
  lines=$(grep . <<<"$2" | LC_ALL=C sort -u || true)
  printing && return 0
  if [ -z "$lines" ]; then
    ok "$kind: none"
    return 0
  fi
  n=$(grep -c . <<<"$lines")
  printf 'FAIL  %s: %s left\n' "$kind" "$n"
  while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$lines"
  leftovers=$((leftovers + n))
}

# unreadable KIND: the API of KIND answered with an error (shown above by aws): the sweep cannot say it is clean.
unreadable() {
  printf 'FAIL  %s: could not be read (error above)\n' "$1"
  unread="$unread $1"
}

# sweep_kind KIND FUNCTION: FUNCTION prints the leftovers of KIND, or fails when an API call failed.
sweep_kind() {
  local lines
  if lines=$("$2"); then
    found "$1" "$lines"
  else
    unreadable "$1"
  fi
}

eks_clusters() { q '.clusters[] | select(startswith("svp-"))' eks list-clusters; }

instances() {
  local states=Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped f
  for f in "$svp_tag" "$k8s_tag"; do
    q '.Reservations[].Instances[] | "\(.InstanceId) \(.State.Name) \(.InstanceType)"' ec2 describe-instances --filters "$states" "$f" || return 1
  done
}

volumes() {
  local f
  for f in "$svp_tag" "$k8s_tag" Name=tag-key,Values=ebs.csi.aws.com/cluster; do
    q '.Volumes[] | "\(.VolumeId) \(.State) \(.Size) GiB \((.Tags // []) | map(select(.Key == "kubernetes.io/created-for/pvc/name")) | .[0].Value // "")"' \
      ec2 describe-volumes --filters "$f" || return 1
  done
}

snapshots() {
  local f
  for f in "$svp_tag" Name=tag-key,Values=ebs.csi.aws.com/cluster; do
    q '.Snapshots[] | "\(.SnapshotId) \(.State) \(.VolumeSize) GiB"' ec2 describe-snapshots --owner-ids self --filters "$f" || return 1
  done
}

vpcs() { q '.Vpcs[] | "\(.VpcId) \(.CidrBlock)"' ec2 describe-vpcs --filters "$svp_tag"; }

nat_gateways() {
  q '.NatGateways[] | "\(.NatGatewayId) \(.State)"' ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting "$svp_tag"
}

addresses() { q '.Addresses[] | "\(.AllocationId) \(.PublicIp) \(.AssociationId // "unassociated")"' ec2 describe-addresses --filters "$svp_tag"; }

# The VPCs of the lab that are left: any interface or security group in them is a leftover too.
vpc_filter() {
  printing && {
    echo 'Name=vpc-id,Values=<VPC-ids-above>'
    return 0
  }
  [ -z "$vpc_ids" ] || echo "Name=vpc-id,Values=$(tr ' ' ',' <<<"$vpc_ids")"
}

interfaces() {
  local f
  for f in "$svp_tag" 'Name=tag:cluster.k8s.amazonaws.com/name,Values=svp-*' 'Name=description,Values=Amazon EKS svp-*' $(vpc_filter); do
    q '.NetworkInterfaces[] | "\(.NetworkInterfaceId) \(.Status) \(.Description)"' ec2 describe-network-interfaces --filters "$f" || return 1
  done
}

security_groups() {
  local f
  for f in "$svp_tag" "$k8s_tag" 'Name=tag:elbv2.k8s.aws/cluster,Values=svp-*' $(vpc_filter); do
    q '.SecurityGroups[] | "\(.GroupId) \(.GroupName)"' ec2 describe-security-groups --filters "$f" || return 1
  done
}

# elbv2_tagged KIND-ARNS-FILTER AWS-ARGS...: the ARNs of the answer whose tags are the lab's (describe-tags takes 20 at a
# time).
elbv2_tagged() {
  local arns_filter=$1 arns batch
  shift
  arns=$(q "$arns_filter" "$@") || return 1
  printing && arns='<ARNs-above-20-at-a-time>'
  while [ -n "$arns" ]; do
    batch=$(head -n 20 <<<"$arns")
    arns=$(tail -n +21 <<<"$arns")
    # shellcheck disable=SC2046 # one word per ARN
    q '.TagDescriptions[] | select(any(.Tags[];
        (.Key == "Project" and .Value == "svp")
        or (.Key == "elbv2.k8s.aws/cluster" and (.Value | startswith("svp-")))
        or (.Key | startswith("kubernetes.io/cluster/svp-")))) | .ResourceArn' \
      elbv2 describe-tags --resource-arns $(printf '%s\n' "$batch") || return 1
  done
}
load_balancers() { elbv2_tagged '.LoadBalancers[].LoadBalancerArn' elbv2 describe-load-balancers; }
target_groups() { elbv2_tagged '.TargetGroups[].TargetGroupArn' elbv2 describe-target-groups; }

rds_instances() {
  q '.DBInstances[] | select((.DBInstanceIdentifier | startswith("svp-")) or any(.TagList[]?; .Key == "Project" and .Value == "svp"))
    | "\(.DBInstanceIdentifier) \(.DBInstanceStatus)"' rds describe-db-instances
}
rds_snapshots() {
  q '.DBSnapshots[] | select((.DBInstanceIdentifier | startswith("svp-")) or any(.TagList[]?; .Key == "Project" and .Value == "svp"))
    | "\(.DBSnapshotIdentifier) \(.SnapshotType) \(.Status)"' rds describe-db-snapshots || return 1
  q '.DBInstanceAutomatedBackups[] | select(.DBInstanceIdentifier | startswith("svp-")) | "\(.DBInstanceAutomatedBackupsArn) \(.Status)"' \
    rds describe-db-instance-automated-backups
}

# Buckets named svp-*; the state bucket of aws/bootstrap (Stack=bootstrap) goes to kept_buckets.
buckets() {
  local names b tags
  names=$(q '.Buckets[].Name | select(startswith("svp-"))' s3api list-buckets) || return 1
  printing && names='<each-bucket-svp-*-above>'
  for b in $names; do
    tags=$(aws_ s3api get-bucket-tagging --bucket "$b" --output json 2>/dev/null) || tags='{"TagSet": []}'
    printing && continue
    if jq -e 'any(.TagSet[]?; .Key == "Stack" and .Value == "bootstrap")' <<<"$tags" >/dev/null; then
      echo "$b" >>"$kept_file"
    else
      echo "$b"
    fi
  done
}

distributions() {
  q '.DistributionList.Items[]? | select(((.Comment // "") | startswith("Media of svp-")) or any(.Origins.Items[]?; .DomainName | startswith("svp-")))
    | "\(.Id) \(.Status) enabled=\(.Enabled) \(.DomainName)"' cloudfront list-distributions
}
cloudfront_policies() {
  q '.OriginAccessControlList.Items[]? | select(.Name | startswith("svp-")) | "origin access control \(.Id) \(.Name)"' \
    cloudfront list-origin-access-controls || return 1
  q '.ResponseHeadersPolicyList.Items[]?.ResponseHeadersPolicy | select(.ResponseHeadersPolicyConfig.Name | startswith("svp-"))
    | "response headers policy \(.Id) \(.ResponseHeadersPolicyConfig.Name)"' cloudfront list-response-headers-policies --type custom
}

# Log groups EKS or RDS make under the lab's names (untagged), and any tagged Project=svp (the VPC flow log).
log_groups() {
  q '.logGroups[].logGroupName | select(test("^/aws/eks/svp-|^/aws/rds/instance/svp-"))' logs describe-log-groups || return 1
  q '.ResourceTagMappingList[].ResourceARN' resourcegroupstaggingapi get-resources --resource-type-filters logs:log-group \
    --tag-filters Key=Project,Values=svp
}

# Secrets of the lab, and the master secret RDS keeps for an instance svp-* (tag aws:rds:primaryDBInstanceArn); one
# scheduled for deletion is listed with its date: until then no secret of that name can be made.
secrets() {
  q '.SecretList[] | select((.Name | startswith("svp")) or any(.Tags[]?; (.Key == "Project" and .Value == "svp")
      or (.Key == "aws:rds:primaryDBInstanceArn" and (.Value | test(":db:svp-")))))
    | "\(.Name)\(if .DeletedDate then " (scheduled for deletion since \(.DeletedDate))" else "" end)"' \
    secretsmanager list-secrets --include-planned-deletion
}

kms_keys() {
  q '.Aliases[] | select(.AliasName | test("^alias/(svp|eks/svp-)")) | "\(.AliasName) \(.TargetKeyId // "")"' kms list-aliases || return 1
  q '.ResourceTagMappingList[].ResourceARN' resourcegroupstaggingapi get-resources --resource-type-filters kms:key \
    --tag-filters Key=Project,Values=svp
}

# Records of the lab zone but NS and SOA at its apex, the zone's own.
records() {
  local ids id
  # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
  ids=$(q '.HostedZones[] | select(.Name == ($ENV.SVP_SWEEP_ZONE + ".")) | .Id' route53 list-hosted-zones-by-name --dns-name "$zone.") ||
    return 1
  printing && ids='<id-of-the-lab-zone>'
  for id in $ids; do
    printing || echo "hosted zone $zone ($id), NS and SOA at its apex" >>"$kept_file"
    # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
    q '.ResourceRecordSets[] | select((.Name == ($ENV.SVP_SWEEP_ZONE + ".") and (.Type == "NS" or .Type == "SOA")) | not)
      | "\(.Name) \(.Type)"' route53 list-resource-record-sets --hosted-zone-id "$id" || return 1
  done
}

lab_zone
export SVP_SWEEP_ZONE=$zone
kept_file=$(mktemp)
trap 'rm -f "$kept_file"' EXIT

step "sweep.sh: leftovers of the lab in $region (read only)"
check_account
sweep_kind "EKS clusters" eks_clusters
sweep_kind "EC2 instances" instances
sweep_kind "EBS volumes" volumes
sweep_kind "EBS snapshots" snapshots
vpc_ids=
if vpc_lines=$(vpcs); then
  found VPCs "$vpc_lines"
  vpc_ids=$(awk '{ print $1 }' <<<"$vpc_lines" | grep . | oneline || true)
else
  unreadable VPCs
fi
sweep_kind "NAT gateways" nat_gateways
sweep_kind "Elastic IPs" addresses
sweep_kind "network interfaces" interfaces
sweep_kind "security groups" security_groups
sweep_kind "ELBv2 load balancers" load_balancers
sweep_kind "ELBv2 target groups" target_groups
sweep_kind "RDS instances" rds_instances
sweep_kind "RDS snapshots and automated backups" rds_snapshots
sweep_kind "S3 buckets" buckets
sweep_kind "CloudFront distributions" distributions
sweep_kind "CloudFront origin access controls and response headers policies" cloudfront_policies
sweep_kind "CloudWatch log groups" log_groups
sweep_kind "Secrets Manager secrets (scheduled for deletion included)" secrets
sweep_kind "KMS keys" kms_keys
sweep_kind "records of $zone" records

printing && exit 0
while read -r line; do
  [ -z "$line" ] || printf 'kept  %s (aws/bootstrap)\n' "$line"
done <"$kept_file"
[ -z "$unread" ] || fail "could not read:$unread; the sweep is not clean until it reads every kind"
[ "$leftovers" -eq 0 ] ||
  fail "$leftovers leftover(s) above: delete them by hand with the commands of docs/runbooks/session-stg.md, then run the sweep again"
ok "nothing left but aws/bootstrap"
