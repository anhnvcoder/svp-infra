#!/usr/bin/env bash
# Last steps of every AWS session, after the destroy of both roots: lists what is left in an account, from the AWS APIs
# alone, so it works when a destroy stopped half-way or the state is lost. Read only: each leftover comes with the
# command that deletes it, for the learner to run. Run for the environment's account (stg, prd), then for mgmt, each
# with its own profile. Exit 0 when nothing else is left, 1 when anything is left or a kind could not be read.

# Looks for resources tagged Project=svp, or with a tag Kubernetes components put on what they make
# (kubernetes.io/cluster/svp-*, elbv2.k8s.aws/cluster, ebs.csi.aws.com/cluster, cluster.k8s.amazonaws.com/name), or
# named svp-*. What stays between sessions (a Stack of the environment's kept list in env_table of lib.sh) is printed as
# "kept", and KMS keys in PendingDeletion as "pending deletion", not counted.

# Design notes: README.md.

# Usage: aws/scripts/sweep.sh [--print] mgmt|stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] $(env_names)"
env_arg "$1" any

svp_tag=Name=tag:Project,Values=svp
k8s_tag='Name=tag-key,Values=kubernetes.io/cluster/svp-*'
leftovers=0
unread=

# q FILTER AWS-ARGS...: the lines jq's FILTER makes of the JSON answer of aws AWS-ARGS (nothing with --print). The
# Stack tags this account keeps are in $KEPT (a JSON list) for the filters.
q() {
  local filter=$1 out
  shift
  out=$(aws_ "$@" --output json) || return 1
  printing && return 0
  jq -r "$filter" <<<"$out"
}
q_global() {
  local filter=$1 out
  shift
  out=$(aws_global_ "$@" --output json) || return 1
  printing && return 0
  jq -r "$filter" <<<"$out"
}
KEPT=$(printf '%s' "$kept_stacks" | jq -Rc 'split(",")')
export KEPT

# found KIND LINES DELETE: one line ok or FAIL for KIND, then each leftover indented, with the command that deletes it:
# DELETE with {} for the first word of the leftover's line, run with the account's profile in $region, or the runbook's
# section when one command does not do it.
found() {
  local kind=$1 lines=$2 delete=$3 n line id
  lines=$(grep . <<<"$lines" | LC_ALL=C sort -u || true)
  printing && return 0
  if [ -z "$lines" ]; then
    ok "$kind: none"
    return 0
  fi
  n=$(grep -c . <<<"$lines")
  printf 'FAIL  %s: %s left\n' "$kind" "$n"
  while IFS= read -r line; do
    printf '        %s\n' "$line"
    id=${line%% *}
    case $delete in
      aws\ *) printf '          delete: AWS_PROFILE=%s %s --region %s\n' "$profile" "${delete//\{\}/$id}" "$region" ;;
      *) printf '          delete: %s\n' "$delete" ;;
    esac
  done <<<"$lines"
  leftovers=$((leftovers + n))
}

# unreadable KIND: the API of KIND answered with an error (shown above by aws): the sweep cannot say it is clean.
unreadable() {
  printf 'FAIL  %s: could not be read (error above)\n' "$1"
  unread="$unread $1"
}

# sweep_kind KIND FUNCTION DELETE: FUNCTION prints the leftovers of KIND, or fails when an API call failed.
sweep_kind() {
  local lines
  if lines=$("$2"); then
    found "$1" "$lines" "$3"
  else
    unreadable "$1"
  fi
}

# keep LINE: printed at the end as kept or pending deletion, not counted.
keep() { printing || printf '%s\n' "$1" >>"$kept_file"; }

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

# elbv2_tagged KIND-ARNS-FILTER AWS-ARGS...: the ARNs of the answer whose tags are the lab's (describe-tags takes 20 at
# a time).
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
# The final snapshot a destroy of prd writes is one of them: the runbook reads it, then deletes it.
rds_snapshots() {
  q '.DBSnapshots[] | select((.DBInstanceIdentifier | startswith("svp-")) or any(.TagList[]?; .Key == "Project" and .Value == "svp"))
    | "\(.DBSnapshotIdentifier) \(.SnapshotType) \(.Status)"' rds describe-db-snapshots
}
rds_backups() {
  q '.DBInstanceAutomatedBackups[] | select(.DBInstanceIdentifier | startswith("svp-")) | "\(.DBInstanceAutomatedBackupsArn) \(.Status)"' \
    rds describe-db-instance-automated-backups
}

# Buckets named svp-*; those tagged with a kept Stack go to the kept list.
buckets() {
  local names b tags
  names=$(q '.Buckets[].Name | select(startswith("svp-"))' s3api list-buckets) || return 1
  printing && names='<each-bucket-svp-*-above>'
  for b in $names; do
    tags=$(aws_ s3api get-bucket-tagging --bucket "$b" --output json 2>/dev/null) || tags='{"TagSet": []}'
    printing && continue
    if jq -e 'any(.TagSet[]?; .Key == "Stack" and (.Value | IN($ENV.KEPT | fromjson[])))' <<<"$tags" >/dev/null; then
      keep "kept  bucket $b (Stack=$(jq -r '.TagSet[] | select(.Key == "Stack") | .Value' <<<"$tags"))"
    else
      echo "$b"
    fi
  done
}

# The plans of the account (CloudFront flat-rate and any other: the account holds only the lab, and a plan made by hand in
# the console is a leftover too), in us-east-1 whatever the region of the environment. A distribution with a plan cannot
# be deleted, so this kind is read before the distributions. A plan with a cancellation already scheduled (paid tiers;
# a Free plan is cancelled at once) is "kept", not counted. The answer is read whole: the CLI pages by itself.
subscriptions() {
  local out line
  out=$(aws_global_ pricing-plan-manager list-subscriptions --output json) || return 1
  printing && return 0
  jq -r '.subscriptionSummaries[]? | select(.scheduledChange.changeType != "CANCELLATION")
    | "\(.arn) \(.planFamily) \(.planTier) \(.status) \((.resourceArns // []) | join(","))"' <<<"$out"
  while IFS= read -r line; do
    keep "$line"
  done < <(jq -r '.subscriptionSummaries[]? | select(.scheduledChange.changeType == "CANCELLATION")
    | "kept  pricing plan \(.arn) (\(.planFamily) \(.planTier)): cancellation scheduled \(.scheduledChange.effectiveDate // "?")"' <<<"$out")
}

distributions() {
  q '.DistributionList.Items[]? | select(((.Comment // "") | startswith("Media of svp-")) or any(.Origins.Items[]?; .DomainName | startswith("svp-")))
    | "\(.Id) \(.Status) enabled=\(.Enabled) \(.DomainName)"' cloudfront list-distributions
}
cloudfront_policies() {
  q '.OriginAccessControlList.Items[]? | select(.Name | startswith("svp-")) | "\(.Id) origin access control \(.Name)"' \
    cloudfront list-origin-access-controls || return 1
  q '.ResponseHeadersPolicyList.Items[]?.ResponseHeadersPolicy | select(.ResponseHeadersPolicyConfig.Name | startswith("svp-"))
    | "\(.Id) response headers policy \(.ResponseHeadersPolicyConfig.Name)"' cloudfront list-response-headers-policies --type custom
}
web_acls() {
  q_global '.WebACLs[] | select(.Name | startswith("svp-")) | "\(.Name) \(.Id)"' wafv2 list-web-acls --scope CLOUDFRONT
}

# Log groups EKS or RDS make under the lab's names (untagged: they write them outside Terraform's state, and again
# after a destroy while the last logs arrive), RDS's Enhanced Monitoring group, and any tagged Project=svp but with a
# kept Stack (the VPC flow log, the groups the rds module makes).
log_groups() {
  q '.logGroups[].logGroupName | select(test("^/aws/eks/svp-|^/aws/rds/instance/svp-|^RDSOSMetrics$"))' logs describe-log-groups || return 1
  # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
  q '.ResourceTagMappingList[] | select(any(.Tags[]?; .Key == "Stack" and (.Value | IN($ENV.KEPT | fromjson[]))) | not)
    | .ResourceARN | sub("^arn:aws:logs:[^:]*:[^:]*:log-group:"; "") | sub(":\\*$"; "")' \
    resourcegroupstaggingapi get-resources --resource-type-filters logs:log-group --tag-filters Key=Project,Values=svp
}

# Secrets of the lab, and the master secret RDS keeps for an instance svp-* (tag aws:rds:primaryDBInstanceArn); one
# scheduled for deletion is listed with its date: until then no secret of that name can be made.
secrets() {
  q '.SecretList[] | select((.Name | startswith("svp")) or any(.Tags[]?; (.Key == "Project" and .Value == "svp")
      or (.Key == "aws:rds:primaryDBInstanceArn" and (.Value | test(":db:svp-")))))
    | "\(.Name)\(if .DeletedDate then " (scheduled for deletion since \(.DeletedDate))" else "" end)"' \
    secretsmanager list-secrets --include-planned-deletion
}

# KMS keys behind an alias of the lab (alias/svp*, alias/eks/svp-*) or tagged Project=svp, each read once:
# PendingDeletion is "pending deletion", a kept Stack is "kept", anything else is left.
kms_keys() {
  local ids id key tags state stack
  ids=$(q '.Aliases[] | select(.AliasName | test("^alias/(svp|eks/svp-)")) | select(.TargetKeyId) | .TargetKeyId' kms list-aliases) || return 1
  ids="$ids
$(q '.ResourceTagMappingList[].ResourceARN | sub("^.*:key/"; "")' resourcegroupstaggingapi get-resources --resource-type-filters kms:key \
    --tag-filters Key=Project,Values=svp)" || return 1
  printing && ids='<each-key-above>'
  for id in $(grep . <<<"$ids" | LC_ALL=C sort -u || true); do
    key=$(aws_ kms describe-key --key-id "$id" --output json) || return 1
    tags=$(aws_ kms list-resource-tags --key-id "$id" --output json) || return 1
    printing && continue
    state=$(jq -r '.KeyMetadata.KeyState' <<<"$key")
    [ "$(jq -r '.KeyMetadata.KeyManager' <<<"$key")" = CUSTOMER ] || continue
    stack=$(jq -r '[.Tags[]? | select(.TagKey == "Stack") | .TagValue][0] // ""' <<<"$tags")
    if [ "$state" = PendingDeletion ]; then
      keep "pending deletion  KMS key $id, deleted on $(jq -r '.KeyMetadata.DeletionDate // "?"' <<<"$key")"
    elif [ -n "$stack" ] && jq -e --arg s "$stack" 'IN($ENV.KEPT | fromjson[]; $s)' -n >/dev/null; then
      keep "kept  KMS key $id (Stack=$stack)"
    else
      echo "$id $state${stack:+ Stack=$stack}"
    fi
  done
}

# Records of the account's hosted zone but NS and SOA at its apex and the NS records below it, which delegate a child
# zone (delegated_subdomains of the baseline) and stay with the zone: ExternalDNS and cert-manager never write NS.
records() {
  local ids id
  export SVP_SWEEP_ZONE=$zone
  # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
  ids=$(q '.HostedZones[] | select(.Name == ($ENV.SVP_SWEEP_ZONE + ".")) | .Id' route53 list-hosted-zones-by-name --dns-name "$zone.") ||
    return 1
  printing && ids='<id-of-the-zone>'
  for id in $ids; do
    keep "kept  hosted zone $zone ($id), NS and SOA at its apex, NS records below it"
    # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
    q '($ENV.SVP_SWEEP_ZONE + ".") as $apex | .ResourceRecordSets[]
      | select((.Name == $apex and .Type == "SOA") | not)
      | select((.Type == "NS" and (.Name == $apex or (.Name | endswith("." + $apex)))) | not)
      | "\(.Name) \(.Type)"' route53 list-resource-record-sets --hosted-zone-id "$id" || return 1
  done
}

env_zone
kept_file=$(mktemp)
trap 'rm -f "$kept_file"' EXIT
runbook=docs/runbooks/session-stg.md#lệnh-xoá-tay-theo-loại

step "sweep.sh: leftovers of the lab in account $env_name, $region and $global_region (read only)"
check_account
sweep_kind "EKS clusters" eks_clusters "aws eks delete-cluster --name {}"
sweep_kind "EC2 instances" instances "aws ec2 terminate-instances --instance-ids {}"
sweep_kind "EBS volumes" volumes "aws ec2 delete-volume --volume-id {}"
sweep_kind "EBS snapshots" snapshots "aws ec2 delete-snapshot --snapshot-id {}"
vpc_ids=
if vpc_lines=$(vpcs); then
  found VPCs "$vpc_lines" "aws ec2 delete-vpc --vpc-id {}"
  vpc_ids=$(awk '{ print $1 }' <<<"$vpc_lines" | grep . | oneline || true)
else
  unreadable VPCs
fi
sweep_kind "NAT gateways" nat_gateways "aws ec2 delete-nat-gateway --nat-gateway-id {}"
sweep_kind "Elastic IPs" addresses "aws ec2 release-address --allocation-id {}"
sweep_kind "network interfaces" interfaces "aws ec2 delete-network-interface --network-interface-id {}"
sweep_kind "security groups" security_groups "aws ec2 delete-security-group --group-id {}"
sweep_kind "ELBv2 load balancers" load_balancers "aws elbv2 delete-load-balancer --load-balancer-arn {}"
sweep_kind "ELBv2 target groups" target_groups "aws elbv2 delete-target-group --target-group-arn {}"
sweep_kind "RDS instances" rds_instances \
  "aws rds delete-db-instance --db-instance-identifier {} --skip-final-snapshot --delete-automated-backups"
sweep_kind "RDS snapshots" rds_snapshots "aws rds delete-db-snapshot --db-snapshot-identifier {}"
sweep_kind "RDS automated backups" rds_backups "aws rds delete-db-instance-automated-backup --db-instance-automated-backups-arn {}"
sweep_kind "S3 buckets" buckets "$runbook (versioned: every version first)"
sweep_kind "CloudFront pricing plan subscriptions" subscriptions \
  "$runbook (cancel the plan first: cancel-subscription takes the eTag of get-subscription, both in us-east-1)"
sweep_kind "CloudFront distributions" distributions "$runbook (disable, wait, then delete)"
sweep_kind "CloudFront origin access controls and response headers policies" cloudfront_policies "$runbook"
sweep_kind "WAF web ACLs of CloudFront" web_acls "$runbook (delete-web-acl takes the lock token of get-web-acl)"
sweep_kind "CloudWatch log groups" log_groups "aws logs delete-log-group --log-group-name {}"
sweep_kind "Secrets Manager secrets (scheduled for deletion included)" secrets \
  "aws secretsmanager delete-secret --secret-id {} --force-delete-without-recovery"
sweep_kind "KMS keys" kms_keys "aws kms schedule-key-deletion --key-id {} --pending-window-in-days 7"
[ -z "$zone" ] || sweep_kind "records of $zone" records "$runbook (change-resource-record-sets DELETE)"

printing && exit 0
while IFS= read -r line; do
  [ -z "$line" ] || printf '%s\n' "$line"
done <"$kept_file"
[ -z "$unread" ] || fail "could not read:$unread; the sweep is not clean until it reads every kind"
[ "$leftovers" -eq 0 ] ||
  fail "$leftovers leftover(s) in account $env_name above: delete each with the command under it, then run aws/scripts/sweep.sh $env_name again"
ok "nothing left in account $env_name but what it keeps (Stack=$kept_stacks) and keys pending deletion"
