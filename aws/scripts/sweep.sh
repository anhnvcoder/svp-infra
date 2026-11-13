#!/usr/bin/env bash
# Last steps of every AWS session, after the destroy of both roots: lists what is left in an account, from the AWS APIs
# alone, so it works when a destroy stopped half-way or the state is lost. Read only: each leftover comes with the
# command that deletes it, for the learner to run. Run for the environment's account (stg, prd), then for mgmt, each
# with its own profile. Exit 0 when nothing else is left, 1 when anything is left or a kind could not be read.

# Looks for resources tagged Project=svp, or with a tag Kubernetes components put on what they make
# (kubernetes.io/cluster/svp-*, elbv2.k8s.aws/cluster, ebs.csi.aws.com/cluster, cluster.k8s.amazonaws.com/name,
# karpenter.sh/nodepool, karpenter.k8s.aws/cluster), or named svp-* (AmazonMSK_svp-* for the SCRAM secrets, Karpenter*
# for the interruption rules of EventBridge). What stays between sessions (a Stack of the environment's kept
# list in env_table of lib.sh) is printed as "kept", and KMS keys in PendingDeletion as "pending deletion", not counted;
# an alias of the lab still on such a key is counted: it keeps its name, so the next session cannot make it again.

# Reads the home region, and us-east-1 for what CloudFront keeps there (web ACLs, pricing plans, certificates, log
# deliveries), for the OIDC providers and roles of CI (IAM is global, its endpoint in us-east-1) and for the kinds a
# baseline keeps there too (the DNSSEC alarms of prd, its query log group, their SNS topic and KMS keys): each of those
# kinds reads the Stack tag, so what a baseline keeps is "kept" in either region.

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

# global FUNCTION ARGS...: FUNCTION with $region set to us-east-1, so that its aws calls, and the delete commands
# found prints for it, name that region.
global() {
  local region=$global_region
  "$@"
}

# is_kept STACK: STACK is one of the Stack tags this account keeps.
is_kept() { [ -n "$1" ] && case ",$kept_stacks," in *",$1,"*) true ;; *) false ;; esac; }
# stack_tag: the value of tag Stack in the JSON on stdin ({"Tags": [{"Key", "Value"}]}), empty without one.
stack_tag() { jq -r '[.Tags[]? | select(.Key == "Stack") | .Value][0] // ""'; }

# found KIND LINES DELETE: one line ok or FAIL for KIND, then each leftover indented, with the command that deletes it:
# DELETE with {} for the first word of the leftover's line and {rest} for the words after it, run with the account's
# profile in $region, or the runbook's section when one command does not do it.
found() {
  local kind=$1 lines=$2 delete=$3 n line id rest cmd
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
    rest=${line#"$id"}
    rest=${rest# }
    cmd=${delete//\{rest\}/$rest}
    case $delete in
      aws\ *) printf '          delete: AWS_PROFILE=%s %s --region %s\n' "$profile" "${cmd//\{\}/$id}" "$region" ;;
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
  for f in "$svp_tag" "$k8s_tag" Name=tag-key,Values=karpenter.sh/nodepool; do
    q '.Reservations[].Instances[] | "\(.InstanceId) \(.State.Name) \(.InstanceType)"' ec2 describe-instances --filters "$states" "$f" || return 1
  done
}

# Launch templates Karpenter makes for each EC2NodeClass (tag karpenter.k8s.aws/cluster), and any of the lab's.
launch_templates() {
  local f
  for f in "$svp_tag" 'Name=tag:karpenter.k8s.aws/cluster,Values=svp-*'; do
    q '.LaunchTemplates[] | "\(.LaunchTemplateId) \(.LaunchTemplateName)"' ec2 describe-launch-templates --filters "$f" || return 1
  done
}

# Instance profiles Karpenter makes for an EC2NodeClass, outside Terraform's state: under path /karpenter/<region>/
# <cluster>/, with the node role svp-<env>-karpenter-node. While one holds the role, IAM refuses to delete the role.
instance_profiles() {
  q '.InstanceProfiles[] | select((.Path | test("^/karpenter/[^/]+/svp-")) or any(.Roles[]?; .RoleName | startswith("svp-")))
    | "\(.InstanceProfileName) \(.Roles[0].RoleName // "-")"' iam list-instance-profiles
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

# Endpoints of the lab or in its VPCs left, such as the interface endpoints svp-<env>-<service>, billed by the hour, or
# one GuardDuty makes itself outside any state when its agent management is on. Their network interfaces go with them.
vpc_endpoints() {
  local f
  for f in "$svp_tag" 'Name=tag:Name,Values=svp-*' $(vpc_filter); do
    q '.VpcEndpoints[] | select((.State | ascii_downcase) != "deleted") | "\(.VpcEndpointId) \(.VpcEndpointType) \(.ServiceName) \(.State)"' \
      ec2 describe-vpc-endpoints --filters "$f" || return 1
  done
}

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
  for f in "$svp_tag" "$k8s_tag" 'Name=tag:elbv2.k8s.aws/cluster,Values=svp-*' 'Name=group-name,Values=svp-*' $(vpc_filter); do
    q '.SecurityGroups[] | select(.GroupName | startswith("CloudFront-VPCOrigins-Service-SG") | not) | "\(.GroupId) \(.GroupName)"' \
      ec2 describe-security-groups --filters "$f" || return 1
  done
}

# The security group CloudFront makes in the VPC of a VPC origin, outside any state: it goes with the VPC origin, some
# time after it, so one left here is a kind of its own, deleted by hand only once no VPC origin is left.
vpc_origin_security_groups() {
  local f
  for f in $(vpc_filter); do
    q '.SecurityGroups[] | select(.GroupName | startswith("CloudFront-VPCOrigins-Service-SG")) | "\(.GroupId) \(.GroupName) \(.VpcId)"' \
      ec2 describe-security-groups --filters "$f" || return 1
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

# ACM certificates tagged Project=svp (an untagged one is never touched): the ALB's in the home region, the viewer
# certificates of CloudFront in us-east-1. list-certificates leaves out every key type but RSA 2048 unless told.
certificates() {
  local lines arn domain tags stack
  lines=$(q '.CertificateSummaryList[] | "\(.CertificateArn) \(.DomainName)"' acm list-certificates \
    --includes keyTypes=RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1) || return 1
  printing && lines='<each-certificate-above> <its-domain>'
  while read -r arn domain; do
    [ -n "$arn" ] || continue
    tags=$(aws_ acm list-tags-for-certificate --certificate-arn "$arn" --output json) || return 1
    printing && continue
    jq -e 'any(.Tags[]?; .Key == "Project" and .Value == "svp")' <<<"$tags" >/dev/null || continue
    stack=$(stack_tag <<<"$tags")
    if is_kept "$stack"; then
      keep "kept  ACM certificate $arn $domain (Stack=$stack)"
    else
      echo "$arn $domain${stack:+ Stack=$stack}"
    fi
  done <<<"$lines"
}

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

# MSK refuses to delete a configuration while a cluster uses it: the clusters are listed, and deleted, first.
msk_clusters() { q '.ClusterInfoList[] | select(.ClusterName | startswith("svp-")) | "\(.ClusterArn) \(.State)"' kafka list-clusters-v2; }
msk_configurations() { q '.Configurations[] | select(.Name | startswith("svp-")) | "\(.Arn) \(.State)"' kafka list-configurations; }

# ElastiCache: the replication group first, then what it used (its user group, then the users, the subnet and
# parameter groups), in the order AWS lets them go. ElastiCache's own user default and default.* groups are not svp-*.
replication_groups() {
  q '.ReplicationGroups[] | select(.ReplicationGroupId | startswith("svp-")) | "\(.ReplicationGroupId) \(.Status)"' \
    elasticache describe-replication-groups
}
cache_user_groups() { q '.UserGroups[] | select(.UserGroupId | startswith("svp-")) | "\(.UserGroupId) \(.Status)"' elasticache describe-user-groups; }
cache_users() { q '.Users[] | select(.UserId | startswith("svp-")) | "\(.UserId) \(.Status) \(.UserName)"' elasticache describe-users; }
cache_subnet_groups() {
  q '.CacheSubnetGroups[] | select(.CacheSubnetGroupName | startswith("svp-")) | .CacheSubnetGroupName' elasticache describe-cache-subnet-groups
}
cache_parameter_groups() {
  q '.CacheParameterGroups[] | select(.CacheParameterGroupName | startswith("svp-")) | "\(.CacheParameterGroupName) \(.CacheParameterGroupFamily)"' \
    elasticache describe-cache-parameter-groups
}

# The interruption queue of Karpenter (svp-<env>-karpenter) and any other queue svp-*.
queues() { q '.QueueUrls[]?' sqs list-queues --queue-name-prefix svp-; }

# The EventBridge rules that feed that queue (Karpenter<event>-<suffix>), each with the ids of its targets, which go
# before the rule.
event_rules() {
  local names n ids
  names=$(q '.Rules[].Name' events list-rules --name-prefix Karpenter) || return 1
  printing && names='<each-rule-above>'
  for n in $names; do
    ids=$(q '[.Targets[].Id] | join(" ")' events list-targets-by-rule --rule "$n") || return 1
    printing || echo "$n $ids"
  done
}

# Alarms of the lab (svp-<env>-<alarm>) and the target tracking alarms Application Auto Scaling makes for the storage of
# an MSK cluster svp-*, which deleting the cluster before its scaling policy leaves behind; an alarm tagged with a kept
# Stack (the DNSSEC alarms of aws/accounts/prd) goes to the kept list.
alarms() {
  local lines name arn tags stack
  lines=$(q '.MetricAlarms[] | select(.AlarmName | startswith("svp-") or (startswith("TargetTracking-") and contains(":cluster/svp-")))
    | "\(.AlarmName)\t\(.AlarmArn)"' cloudwatch describe-alarms) || return 1
  printing && lines=$(printf '%s\t%s' '<each-alarm-above>' '<its-ARN>')
  while IFS=$'\t' read -r name arn; do
    [ -n "$name" ] || continue
    tags=$(aws_ cloudwatch list-tags-for-resource --resource-arn "$arn" --output json) || return 1
    printing && continue
    stack=$(stack_tag <<<"$tags")
    if is_kept "$stack"; then keep "kept  alarm $name (Stack=$stack)"; else echo "$name"; fi
  done <<<"$lines"
}

# SNS topics of the lab (svp-*): the alarm topic of a root; one tagged with a kept Stack goes to the kept list.
sns_topics() {
  local arns arn tags stack
  arns=$(q '.Topics[].TopicArn | select(sub("^.*:"; "") | startswith("svp-"))' sns list-topics) || return 1
  printing && arns='<each-topic-above>'
  for arn in $arns; do
    tags=$(aws_ sns list-tags-for-resource --resource-arn "$arn" --output json) || return 1
    printing && continue
    stack=$(stack_tag <<<"$tags")
    if is_kept "$stack"; then keep "kept  SNS topic $arn (Stack=$stack)"; else echo "$arn"; fi
  done
}

# GuardDuty Malware Protection plans on a bucket of the lab (uploads of the media module): one left keeps scanning, and
# a plan of the same bucket cannot be made again. Deleting it also removes the EventBridge rule
# DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3* GuardDuty made for it, so that rule is never listed on its own.
malware_protection_plans() {
  local ids id
  ids=$(q '.MalwareProtectionPlans[]?.MalwareProtectionPlanId' guardduty list-malware-protection-plans) || return 1
  printing && ids='<each-plan-above>'
  for id in $ids; do
    # shellcheck disable=SC2016 # $p and $b are jq's, not the shell's
    q '. as $p | ($p.ProtectedResource.S3Bucket.BucketName // "") as $b
      | select(($b | startswith("svp-")) or ($p.Tags.Project // "") == "svp")
      | "\($p.Arn | sub("^.*/"; "")) \($b) \($p.Status // "?")"' \
      guardduty get-malware-protection-plan --malware-protection-plan-id "$id" || return 1
  done
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

# The plans of the account (CloudFront flat-rate and any other: the account holds only the lab, so a plan made by hand
# in the console is a leftover too), in us-east-1 whatever the region of the environment. A distribution with a plan
# cannot be deleted, so this kind is read before the distributions. A plan with a cancellation already scheduled (paid
# tiers; a Free plan is cancelled at once) is "kept", not counted. The answer is read whole: the CLI pages by itself.
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

# Distributions svp-<env>-<web|api|media> by their comment, or with an origin of the lab (a bucket svp-*): the origin
# of web and api is a VPC origin, whose domain is the ALB's.
distributions() {
  q '.DistributionList.Items[]? | select(((.Comment // "") | startswith("svp-")) or any(.Origins.Items[]?; .DomainName | startswith("svp-")))
    | "\(.Id) \(.Status) enabled=\(.Enabled) \(.DomainName) \(.Comment // "")"' cloudfront list-distributions
}
vpc_origins() { q '.VpcOriginList.Items[]? | select(.Name | startswith("svp-")) | "\(.Id) \(.Name) \(.Status)"' cloudfront list-vpc-origins; }
cloudfront_policies() {
  q '.OriginAccessControlList.Items[]? | select(.Name | startswith("svp-")) | "\(.Id) origin access control \(.Name)"' \
    cloudfront list-origin-access-controls || return 1
  q '.ResponseHeadersPolicyList.Items[]?.ResponseHeadersPolicy | select(.ResponseHeadersPolicyConfig.Name | startswith("svp-"))
    | "\(.Id) response headers policy \(.ResponseHeadersPolicyConfig.Name)"' cloudfront list-response-headers-policies --type custom
}
web_acls() {
  q_global '.WebACLs[] | select(.Name | startswith("svp-")) | "\(.Name) \(.Id)"' wafv2 list-web-acls --scope CLOUDFRONT
}

# Standard logs of CloudFront (us-east-1): each distribution's delivery source svp-<env>-<name> and its delivery, which
# goes first. The delivery destinations svp-cloudfront-<env> live in the log archive account: one here is left too.
log_deliveries() {
  q '.deliveries[]? | select(.deliverySourceName | startswith("svp-")) | "\(.id) \(.deliverySourceName) \(.deliveryDestinationArn // "")"' \
    logs describe-deliveries
}
log_delivery_sources() {
  q '.deliverySources[]? | select(.name | startswith("svp-")) | "\(.name) \(.service // "") \(.logType // "")"' logs describe-delivery-sources
}
log_delivery_destinations() {
  q '.deliveryDestinations[]? | select(.name | startswith("svp-")) | "\(.name) \(.deliveryDestinationType // "")"' \
    logs describe-delivery-destinations
}

# Log groups EKS or RDS make under the lab's names (untagged: they write them outside Terraform's state, and again
# after a destroy while the last logs arrive), the broker log group of MSK by name as well, RDS's Enhanced Monitoring
# group, and any tagged Project=svp (the groups the rds module makes); one with a kept Stack (the query log group of
# aws/accounts/prd) goes to the kept list.
log_groups() {
  local lines name stack
  q '.logGroups[].logGroupName | select(test("^/aws/eks/svp-|^/aws/rds/instance/svp-|^/aws/msk/svp-|^RDSOSMetrics$"))' logs describe-log-groups || return 1
  # shellcheck disable=SC2016 # $stack is jq's, not the shell's
  lines=$(q '.ResourceTagMappingList[] | ([.Tags[]? | select(.Key == "Stack") | .Value][0] // "") as $stack
    | "\(.ResourceARN | sub("^arn:aws:logs:[^:]*:[^:]*:log-group:"; "") | sub(":\\*$"; ""))\t\($stack)"' \
    resourcegroupstaggingapi get-resources --resource-type-filters logs:log-group --tag-filters Key=Project,Values=svp) || return 1
  while IFS=$'\t' read -r name stack; do
    [ -n "$name" ] || continue
    if is_kept "$stack"; then keep "kept  log group $name (Stack=$stack)"; else echo "$name"; fi
  done <<<"$lines"
}

# Secrets of the lab (MSK's SCRAM secrets included) and RDS's master secret for an instance svp-* (tag
# aws:rds:primaryDBInstanceArn); one scheduled for deletion shows its date: its name stays taken until then.
# One with a kept Stack (the pull-through cache credentials, named by ECR, not by us) goes to the kept list.
secrets() {
  local lines name stack
  # shellcheck disable=SC2016 # $stack is jq's, not the shell's
  lines=$(q '.SecretList[] | select((.Name | startswith("svp")) or (.Name | startswith("AmazonMSK_svp-")) or any(.Tags[]?; (.Key == "Project" and .Value == "svp")
      or (.Key == "aws:rds:primaryDBInstanceArn" and (.Value | test(":db:svp-")))))
    | ([.Tags[]? | select(.Key == "Stack") | .Value][0] // "") as $stack
    | "\(.Name)\(if .DeletedDate then " (scheduled for deletion since \(.DeletedDate))" else "" end)\t\($stack)"' \
    secretsmanager list-secrets --include-planned-deletion) || return 1
  while IFS=$'\t' read -r name stack; do
    [ -n "$name" ] || continue
    if is_kept "$stack"; then keep "kept  secret $name (Stack=$stack)"; else echo "$name"; fi
  done <<<"$lines"
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

# Aliases of the lab on a key in PendingDeletion: a destroy deletes them with the key, so one left here follows a key
# scheduled by hand after a lost state, and the next session's alias of that name fails with AlreadyExists.
kms_aliases() {
  local lines name id key
  lines=$(q '.Aliases[] | select(.AliasName | test("^alias/(svp|eks/svp-)")) | select(.TargetKeyId) | "\(.AliasName) \(.TargetKeyId)"' \
    kms list-aliases) || return 1
  printing && lines='<each-alias-above> <its-key>'
  while read -r name id; do
    [ -n "$name" ] || continue
    key=$(aws_ kms describe-key --key-id "$id" --output json) || return 1
    printing && continue
    [ "$(jq -r '.KeyMetadata.KeyState' <<<"$key")" != PendingDeletion ] || echo "$name on key $id pending deletion"
  done <<<"$lines"
}

# Records of the account's hosted zone but what the baseline keeps with the zone: NS, SOA and CAA at its apex, and the
# NS records below it, which delegate a child zone (delegated_subdomains). The session's records (aliases, ACM
# validation) are root env's, and go with its destroy.
records() {
  local ids id
  export SVP_SWEEP_ZONE=$zone
  # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
  ids=$(q '.HostedZones[] | select(.Name == ($ENV.SVP_SWEEP_ZONE + ".")) | .Id' route53 list-hosted-zones-by-name --dns-name "$zone.") ||
    return 1
  printing && ids='<id-of-the-zone>'
  for id in $ids; do
    keep "kept  hosted zone $zone ($id), NS, SOA and CAA at its apex, NS records below it"
    # shellcheck disable=SC2016 # $ENV is jq's, not the shell's
    q '($ENV.SVP_SWEEP_ZONE + ".") as $apex | .ResourceRecordSets[]
      | select((.Name == $apex and (.Type == "SOA" or .Type == "CAA")) | not)
      | select((.Type == "NS" and (.Name == $apex or (.Name | endswith("." + $apex)))) | not)
      | "\(.Name) \(.Type)"' route53 list-resource-record-sets --hosted-zone-id "$id" || return 1
  done
}

# The pull-through cache rules and the repositories ECR makes for them carry no tags: aws/accounts/<env> makes the
# rules, so both are kept in an account that keeps its Stack, and any other rule is left.
cache_stack=baseline
cache_prefixes=" ghcr docker-hub quay k8s ecr-public "
is_cache_prefix() { case $cache_prefixes in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

cache_rules() {
  local lines prefix upstream
  lines=$(q '.pullThroughCacheRules[]? | "\(.ecrRepositoryPrefix) \(.upstreamRegistryUrl)"' ecr describe-pull-through-cache-rules) ||
    return 1
  while read -r prefix upstream; do
    [ -n "$prefix" ] || continue
    if is_kept "$cache_stack" && is_cache_prefix "$prefix"; then
      keep "kept  ECR pull-through cache rule $prefix ($upstream)"
    else
      echo "$prefix $upstream"
    fi
  done <<<"$lines"
}

# ECR repositories of the lab: the release ones (svp-backend/*, svp-frontend/*, tagged) and those the cache made.
ecr_repositories() {
  local lines name arn tags stack
  lines=$(q '.repositories[] | select(.repositoryName | test("^(svp-[^/]+|ghcr|docker-hub|quay|k8s|ecr-public)/"))
    | "\(.repositoryName)\t\(.repositoryArn)"' ecr describe-repositories) || return 1
  printing && lines=$(printf '%s\t%s' '<each-repository-above>' '<its-ARN>')
  while IFS=$'\t' read -r name arn; do
    [ -n "$name" ] || continue
    if is_cache_prefix "${name%%/*}"; then
      if is_kept "$cache_stack"; then keep "kept  ECR repository $name (made by the pull-through cache)"; else echo "$name"; fi
      continue
    fi
    tags=$(aws_ ecr list-tags-for-resource --resource-arn "$arn" --output json) || return 1
    printing && continue
    stack=$(jq -r '[.tags[]? | select(.Key == "Stack") | .Value][0] // ""' <<<"$tags")
    if is_kept "$stack"; then keep "kept  ECR repository $name (Stack=$stack)"; else echo "$name${stack:+ Stack=$stack}"; fi
  done <<<"$lines"
}

# AMP workspaces svp-<env>, which aws/accounts/<env> keeps between sessions.
amp_workspaces() {
  local lines id alias stack
  lines=$(q '.workspaces[]? | select((.alias // "") | startswith("svp-")) | "\(.workspaceId)\t\(.alias)\t\(.tags.Stack // "")"' \
    amp list-workspaces) || return 1
  while IFS=$'\t' read -r id alias stack; do
    [ -n "$id" ] || continue
    if is_kept "$stack"; then keep "kept  AMP workspace $id $alias (Stack=$stack)"; else echo "$id $alias${stack:+ Stack=$stack}"; fi
  done <<<"$lines"
}

# The rule groups namespaces ACK makes in those workspaces each session, which pre-destroy.sh deletes: one left keeps
# its ruler evaluating, billed, until the next session.
amp_rule_groups() {
  local ids id
  ids=$(q '.workspaces[]? | select((.alias // "") | startswith("svp-")) | .workspaceId' amp list-workspaces) || return 1
  printing && ids='<each-workspace-above>'
  for id in $ids; do
    q '.ruleGroupsNamespaces[]? | "\(.name) \(.arn | split("/")[1])"' amp list-rule-groups-namespaces --workspace-id "$id" ||
      return 1
  done
}

# Amazon Managed Grafana workspaces svp-<env>, which aws/accounts/<env> keeps between sessions.
grafana_workspaces() {
  local lines id name stack
  lines=$(q '.workspaces[]? | select((.name // "") | startswith("svp-")) | "\(.id)\t\(.name)\t\(.tags.Stack // "")"' \
    grafana list-workspaces) || return 1
  while IFS=$'\t' read -r id name stack; do
    [ -n "$id" ] || continue
    if is_kept "$stack"; then keep "kept  Grafana workspace $id $name (Stack=$stack)"; else echo "$id $name${stack:+ Stack=$stack}"; fi
  done <<<"$lines"
}

# IAM OIDC providers tagged Project=svp (GitHub's for the roles of CI); an untagged one is never touched.
oidc_providers() {
  local arns arn tags stack
  arns=$(q '.OpenIDConnectProviderList[]?.Arn' iam list-open-id-connect-providers) || return 1
  printing && arns='<each-provider-above>'
  for arn in $arns; do
    tags=$(aws_ iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" --output json) || return 1
    printing && continue
    jq -e 'any(.Tags[]?; .Key == "Project" and .Value == "svp")' <<<"$tags" >/dev/null || continue
    stack=$(stack_tag <<<"$tags")
    if is_kept "$stack"; then keep "kept  IAM OIDC provider $arn (Stack=$stack)"; else echo "$arn${stack:+ Stack=$stack}"; fi
  done
}

# The roles GitHub Actions assumes to push to ECR (svp-ci-*).
ci_roles() {
  local names n tags stack
  names=$(q '.Roles[] | select(.RoleName | startswith("svp-ci-")) | .RoleName' iam list-roles) || return 1
  printing && names='<each-role-above>'
  for n in $names; do
    tags=$(aws_ iam list-role-tags --role-name "$n" --output json) || return 1
    printing && continue
    stack=$(stack_tag <<<"$tags")
    if is_kept "$stack"; then keep "kept  IAM role $n (Stack=$stack)"; else echo "$n${stack:+ Stack=$stack}"; fi
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
sweep_kind "EC2 launch templates" launch_templates "aws ec2 delete-launch-template --launch-template-id {}"
sweep_kind "IAM instance profiles of Karpenter" instance_profiles \
  "aws iam remove-role-from-instance-profile --instance-profile-name {} --role-name {rest} --region $region && AWS_PROFILE=$profile aws iam delete-instance-profile --instance-profile-name {}"
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
sweep_kind "VPC endpoints" vpc_endpoints "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids {}"
sweep_kind "network interfaces" interfaces "aws ec2 delete-network-interface --network-interface-id {}"
sweep_kind "security groups" security_groups "aws ec2 delete-security-group --group-id {}"
sweep_kind "security groups of CloudFront VPC origins" vpc_origin_security_groups \
  "$runbook (CloudFront deletes it after its VPC origin; once no VPC origin is left, delete-security-group)"
sweep_kind "ELBv2 load balancers" load_balancers "aws elbv2 delete-load-balancer --load-balancer-arn {}"
sweep_kind "ELBv2 target groups" target_groups "aws elbv2 delete-target-group --target-group-arn {}"
sweep_kind "ACM certificates" certificates "aws acm delete-certificate --certificate-arn {}"
sweep_kind "RDS instances" rds_instances \
  "aws rds delete-db-instance --db-instance-identifier {} --skip-final-snapshot --delete-automated-backups"
sweep_kind "RDS snapshots" rds_snapshots "aws rds delete-db-snapshot --db-snapshot-identifier {}"
sweep_kind "RDS automated backups" rds_backups "aws rds delete-db-instance-automated-backup --db-instance-automated-backups-arn {}"
sweep_kind "MSK clusters" msk_clusters "aws kafka delete-cluster --cluster-arn {}"
sweep_kind "MSK configurations" msk_configurations "aws kafka delete-configuration --arn {}"
sweep_kind "ElastiCache replication groups" replication_groups "aws elasticache delete-replication-group --replication-group-id {}"
sweep_kind "ElastiCache user groups" cache_user_groups "aws elasticache delete-user-group --user-group-id {}"
sweep_kind "ElastiCache users" cache_users "aws elasticache delete-user --user-id {}"
sweep_kind "ElastiCache subnet groups" cache_subnet_groups "aws elasticache delete-cache-subnet-group --cache-subnet-group-name {}"
sweep_kind "ElastiCache parameter groups" cache_parameter_groups \
  "aws elasticache delete-cache-parameter-group --cache-parameter-group-name {}"
sweep_kind "GuardDuty Malware Protection plans" malware_protection_plans \
  "aws guardduty delete-malware-protection-plan --malware-protection-plan-id {}"
sweep_kind "S3 buckets" buckets "$runbook (versioned: every version first)"
sweep_kind "CloudFront pricing plan subscriptions" subscriptions \
  "$runbook (cancel the plan first: cancel-subscription takes the eTag of get-subscription, both in us-east-1)"
sweep_kind "CloudFront distributions" distributions "$runbook (disable, wait, then delete)"
sweep_kind "CloudFront VPC origins" vpc_origins \
  "$runbook (after the distributions that use it: delete-vpc-origin takes the ETag of get-vpc-origin)"
sweep_kind "CloudFront origin access controls and response headers policies" cloudfront_policies "$runbook"
sweep_kind "WAF web ACLs of CloudFront" web_acls "$runbook (delete-web-acl takes the lock token of get-web-acl)"
global sweep_kind "ACM certificates in us-east-1" certificates "aws acm delete-certificate --certificate-arn {}"
global sweep_kind "CloudWatch Logs deliveries in us-east-1" log_deliveries "aws logs delete-delivery --id {}"
global sweep_kind "CloudWatch Logs delivery sources in us-east-1" log_delivery_sources "aws logs delete-delivery-source --name {}"
global sweep_kind "CloudWatch Logs delivery destinations in us-east-1" log_delivery_destinations \
  "aws logs delete-delivery-destination --name {}"
sweep_kind "SQS queues" queues "aws sqs delete-queue --queue-url {}"
sweep_kind "EventBridge rules of Karpenter" event_rules \
  "aws events remove-targets --rule {} --ids {rest} --region $region && AWS_PROFILE=$profile aws events delete-rule --name {}"
sweep_kind "CloudWatch alarms" alarms "aws cloudwatch delete-alarms --alarm-names {}"
sweep_kind "CloudWatch log groups" log_groups "aws logs delete-log-group --log-group-name {}"
sweep_kind "SNS topics" sns_topics "aws sns delete-topic --topic-arn {}"
sweep_kind "AMP rule groups namespaces" amp_rule_groups "aws amp delete-rule-groups-namespace --name {} --workspace-id {rest}"
sweep_kind "AMP workspaces" amp_workspaces "aws amp delete-workspace --workspace-id {}"
sweep_kind "Managed Grafana workspaces" grafana_workspaces "aws grafana delete-workspace --workspace-id {}"
sweep_kind "ECR repositories" ecr_repositories "aws ecr delete-repository --repository-name {} --force"
sweep_kind "ECR pull-through cache rules" cache_rules "aws ecr delete-pull-through-cache-rule --ecr-repository-prefix {}"
global sweep_kind "IAM OIDC providers" oidc_providers "aws iam delete-open-id-connect-provider --open-id-connect-provider-arn {}"
global sweep_kind "IAM roles of CI" ci_roles "$runbook (delete-role-policy for each inline policy, then delete-role)"
sweep_kind "Secrets Manager secrets (scheduled for deletion included)" secrets \
  "aws secretsmanager delete-secret --secret-id {} --force-delete-without-recovery"
sweep_kind "KMS keys" kms_keys "aws kms schedule-key-deletion --key-id {} --pending-window-in-days 7"
sweep_kind "KMS aliases on keys pending deletion" kms_aliases "aws kms delete-alias --alias-name {}"
global sweep_kind "CloudWatch alarms in us-east-1" alarms "aws cloudwatch delete-alarms --alarm-names {}"
global sweep_kind "CloudWatch log groups in us-east-1" log_groups "aws logs delete-log-group --log-group-name {}"
global sweep_kind "SNS topics in us-east-1" sns_topics "aws sns delete-topic --topic-arn {}"
global sweep_kind "KMS keys in us-east-1" kms_keys "aws kms schedule-key-deletion --key-id {} --pending-window-in-days 7"
global sweep_kind "KMS aliases on keys pending deletion in us-east-1" kms_aliases "aws kms delete-alias --alias-name {}"
[ -z "$zone" ] || sweep_kind "records of $zone" records "$runbook (change-resource-record-sets DELETE)"

printing && exit 0
while IFS= read -r line; do
  [ -z "$line" ] || printf '%s\n' "$line"
done <"$kept_file"
[ -z "$unread" ] || fail "could not read:$unread; the sweep is not clean until it reads every kind"
[ "$leftovers" -eq 0 ] ||
  fail "$leftovers leftover(s) in account $env_name above: delete each with the command under it, then run aws/scripts/sweep.sh $env_name again"
ok "nothing left in account $env_name but what it keeps (Stack=$kept_stacks) and keys pending deletion"
