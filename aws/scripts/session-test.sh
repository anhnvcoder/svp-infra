#!/usr/bin/env bash
# Self-test of the session scripts of this directory, with fake aws, kubectl, terraform, make, nc and dig on PATH (and
# git repositories made here as the clones of the code repository and of svp-gitops): no account, cluster or network is
# reached. Runs on the Mac (bash 3.2) and on Linux; needs git and jq. The fake aws and terraform answer as the account
# of their profile (anhnv-sso 000000000000, anhnv-stg 111111111111, anhnv-prd 222222222222).

# Covers --print of the whole session and each script of the directory: the account and DNS guards, the order rules of
# tf.sh and pre-destroy.sh, the secret handling and the edge's wait of bootstrap.sh, the ladder of measure.sh, the
# pinned digests of ecr-warm.sh and the leftovers of sweep.sh in both regions.

# Usage: aws/scripts/session-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
runbooks=$(cd "$src/../.." && pwd)/docs/runbooks
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
# learner's own files (<env>.auto.tfvars, a plan file, a session).
infra_root=$work/infra
here=$infra_root/aws/scripts
mkdir -p "$here"
# The hosted zone of each environment's account: prd holds the root zone of the lab, stg a child zone of it.
zones='prd aws.svp.example
stg stg.aws.svp.example'
zone_of() { awk -v e="$1" '$1 == e { print $2 }' <<<"$zones"; }
for e in stg prd; do
  mkdir -p "$infra_root/aws/envs/$e" "$infra_root/aws/gitops/$e" "$infra_root/aws/accounts/$e"
  printf 'zone_name = "%s"\n' "$(zone_of "$e")" >"$infra_root/aws/accounts/$e/$e.auto.tfvars"
  printf '%s\n' "hosted_zone_id = \"Z0TFVARS\"" "domain         = \"$(zone_of "$e")\"" >"$infra_root/aws/envs/$e/$e.auto.tfvars"
  printf 'bucket = "svp-tfstate-fake"\n' >"$infra_root/aws/backend-$e.hcl"
done
printf 'rds_deletion_protection = false\n' >"$infra_root/aws/envs/prd/teardown.tfvars"
cp "$src"/*.sh "$here"/
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
# Each fake logs its call to $FAKE_LOG. aws and terraform answer as the account of their profile, and log the profile
# to $FAKE_LOG.profiles; aws checks the region (us-east-1 for WAF of CloudFront, the Pricing Plan Manager, the log
# deliveries of CloudFront, IAM of CI; either for the kinds the sweep reads in both) and answers as that region.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
case ${AWS_PROFILE:-} in
  anhnv-sso) account=000000000000 zone= stack=bootstrap ;;
  anhnv-stg) account=111111111111 zone=stg.aws.svp.example stack=baseline ;;
  anhnv-prd) account=222222222222 zone=aws.svp.example stack=baseline ;;
  *) echo "fake aws: AWS_PROFILE is '${AWS_PROFILE:-}'" >&2; exit 97 ;;
esac
echo "$AWS_PROFILE" >>"$FAKE_LOG.profiles"
# FAKE_ACCOUNT: the profile signs in to another account (a profile pointing at the wrong account).
account=${FAKE_ACCOUNT:-$account}
envname=${AWS_PROFILE#anhnv-}
region= prev=
for a in "$@"; do [ "$prev" != --region ] || region=$a; prev=$a; done
case "$1 $2" in
  wafv2\ * | pricing-plan-manager\ * | "logs describe-deliver"* | "iam list-open-id-connect-provider"* | "iam list-role"*) want=us-east-1 ;;
  kms\ * | cloudwatch\ * | sns\ * | acm\ * | resourcegroupstaggingapi\ * | logs\ *) want="ap-southeast-1 us-east-1" ;;
  *) want=ap-southeast-1 ;;
esac
case " $want " in *" $region "*) ;; *) echo "fake aws: --region '$region', not $want" >&2; exit 97 ;; esac
us=
[ "$region" != us-east-1 ] || us=1
left=${FAKE_LEFTOVER:-}
# The management account has no hosted zone.
[ "$1" != route53 ] || [ -n "$zone" ] || { echo "fake aws: no hosted zone in account $account" >&2; exit 98; }
case "$1 $2" in
  "sts get-caller-identity") echo "{\"Account\":\"$account\",\"Arn\":\"arn:aws:sts::$account:assumed-role/AWSReservedSSO_SvpAdmin_0/learner\"}" ;;
  # FAKE_NO_CLUSTER: an account where the cluster was never made.
  "eks update-kubeconfig")
    [ -z "${FAKE_NO_CLUSTER:-}" ] || { echo "fake aws: ResourceNotFoundException: No cluster found." >&2; exit 254; }
    echo "Added new context" ;;
  "eks describe-cluster")
    printf '{"cluster":{"arn":"arn:aws:eks:ap-southeast-1:%s:cluster/%s","endpoint":"https://0123ABCD.gr7.ap-southeast-1.eks.amazonaws.com"}}\n' "$account" "$4" ;;
  "eks list-clusters") echo '{"clusters":[]}' ;;
  "secretsmanager get-secret-value") printf '{"username":"postgres","password":"%s"}\n' "$FAKE_PASSWORD" ;;
  "secretsmanager list-secrets")
    # The pull-through cache credentials of aws/accounts/<env> (names fixed by ECR), kept by their Stack.
    cache='{"Name":"ecr-pullthroughcache/ghcr","Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]},{"Name":"ecr-pullthroughcache/docker-hub","Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}'
    [ -n "$zone" ] || cache='{"Name":"other-project","Tags":[]}'
    if [ "$left" = secret ]; then
      echo "{\"SecretList\":[$cache,{\"Name\":\"svp/stg/web\",\"DeletedDate\":\"2026-10-30T10:00:00Z\",\"Tags\":[{\"Key\":\"Project\",\"Value\":\"svp\"}]}]}"
    elif [ "$left" = msk-secret ]; then
      # A SCRAM secret of MSK whose tags are gone: found by its name alone.
      echo '{"SecretList":[{"Name":"AmazonMSK_svp-stg-svp-admin","Tags":[]}]}'
    else
      echo "{\"SecretList\":[$cache,{\"Name\":\"other-project\",\"Tags\":[]}]}"
    fi ;;
  "route53 list-hosted-zones-by-name") echo "{\"HostedZones\":[{\"Id\":\"/hostedzone/Z0FAKE\",\"Name\":\"$zone.\"}]}" ;;
  "route53 list-resource-record-sets")
    {
      printf '{"Name":"%s.","Type":"NS"}\n{"Name":"%s.","Type":"SOA"}\n{"Name":"%s.","Type":"CAA"}\n' "$zone" "$zone" "$zone"
      # The zone of prd delegates the zone of stg.
      [ "$zone" != aws.svp.example ] || printf '{"Name":"stg.aws.svp.example.","Type":"NS"}\n'
      # FAKE_LEFTOVER=record: records of a root env a destroy left (alias, ACM validation), and a CAA below the apex.
      [ "$left" != record ] || printf '{"Name":"api.%s.","Type":"%s"}\n' "$zone" A "$zone" AAAA "$zone" CAA
      [ "$left" != record ] || printf '{"Name":"_0fake.api.%s.","Type":"CNAME"}\n' "$zone"
    } | jq -s '{ResourceRecordSets: .}' ;;
  # In us-east-1 of prd, what aws/accounts/prd keeps there (Stack=baseline): the KMS keys of DNSSEC and of the alarm
  # topic, the query log group of the zone.
  "resourcegroupstaggingapi get-resources")
    case "$us $zone $* " in
      "1 aws.svp.example "*" kms:key "*)
        for k in key-dnssec key-dns-alarms; do printf '{"ResourceARN":"arn:aws:kms:us-east-1:%s:key/%s","Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}\n' "$account" "$k"; done |
          jq -s '{ResourceTagMappingList: .}' ;;
      "1 aws.svp.example "*" logs:log-group "*)
        printf '{"ResourceARN":"arn:aws:logs:us-east-1:%s:log-group:/aws/route53/aws.svp.example:*","Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}\n' "$account" |
          jq -s '{ResourceTagMappingList: .}' ;;
      1\ *) echo '{"ResourceTagMappingList":[]}' ;;
      *" kms:key "*)
        for k in key-eks key-msk; do printf '{"ResourceARN":"arn:aws:kms:ap-southeast-1:%s:key/%s","Tags":[{"Key":"Project","Value":"svp"}]}\n' "$account" "$k"; done |
          jq -s '{ResourceTagMappingList: .}' ;;
      *" logs:log-group "*)
        # The log group of the rds module, kept by no Stack: a leftover once its root is destroyed.
        [ "$left" != log-group ] || printf '{"ResourceARN":"arn:aws:logs:ap-southeast-1:%s:log-group:/aws/rds/svp-stg/postgresql:*","Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}\n' "$account" |
          jq -s '{ResourceTagMappingList: .}' ;;
      *) echo '{"ResourceTagMappingList":[]}' ;;
    esac ;;
  # A destroy deletes the alias of a root's key; it is left with the key (FAKE_LEFTOVER=kms, msk-kms), or alone on a key
  # scheduled for deletion by hand after a lost state (msk-alias).
  "kms list-aliases")
    if [ -n "$us" ]; then
      [ "$zone" != aws.svp.example ] ||
        printf '{"AliasName":"alias/svp-dnssec","TargetKeyId":"key-dnssec"}\n{"AliasName":"alias/svp-prd-dns-alarms","TargetKeyId":"key-dns-alarms"}\n'
    else
      printf '{"AliasName":"alias/aws/ebs","TargetKeyId":"key-aws"}\n{"AliasName":"alias/svp-tfstate","TargetKeyId":"key-state"}\n'
      [ "$left" != kms ] || printf '{"AliasName":"alias/svp-prd-eks-secrets","TargetKeyId":"key-eks"}\n'
      # The EBS key of aws/baseline, in the accounts that run EC2 alone.
      [ -z "$zone" ] || printf '{"AliasName":"alias/svp-ebs","TargetKeyId":"key-ebs"}\n'
      case $left in msk-kms | msk-alias) printf '{"AliasName":"alias/svp-prd-msk-scram","TargetKeyId":"key-msk"}\n' ;; esac
    fi | jq -s '{Aliases: .}' ;;
  "kms describe-key")
    # key-eks: the key of the cluster's Secrets, key-msk: the key of MSK (SCRAM secrets and broker volumes), each
    # PendingDeletion after a destroy (FAKE_LEFTOVER=kms, msk-kms: still Enabled).
    if [ "$4" = key-eks ] && [ "$left" != kms ]; then
      echo '{"KeyMetadata":{"KeyId":"key-eks","KeyState":"PendingDeletion","KeyManager":"CUSTOMER","DeletionDate":"2026-11-12T00:00:00Z"}}'
    elif [ "$4" = key-msk ] && [ "$left" != msk-kms ]; then
      echo '{"KeyMetadata":{"KeyId":"key-msk","KeyState":"PendingDeletion","KeyManager":"CUSTOMER","DeletionDate":"2026-11-15T00:00:00Z"}}'
    else
      echo "{\"KeyMetadata\":{\"KeyId\":\"$4\",\"KeyState\":\"Enabled\",\"KeyManager\":\"CUSTOMER\"}}"
    fi ;;
  "kms list-resource-tags")
    if [ "$4" = key-state ]; then echo "{\"Tags\":[{\"TagKey\":\"Project\",\"TagValue\":\"svp\"},{\"TagKey\":\"Stack\",\"TagValue\":\"$stack\"}]}"
    elif [ "$4" = key-ebs ]; then echo '{"Tags":[{"TagKey":"Project","TagValue":"svp"},{"TagKey":"Stack","TagValue":"security-baseline"}]}'
    elif [ "$4" = key-dnssec ] || [ "$4" = key-dns-alarms ]; then echo '{"Tags":[{"TagKey":"Project","TagValue":"svp"},{"TagKey":"Stack","TagValue":"baseline"}]}'
    else echo '{"Tags":[{"TagKey":"Project","TagValue":"svp"},{"TagKey":"Stack","TagValue":"prd"}]}'; fi ;;
  "ec2 describe-volumes")
    if [ "$left" = volume ] && [[ "$*" == *tag:Project* ]]; then
      echo '{"Volumes":[{"VolumeId":"vol-0fake","State":"available","Size":10,"Tags":[{"Key":"kubernetes.io/created-for/pvc/name","Value":"storage-loki-0"}]}]}'
    else
      echo '{"Volumes":[]}'
    fi ;;
  # Instances of Karpenter (filter on tag karpenter.sh/nodepool): those of $FAKE_STATE/karpenter-instances ("id state
  # type nodepool"), which deleting the NodePools ends, and one left for the sweep (FAKE_LEFTOVER=karpenter).
  "ec2 describe-instances")
    {
      if [[ "$*" == *karpenter.sh/nodepool* ]]; then
        [ "$left" != karpenter ] || echo "i-0karp running m7g.large default"
        [ ! -s "$FAKE_STATE/karpenter-instances" ] || cat "$FAKE_STATE/karpenter-instances"
      fi
    } | while read -r id st ty pool; do
      jq -n --arg i "$id" --arg s "$st" --arg t "$ty" --arg p "$pool" \
        '{InstanceId: $i, State: {Name: $s}, InstanceType: $t, Tags: [{Key: "karpenter.sh/nodepool", Value: $p}]}'
    done | jq -s '{Reservations: [{Instances: .}]}' ;;
  # FAKE_LEFTOVER=karpenter: what Karpenter makes outside Terraform's state, left after a destroy.
  "ec2 describe-launch-templates")
    if [ "$left" = karpenter ] && [[ "$*" == *karpenter.k8s.aws/cluster* ]]; then
      echo '{"LaunchTemplates":[{"LaunchTemplateId":"lt-0karp","LaunchTemplateName":"karpenter.k8s.aws/1234567890"}]}'
    else
      echo '{"LaunchTemplates":[]}'
    fi ;;
  "iam list-instance-profiles")
    {
      echo '{"InstanceProfileName":"other-profile","Path":"/","Roles":[{"RoleName":"other-role"}]}'
      [ "$left" != karpenter ] ||
        echo '{"InstanceProfileName":"svp-stg_1234567890","Path":"/karpenter/ap-southeast-1/svp-stg/uid/","Roles":[{"RoleName":"svp-stg-karpenter-node"}]}'
    } | jq -s '{InstanceProfiles: .}' ;;
  "sqs list-queues")
    if [ "$left" = karpenter ]; then echo "{\"QueueUrls\":[\"https://sqs.ap-southeast-1.amazonaws.com/$account/svp-stg-karpenter\"]}"; else echo '{}'; fi ;;
  # The rule GuardDuty manages for the Malware Protection plan of uploads is there whatever is left: it is GuardDuty's.
  "events list-rules")
    prefix=$(sed -n 's/.* --name-prefix \([^ ]*\) .*/\1/p' <<<" $* ")
    {
      echo '{"Name":"DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3ManagedRule-fake"}'
      [ "$left" != karpenter ] || echo '{"Name":"KarpenterSpotInterrupt-2026"}'
    } | jq -s --arg p "$prefix" '{Rules: map(select(.Name | startswith($p)))}' ;;
  "events list-targets-by-rule") echo '{"Targets":[{"Id":"KarpenterInterruptionQueueTarget"}]}' ;;
  # FAKE_LEFTOVER=alarm: an alarm of the lab and the target tracking alarm of MSK's storage, beside another one's. In
  # us-east-1 of prd, the DNSSEC alarms aws/accounts/prd keeps; FAKE_LEFTOVER=us-east-1, an alarm of root env there.
  "cloudwatch describe-alarms")
    {
      echo '{"AlarmName":"other-alarm"}'
      if [ -n "$us" ]; then
        [ "$zone" != aws.svp.example ] || printf '{"AlarmName":"svp-prd-dnssec-%s"}\n' internal-failure ksk-action-needed
        [ "$left" != us-east-1 ] || echo '{"AlarmName":"svp-prd-edge-5xx"}'
      elif [ "$left" = alarm ]; then
        echo '{"AlarmName":"svp-stg-rds-storage-low"}'
        echo "{\"AlarmName\":\"TargetTracking-arn:aws:kafka:ap-southeast-1:$account:cluster/svp-stg/c-fake-AlarmHigh-0a1b\"}"
      fi
    } | jq -s --arg p "arn:aws:cloudwatch:$region:$account:alarm:" '{MetricAlarms: map(. + {AlarmArn: ($p + .AlarmName)})}' ;;
  # The DNSSEC alarms carry Stack=baseline, the alarms of root env their env's Stack, Application Auto Scaling's none.
  "cloudwatch list-tags-for-resource")
    case $4 in
      *:alarm:svp-prd-dnssec-*) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}' ;;
      *:alarm:svp-*) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}' ;;
      *) echo '{"Tags":[]}' ;;
    esac ;;
  # Another project's topic always; in us-east-1 of prd, the topic of the DNSSEC alarms aws/accounts/prd keeps;
  # FAKE_LEFTOVER=sns, the alarm topic of root env stg; FAKE_LEFTOVER=us-east-1, one of root env prd in us-east-1.
  "sns list-topics")
    {
      echo other-topic
      if [ -n "$us" ]; then
        [ "$zone" != aws.svp.example ] || echo svp-prd-dns-alarms
        [ "$left" != us-east-1 ] || echo svp-prd-edge-alarms
      else
        [ "$left" != sns ] || echo svp-stg-alarms
      fi
    } | jq -R --arg p "arn:aws:sns:$region:$account:" '{TopicArn: ($p + .)}' | jq -s '{Topics: .}' ;;
  "sns list-tags-for-resource")
    case $4 in
      *:svp-prd-dns-alarms) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}' ;;
      *) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}' ;;
    esac ;;
  # Another project's certificate always (no tag Project=svp); FAKE_LEFTOVER=cert: the ALB's in the home region, the
  # viewer certificate of web in us-east-1, both ECDSA P-256, which list-certificates leaves out unless asked for.
  "acm list-certificates")
    {
      echo '{"CertificateArn":"arn:aws:acm:'"$region"':'"$account"':certificate/other","DomainName":"other.example","KeyAlgorithm":"RSA-2048"}'
      case " $* " in *EC_prime256v1*) [ "$left" != cert ] ||
        echo '{"CertificateArn":"arn:aws:acm:'"$region"':'"$account"':certificate/svp-fake","DomainName":"stg.aws.svp.example","KeyAlgorithm":"EC-prime256v1"}' ;; esac
    } | jq -s '{CertificateSummaryList: .}' ;;
  "acm list-tags-for-certificate")
    case $4 in
      *:certificate/other) echo '{"Tags":[{"Key":"Name","Value":"other"}]}' ;;
      *) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}' ;;
    esac ;;
  # FAKE_LEFTOVER=delivery: the standard logs of distribution svp-stg-web, beside another one's.
  "logs describe-deliveries")
    {
      echo '{"id":"other-delivery","deliverySourceName":"other-source"}'
      [ "$left" != delivery ] ||
        echo '{"id":"dlv-fake","deliverySourceName":"svp-stg-web","deliveryDestinationArn":"arn:aws:logs:us-east-1:333333333333:delivery-destination:svp-cloudfront-stg"}'
    } | jq -s '{deliveries: .}' ;;
  "logs describe-delivery-sources")
    {
      echo '{"name":"other-source","service":"cloudfront","logType":"ACCESS_LOGS"}'
      [ "$left" != delivery ] || echo '{"name":"svp-stg-web","service":"cloudfront","logType":"ACCESS_LOGS"}'
    } | jq -s '{deliverySources: .}' ;;
  "logs describe-delivery-destinations")
    if [ "$left" = delivery ]; then echo '{"deliveryDestinations":[{"name":"svp-cloudfront-stg","deliveryDestinationType":"S3"}]}'
    else echo '{"deliveryDestinations":[]}'; fi ;;
  "ec2 describe-snapshots") echo '{"Snapshots":[]}' ;;
  "ec2 describe-vpcs")
    if [ "$left" = vpc-origin-sg ]; then echo '{"Vpcs":[{"VpcId":"vpc-0fake","CidrBlock":"10.20.0.0/16"}]}'; else echo '{"Vpcs":[]}'; fi ;;
  "ec2 describe-nat-gateways") echo '{"NatGateways":[]}' ;;
  "ec2 describe-addresses") echo '{"Addresses":[]}' ;;
  # FAKE_LEFTOVER=endpoint: the interface endpoint guardduty-data, and a deleted one AWS still lists for a while;
  # interface-endpoint: an interface endpoint of root env found by its name alone, its tags gone.
  "ec2 describe-vpc-endpoints")
    if [ "$left" = interface-endpoint ] && [[ "$*" == *tag:Name,Values=svp-* ]]; then
      echo '{"VpcEndpoints":[{"VpcEndpointId":"vpce-0sts","VpcEndpointType":"Interface","ServiceName":"com.amazonaws.ap-southeast-1.sts","State":"available","Tags":[{"Key":"Name","Value":"svp-stg-sts"}]}]}'
    elif [ "$left" = endpoint ] && [[ "$*" == *tag:Project* ]]; then
      echo '{"VpcEndpoints":[{"VpcEndpointId":"vpce-0fake","VpcEndpointType":"Interface","ServiceName":"com.amazonaws.ap-southeast-1.guardduty-data","State":"available"},{"VpcEndpointId":"vpce-0gone","VpcEndpointType":"Gateway","ServiceName":"com.amazonaws.ap-southeast-1.s3","State":"deleted"}]}'
    else
      echo '{"VpcEndpoints":[]}'
    fi ;;
  # A plan of another project's bucket always; FAKE_LEFTOVER=malware: the plan of the env's uploads bucket.
  "guardduty list-malware-protection-plans")
    {
      echo '{"MalwareProtectionPlanId":"plan-other"}'
      [ "$left" != malware ] || echo '{"MalwareProtectionPlanId":"plan-svp"}'
    } | jq -s '{MalwareProtectionPlans: .}' ;;
  "guardduty get-malware-protection-plan")
    case $4 in
      plan-svp) b=svp-stg-uploads-$account-ap-southeast-1 t='{"Project":"svp","Stack":"stg"}' ;;
      *) b=someone-else t='{}' ;;
    esac
    jq -n --arg a "arn:aws:guardduty:ap-southeast-1:$account:malware-protection-plan/$4" --arg b "$b" --argjson t "$t" \
      '{Arn: $a, ProtectedResource: {S3Bucket: {BucketName: $b}}, Status: "ACTIVE", Tags: $t}' ;;
  "ec2 describe-network-interfaces") echo '{"NetworkInterfaces":[]}' ;;
  # FAKE_LEFTOVER=vpc-origin-sg: the VPC of the lab is left with the group CloudFront made for a VPC origin in it.
  "ec2 describe-security-groups")
    if [ "$left" = interface-endpoint ] && [[ "$*" == *group-name,Values=svp-* ]]; then
      echo '{"SecurityGroups":[{"GroupId":"sg-0ep","GroupName":"svp-stg-endpoints","VpcId":"vpc-0fake"}]}'
    elif [ "$left" = vpc-origin-sg ] && [[ "$*" == *vpc-id* ]]; then
      echo '{"SecurityGroups":[{"GroupId":"sg-0cf","GroupName":"CloudFront-VPCOrigins-Service-SG-0fake","VpcId":"vpc-0fake"}]}'
    else
      echo '{"SecurityGroups":[]}'
    fi ;;
  # FAKE_LEFTOVER=edge: the ALB and the target group of the edge module (tag Project=svp of root env), beside another
  # one's; FAKE_TG_STATES: the states of the targets of the edge's target group, one call after another ("initial
  # healthy" by default: healthy at the second read).
  "elbv2 describe-load-balancers")
    if [ "$left" = edge ]; then
      echo "{\"LoadBalancers\":[{\"LoadBalancerArn\":\"arn:aws:elasticloadbalancing:ap-southeast-1:$account:loadbalancer/app/svp-stg-edge/0a1b\"},{\"LoadBalancerArn\":\"arn:aws:elasticloadbalancing:ap-southeast-1:$account:loadbalancer/app/other/9z\"}]}"
    else echo '{"LoadBalancers":[]}'; fi ;;
  "elbv2 describe-target-groups")
    if [ "$left" = edge ]; then echo "{\"TargetGroups\":[{\"TargetGroupArn\":\"arn:aws:elasticloadbalancing:ap-southeast-1:$account:targetgroup/svp-stg-envoy/2c3d\"}]}"
    else echo '{"TargetGroups":[]}'; fi ;;
  "elbv2 describe-tags")
    shift 3
    for arn in "$@"; do
      case $arn in
        --*) break ;;
        */svp-*) jq -n --arg a "$arn" '{ResourceArn: $a, Tags: [{Key: "Project", Value: "svp"}, {Key: "Stack", Value: "stg"}]}' ;;
        *) jq -n --arg a "$arn" '{ResourceArn: $a, Tags: []}' ;;
      esac
    done | jq -s '{TagDescriptions: .}' ;;
  "elbv2 describe-target-health")
    c=$(( $(cat "$FAKE_STATE/tg-calls" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$FAKE_STATE/tg-calls"
    set -- ${FAKE_TG_STATES:-initial healthy}
    [ "$c" -le $# ] || c=$#
    eval "st=\${$c}"
    jq -n --arg s "$st" '{TargetHealthDescriptions: [{Target: {Id: "10.0.4.20", Port: 10443}, TargetHealth: {State: $s}}]}' ;;
  "rds describe-db-instances") echo '{"DBInstances":[]}' ;;
  "rds describe-db-snapshots")
    if [ "$left" = snapshot ]; then
      echo '{"DBSnapshots":[{"DBSnapshotIdentifier":"svp-prd-final-0a1b2c3d","DBInstanceIdentifier":"svp-prd","SnapshotType":"manual","Status":"available"}]}'
    else
      echo '{"DBSnapshots":[]}'
    fi ;;
  "rds describe-db-instance-automated-backups")
    if [ "$left" = backup ]; then
      echo '{"DBInstanceAutomatedBackups":[{"DBInstanceIdentifier":"svp-prd","DBInstanceAutomatedBackupsArn":"arn:aws:rds:ap-southeast-1:222222222222:auto-backup:ab-fake","Status":"retained"}]}'
    else
      echo '{"DBInstanceAutomatedBackups":[]}'
    fi ;;
  "s3api list-buckets") echo "{\"Buckets\":[{\"Name\":\"svp-tfstate-$account-ap-southeast-1\"},{\"Name\":\"someone-else\"}]}" ;;
  "s3api get-bucket-tagging") echo "{\"TagSet\":[{\"Key\":\"Project\",\"Value\":\"svp\"},{\"Key\":\"Stack\",\"Value\":\"$stack\"}]}" ;;
  # FAKE_LEFTOVER=distribution: distribution svp-stg-web, whose origin is the VPC origin to the internal ALB, beside
  # another one's.
  "cloudfront list-distributions")
    {
      echo '{"Id":"EOTHER","Status":"Deployed","Enabled":true,"DomainName":"d0other.cloudfront.net","Comment":"other","Origins":{"Items":[{"DomainName":"other.s3.amazonaws.com"}]}}'
      [ "$left" != distribution ] ||
        echo '{"Id":"EWEB","Status":"Deployed","Enabled":false,"DomainName":"d0web.cloudfront.net","Comment":"svp-stg-web","Origins":{"Items":[{"DomainName":"internal-svp-stg-edge-1.ap-southeast-1.elb.amazonaws.com"}]}}'
    } | jq -s '{DistributionList: {Items: .}}' ;;
  "cloudfront list-vpc-origins")
    if [ "$left" = vpc-origin ]; then echo '{"VpcOriginList":{"Items":[{"Id":"vo_0fake","Name":"svp-stg-edge","Status":"Deployed"},{"Id":"vo_other","Name":"other","Status":"Deployed"}]}}'
    else echo '{"VpcOriginList":{"Items":[]}}'; fi ;;
  "cloudfront list-origin-access-controls") echo '{"OriginAccessControlList":{"Items":[]}}' ;;
  "cloudfront list-response-headers-policies") echo '{"ResponseHeadersPolicyList":{"Items":[]}}' ;;
  "wafv2 list-web-acls")
    if [ "$left" = waf ]; then echo '{"WebACLs":[{"Name":"svp-prd-web","Id":"waf-web"},{"Name":"svp-prd-api","Id":"waf-api"},{"Name":"svp-prd-media","Id":"waf-fake"}]}'
    else echo '{"WebACLs":[]}'; fi ;;
  # FAKE_LEFTOVER=subscription: a Free plan left; cancellation: a paid plan whose cancellation is scheduled;
  # subscription-error: the API answers with an error.
  "pricing-plan-manager list-subscriptions")
    case $left in
      subscription-error) echo "fake aws: AccessDeniedException on list-subscriptions" >&2; exit 254 ;;
      subscription) echo "{\"subscriptionSummaries\":[{\"arn\":\"arn:aws:pricingplanmanager::$account:subscription/sub-fake\",\"planFamily\":\"CloudFront\",\"planTier\":\"FREE\",\"status\":\"ACTIVE\",\"resourceArns\":[\"arn:aws:cloudfront::$account:distribution/EFAKE\",\"arn:aws:wafv2:us-east-1:$account:global/webacl/svp-prd-media/waf-fake\"],\"scheduledChange\":null,\"eTag\":\"e1\"}]}" ;;
      cancellation) echo "{\"subscriptionSummaries\":[{\"arn\":\"arn:aws:pricingplanmanager::$account:subscription/sub-paid\",\"planFamily\":\"CloudFront\",\"planTier\":\"PRO\",\"status\":\"ACTIVE\",\"resourceArns\":[],\"scheduledChange\":{\"changeType\":\"CANCELLATION\",\"effectiveDate\":\"2026-12-01T00:00:00Z\"},\"eTag\":\"e2\"}]}" ;;
      *) echo '{"subscriptionSummaries":[]}' ;;
    esac ;;
  "logs describe-log-groups")
    if [ "$left" = msk-log ] && [ -z "$us" ]; then echo '{"logGroups":[{"logGroupName":"/aws/msk/svp-prd"}]}'; else echo '{"logGroups":[]}'; fi ;;
  # FAKE_LEFTOVER=msk: a cluster and its configuration; elasticache: a replication group and what it used.
  "kafka list-clusters-v2")
    if [ "$left" = msk ]; then
      echo "{\"ClusterInfoList\":[{\"ClusterName\":\"svp-stg\",\"ClusterArn\":\"arn:aws:kafka:ap-southeast-1:$account:cluster/svp-stg/c-fake\",\"State\":\"DELETING\"},{\"ClusterName\":\"other\",\"ClusterArn\":\"arn:other\",\"State\":\"ACTIVE\"}]}"
    else
      echo '{"ClusterInfoList":[]}'
    fi ;;
  "kafka list-configurations")
    if [ "$left" = msk ]; then
      echo "{\"Configurations\":[{\"Name\":\"svp-stg-4-1-x-kraft\",\"Arn\":\"arn:aws:kafka:ap-southeast-1:$account:configuration/svp-stg-4-1-x-kraft/cfg-fake\",\"State\":\"ACTIVE\"}]}"
    else
      echo '{"Configurations":[]}'
    fi ;;
  "elasticache describe-replication-groups")
    if [ "$left" = elasticache ]; then echo '{"ReplicationGroups":[{"ReplicationGroupId":"svp-stg","Status":"available"}]}'
    else echo '{"ReplicationGroups":[]}'; fi ;;
  "elasticache describe-user-groups")
    if [ "$left" = elasticache ]; then echo '{"UserGroups":[{"UserGroupId":"svp-stg","Status":"active"}]}'
    else echo '{"UserGroups":[]}'; fi ;;
  "elasticache describe-users")
    # ElastiCache's own user default is always there and never a leftover.
    if [ "$left" = elasticache ]; then echo '{"Users":[{"UserId":"default","UserName":"default","Status":"active"},{"UserId":"svp-stg-gateway","UserName":"svp-gateway","Status":"active"}]}'
    else echo '{"Users":[{"UserId":"default","UserName":"default","Status":"active"}]}'; fi ;;
  "elasticache describe-cache-subnet-groups")
    if [ "$left" = elasticache ]; then echo '{"CacheSubnetGroups":[{"CacheSubnetGroupName":"svp-stg"},{"CacheSubnetGroupName":"default"}]}'
    else echo '{"CacheSubnetGroups":[{"CacheSubnetGroupName":"default"}]}'; fi ;;
  "elasticache describe-cache-parameter-groups")
    if [ "$left" = elasticache ]; then echo '{"CacheParameterGroups":[{"CacheParameterGroupName":"svp-stg-valkey9","CacheParameterGroupFamily":"valkey9"},{"CacheParameterGroupName":"default.valkey9","CacheParameterGroupFamily":"valkey9"}]}'
    else echo '{"CacheParameterGroups":[{"CacheParameterGroupName":"default.valkey9","CacheParameterGroupFamily":"valkey9"}]}'; fi ;;
  # Amazon Managed Grafana: service account svp-grafana-operator (FAKE_NO_GRAFANA_SA: none) with two older tokens; a
  # new token's key is $FAKE_GRAFANA_TOKEN.
  "grafana list-workspace-service-accounts")
    {
      echo '{"id":"9","name":"other"}'
      [ -n "${FAKE_NO_GRAFANA_SA:-}" ] || echo '{"id":"4","name":"svp-grafana-operator","grafanaRole":"ADMIN"}'
    } | jq -s '{serviceAccounts: .}' ;;
  "grafana list-workspace-service-account-tokens") echo '{"serviceAccountTokens":[{"id":"11","name":"old-1"},{"id":"12","name":"old-2"}]}' ;;
  "grafana delete-workspace-service-account-token") echo '{}' ;;
  "grafana create-workspace-service-account-token")
    jq -n --arg k "$FAKE_GRAFANA_TOKEN" '{serviceAccountId: "4", serviceAccountToken: {id: "13", key: $k, name: "new"}}' ;;
  # Logs whether the value read from --secret-string file://<path> is the token's map, and whether that path was a
  # regular file, never the value.
  "secretsmanager put-secret-value")
    f= prev=
    for a in "$@"; do [ "$prev" != --secret-string ] || f=${a#file://}; prev=$a; done
    if [ -f "$f" ]; then kind=file; else kind=pipe; fi
    v=$(cat "$f")
    if [ "$v" = "$(jq -cn --arg k "$FAKE_GRAFANA_TOKEN" '{SVP_GRAFANA_OPERATOR_TOKEN: $k}')" ]; then r=match; else r=other; fi
    echo "put-secret-value value=$r from=$kind" >>"$FAKE_LOG"
    echo v1 ;;
  # ECR: $FAKE_STATE/ecr-tags ("repository tag digest") is what the cache holds for a tag once pulled through it,
  # $FAKE_STATE/ecr-digests ("repository digest") the digests it holds besides.
  "ecr batch-get-image")
    repo= tag= prev=
    for a in "$@"; do case $prev in --repository-name) repo=$a ;; --image-ids) tag=${a#imageTag=} ;; esac; prev=$a; done
    d=$(awk -v r="$repo" -v t="$tag" '$1 == r && $2 == t { print $3 }' "$FAKE_STATE/ecr-tags")
    if [ -n "$d" ]; then
      jq -n --arg a "$account" --arg r "$repo" --arg t "$tag" --arg d "$d" '{images: [{registryId: $a, repositoryName: $r, imageId: {imageDigest: $d, imageTag: $t}}], failures: []}'
    else
      jq -n --arg a "$account" --arg t "$tag" '{images: [], failures: [{imageId: {imageTag: $t}, failureCode: "ImageNotFound", failureReason: ("Requested image not found in registry " + $a)}]}'
    fi ;;
  "ecr describe-images")
    repo= dg= prev=
    for a in "$@"; do case $prev in --repository-name) repo=$a ;; --image-ids) dg=${a#imageDigest=} ;; esac; prev=$a; done
    if awk '{ print $1, $3 }' "$FAKE_STATE/ecr-tags" | cat - "$FAKE_STATE/ecr-digests" | grep -qx "$repo $dg"; then
      echo '{"imageDetails":[{}]}'
    else
      echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageDigest:'$dg'} does not exist within the repository with name '$repo' in the registry with id '$account'" >&2
      exit 254
    fi ;;
  # What aws/accounts/<env> keeps (Stack=baseline): the five cache rules, a release repository and one the cache made,
  # AMP and Grafana workspaces, GitHub's OIDC provider and roles of CI; another project's repository, provider and role
  # always. FAKE_LEFTOVER=cache: a cache rule and its repository (left in the management account), ecr: a release
  # repository of another Stack, amp-rules: the rule groups namespaces of ACK, oidc: an OIDC provider of root env.
  "ecr describe-pull-through-cache-rules")
    {
      [ "$stack" != baseline ] || for p in ghcr docker-hub quay k8s ecr-public; do echo "$p"; done
      [ "$left" != cache ] || echo k8s
    } | jq -R '{ecrRepositoryPrefix: ., upstreamRegistryUrl: "upstream.example"}' | jq -s '{pullThroughCacheRules: .}' ;;
  "ecr describe-repositories")
    {
      echo other-project/app
      [ "$stack" != baseline ] || printf '%s\n' svp-backend/gateway docker-hub/library/alpine
      [ "$left" != cache ] || echo k8s/pause
      [ "$left" != ecr ] || echo svp-backend/old
    } | jq -R --arg p "arn:aws:ecr:$region:$account:repository/" '{repositoryName: ., repositoryArn: ($p + .)}' | jq -s '{repositories: .}' ;;
  "ecr list-tags-for-resource")
    case $4 in
      */svp-backend/old) echo '{"tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}' ;;
      */svp-*) echo "{\"tags\":[{\"Key\":\"Project\",\"Value\":\"svp\"},{\"Key\":\"Stack\",\"Value\":\"$stack\"}]}" ;;
      *) echo "fake aws: tags of $4 read" >&2; exit 98 ;;
    esac ;;
  "amp list-workspaces")
    if [ "$stack" = baseline ]; then
      jq -n --arg e "svp-$envname" '{workspaces: [{workspaceId: "ws-0fake", alias: $e, tags: {Project: "svp", Stack: "baseline"}}, {workspaceId: "ws-other", alias: "other"}]}'
    else
      echo '{"workspaces":[]}'
    fi ;;
  "amp list-rule-groups-namespaces")
    if [ "$left" = amp-rules ]; then
      for n in svp-alerts slo-generated; do
        jq -n --arg a "arn:aws:aps:$region:$account:rulegroupsnamespace/$4/$n" --arg n "$n" '{name: $n, arn: $a}'
      done | jq -s '{ruleGroupsNamespaces: .}'
    else
      echo '{"ruleGroupsNamespaces":[]}'
    fi ;;
  "grafana list-workspaces")
    if [ "$stack" = baseline ]; then
      jq -n --arg e "svp-$envname" '{workspaces: [{id: "g-0fake", name: $e, tags: {Project: "svp", Stack: "baseline"}}]}'
    else
      echo '{"workspaces":[]}'
    fi ;;
  "iam list-open-id-connect-providers")
    {
      echo "arn:aws:iam::$account:oidc-provider/other.example"
      [ "$stack" != baseline ] || echo "arn:aws:iam::$account:oidc-provider/token.actions.githubusercontent.com"
      [ "$left" != oidc ] || echo "arn:aws:iam::$account:oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/0FAKE"
    } | jq -R '{Arn: .}' | jq -s '{OpenIDConnectProviderList: .}' ;;
  "iam list-open-id-connect-provider-tags")
    case $4 in
      *token.actions*) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}' ;;
      *oidc.eks*) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"stg"}]}' ;;
      *) echo '{"Tags":[]}' ;;
    esac ;;
  "iam list-roles")
    {
      echo other-role
      [ "$stack" != baseline ] || printf '%s\n' svp-ci-ecr-release-backend svp-ci-ecr-rescan-backend
    } | jq -R '{RoleName: .}' | jq -s '{Roles: .}' ;;
  "iam list-role-tags")
    case $4 in
      svp-ci-*) echo '{"Tags":[{"Key":"Project","Value":"svp"},{"Key":"Stack","Value":"baseline"}]}' ;;
      *) echo "fake aws: tags of role $4 read" >&2; exit 98 ;;
    esac ;;
  *) echo "fake aws: unexpected $1 $2" >&2; exit 98 ;;
esac
EOF

# terraform: init with a backend, as the real one, refuses a .terraform that names another backend unless told to
# -reconfigure (or -migrate-state), and records the backend it was given; plan writes the file of -out=.
cat >"$bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"$FAKE_LOG"
case ${AWS_PROFILE:-} in anhnv-sso | anhnv-stg | anhnv-prd) ;; *) echo "fake terraform: AWS_PROFILE is '${AWS_PROFILE:-}'" >&2; exit 97 ;; esac
echo "$AWS_PROFILE" >>"$FAKE_LOG.profiles"
echo "account=${TF_VAR_account_id:-} chart=${TF_VAR_svp_cluster_chart:-} chat=${TF_VAR_telegram_chat_id-unset}" >>"$FAKE_LOG.tfenv"
echo "log_archive=${TF_VAR_log_archive_account_id-unset}" >>"$FAKE_LOG.tfenv"
dir= out=
for a in "$@"; do case $a in -chdir=*) dir=${a#-chdir=} ;; -out=*) out=${a#-out=} ;; esac; done
env=${dir##*/}
args="$*"
case "${args#-chdir=* }" in
  init\ *)
    backend=$(printf '%s\n' "$@" | sed -n 's/^-backend-config=//p' | tr '\n' ' ')
    if [ -f "$dir/.terraform/terraform.tfstate" ] && [ "$(cat "$dir/.terraform/terraform.tfstate")" != "$backend" ]; then
      case " $* " in
        *" -reconfigure "* | *" -migrate-state "*) ;;
        *) echo "fake terraform: Backend configuration changed; run init with -reconfigure or -migrate-state" >&2; exit 1 ;;
      esac
    fi
    mkdir -p "$dir/.terraform" && printf '%s' "$backend" >"$dir/.terraform/terraform.tfstate" ;;
  "output -json name_servers")
    echo '["ns-1.awsdns-01.org","ns-2.awsdns-02.co.uk","ns-3.awsdns-03.com","ns-4.awsdns-04.net"]' ;;
  "output -json cluster_values")
    domain=$(sed -n 's/^domain *= *"\(.*\)"$/\1/p' "$dir/$env.auto.tfvars")
    # FAKE_TF_OLD_VALUES: the values of a root before the edge, without the target group of Envoy.
    if [ -n "${FAKE_TF_OLD_VALUES:-}" ]; then
      echo "{\"name\":\"svp-$env\",\"domain\":\"$domain\",\"hostedZoneId\":\"Z0FAKE\"}"
    else
      echo "{\"name\":\"svp-$env\",\"domain\":\"$domain\",\"edgeTargetGroupArn\":\"arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:targetgroup/svp-$env-envoy/2c3d\",\"edgeCidrs\":[\"10.20.240.0/27\"],\"grafanaUrl\":\"https://g-0fake.grafana-workspace.ap-southeast-1.amazonaws.com\"}"
    fi ;;
  "output -raw rds_master_user_secret_arn") printf 'arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:rds!db-fake' ;;
  "show -no-color "*.destroy.tfplan) printf '%s\n' 'Terraform will perform the following actions:' '  # aws_vpc.this will be destroyed' \
    'Plan: 0 to add, 0 to change, 3 to destroy.' ;;
  "show -no-color "*.teardown.tfplan) printf '%s\n' 'Terraform will perform the following actions:' \
    '  # module.rds.aws_db_instance.this will be updated in-place' 'Plan: 0 to add, 2 to change, 0 to destroy.' ;;
  "show -no-color "*.tfplan) printf '%s\n' 'Terraform will perform the following actions:' '  # aws_vpc.this will be created' \
    'Plan: 1 to add, 0 to change, 0 to destroy.' ;;
  plan\ *) [ -z "$out" ] || : >"$dir/$out" ;;
  # FAKE_TF_STATE: eks, a whole apply: cluster (and a data source of it), DB instance, edge ALB (with listener and
  # target group), buckets (a read of one, a resource of a type that starts like it); partial, an apply that failed
  # before the cluster and DB instance, with the buckets made; fail, no readable state; else, none of them.
  "state list")
    case ${FAKE_TF_STATE:-} in
      eks) printf '%s\n' 'module.eks.module.eks.data.aws_eks_cluster.this[0]' 'module.eks.module.eks.aws_eks_cluster.this[0]' \
        'module.network.module.vpc.aws_vpc.this[0]' 'module.rds.aws_db_instance.this' 'module.edge.aws_lb.this' \
        'module.edge.aws_lb_listener.https' 'module.edge.aws_lb_target_group.envoy' 'module.media.aws_s3_bucket.this["media"]' \
        'module.media.aws_s3_bucket.this["uploads"]' 'module.media.aws_s3_bucket.logs[0]' 'module.media.data.aws_s3_bucket.read' \
        'module.media.aws_s3_bucket_versioning.this["media"]' ;;
      partial) printf '%s\n' 'module.network.module.vpc.aws_vpc.this[0]' 'module.media.aws_s3_bucket.this["media"]' \
        'module.media.aws_s3_bucket.this["uploads"]' 'module.media.aws_s3_bucket_versioning.this["media"]' ;;
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

# nc: the check of the tunnel; FAKE_TUNNEL=closed, nothing listens.
cat >"$bin/nc" <<'EOF'
#!/usr/bin/env bash
echo "nc $*" >>"$FAKE_LOG"
[ "${FAKE_TUNNEL:-open}" = open ]
EOF

cat >"$bin/make" <<'EOF'
#!/usr/bin/env bash
# Logs whether the password reached make's environment, never the value.
if [ "${SVP_RDS_MASTER_PASSWORD:-}" = "$FAKE_PASSWORD" ]; then pw=match; elif [ -n "${SVP_RDS_MASTER_PASSWORD:-}" ]; then pw=other; else pw=none; fi
# kv: the names of the Kafka and Valkey password variables in make's environment (Terraform writes those passwords).
kv=$(env | grep -oE '^SVP_(KAFKA|VALKEY)_[A-Z_]*_PASSWORD=' | sort | tr -d '=' | tr '\n' ',' || true)
echo "make $* password=$pw profile=${AWS_PROFILE:-} kv=${kv:-none}" >>"$FAKE_LOG"
echo "ok    entries written (fake make)"
# FAKE_MAKE_LEAK: a target that prints the password, which bootstrap.sh must catch in its log.
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

# kubectl: a cluster in files of $FAKE_STATE (apps: "wave name", appset, root, svp-apps, lb, pvcs: "namespace name",
# nodes); with FAKE_NO_ARGOCD, a cluster where root gitops never ran (no CRD of Argo CD, Gateway API or LBC); with
# FAKE_GATEWAY_CRD_DOWN, the read of the Gateway API CRD (step 2 of pre-destroy.sh) fails; FAKE_ROOT_NEVER, svp-root
# never gets Synced and Healthy; FAKE_NO_KARPENTER, no CRD of Karpenter; FAKE_KARPENTER_STUCK, deleting the NodePools
# ends no NodeClaim (nodeclaims: "name node") and no instance.
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
[ "${1:-}" != config ] || exit 0
case "${1:-} ${2:-}" in "--context svp-stg" | "--context svp-prd") ;; *) echo "fake kubectl: not --context svp-stg|svp-prd: $*" >&2; exit 97 ;; esac
shift 2
s=$FAKE_STATE
items() { jq -s '{items: .}'; }
case "$*" in
  "get crd applications.argoproj.io --ignore-not-found -o name" | "get crd applicationsets.argoproj.io --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo "customresourcedefinition.apiextensions.k8s.io/$2" ;;
  "get crd gateways.gateway.networking.k8s.io --ignore-not-found -o name")
    [ -z "${FAKE_GATEWAY_CRD_DOWN:-}" ] || { echo "fake kubectl: connection refused" >&2; exit 1; }
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io ;;
  "-n argocd get application svp-root --ignore-not-found -o name") [ ! -e "$s/root" ] || echo application.argoproj.io/svp-root ;;
  "-n argocd get application svp-apps --ignore-not-found -o name") [ ! -e "$s/svp-apps" ] || echo application.argoproj.io/svp-apps ;;
  "-n argocd patch application "*) ;;
  # The ApplicationSet owns svp-root: deleting it deletes svp-root, which has no finalizer.
  "-n argocd delete applicationset svp-bootstrap "*) rm -f "$s/appset" "$s/root" ;;
  "-n argocd delete application svp-root "*) rm -f "$s/root" ;;
  "-n argocd delete application svp-apps "*) rm -f "$s/svp-apps" ;;
  "-n argocd get applications -o json")
    while read -r w n; do [ -z "$n" ] || jq -n --arg w "$w" --arg n "$n" \
      '{metadata: {name: $n, annotations: {"argocd.argoproj.io/sync-wave": $w}}}'; done <"$s/apps" | items ;;
  "-n argocd delete application "*" --wait=false")
    name=$5; grep -v " $name\$" "$s/apps" >"$s/apps.new" || true; mv "$s/apps.new" "$s/apps"
    [ "$name" != svp-cluster ] || rm -f "$s/tgb" ;;
  "-n argocd get application "*" --ignore-not-found -o name") ! grep -q " $5\$" "$s/apps" || echo "application.argoproj.io/$5" ;;
  "-n argocd get applications.argoproj.io "*" --ignore-not-found -o json")
    # svp-observability turns Healthy at the second read; svp-root is Synced and Healthy unless FAKE_ROOT_NEVER.
    c=$(( $(cat "$s/app-calls-$5" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$s/app-calls-$5"
    case $5 in
      svp-observability) if [ "$c" -ge 2 ]; then h=Healthy; else h=Progressing; fi; sy=Synced ;;
      svp-root) if [ -n "${FAKE_ROOT_NEVER:-}" ]; then sy=OutOfSync h=Progressing; else sy=Synced h=Healthy; fi ;;
      *) exit 0 ;;
    esac
    jq -n --arg s "$sy" --arg h "$h" '{status: {sync: {status: $s}, health: {status: $h}}}' ;;
  "-n svp-edge delete gateway svp "*) rm -f "$s/lb" ;;
  "get services -A -o json")
    if [ -e "$s/lb" ]; then echo '{"items":[{"spec":{"type":"LoadBalancer"}}]}'; else echo '{"items":[{"spec":{"type":"ClusterIP"}}]}'; fi ;;
  "get crd nodepools.karpenter.sh --ignore-not-found -o name" | "get crd ec2nodeclasses.karpenter.k8s.aws --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}${FAKE_NO_KARPENTER:-}" ] || echo "customresourcedefinition.apiextensions.k8s.io/$3" ;;
  "delete nodepools.karpenter.sh --all --wait=false")
    [ -n "${FAKE_KARPENTER_STUCK:-}" ] || { : >"$s/nodeclaims"; : >"$s/karpenter-instances"; } ;;
  "delete ec2nodeclasses.karpenter.k8s.aws --all --wait=false") ;;
  "get nodeclaims.karpenter.sh -o json")
    while read -r n node; do [ -z "$n" ] || jq -n --arg n "$n" --arg node "$node" '{metadata: {name: $n}, status: {nodeName: $node}}'; done \
      <"$s/nodeclaims" | items ;;
  "get crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found -o name")
    [ -n "${FAKE_NO_ARGOCD:-}" ] || echo customresourcedefinition.apiextensions.k8s.io/targetgroupbindings.elbv2.k8s.aws ;;
  # TargetGroupBinding svp-envoy ($s/tgb) is svp-cluster's: deleting the Gateway leaves it. With FAKE_TGB_STUCK, LBC
  # never lets it go, and kubectl's wait times out.
  "-n envoy-gateway-system delete targetgroupbindings.elbv2.k8s.aws svp-envoy --ignore-not-found --wait=true --timeout="*)
    [ -z "${FAKE_TGB_STUCK:-}" ] || { echo "error: timed out waiting for the condition on targetgroupbindings/svp-envoy" >&2; exit 1; }
    rm -f "$s/tgb" ;;
  "get targetgroupbindings.elbv2.k8s.aws -A -o json") if [ -e "$s/tgb" ]; then echo '{"items":[{}]}'; else echo '{"items":[]}'; fi ;;
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
  # ACK's resources of AMP ($s/ack-crs: "kind namespace name workspace"; the file alone means the CRDs are there),
  # deleted by its controller while $s/ack-up is there, else held by their finalizer until it is cleared.
  "get crd rulegroupsnamespaces.prometheusservice.services.k8s.aws --ignore-not-found -o name")
    [ ! -e "$s/ack-crs" ] || echo customresourcedefinition.apiextensions.k8s.io/rulegroupsnamespaces.prometheusservice.services.k8s.aws ;;
  "get rulegroupsnamespaces.prometheusservice.services.k8s.aws,alertmanagerdefinitions.prometheusservice.services.k8s.aws -A -o json")
    while read -r k ns n ws; do [ -z "$n" ] || jq -n --arg k "$k" --arg ns "$ns" --arg n "$n" --arg ws "$ws" \
      '{kind: $k, metadata: {namespace: $ns, name: $n}, spec: ({workspaceID: $ws} + (if $k == "RuleGroupsNamespace" then {name: $n} else {} end))}'
    done <"$s/ack-crs" | items ;;
  "get pods -A -o json")
    if [ -e "$s/ack-up" ]; then
      echo '{"items":[{"spec":{"serviceAccountName":"ack-prometheusservice-controller"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    else
      echo '{"items":[{"spec":{"serviceAccountName":"other"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi ;;
  "delete rulegroupsnamespaces.prometheusservice.services.k8s.aws,alertmanagerdefinitions.prometheusservice.services.k8s.aws -A --all --wait=false")
    [ ! -e "$s/ack-up" ] || : >"$s/ack-crs" ;;
  "-n "*" patch "*".prometheusservice.services.k8s.aws "*' --type merge -p {"metadata":{"finalizers":null}}')
    case $4 in rulegroupsnamespaces.*) k=RuleGroupsNamespace ;; *) k=AlertManagerDefinition ;; esac
    grep -v "^$k $2 $5 " "$s/ack-crs" >"$s/ack-crs.new" || true; mv "$s/ack-crs.new" "$s/ack-crs" ;;
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

# The clones: the code repository with chart svp-cluster, a fake run.sh of the k6 Job and a .env (untracked, as
# make env leaves it), and svp-gitops whose envs/<env>/charts.yaml name a commit of it; each with an origin.
git_() { git -c user.name=test -c user.email=test@svp.example -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
make_clone() {
  local dir=$1
  git_ init -q --bare "$dir.origin.git"
  git_ init -q "$dir"
}
push_clone() {
  local dir=$1
  git_ -C "$dir" add -A
  git_ -C "$dir" commit -q -m init
  git_ -C "$dir" remote add origin "$dir.origin.git"
  git_ -C "$dir" push -q origin main
  git_ -C "$dir" fetch -q origin
}
make_clone "$work/backend"
mkdir -p "$work/backend/deploy/k6/cloud" "$work/backend/deploy/helm/svp-cluster/templates"
printf 'apiVersion: v2\nname: svp-cluster\nversion: 0.1.0\n' >"$work/backend/deploy/helm/svp-cluster/Chart.yaml"
printf '.env\n.k6/\n' >"$work/backend/.gitignore"
cat >"$work/backend/deploy/k6/cloud/run.sh" <<'EOF'
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
chmod +x "$work/backend/deploy/k6/cloud/run.sh"
push_clone "$work/backend"
printf 'SVP_ALERT_TELEGRAM_CHAT_ID=-1001234\n' >"$work/backend/.env"
chart_rev=$(git -C "$work/backend" rev-parse HEAD)
make_clone "$work/gitops"
for e in stg prd; do
  mkdir -p "$work/gitops/envs/$e"
  printf '# The commit of the code repository.\nrevision: %s\npodSecurityVersion: v1.36\n' "$chart_rev" >"$work/gitops/envs/$e/charts.yaml"
done
push_clone "$work/gitops"

grafana_token=glsa_fakeOperatorToken_0123456789abcdef
export PATH="$bin:$PATH" FAKE_LOG=$log FAKE_STATE=$state FAKE_PASSWORD=$password FAKE_GRAFANA_TOKEN=$grafana_token
export SVP_BACKEND_DIR=$work/backend SVP_GITOPS_DIR=$work/gitops SVP_SESSION_POLL=0
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000 SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222
export SVP_AWS_LOG_ACCOUNT_ID=333333333333
unset SVP_SESSION_DIR

# clear_log: an empty log of calls, profiles and Terraform variables.
clear_log() { : >"$log" && : >"$log.profiles" && : >"$log.tfenv"; }
# new_session: a fresh session directory under .session/ of the copy.
new_session() {
  SVP_SESSION_DIR=$infra_root/.session/test-$$-$RANDOM
  export SVP_SESSION_DIR
  mkdir -p "$SVP_SESSION_DIR"
  clear_log
}
# profiles_are PROFILE: every aws and terraform call since the log was cleared used PROFILE, and there was one.
profiles_are() { [ "$(LC_ALL=C sort -u "$log.profiles")" = "$1" ]; }

# has_mark EVENT: the session's timeline holds EVENT.
has_mark() { awk -F '\t' -v e="$1" '$3 == e { found = 1 } END { exit !found }' "$SVP_SESSION_DIR/timeline.tsv"; }
no_mark() { ! has_mark "$1"; }
add_mark() { printf '%s\t%s\t%s\n' 2026-11-05T00:00:00Z "$(date +%s)" "$1" >>"$SVP_SESSION_DIR/timeline.tsv"; }

# index FILE PATTERN: the number of the first line of FILE matching PATTERN (grep -E), 0 when none.
index() { grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1 || true; }
before() {
  local a b
  a=$(index "$1" "$2")
  b=$(index "$1" "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# --- the scripts themselves -------------------------------------------------------------------------------------
# The runbooks run each script by its path (aws/scripts/<script> ...), never through bash, so each must be executable
# as git records it (lib.sh, sourced, too).
for f in "$src"/*.sh; do
  expect "$(basename "$f") is executable" test -x "$f"
done

# --- --print ----------------------------------------------------------------------------------------------------
for e in stg prd; do
  clear_log
  out=$work/print-$e.out
  bash "$here/session.sh" --print "$e" >"$out" 2>&1 || bad "session.sh --print $e exits 0"
  expect "--print $e calls no aws, kubectl, terraform, make, nc, dig" test ! -s "$log"
  sed -n 's/^### step [0-9]*: aws\/scripts\///p' "$out" >"$work/order.print"
  sed -n 's/^| [0-9]* | `aws\/scripts\/\([^`]*\)`.*/\1/p' "$runbooks/session-$e.md" >"$work/order.runbook"
  expect "--print $e: the steps are the table of session-$e.md, in order" diff "$work/order.runbook" "$work/order.print"
  expect "--print $e: twenty steps" test "$(grep -c . "$work/order.runbook")" = 20
  sed -n '/^### step 20:/q;p' "$out" >"$work/print-env.out"
  expect "--print $e: every aws and terraform command of steps 1 to 19 names profile anhnv-$e, every aws command a region" \
    sh -c '[ -z "$(grep -E "^\+ ([^ ]+ )*(aws|terraform) " "$1" | grep -vE "^\+ ([^ ]+ )?AWS_PROFILE=anhnv-$2 (aws .*--region (ap-southeast-1|us-east-1)|terraform )")" ]' _ "$work/print-env.out" "$e"
  expect "--print $e: step 20 is sweep.sh mgmt, with profile anhnv-sso alone" \
    sh -c 'sed -n "/^### step 20:/,\$p" "$1" >"$1.20" && grep -q "^### step 20: aws/scripts/sweep.sh mgmt$" "$1.20" &&
      [ -z "$(grep -E "^\+ .* aws " "$1.20" | grep -vE "^\+ AWS_PROFILE=anhnv-sso aws .*--region (ap-southeast-1|us-east-1)")" ]' _ "$out"
  expect "--print $e: init of both roots with the account's backend, each its own key, -reconfigure" \
    sh -c 'grep -q "aws/envs/$2 init -input=false -reconfigure -backend-config=../../backend-$2.hcl -backend-config=key=aws/$2/terraform.tfstate$" "$1" &&
      grep -q "aws/gitops/$2 init -input=false -reconfigure -backend-config=../../backend-$2.hcl -backend-config=key=aws/gitops/$2/terraform.tfstate$" "$1"' _ "$out" "$e"
  expect "--print $e: root env applied, then the secrets, then root gitops" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      b "$1" "aws/envs/$2 apply -input=false $2.tfplan" "make .* eks-secrets CONTEXT=svp-$2" &&
      b "$1" "make .* eks-secrets CONTEXT=svp-$2" "aws/gitops/$2 apply -input=false $2.tfplan" &&
      b "$1" "aws/gitops/$2 apply -input=false $2.tfplan" "make .* eks-glitchtip-init CONTEXT=svp-$2"' _ "$out" "$e"
  expect "--print $e: ApplicationSet svp-bootstrap deleted before any child Application" \
    before "$out" 'delete applicationset svp-bootstrap' "delete application '<each workload"
  expect "--print $e: every PVC deleted before the platform Applications and before terraform plan -destroy" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      b "$1" "delete pvc --all" "delete application .<each platform" && b "$1" "delete pvc --all" "terraform .* plan -destroy"' _ "$out"
  expect "--print $e: root gitops destroyed before root env" \
    before "$out" "aws/gitops/$e apply -input=false $e.destroy.tfplan" "aws/envs/$e plan -destroy"
  expect "--print $e: no terraform destroy, only the apply of saved plans" test -z "$(grep -E '^\+ .*terraform -chdir=[^ ]* destroy' "$out")"
  expect "--print $e: NodePools deleted after the PVCs, EC2NodeClasses after them, both before the platform Applications" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      b "$1" "delete pvc --all" "delete nodepools.karpenter.sh --all" &&
      b "$1" "delete nodepools.karpenter.sh --all" "delete ec2nodeclasses.karpenter.k8s.aws --all" &&
      b "$1" "delete ec2nodeclasses.karpenter.k8s.aws --all" "delete application .<each platform"' _ "$out"
  expect "--print $e: waits up to 900 s for the NodeClaims and the instances of Karpenter, before the platform Applications" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      grep -q "up to 900 s, until no NodeClaim is left" "$1" &&
      b "$1" "up to 900 s, until no EC2 instance Karpenter made for svp-$2 is left" "delete application .<each platform" &&
      grep -q "ec2 describe-instances --filters Name=tag:kubernetes.io/cluster/svp-$2,Values=owned Name=tag-key,Values=karpenter.sh/nodepool " "$1"' _ "$out" "$e"
done
# The tunnel's local port of each environment, as the scripts take it (env_table of lib.sh), is the one of its roots.
for e in stg prd; do
  port=$(awk -v e="$e" '$1 == e { print $6 }' <<<"$(sed -n "/^env_table='/,/'$/p" "$src/lib.sh" | sed "s/^env_table='//; s/'$//")")
  expect "$e: tunnel port $port of lib.sh is api_tunnel_port of aws/envs/$e and api_server_url of aws/gitops/$e" \
    sh -c 'grep -qE "^api_tunnel_port +=  *$2$" "$1/aws/envs/$3/$3.tfvars" && grep -qE "^api_server_url += \"https://127\.0\.0\.1:$2\"$" "$1/aws/gitops/$3/$3.tfvars"' \
    _ "$(cd "$src/../.." && pwd)" "$port" "$e"
done
expect "--print prd: the tunnel checked before the first kubectl to the API" before "$work/print-prd.out" '^\+ nc -z -w 3 127.0.0.1 6443' 'kubectl --context svp-prd'
expect "--print prd: the tunnel checked before the plan of root gitops" before "$work/print-prd.out" '^\+ nc -z' 'aws/gitops/prd plan '
expect "--print prd: the kubeconfig points at the tunnel" grep -q "^+ kubectl config set-cluster .* --server=https://127.0.0.1:6443 '--tls-server-name=" "$work/print-prd.out"
expect "--print prd: teardown plan with both var files, targeting the DB instance, ALB and buckets of the state, applied, before the destroy plan with both" \
  sh -c 'before() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    before "$1" "aws/envs/prd state list$" "aws/envs/prd plan -input=false -var-file=prd.tfvars -var-file=teardown.tfvars" &&
    grep -qF "aws/envs/prd plan -input=false -var-file=prd.tfvars -var-file=teardown.tfvars '"'"'-target=<each aws_db_instance and aws_lb and aws_s3_bucket of the state>'"'"' -out=prd.teardown.tfplan" "$1" &&
    grep -q "aws/envs/prd apply -input=false prd.teardown.tfplan$" "$1" &&
    grep -q "aws/envs/prd plan -destroy -input=false -var-file=prd.tfvars -var-file=teardown.tfvars -out=prd.destroy.tfplan$" "$1"' _ "$work/print-prd.out"
for e in stg prd; do
  expect "--print $e: the target health of the edge read after svp-root, before the smoke" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      b "$1" "applications.argoproj.io svp-root" "AWS_PROFILE=anhnv-$2 aws elbv2 describe-target-health --target-group-arn .<edgeTargetGroupArn of cluster-values.json>. --output json --region ap-southeast-1" &&
      b "$1" "elbv2 describe-target-health" "eks-smoke CONTEXT=svp-$2"' _ "$work/print-$e.out" "$e"
done
expect "--print prd: no k6 level, the smoke alone" sh -c '! grep -q "eks-rl-reset" "$1" && grep -q "eks-smoke CONTEXT=svp-prd" "$1"' _ "$work/print-prd.out"
expect "--print stg: the tunnel on 6444 checked before the first kubectl to the API, the kubeconfig points at it" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "^\+ nc -z -w 3 127.0.0.1 6444" "kubectl --context svp-stg" && b "$1" "^\+ nc -z" "aws/gitops/stg plan " &&
    grep -q "^+ kubectl config set-cluster .* --server=https://127.0.0.1:6444 .--tls-server-name=" "$1" && ! grep -q "127.0.0.1:6443" "$1"' _ "$work/print-stg.out"
expect "--print stg: no teardown file" \
  sh -c '! grep -E "^\+ " "$1" | grep -q "teardown" && grep -q "aws/envs/stg plan -destroy -input=false -var-file=stg.tfvars -out=stg.destroy.tfplan$" "$1"' _ "$work/print-stg.out"
expect "--print stg: an eks-rl-reset before each of the four k6 levels" test "$(grep -c 'make .* eks-rl-reset CONTEXT=svp-stg' "$work/print-stg.out")" = 4

# --- check-account.sh -------------------------------------------------------------------------------------------
for e in mgmt stg prd; do
  new_session
  case $e in mgmt) p=anhnv-sso a=000000000000 ;; stg) p=anhnv-stg a=111111111111 ;; prd) p=anhnv-prd a=222222222222 ;; esac
  expect "check-account.sh $e passes on its account" bash "$here/check-account.sh" "$e" >"$work/out" 2>&1
  expect "check-account.sh $e uses profile $p alone and prints its account and ARN" \
    sh -c '[ "$(sort -u "$1.profiles")" = "$2" ] && grep -q "^ok    account $3 of $4, arn:aws:sts::$3:" "$5"' _ "$log" "$p" "$a" "$e" "$work/out"
  expect "check-account.sh $e starts the timeline" has_mark session-start
  for o in 000000000000 111111111111 222222222222; do
    [ "$o" != "$a" ] || continue
    expect "check-account.sh $e refuses the account $o of another environment" \
      sh -c '! FAKE_ACCOUNT=$3 bash "$1/check-account.sh" "$2" >"$4" 2>&1 && grep -q "is account .$3. .*not SVP_AWS_.*_ACCOUNT_ID $5 of $2" "$4"' \
      _ "$here" "$e" "$o" "$work/out" "$a"
  done
done
expect "check-account.sh stg refuses when its variable is not exported, and names it" \
  sh -c '! env -u SVP_AWS_STG_ACCOUNT_ID bash "$1/check-account.sh" stg >"$2" 2>&1 && grep -q "set SVP_AWS_STG_ACCOUNT_ID" "$2"' _ "$here" "$work/out"
# The single variable of one account, before the accounts of the organization: never read, so set alone it is refused.
expect "check-account.sh prd ignores the old single account variable, and names SVP_AWS_PRD_ACCOUNT_ID" \
  sh -c '! env -u SVP_AWS_PRD_ACCOUNT_ID "SVP_AWS_""ACCOUNT_ID=222222222222" bash "$1/check-account.sh" prd >"$2" 2>&1 && grep -q "set SVP_AWS_PRD_ACCOUNT_ID" "$2"' _ "$here" "$work/out"
expect "check-account.sh refuses an environment it does not know" sh -c '! bash "$1/check-account.sh" dev >/dev/null 2>&1' _ "$here"

# --- check-dns.sh -----------------------------------------------------------------------------------------------
clear_log
expect "check-dns.sh stg passes when both resolvers answer the zone's name servers" bash "$here/check-dns.sh" stg >/dev/null
expect "check-dns.sh stg reads name_servers of aws/accounts/stg with anhnv-stg" \
  sh -c 'grep -q "^terraform -chdir=.*/aws/accounts/stg output -json name_servers$" "$1" && [ "$(sort -u "$1.profiles")" = anhnv-stg ]' _ "$log"
expect "check-dns.sh stg asks two public resolvers for stg.aws.svp.example" \
  test "$(grep -cE '^dig NS stg.aws.svp.example .*@(1.1.1.1|8.8.8.8)$' "$log")" -ge 2
clear_log
expect "check-dns.sh prd asks two public resolvers for its zone aws.svp.example" \
  sh -c 'bash "$1/check-dns.sh" prd >/dev/null && [ "$(grep -cE "^dig NS aws.svp.example .*@(1.1.1.1|8.8.8.8)$" "$2")" -ge 2 ]' _ "$here" "$log"
expect "check-dns.sh stops on other name servers, naming both places of a delegation" \
  sh -c '! FAKE_DIG=other bash "$1/check-dns.sh" prd >"$2" 2>&1 && grep -q "^FAIL  resolver 1.1.1.1 returns NS .* for aws.svp.example, not the hosted zone.s" "$2" &&
    grep -q "delegated_subdomains of aws/accounts/prd, of the root zone the NS records aws at the parent.s DNS" "$2"' _ "$here" "$work/out"
expect "check-dns.sh stops on no answer, naming both places of a delegation" \
  sh -c '! FAKE_DIG=empty bash "$1/check-dns.sh" stg >"$2" 2>&1 && grep -q "^FAIL  resolver 1.1.1.1 returns no NS for stg.aws.svp.example: .*delegated_subdomains of aws/accounts/prd" "$2"' _ "$here" "$work/out"
mv "$infra_root/aws/accounts/stg/stg.auto.tfvars" "$work/zone.aside"
clear_log
expect "check-dns.sh without aws/accounts/stg/stg.auto.tfvars stops before any command, naming the file" \
  sh -c '! bash "$1/check-dns.sh" stg >"$2" 2>&1 && grep -q "^FAIL  no .*/aws/accounts/stg/stg.auto.tfvars" "$2" && [ ! -s "$3" ]' _ "$here" "$work/out" "$log"
expect "check-dns.sh --print without that file calls nothing and shows the placeholder of the zone" \
  sh -c 'bash "$1/check-dns.sh" --print stg >"$2" 2>&1 && grep -q "^+ dig NS .<zone_name of aws/accounts/stg>. " "$2" && [ ! -s "$3" ]' _ "$here" "$work/out" "$log"
printf 'zone_name = "Stg.aws.svp.example."\n' >"$infra_root/aws/accounts/stg/stg.auto.tfvars"
expect "check-dns.sh refuses a zone_name that is not a DNS name, naming the file" \
  sh -c '! bash "$1/check-dns.sh" stg >"$2" 2>&1 && grep -q "^FAIL  zone_name .Stg.aws.svp.example.. of .*/aws/accounts/stg/stg.auto.tfvars is not a DNS name" "$2"' _ "$here" "$work/out"
mv "$work/zone.aside" "$infra_root/aws/accounts/stg/stg.auto.tfvars"
expect "check-dns.sh calls no AWS API" test -z "$(grep '^aws ' "$log")"
expect "check-dns.sh takes no mgmt" sh -c '! bash "$1/check-dns.sh" mgmt >/dev/null 2>&1' _ "$here"

# --- tf.sh: backend of each root ---------------------------------------------------------------------------------
new_session
for e in stg prd; do
  # A .terraform left by an init with the backend of the management account, before the accounts of the organization.
  for r in envs gitops; do
    mkdir -p "$infra_root/aws/$r/$e/.terraform"
    printf '%s' '../../backend.hcl ' >"$infra_root/aws/$r/$e/.terraform/terraform.tfstate"
  done
  clear_log
  expect "tf.sh $e env init and gitops init run where .terraform names the old backend" \
    sh -c 'bash "$1/tf.sh" "$2" env init >/dev/null 2>&1 && bash "$1/tf.sh" "$2" gitops init >/dev/null 2>&1' _ "$here" "$e"
  expect "tf.sh $e init: root env with backend-$e.hcl, key aws/$e/terraform.tfstate, -reconfigure" \
    grep -q "^terraform -chdir=.*/aws/envs/$e init -input=false -reconfigure -backend-config=../../backend-$e.hcl -backend-config=key=aws/$e/terraform.tfstate$" "$log"
  expect "tf.sh $e init: root gitops with the same file, key aws/gitops/$e/terraform.tfstate, -reconfigure" \
    grep -q "^terraform -chdir=.*/aws/gitops/$e init -input=false -reconfigure -backend-config=../../backend-$e.hcl -backend-config=key=aws/gitops/$e/terraform.tfstate$" "$log"
  expect "tf.sh $e init: the two roots end on the same backend file and two different keys" \
    sh -c '[ "$(cat "$1/aws/envs/$2/.terraform/terraform.tfstate")" = "../../backend-$2.hcl key=aws/$2/terraform.tfstate " ] &&
      [ "$(cat "$1/aws/gitops/$2/.terraform/terraform.tfstate")" = "../../backend-$2.hcl key=aws/gitops/$2/terraform.tfstate " ]' _ "$infra_root" "$e"
  expect "tf.sh $e init: profile anhnv-$e, TF_VAR_account_id the account of $e" \
    sh -c 'profile=$(sort -u "$1.profiles"); account=$(sed -n "s/^account=\([0-9]*\) .*/\1/p" "$1.tfenv" | sort -u)
      [ "$profile" = anhnv-$2 ] && case $2 in stg) [ "$account" = 111111111111 ] ;; prd) [ "$account" = 222222222222 ] ;; esac' _ "$log" "$e"
done
mv "$infra_root/aws/backend-stg.hcl" "$work/backend.aside"
expect "tf.sh init refuses without aws/backend-stg.hcl, and says how to write it" \
  sh -c '! bash "$1/tf.sh" stg env init >"$2" 2>&1 && grep -q "terraform -chdir=aws/accounts/stg output -raw backend_hcl > aws/backend-stg.hcl" "$2"' _ "$here" "$work/out"
mv "$work/backend.aside" "$infra_root/aws/backend-stg.hcl"
expect "tf.sh refuses a root it does not know" sh -c '! bash "$1/tf.sh" stg accounts init >/dev/null 2>&1' _ "$here"
expect "tf.sh refuses mgmt" sh -c '! bash "$1/tf.sh" mgmt env init >/dev/null 2>&1' _ "$here"

# --- tf.sh: plan, show, apply ------------------------------------------------------------------------------------
new_session
envs=$infra_root/aws/envs
expect "tf.sh apply refuses without a plan file" sh -c '! bash "$1/tf.sh" stg env apply >/dev/null 2>&1' _ "$here"
expect "tf.sh show refuses without a plan file" sh -c '! bash "$1/tf.sh" stg env show >/dev/null 2>&1' _ "$here"
expect "tf.sh env plan runs" bash "$here/tf.sh" stg env plan >"$work/out" 2>&1
expect "tf.sh env plan: stg.tfvars alone into stg.tfplan" grep -q '^terraform -chdir=.*/aws/envs/stg plan -input=false -var-file=stg.tfvars -out=stg.tfplan$' "$log"
expect "tf.sh env plan wrote the plan text in the session directory" grep -q '^Plan: 1 to add' "$SVP_SESSION_DIR/stg-env-plan.txt"
expect "tf.sh env plan says which text to read, then apply" grep -qF "read $SVP_SESSION_DIR/stg-env-plan.txt, then tf.sh stg env apply" "$work/out"
expect "tf.sh show wrote nothing in the repository tree" test -z "$(find "$infra_root" -name '*-plan.txt' -not -path "$infra_root/.session/*")"
expect "tf.sh env apply runs" bash "$here/tf.sh" stg env apply >/dev/null 2>&1
expect "tf.sh env apply applied the plan file and removed it" \
  sh -c 'grep -q "^terraform -chdir=.*/aws/envs/stg apply -input=false stg.tfplan$" "$1" && [ ! -e "$2/stg/stg.tfplan" ]' _ "$log" "$envs"
expect "tf.sh env apply marks env-apply-start, then env-apply-end" sh -c 'has() { awk -F "\t" -v e="$2" "\$3 == e { f = 1 } END { exit !f }" "$1"; }; has "$1" env-apply-start && has "$1" env-apply-end' _ "$SVP_SESSION_DIR/timeline.tsv"
mv "$envs/stg/stg.auto.tfvars" "$work/tfvars.aside"
expect "tf.sh env plan refuses without stg.auto.tfvars" sh -c '! bash "$1/tf.sh" stg env plan >"$2" 2>&1 && grep -q "stg.auto.tfvars" "$2"' _ "$here" "$work/out"
mv "$work/tfvars.aside" "$envs/stg/stg.auto.tfvars"
for e in stg prd; do
  clear_log
  expect "tf.sh $e env plan: TF_VAR_log_archive_account_id is SVP_AWS_LOG_ACCOUNT_ID" \
    sh -c 'bash "$1/tf.sh" "$2" env plan >/dev/null 2>&1 && [ "$(sed -n "s/^log_archive=//p" "$3.tfenv" | sort -u)" = 333333333333 ]' _ "$here" "$e" "$log"
  for v in '' 33333333333 log-account; do
    clear_log
    expect "tf.sh $e env plan refuses SVP_AWS_LOG_ACCOUNT_ID '$v' before any aws or terraform, and says how to set it" \
      sh -c '! SVP_AWS_LOG_ACCOUNT_ID=$3 bash "$1/tf.sh" "$2" env plan >"$4" 2>&1 && grep -q "set SVP_AWS_LOG_ACCOUNT_ID to the 12 digits of the svp-log-archive account" "$4" &&
        [ ! -s "$5" ]' _ "$here" "$e" "$v" "$work/out" "$log"
  done
  clear_log
  expect "tf.sh $e env init refuses without SVP_AWS_LOG_ACCOUNT_ID too" \
    sh -c '! env -u SVP_AWS_LOG_ACCOUNT_ID bash "$1/tf.sh" "$2" env init >"$3" 2>&1 && grep -q "set SVP_AWS_LOG_ACCOUNT_ID" "$3"' _ "$here" "$e" "$work/out"
done
rm -f "$envs/stg/stg.tfplan" "$envs/prd/prd.tfplan"
clear_log
expect "tf.sh gitops plan runs without SVP_AWS_LOG_ACCOUNT_ID: root gitops writes no log" \
  sh -c 'env -u SVP_AWS_LOG_ACCOUNT_ID bash "$1/tf.sh" stg gitops plan >/dev/null 2>&1 && grep -qx "log_archive=unset" "$2.tfenv"' _ "$here" "$log"
clear_log
expect "tf.sh gitops plan runs, needing no auto.tfvars" bash "$here/tf.sh" stg gitops plan >"$work/out" 2>&1
expect "tf.sh gitops plan: stg.tfvars into stg.tfplan of aws/gitops/stg" \
  grep -q '^terraform -chdir=.*/aws/gitops/stg plan -input=false -var-file=stg.tfvars -out=stg.tfplan$' "$log"
expect "tf.sh gitops plan: chart svp-cluster at the revision of envs/stg/charts.yaml, extracted in the session" \
  sh -c 'sed -n "s/^account=[0-9]* //p" "$2.tfenv" | grep -q "^chart=$1/svp-cluster-chart/deploy/helm/svp-cluster " && [ -f "$1/svp-cluster-chart/deploy/helm/svp-cluster/Chart.yaml" ] &&
    grep -q "^ok    chart svp-cluster at $3 " "$4"' _ "$SVP_SESSION_DIR" "$log" "$chart_rev" "$work/out"
expect "tf.sh gitops plan: Telegram chat of the code repository's .env" grep -q ' chat=-1001234$' "$log.tfenv"
# The value as the strict reader of .env of the code repository takes it: plain, or in one pair of quotes.
for q in "'" '"'; do
  printf 'SVP_ALERT_TELEGRAM_CHAT_ID=%s-1001234%s\n' "$q" "$q" >"$work/backend/.env"
  clear_log
  expect "tf.sh gitops plan: the chat of .env in $q quotes, without them" \
    sh -c 'bash "$1/tf.sh" stg gitops plan >/dev/null 2>&1 && grep -q " chat=-1001234$" "$2.tfenv"' _ "$here" "$log"
done
printf 'SVP_ALERT_TELEGRAM_CHAT_ID=%s\n' "'-1001234\"" >"$work/backend/.env"
expect "tf.sh gitops plan refuses a chat of .env in quotes that do not match" \
  sh -c '! bash "$1/tf.sh" stg gitops plan >"$2" 2>&1 && grep -q "SVP_ALERT_TELEGRAM_CHAT_ID of .* is not a Telegram chat id" "$2"' _ "$here" "$work/out"
printf 'SVP_ALERT_TELEGRAM_CHAT_ID=-1001234\n' >"$work/backend/.env"
expect "tf.sh gitops plan wrote its own plan text" grep -q '^Plan: 1 to add' "$SVP_SESSION_DIR/stg-gitops-plan.txt"
clear_log
expect "tf.sh prd gitops plan refuses while the tunnel is closed, before any terraform, and says how to open it" \
  sh -c '! FAKE_TUNNEL=closed bash "$1/tf.sh" prd gitops plan >"$2" 2>&1 && grep -q "no tunnel on 127.0.0.1:6443" "$2" && grep -q "output -raw api_tunnel_command" "$2" &&
    ! grep -q "^terraform " "$3"' _ "$here" "$work/out" "$log"
expect "tf.sh prd gitops init needs no tunnel" sh -c 'FAKE_TUNNEL=closed bash "$1/tf.sh" prd gitops init >/dev/null 2>&1' _ "$here"
rm -f "$infra_root"/aws/*/*/*.tfplan

# --- tf.sh: teardown and destroy order ---------------------------------------------------------------------------
new_session
bash "$here/check-account.sh" stg >/dev/null
expect "tf.sh gitops plan --destroy refuses before pre-destroy.sh" sh -c '! bash "$1/tf.sh" stg gitops plan --destroy >"$2" 2>&1 && grep -q "pre-destroy.sh stg has not finished" "$2"' _ "$here" "$work/out"
expect "tf.sh env plan --destroy refuses before root gitops is destroyed" \
  sh -c '! bash "$1/tf.sh" stg env plan --destroy >"$2" 2>&1 && grep -q "root gitops of stg is not destroyed" "$2"' _ "$here" "$work/out"
expect "tf.sh: refused destroy plans ran no terraform plan -destroy" test -z "$(grep '^terraform .* plan -destroy' "$log")"
expect "tf.sh gitops plan --destroy --leftovers refuses without pre-destroy-start" \
  sh -c '! bash "$1/tf.sh" stg gitops plan --destroy --leftovers >"$2" 2>&1 && grep -q "pre-destroy.sh stg never started in this session" "$2"' _ "$here" "$work/out"
expect "tf.sh: --leftovers is for root gitops, --no-cluster for root env" \
  sh -c '! bash "$1/tf.sh" stg env plan --destroy --leftovers >/dev/null 2>&1 && ! bash "$1/tf.sh" stg gitops plan --destroy --no-cluster >/dev/null 2>&1' _ "$here"
expect "tf.sh destroy refuses without the destroy plan file" \
  sh -c '! bash "$1/tf.sh" stg gitops destroy >"$2" 2>&1 && grep -q "run tf.sh stg gitops plan --destroy" "$2"' _ "$here" "$work/out"
expect "tf.sh stg env plan --teardown and apply --teardown skip: stg has no teardown file" \
  sh -c 'bash "$1/tf.sh" stg env plan --teardown >"$2" 2>&1 && grep -q "^skip  aws/envs/stg has no teardown file" "$2" && bash "$1/tf.sh" stg env apply --teardown >/dev/null 2>&1' _ "$here" "$work/out"
expect "tf.sh: --teardown is for root env" sh -c '! bash "$1/tf.sh" prd gitops plan --teardown >/dev/null 2>&1' _ "$here"
add_mark pre-destroy-done
clear_log
expect "tf.sh gitops plan --destroy runs after pre-destroy.sh" bash "$here/tf.sh" stg gitops plan --destroy >"$work/out" 2>&1
expect "tf.sh gitops plan --destroy: plan -destroy of aws/gitops/stg with its chart" \
  sh -c 'grep -q "^terraform -chdir=.*/aws/gitops/stg plan -destroy -input=false -var-file=stg.tfvars -out=stg.destroy.tfplan$" "$1" && grep -q "chart=.*/svp-cluster-chart/" "$1.tfenv"' _ "$log"
expect "tf.sh gitops plan --destroy wrote the text to the session directory" \
  grep -qx 'Plan: 0 to add, 0 to change, 3 to destroy.' "$SVP_SESSION_DIR/stg-gitops-destroy-plan.txt"
expect "tf.sh gitops destroy runs" bash "$here/tf.sh" stg gitops destroy >"$work/out" 2>&1
expect "tf.sh gitops destroy applied the destroy plan file, never terraform destroy, and removed it" \
  sh -c 'grep -q "^terraform -chdir=.*/aws/gitops/stg apply -input=false stg.destroy.tfplan$" "$1" && ! grep -qE "^terraform -chdir=[^ ]* destroy" "$1" && [ ! -e "$2/aws/gitops/stg/stg.destroy.tfplan" ]' _ "$log" "$infra_root"
expect "tf.sh gitops destroy marks gitops-destroy-end and says what is next" sh -c 'awk -F "\t" "\$3 == \"gitops-destroy-end\" { f = 1 } END { exit !f }" "$1" && grep -q "next: tf.sh stg env plan --teardown" "$2"' _ "$SVP_SESSION_DIR/timeline.tsv" "$work/out"
expect "tf.sh stg env plan --destroy runs once root gitops is destroyed" bash "$here/tf.sh" stg env plan --destroy >/dev/null 2>&1
expect "tf.sh stg env plan --destroy: stg.tfvars alone" grep -q '^terraform -chdir=.*/aws/envs/stg plan -destroy -input=false -var-file=stg.tfvars -out=stg.destroy.tfplan$' "$log"
clear_log
expect "tf.sh stg env destroy runs and says to sweep next" sh -c 'bash "$1/tf.sh" stg env destroy >"$2" 2>&1 && grep -q "now aws/scripts/sweep.sh stg" "$2"' _ "$here" "$work/out"
expect "tf.sh stg env destroy marks env-destroy-start and env-destroy-end" sh -c 'has() { awk -F "\t" -v e="$2" "\$3 == e { f = 1 } END { exit !f }" "$1"; }; has "$1" env-destroy-start && has "$1" env-destroy-end' _ "$SVP_SESSION_DIR/timeline.tsv"

new_session
add_mark gitops-destroy-end
export FAKE_TF_STATE=eks
expect "tf.sh prd env plan --destroy refuses while the protections are on, before any terraform plan, and says how to lift them" \
  sh -c '! bash "$1/tf.sh" prd env plan --destroy >"$2" 2>&1 && grep -q "protections of aws/envs/prd are still on" "$2" && grep -q "tf.sh prd env plan --teardown" "$2" &&
    ! grep -q "^terraform .* plan" "$3"' _ "$here" "$work/out" "$log"
expect "tf.sh prd env apply --teardown refuses without the teardown plan" sh -c '! bash "$1/tf.sh" prd env apply --teardown >/dev/null 2>&1' _ "$here"
expect "tf.sh prd env plan --teardown runs" bash "$here/tf.sh" prd env plan --teardown >"$work/out" 2>&1
expect "tf.sh prd env plan --teardown: prd.tfvars and teardown.tfvars, the DB instance, the ALB and the buckets of the state as targets, into prd.teardown.tfplan, its text in the session" \
  sh -c 'grep -qxF "terraform -chdir=$3/prd plan -input=false -var-file=prd.tfvars -var-file=teardown.tfvars -target=module.rds.aws_db_instance.this -target=module.edge.aws_lb.this -target=module.media.aws_s3_bucket.this[\"media\"] -target=module.media.aws_s3_bucket.this[\"uploads\"] -target=module.media.aws_s3_bucket.logs[0] -out=prd.teardown.tfplan" "$1" &&
    grep -q "^Plan: 0 to add, 2 to change" "$2/prd-env-teardown-plan.txt"' _ "$log" "$SVP_SESSION_DIR" "$envs"
expect "tf.sh prd env plan --teardown: no target of a data source, of another type or of the cluster" \
  sh -c '! grep "^terraform .* -out=prd.teardown.tfplan$" "$1" | grep -qE "target=[^ ]*(data\.|aws_s3_bucket_versioning|aws_lb_listener|aws_lb_target_group|aws_eks_cluster|aws_vpc)"' _ "$log"
expect "tf.sh prd env plan --teardown read the state first" before "$log" 'terraform .*/aws/envs/prd state list' 'terraform .* -out=prd.teardown.tfplan'
expect "tf.sh prd env plan --destroy still refuses: the teardown plan is not applied" sh -c '! bash "$1/tf.sh" prd env plan --destroy >/dev/null 2>&1' _ "$here"
expect "tf.sh prd env apply --teardown applies it and marks env-teardown-applied" \
  sh -c 'bash "$1/tf.sh" prd env apply --teardown >/dev/null 2>&1 && grep -q "^terraform -chdir=.*/aws/envs/prd apply -input=false prd.teardown.tfplan$" "$2" &&
    awk -F "\t" "\$3 == \"env-teardown-applied\" { f = 1 } END { exit !f }" "$3/timeline.tsv" && [ ! -e "$4/prd/prd.teardown.tfplan" ]' _ "$here" "$log" "$SVP_SESSION_DIR" "$envs"
clear_log
expect "tf.sh prd env plan --destroy runs once the teardown is applied" bash "$here/tf.sh" prd env plan --destroy >/dev/null 2>&1
expect "tf.sh prd env plan --destroy: prd.tfvars and teardown.tfvars, no target, profile anhnv-prd" \
  sh -c 'grep -q "^terraform -chdir=.*/aws/envs/prd plan -destroy -input=false -var-file=prd.tfvars -var-file=teardown.tfvars -out=prd.destroy.tfplan$" "$1" && [ "$(sort -u "$1.profiles")" = anhnv-prd ]' _ "$log"
rm -f "$envs/prd/prd.destroy.tfplan"
unset FAKE_TF_STATE

# An apply of prd that failed halfway (a quota, before the cluster and the DB instance): the teardown plan targets the
# buckets it made alone, so it creates nothing and never meets the failure again, and the destroy can go on.
new_session
add_mark env-apply-start
expect "tf.sh prd env plan --destroy --no-cluster after a failed apply refuses while the buckets keep their protection" \
  sh -c '! FAKE_TF_STATE=partial bash "$1/tf.sh" prd env plan --destroy --no-cluster >"$2" 2>&1 && grep -q "protections of aws/envs/prd are still on" "$2"' _ "$here" "$work/out"
clear_log
expect "tf.sh prd env plan --teardown after a failed apply targets the buckets of the state alone" \
  sh -c 'FAKE_TF_STATE=partial bash "$1/tf.sh" prd env plan --teardown >/dev/null 2>&1 &&
    grep -qxF "terraform -chdir=$3/prd plan -input=false -var-file=prd.tfvars -var-file=teardown.tfvars -target=module.media.aws_s3_bucket.this[\"media\"] -target=module.media.aws_s3_bucket.this[\"uploads\"] -out=prd.teardown.tfplan" "$2"' _ "$here" "$log" "$envs"
expect "tf.sh prd env apply --teardown, then plan --destroy --no-cluster run after a failed apply" \
  sh -c 'FAKE_TF_STATE=partial bash "$1/tf.sh" prd env apply --teardown >/dev/null 2>&1 && FAKE_TF_STATE=partial bash "$1/tf.sh" prd env plan --destroy --no-cluster >/dev/null 2>&1 &&
    grep -q "^terraform -chdir=.*/aws/envs/prd plan -destroy -input=false -var-file=prd.tfvars -var-file=teardown.tfvars -out=prd.destroy.tfplan$" "$2"' _ "$here" "$log"
rm -f "$envs/prd/prd.destroy.tfplan"

# An apply that failed before any DB instance or bucket: nothing to lift, no teardown plan.
new_session
add_mark env-apply-start
expect "tf.sh prd env plan --teardown with no DB instance, ALB or bucket in the state skips, and records env-teardown-applied" \
  sh -c 'bash "$1/tf.sh" prd env plan --teardown >"$2" 2>&1 && grep -q "^skip  the state of aws/envs/prd holds no aws_db_instance or aws_lb or aws_s3_bucket" "$2" &&
    ! grep -q "^terraform .* plan" "$3" && [ ! -e "$4/prd/prd.teardown.tfplan" ]' _ "$here" "$work/out" "$log" "$envs"
expect "tf.sh prd env plan --teardown with nothing to lift marks env-teardown-applied" has_mark env-teardown-applied
expect "tf.sh prd env apply --teardown skips once env-teardown-applied is recorded and no teardown plan is left" \
  sh -c 'bash "$1/tf.sh" prd env apply --teardown >"$2" 2>&1 && grep -q "^skip  no teardown plan left" "$2" && ! grep -q "^terraform .* apply" "$3"' _ "$here" "$work/out" "$log"
expect "tf.sh prd env plan --destroy --no-cluster runs when nothing was to lift" bash "$here/tf.sh" prd env plan --destroy --no-cluster >/dev/null 2>&1
rm -f "$envs/prd/prd.destroy.tfplan"

# --no-cluster: an apply that failed before EKS; root gitops was never applied.
new_session
expect "tf.sh env plan --destroy --no-cluster runs with no cluster-values.json and no EKS cluster in the state" \
  bash "$here/tf.sh" stg env plan --destroy --no-cluster >/dev/null 2>&1
expect "tf.sh env plan --destroy --no-cluster read the state before planning" before "$log" 'terraform .* state list' 'terraform .* plan -destroy'
rm -f "$envs/stg/stg.destroy.tfplan"
clear_log
expect "tf.sh env plan --destroy --no-cluster refuses when the state holds an EKS cluster, and points to pre-destroy.sh" \
  sh -c '! FAKE_TF_STATE=eks bash "$1/tf.sh" stg env plan --destroy --no-cluster >"$2" 2>&1 && grep -q "state holds EKS cluster .*run aws/scripts/pre-destroy.sh stg first" "$2"' _ "$here" "$work/out"
expect "tf.sh env plan --destroy --no-cluster refuses when the state cannot be read" \
  sh -c '! FAKE_TF_STATE=fail bash "$1/tf.sh" stg env plan --destroy --no-cluster >/dev/null 2>&1' _ "$here"
echo '{"name":"svp-stg","domain":"stg.aws.svp.example"}' >"$SVP_SESSION_DIR/cluster-values.json"
expect "tf.sh env plan --destroy --no-cluster refuses when the session has cluster-values.json" \
  sh -c '! bash "$1/tf.sh" stg env plan --destroy --no-cluster >"$2" 2>&1 && grep -q "cluster-values.json exists" "$2"' _ "$here" "$work/out"
expect "tf.sh env plan --destroy --no-cluster refused: terraform plan -destroy never ran" test -z "$(grep '^terraform .* plan -destroy' "$log")"

# --- bootstrap.sh -------------------------------------------------------------------------------------------------
# The Kafka and Valkey passwords of the local stack are in .env too: the apply of the root writes those of EKS, so no
# session script reads them.
kafka_pw=kafkalocal0000000000000000000001 valkey_pw=valkeylocal000000000000000000001
printf 'SVP_KAFKA_ADMIN_PASSWORD=%s\nSVP_VALKEY_OPS_PASSWORD=%s\n' "$kafka_pw" "$valkey_pw" >>"$work/backend/.env"
for e in stg prd; do
  new_session
  bash "$here/bootstrap.sh" "$e" secrets >"$work/boot.out" 2>&1 || bad "bootstrap.sh $e secrets exits 0 ($(tail -n 3 "$work/boot.out"))"
  values=$SVP_SESSION_DIR/cluster-values.json
  expect "bootstrap.sh $e secrets: account first, profile anhnv-$e alone" \
    sh -c 'grep -m1 "^aws " "$1" | grep -q "^aws sts get-caller-identity " && [ "$(sort -u "$1.profiles")" = "anhnv-$2" ]' _ "$log" "$e"
  expect "bootstrap.sh $e secrets writes the kubeconfig context svp-$e" grep -qE "^aws eks update-kubeconfig --name svp-$e --alias svp-$e" "$log"
  expect "bootstrap.sh $e secrets writes the cluster values, owner only" \
    sh -c 'jq -e ".name == \"svp-$2\"" "$1" >/dev/null && [ -n "$(find "$1" -perm 0600)" ]' _ "$values" "$e"
  expect "bootstrap.sh $e secrets calls make eks-secrets with the context and the password in its environment" \
    grep -qF "make -C $work/backend eks-secrets CONTEXT=svp-$e password=match profile=anhnv-$e" "$log"
  expect "bootstrap.sh $e secrets: the password is in no output, log or session file" \
    sh -c '! grep -rqF -- "$1" "$2" "$3" "$4"' _ "$password" "$work/boot.out" "$log" "$SVP_SESSION_DIR"
  expect "bootstrap.sh $e secrets: the RDS secret reaches jq through a pipe, never a file" test -z "$(grep 'stdin=file' "$log")"
  expect "bootstrap.sh $e secrets marks secrets-written" has_mark secrets-written
  expect "bootstrap.sh $e secrets passes no Kafka or Valkey password to make eks-secrets" \
    grep -qF "make -C $work/backend eks-secrets CONTEXT=svp-$e password=match profile=anhnv-$e kv=none" "$log"
  expect "bootstrap.sh $e secrets: the local Kafka and Valkey passwords of .env are in no output, log or session file" \
    sh -c '! grep -rqF -e "$1" -e "$2" "$3" "$4" "$5"' _ "$kafka_pw" "$valkey_pw" "$work/boot.out" "$log" "$SVP_SESSION_DIR"
  expect "bootstrap.sh $e secrets says the apply of the root wrote the Kafka and Valkey entries" \
    grep -q "kafka-admin, kafka-users, valkey-users by the apply of aws/envs/$e" "$work/boot.out"
  expect "bootstrap.sh $e secrets deletes both older tokens of svp-grafana-operator before it makes one" \
    sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
      for t in 11 12; do b "$1" "^aws grafana delete-workspace-service-account-token --workspace-id g-0fake --service-account-id 4 --token-id $t " \
        "^aws grafana create-workspace-service-account-token " || exit 1; done' _ "$log"
  expect "bootstrap.sh $e secrets makes a token of a day for service account svp-grafana-operator of the workspace of grafanaUrl" \
    grep -qE "^aws grafana create-workspace-service-account-token --workspace-id g-0fake --service-account-id 4 --name svp-grafana-operator-[0-9TZ]+ --seconds-to-live 86400 --output json --region ap-southeast-1$" "$log"
  expect "bootstrap.sh $e secrets writes the token's map to entry svp/$e/grafana-operator from a pipe" \
    sh -c 'grep -q "^aws secretsmanager put-secret-value --secret-id svp/$2/grafana-operator --secret-string file:///dev/stdin --query VersionId --output text --region ap-southeast-1$" "$1" &&
      grep -q "^put-secret-value value=match from=pipe$" "$1"' _ "$log" "$e"
  expect "bootstrap.sh $e secrets: the token is in no argument, output or session file" \
    sh -c '! grep -rqF -- "$1" "$2" "$3" "$4"' _ "$grafana_token" "$work/boot.out" "$log" "$SVP_SESSION_DIR"
  expect "bootstrap.sh $e secrets: the token before secrets-written, then ecr-warm.sh named as the next step" \
    sh -c 'grep -q "^ok    a token of svp-grafana-operator valid 24 h in entry svp/$2/grafana-operator (not shown)$" "$1" &&
      grep -q "next: aws/scripts/ecr-warm.sh $2 <image list>, then aws/scripts/tf.sh $2 gitops init" "$1"' _ "$work/boot.out" "$e"
done
expect "bootstrap.sh prd secrets points the context at the tunnel, TLS server name the endpoint's host" \
  grep -q '^kubectl config set-cluster arn:aws:eks:ap-southeast-1:222222222222:cluster/svp-prd --server=https://127.0.0.1:6443 --tls-server-name=0123ABCD.gr7.ap-southeast-1.eks.amazonaws.com$' "$log"
new_session
expect "bootstrap.sh secrets fails without service account svp-grafana-operator, makes no token, writes nothing" \
  sh -c '! FAKE_NO_GRAFANA_SA=1 bash "$1/bootstrap.sh" stg secrets >"$2" 2>&1 &&
    grep -q "^FAIL  Grafana workspace g-0fake has no service account svp-grafana-operator (the apply of aws/accounts/stg makes it)$" "$2" &&
    ! grep -qE "create-workspace-service-account-token|delete-workspace-service-account-token|put-secret-value" "$3"' _ "$here" "$work/out" "$log"
expect "bootstrap.sh secrets without the token marks no secrets-written" \
  sh -c '! grep -qs secrets-written "$1/timeline.tsv"' _ "$SVP_SESSION_DIR"
new_session
bash "$here/bootstrap.sh" stg secrets >/dev/null 2>&1 || true
expect "bootstrap.sh stg secrets points the context at its own tunnel port" \
  grep -q '^kubectl config set-cluster arn:aws:eks:ap-southeast-1:111111111111:cluster/svp-stg --server=https://127.0.0.1:6444 --tls-server-name=0123ABCD.gr7.ap-southeast-1.eks.amazonaws.com$' "$log"
clear_log
expect "bootstrap.sh stops on another account before any other command" \
  sh -c '! FAKE_ACCOUNT=222222222222 bash "$1/bootstrap.sh" stg secrets >/dev/null 2>&1 && [ -s "$2" ] && ! grep -qv "^aws sts get-caller-identity " "$2"' _ "$here" "$log"
new_session
expect "bootstrap.sh fails when make's output holds the password, and deletes the log" \
  sh -c '! FAKE_MAKE_LEAK=1 bash "$1/bootstrap.sh" stg secrets >"$2" 2>&1 && grep -q "held the RDS master password" "$2" && [ ! -e "$3/eks-secrets.log" ] &&
    ! grep -rqF -- "$4" "$3"' _ "$here" "$work/leak.out" "$SVP_SESSION_DIR" "$password"
git_ -C "$work/backend" switch -q -c feature
expect "bootstrap.sh stops when the code repository is not on main" sh -c '! bash "$1/bootstrap.sh" stg secrets >/dev/null 2>&1' _ "$here"
git_ -C "$work/backend" switch -q main

new_session
expect "bootstrap.sh prd wait refuses while the tunnel is closed" \
  sh -c '! FAKE_TUNNEL=closed bash "$1/bootstrap.sh" prd wait >"$2" 2>&1 && grep -q "no tunnel on 127.0.0.1:6443" "$2"' _ "$here" "$work/out"
expect "bootstrap.sh prd wait with the tunnel closed: no kubectl, no make" test -z "$(grep -E '^(kubectl|make) ' "$log")"
rm -f "$state"/app-calls-* "$state/tg-calls"
tg_arn=arn:aws:elasticloadbalancing:ap-southeast-1:222222222222:targetgroup/svp-prd-envoy/2c3d
echo "{\"name\":\"svp-prd\",\"domain\":\"aws.svp.example\",\"edgeTargetGroupArn\":\"$tg_arn\"}" >"$SVP_SESSION_DIR/cluster-values.json"
clear_log
expect "bootstrap.sh prd wait runs with the tunnel open" bash "$here/bootstrap.sh" prd wait >"$work/out" 2>&1
expect "bootstrap.sh wait: the target health of edgeTargetGroupArn of cluster-values.json, read after svp-root until a target is healthy" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "applications.argoproj.io svp-root" "^aws elbv2 describe-target-health --target-group-arn $2 --output json --region ap-southeast-1$" &&
    [ "$(grep -c "^aws elbv2 describe-target-health " "$1")" = 2 ]' _ "$log" "$tg_arn"
expect "bootstrap.sh wait marks edge-healthy and says measure.sh is next" \
  sh -c 'awk -F "\t" "\$3 == \"edge-healthy\" { f = 1 } END { exit !f }" "$1/timeline.tsv" &&
    grep -q "^ok    the edge.s target group has a healthy target; next: aws/scripts/measure.sh prd$" "$2"' _ "$SVP_SESSION_DIR" "$work/out"
expect "bootstrap.sh wait: svp-observability Healthy, then GlitchTip, then svp-root" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    [ "$(grep -c "applications.argoproj.io svp-observability" "$1")" = 2 ] && b "$1" "applications.argoproj.io svp-observability" "eks-glitchtip-init CONTEXT=svp-prd" &&
    b "$1" "eks-glitchtip-init" "applications.argoproj.io svp-root"' _ "$log"
expect "bootstrap.sh wait marks svp-root-healthy" has_mark svp-root-healthy
new_session
expect "bootstrap.sh wait fails when svp-root never gets Synced and Healthy" \
  sh -c '! FAKE_ROOT_NEVER=1 SVP_BOOTSTRAP_LIMIT=0 bash "$1/bootstrap.sh" stg wait >"$2" 2>&1 && grep -q "svp-root not Synced and Healthy after 0 s (OutOfSync Progressing)" "$2"' _ "$here" "$work/out"
expect "bootstrap.sh wait: no svp-root-healthy when it fails" no_mark svp-root-healthy
new_session
echo "{\"name\":\"svp-prd\",\"domain\":\"aws.svp.example\",\"edgeTargetGroupArn\":\"$tg_arn\"}" >"$SVP_SESSION_DIR/cluster-values.json"
rm -f "$state/tg-calls"
expect "bootstrap.sh wait fails when no target of the edge turns healthy, naming the targets and the TargetGroupBinding" \
  sh -c '! FAKE_TG_STATES=unhealthy SVP_BOOTSTRAP_LIMIT=0 bash "$1/bootstrap.sh" prd wait >"$2" 2>&1 &&
    grep -q "^FAIL  no healthy target in $3 after 0 s (targets: 10.0.4.20 unhealthy): .*describe targetgroupbinding svp-envoy" "$2"' _ "$here" "$work/out" "$tg_arn"
expect "bootstrap.sh wait: no edge-healthy when it fails" no_mark edge-healthy
new_session
expect "bootstrap.sh wait without the cluster values of bootstrap.sh secrets fails, and says so" \
  sh -c '! bash "$1/bootstrap.sh" prd wait >"$2" 2>&1 && grep -q "^FAIL  no edgeTargetGroupArn in .*cluster-values.json: aws/scripts/bootstrap.sh prd secrets writes it" "$2"' _ "$here" "$work/out"
new_session
expect "bootstrap.sh secrets refuses cluster values without edgeTargetGroupArn (a root before the edge)" \
  sh -c '! FAKE_TF_OLD_VALUES=1 bash "$1/bootstrap.sh" stg secrets >"$2" 2>&1 && grep -q "not a map of cluster svp-stg with a domain and an edgeTargetGroupArn" "$2" &&
    ! grep -q "eks-secrets" "$3"' _ "$here" "$work/out" "$log"

# --- pre-destroy.sh ----------------------------------------------------------------------------------------------
new_session
printf '%s\n' "0 cert-manager" "0 envoy-gateway" "0 external-secrets" "0 karpenter" "1 svp-cluster" "1 aws-load-balancer-controller" \
  "2 keda" "2 argo-rollouts" "2 kyverno" "2 kube-prometheus-stack" "3 svp-policy" "3 loki" \
  "3 ack-prometheusservice" "4 svp-data" "5 svp-observability" "6 otel-collector" "7 gateway" "7 web" >"$state/apps"
touch "$state/appset" "$state/root" "$state/svp-apps" "$state/lb" "$state/tgb" "$state/ack-up"
printf '%s\n' "RuleGroupsNamespace svp-obs svp-alerts ws-0fake" "RuleGroupsNamespace svp-obs slo-generated ws-0fake" \
  "AlertManagerDefinition svp-obs svp-alerts ws-0fake" >"$state/ack-crs"
printf '%s\n' "svp-data data-0" "svp-obs prometheus-db-0" >"$state/pvcs"
echo "default-x7k2p ip-10-0-9-9" >"$state/nodeclaims"
echo "i-0karp running m7g.large default" >"$state/karpenter-instances"
FAKE_LEFTOVER=record bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 || bad "pre-destroy.sh stg exits 0 ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh: sync and finalizers of svp-root and svp-apps cleared before the ApplicationSet is deleted" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "patch application svp-root .*finalizers" "delete applicationset svp-bootstrap" && b "$1" "patch application svp-apps .*finalizers" "delete applicationset svp-bootstrap"' _ "$log"
expect "pre-destroy.sh: ApplicationSet, then svp-apps, before any child" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "delete applicationset svp-bootstrap" "delete application svp-apps " && b "$1" "delete application svp-apps " "delete application [a-z-]+ --wait=false"' _ "$log"
expect "pre-destroy.sh: auto-sync of svp-cluster off before the first child is deleted" \
  before "$log" 'patch application svp-cluster .*automated' 'delete application [a-z-]+ --wait=false'
expect "pre-destroy.sh: wave 7 before wave 3, workloads before the Gateway" \
  sh -c '[ "$(grep -n "delete application gateway " "$1" | cut -d: -f1)" -lt "$(grep -n "delete application loki " "$1" | cut -d: -f1)" ]' _ "$log"
expect "pre-destroy.sh: last workload (kube-prometheus-stack) before the Gateway" before "$log" 'delete application kube-prometheus-stack ' 'delete gateway svp'
expect "pre-destroy.sh: Gateway before the PVCs" before "$log" 'delete gateway svp' 'delete pvc --all'
expect "pre-destroy.sh: PVCs before every platform Application" before "$log" 'delete pvc --all' 'delete application (svp-cluster|keda|kyverno|aws-load-balancer-controller) '
expect "pre-destroy.sh: the PVCs of both namespaces" test "$(grep -c 'delete pvc --all' "$log")" = 2
expect "pre-destroy.sh leaves no Application, ApplicationSet or root" sh -c '[ -z "$(grep . "$1/apps")" ] && [ ! -e "$1/appset" ] && [ ! -e "$1/root" ] && [ ! -e "$1/svp-apps" ]' _ "$state"
expect "pre-destroy.sh: the records root env wrote in the zone are none of its business: no call to Route 53" \
  sh -c '! grep -q "^aws route53 " "$1" && ! grep -qi "record" "$2"' _ "$log" "$work/pre.out"
expect "pre-destroy.sh: waits for no TargetGroupBinding and no load balancer or target group of LBC" \
  sh -c 'grep -q "^ok    no TargetGroupBinding$" "$1" && grep -q "^ok    no load balancer or target group of svp-stg in ELBv2$" "$1" &&
    grep -q "resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer elasticloadbalancing:targetgroup --tag-filters Key=elbv2.k8s.aws/cluster,Values=svp-stg " "$2"' _ "$work/pre.out" "$log"
expect "pre-destroy.sh: Gateway, then TargetGroupBinding svp-envoy of svp-cluster, then the wait for none, before the PVCs" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    t="-n envoy-gateway-system delete targetgroupbindings.elbv2.k8s.aws svp-envoy --ignore-not-found --wait=true --timeout=600s"
    b "$1" "delete gateway svp" "$t" && b "$1" "$t" "get targetgroupbindings.elbv2.k8s.aws -A" && b "$1" "$t" "delete pvc --all" &&
    [ "$(grep -c "delete targetgroupbinding" "$1")" = 1 ] && grep -q "^ok    TargetGroupBinding envoy-gateway-system/svp-envoy deleted$" "$2"' _ "$log" "$work/pre.out"
expect "pre-destroy.sh: NodePools after the PVCs, then EC2NodeClasses, then the instances of Karpenter, before Application karpenter" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "delete pvc --all" "delete nodepools.karpenter.sh --all" && b "$1" "delete nodepools.karpenter.sh --all" "delete ec2nodeclasses.karpenter.k8s.aws --all" &&
    b "$1" "delete ec2nodeclasses.karpenter.k8s.aws --all" "get nodeclaims.karpenter.sh" &&
    b "$1" "get nodeclaims.karpenter.sh" "ec2 describe-instances .*karpenter.sh/nodepool" &&
    b "$1" "ec2 describe-instances .*karpenter.sh/nodepool" "delete application karpenter "' _ "$log"
expect "pre-destroy.sh: Application karpenter stays through step 2" \
  sh -c '! sed -n "1,/delete nodepools.karpenter.sh/p" "$1" | grep -q "delete application karpenter "' _ "$log"
expect "pre-destroy.sh: no NodeClaim and no instance of Karpenter, marked pre-destroy-nodes" \
  sh -c 'grep -q "^ok    NodePools and EC2NodeClasses deleted, no NodeClaim$" "$1" && grep -q "^ok    no EC2 instance of Karpenter for svp-stg$" "$1" &&
    awk -F "\t" "\$3 == \"pre-destroy-nodes\" { f = 1 } END { exit !f }" "$2"' _ "$work/pre.out" "$SVP_SESSION_DIR/timeline.tsv"
expect "pre-destroy.sh: auto-sync off, then the ACK resources of AMP deleted while ACK runs, before any Application" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    d="delete rulegroupsnamespaces.prometheusservice.services.k8s.aws,alertmanagerdefinitions.prometheusservice.services.k8s.aws -A --all --wait=false"
    b "$1" "patch application svp-observability .*automated" "$d" && b "$1" "$d" "delete application [a-z-]+ --wait=false"' _ "$log"
expect "pre-destroy.sh: ACK left nothing; no finalizer cleared, nothing listed for AMP" \
  sh -c '[ ! -s "$1/ack-crs" ] && ! grep -q "patch [a-z]*.prometheusservice.services.k8s.aws" "$2" &&
    grep -q "^ok    rules and alerting of AMP deleted by ACK$" "$3" && ! grep -q "left in AMP" "$3"' _ "$state" "$log" "$work/pre.out"
expect "pre-destroy.sh marks pre-destroy-start and pre-destroy-done" sh -c 'has() { awk -F "\t" -v e="$2" "\$3 == e { f = 1 } END { exit !f }" "$1"; }; has "$1" pre-destroy-start && has "$1" pre-destroy-done' _ "$SVP_SESSION_DIR/timeline.tsv"
expect "pre-destroy.sh: no way-out note when every step passes; next is root gitops" \
  sh -c '! grep -q -- "--leftovers" "$1" && grep -q "ready for: aws/scripts/tf.sh stg gitops plan --destroy" "$1"' _ "$work/pre.out"
rm -f "$state/ack-crs" "$state/ack-up"

new_session
: >"$state/apps"
: >"$state/pvcs"
rm -f "$state/appset" "$state/root" "$state/svp-apps" "$state/lb"
FAKE_NO_ARGOCD=1 bash "$here/pre-destroy.sh" prd >"$work/pre.out" 2>&1 ||
  bad "pre-destroy.sh prd exits 0 on a cluster without Argo CD ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh prd: context through the tunnel, checked before the first kubectl to the API" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" "^kubectl config set-cluster .*6443" "^nc -z" && b "$1" "^nc -z" "^kubectl --context svp-prd"' _ "$log"
expect "pre-destroy.sh without Argo CD says so" grep -q '^note  no Argo CD on svp-prd' "$work/pre.out"
expect "pre-destroy.sh without Argo CD calls nothing of Argo CD, the Gateway or the TargetGroupBinding" \
  test -z "$(grep -E -- '-n argocd |delete gateway|delete targetgroupbinding' "$log")"
expect "pre-destroy.sh without Argo CD still waits on load balancers and volumes" \
  sh -c 'grep -q "get services -A" "$1" && grep -q "resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing" "$1" && grep -q "ec2 describe-volumes" "$1"' _ "$log"
expect "pre-destroy.sh without Argo CD marks pre-destroy-done" has_mark pre-destroy-done
expect "pre-destroy.sh without Karpenter skips the NodePools, says so, and still checks its instances" \
  sh -c 'grep -q "^note  no Karpenter on svp-prd" "$1" && ! grep -qE "delete (nodepools|ec2nodeclasses)|nodeclaims" "$2" &&
    grep -q "ec2 describe-instances --filters Name=tag:kubernetes.io/cluster/svp-prd,Values=owned Name=tag-key,Values=karpenter.sh/nodepool " "$2"' _ "$work/pre.out" "$log"
new_session
expect "pre-destroy.sh prd refuses while the tunnel is closed, before any kubectl to the API" \
  sh -c '! FAKE_TUNNEL=closed bash "$1/pre-destroy.sh" prd >"$2" 2>&1 && grep -q "no tunnel on 127.0.0.1:6443" "$2" && ! grep -q "^kubectl --context" "$3"' _ "$here" "$work/out" "$log"
clear_log
expect "pre-destroy.sh on an account without the cluster stops before kubectl and points to --no-cluster" \
  sh -c '! FAKE_NO_CLUSTER=1 bash "$1/pre-destroy.sh" stg >"$2" 2>&1 && grep -q "tf.sh stg env plan --destroy --no-cluster" "$2" && ! grep -q "^kubectl " "$3"' _ "$here" "$work/out" "$log"
expect "pre-destroy.sh red at the kubeconfig still marks pre-destroy-start, not pre-destroy-done" \
  sh -c 'has() { awk -F "\t" -v e="$2" "\$3 == e { f = 1 } END { exit !f }" "$1"; }; has "$1" pre-destroy-start && ! has "$1" pre-destroy-done' _ "$SVP_SESSION_DIR/timeline.tsv"
clear_log
expect "tf.sh gitops plan --destroy --leftovers runs after pre-destroy-start without pre-destroy-done" \
  bash "$here/tf.sh" stg gitops plan --destroy --leftovers >"$work/out" 2>&1
expect "tf.sh gitops plan --destroy --leftovers says what may be left and that sweep.sh lists it" \
  sh -c 'grep -q "^note  --leftovers: .*EBS volumes.*EC2 instances of Karpenter.*stuck-destroy.*sweep.sh stg" "$1" && ! grep -q "ExternalDNS" "$1"' _ "$work/out"
expect "tf.sh gitops plan --destroy --leftovers marks pre-destroy-skipped and writes the destroy plan" \
  sh -c 'awk -F "\t" "\$3 == \"pre-destroy-skipped\" { f = 1 } END { exit !f }" "$1/timeline.tsv" && [ -f "$2/stg.destroy.tfplan" ]' _ "$SVP_SESSION_DIR" "$infra_root/aws/gitops/stg"
expect "tf.sh gitops plan --destroy without --leftovers still refuses in that session" sh -c '! bash "$1/tf.sh" stg gitops plan --destroy >/dev/null 2>&1' _ "$here"
rm -f "$infra_root/aws/gitops/stg/stg.destroy.tfplan"
mv "$envs/stg/stg.auto.tfvars" "$work/tfvars.aside"
new_session
expect "pre-destroy.sh needs no stg.auto.tfvars: it reads no zone" \
  sh -c 'FAKE_NO_ARGOCD=1 bash "$1/pre-destroy.sh" stg >"$2" 2>&1 && grep -q "^ok    ready for: aws/scripts/tf.sh stg gitops plan --destroy" "$2"' _ "$here" "$work/out"
mv "$work/tfvars.aside" "$envs/stg/stg.auto.tfvars"
new_session
FAKE_NO_ARGOCD=1 FAKE_GATEWAY_CRD_DOWN=1 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 &&
  bad "pre-destroy.sh fails when step 2 cannot read the cluster"
expect "pre-destroy.sh red at step 2: the FAIL, then a last line with run again and the way out --leftovers" \
  sh -c 'grep -q "^FAIL  read the CRDs" "$1" && tail -n 1 "$1" | grep -q "^note  fix what the FAIL above names, then aws/scripts/pre-destroy.sh stg again; .*aws/scripts/tf.sh stg gitops plan --destroy --leftovers"' _ "$work/pre.out"
new_session
: >"$state/apps"
echo "default-x7k2p ip-10-0-9-9" >"$state/nodeclaims"
echo "i-0karp running m7g.large default" >"$state/karpenter-instances"
FAKE_KARPENTER_STUCK=1 SVP_KARPENTER_LIMIT=0 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 &&
  bad "pre-destroy.sh fails when a NodeClaim outlives the limit"
expect "pre-destroy.sh red at step 4: the NodeClaim left, then the way out, and no pre-destroy-done" \
  sh -c 'grep -q "^FAIL  NodeClaims left after 0 s: default-x7k2p ip-10-0-9-9;" "$1" &&
    tail -n 1 "$1" | grep -q "^note  fix what the FAIL above names, then aws/scripts/pre-destroy.sh stg again; .*step 2, 3 or 4 is still red" &&
    ! grep -q "delete application svp-cluster " "$2"' _ "$work/pre.out" "$log"
expect "pre-destroy.sh red at step 4 marks no pre-destroy-done" no_mark pre-destroy-done
new_session
printf '%s\n' "1 svp-cluster" "1 aws-load-balancer-controller" "7 gateway" >"$state/apps"
touch "$state/tgb"
echo "svp-data data-0" >"$state/pvcs"
FAKE_TGB_STUCK=1 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 &&
  bad "pre-destroy.sh fails when TargetGroupBinding svp-envoy outlives the limit"
expect "pre-destroy.sh red at step 2 on svp-envoy: the FAIL with LBC's log, the way out, no PVC, svp-cluster or pre-destroy-done" \
  sh -c 'grep -q "^FAIL  TargetGroupBinding envoy-gateway-system/svp-envoy not deleted in 600 s (error above): .*logs deploy/aws-load-balancer-controller" "$1" &&
    tail -n 1 "$1" | grep -q "^note  fix what the FAIL above names, then aws/scripts/pre-destroy.sh stg again; " &&
    ! grep -qE "delete pvc|delete application (svp-cluster|aws-load-balancer-controller) " "$2" && grep -q " svp-cluster$" "$3/apps" &&
    ! awk -F "\t" "\$3 == \"pre-destroy-done\" { f = 1 } END { exit !f }" "$4/timeline.tsv"' _ "$work/pre.out" "$log" "$state" "$SVP_SESSION_DIR"
: >"$state/apps"
: >"$state/pvcs"
rm -f "$state/tgb"
new_session
FAKE_NO_ARGOCD=1 SVP_KARPENTER_LIMIT=0 bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 &&
  bad "pre-destroy.sh fails on an instance of Karpenter left on a cluster without its CRDs"
expect "pre-destroy.sh without Karpenter's CRDs still fails on its instance, named with the sweep" \
  sh -c 'grep -q "^FAIL  instances of Karpenter left: i-0karp running m7g.large default (aws/scripts/sweep.sh stg lists them" "$1"' _ "$work/pre.out"
: >"$state/nodeclaims"
: >"$state/karpenter-instances"

new_session
printf '%s\n' "5 svp-observability" >"$state/apps"
rm -f "$state/ack-up"
printf '%s\n' "RuleGroupsNamespace svp-obs svp-alerts ws-0fake" "AlertManagerDefinition svp-obs svp-alerts ws-0fake" >"$state/ack-crs"
bash "$here/pre-destroy.sh" stg >"$work/pre.out" 2>&1 || bad "pre-destroy.sh stg exits 0 with no pod of ACK ($(tail -n 3 "$work/pre.out"))"
expect "pre-destroy.sh with no pod of ACK: says so, lists what is left in AMP with the delete commands" \
  sh -c 'grep -q "^note  no Ready pod of ACK.s controller: it deletes nothing in AMP$" "$1" &&
    grep -q "^note  left in AMP: rule groups namespace svp-alerts of workspace ws-0fake; delete it: AWS_PROFILE=anhnv-stg aws amp delete-rule-groups-namespace --workspace-id ws-0fake --name svp-alerts --region ap-southeast-1$" "$1" &&
    grep -q "^note  left in AMP: alert manager definition of workspace ws-0fake; delete it: AWS_PROFILE=anhnv-stg aws amp delete-alert-manager-definition --workspace-id ws-0fake --region ap-southeast-1$" "$1"' _ "$work/pre.out"
expect "pre-destroy.sh with no pod of ACK: their finalizers cleared, then svp-observability deleted, and on to the end" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    [ ! -s "$2/ack-crs" ] && b "$1" "patch rulegroupsnamespaces.prometheusservice.services.k8s.aws svp-alerts --type merge" "delete application svp-observability" &&
    grep -q "patch alertmanagerdefinitions.prometheusservice.services.k8s.aws svp-alerts --type merge" "$1"' _ "$log" "$state"
expect "pre-destroy.sh with no pod of ACK marks pre-destroy-done" has_mark pre-destroy-done
rm -f "$state/ack-crs"
: >"$state/apps"

# --- ecr-warm.sh --------------------------------------------------------------------------------------------------
# Pinned digests whose hex holds long runs of decimal digits, as real ones may: none of them is taken for an account id.
d1=sha256:$(printf 'a123456789012345%.0s' 1 2 3 4) d2=sha256:$(printf 'b2%.0s' $(seq 32)) d3=sha256:$(printf 'c3%.0s' $(seq 32))
d4=sha256:$(printf 'd4%.0s' $(seq 32)) d5=sha256:$(printf 'e5%.0s' $(seq 32)) d9=sha256:$(printf 'f9%.0s' $(seq 32))
images=$work/images.txt
printf '%s\n' "docker.io/library/alpine:3.22@$d1" "ghcr.io/external-secrets/external-secrets:v1.1.0@$d2" \
  "quay.io/jetstack/cert-manager-controller:v1.21.2@$d3" "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0@$d4" \
  "public.ecr.aws/karpenter/controller:1.8.1@$d5" >"$images"
printf '%s\n' "docker-hub/library/alpine 3.22 $d1" "ghcr/external-secrets/external-secrets v1.1.0 $d2" \
  "quay/jetstack/cert-manager-controller v1.21.2 $d3" "k8s/kube-state-metrics/kube-state-metrics v2.17.0 $d4" \
  "ecr-public/karpenter/controller 1.8.1 $d5" >"$state/ecr-tags"
: >"$state/ecr-digests"
new_session
expect "ecr-warm.sh stg passes when every pinned digest is in the cache" bash "$here/ecr-warm.sh" stg "$images" >"$work/warm.out" 2>&1
expect "ecr-warm.sh: account first" sh -c 'grep -m1 "^aws " "$1" | grep -q "^aws sts get-caller-identity "' _ "$log"
expect "ecr-warm.sh: profile anhnv-stg alone" profiles_are anhnv-stg
expect "ecr-warm.sh pulls each image by tag through the cache repository of its registry, in the home region" \
  sh -c 'for r in "docker-hub/library/alpine 3.22" "ghcr/external-secrets/external-secrets v1.1.0" "quay/jetstack/cert-manager-controller v1.21.2" \
      "k8s/kube-state-metrics/kube-state-metrics v2.17.0" "ecr-public/karpenter/controller 1.8.1"; do
      set -- "$1" $r
      grep -q "^aws ecr batch-get-image --repository-name $2 --image-ids imageTag=$3 --accepted-media-types application/vnd.oci.image.index.v1+json .* --output json --region ap-southeast-1$" "$1" || exit 1
    done' _ "$log"
expect "ecr-warm.sh marks ecr-warmed and names root gitops as next" \
  sh -c 'grep -q "next: aws/scripts/tf.sh stg gitops init, plan, apply" "$1"' _ "$work/warm.out"
expect "ecr-warm.sh marks ecr-warmed" has_mark ecr-warmed
# The tag moved upstream after the digest was pinned.
printf '%s\n' "docker-hub/library/alpine 3.22 $d9" >"$state/ecr-tags.moved"
grep -v '^docker-hub/library/alpine ' "$state/ecr-tags" >>"$state/ecr-tags.moved"
mv "$state/ecr-tags.moved" "$state/ecr-tags"
new_session
expect "ecr-warm.sh fails when ECR holds another digest for the tag and not the pinned one" \
  sh -c '! bash "$1/ecr-warm.sh" stg "$2" >"$3" 2>&1' _ "$here" "$images" "$work/warm.out"
expect "ecr-warm.sh names the image, tag, pinned digest and the digest ECR holds, and no account id" \
  sh -c 'grep -q "^FAIL  docker.io/library/alpine:3.22: pinned digest $2 not in ECR docker-hub/library/alpine, which holds tag 3.22 at $3$" "$1" &&
    grep -q "^FAIL  1 image(s) not in ECR at their pinned digest" "$1" && ! grep "^FAIL" "$1" | grep -q 111111111111' _ "$work/warm.out" "$d1" "$d9"
expect "ecr-warm.sh: no ecr-warmed when an image is missing" no_mark ecr-warmed
echo "docker-hub/library/alpine $d1" >"$state/ecr-digests"
new_session
expect "ecr-warm.sh passes when the tag moved but the pinned digest is still in ECR, and says so" \
  sh -c 'bash "$1/ecr-warm.sh" stg "$2" >"$3" 2>&1 && grep -q "^note  docker.io/library/alpine:3.22: ECR holds tag 3.22 at $4, and the pinned $5 too$" "$3"' \
  _ "$here" "$images" "$work/warm.out" "$d9" "$d1"
grep -v '^ecr-public/' "$state/ecr-tags" >"$state/ecr-tags.new"; mv "$state/ecr-tags.new" "$state/ecr-tags"
new_session
expect "ecr-warm.sh fails on a tag the cache cannot pull, with the reason, account id masked" \
  sh -c '! bash "$1/ecr-warm.sh" stg "$2" >"$3" 2>&1 &&
    grep -q "^FAIL  public.ecr.aws/karpenter/controller:1.8.1: the cache ecr-public/karpenter/controller has no tag 1.8.1: ImageNotFound: Requested image not found in registry <account>$" "$3" &&
    ! grep "^FAIL" "$3" | grep -q 111111111111' _ "$here" "$images" "$work/warm.out"
for bad_line in "ghcr.io/anhnvcoder/svp-backend/gateway:v1@$d1" "docker.io/library/alpine@$d1" "docker.io/library/alpine:3.22@sha256:abc" \
  "example.com/team/app:1.0@$d1"; do
  printf '%s\n' "docker.io/library/alpine:3.22@$d1" "$bad_line" >"$work/bad.txt"
  new_session
  expect "ecr-warm.sh refuses line '$bad_line' before any call" \
    sh -c '! bash "$1/ecr-warm.sh" stg "$2" >"$3" 2>&1 && grep -q "^FAIL  $2:2" "$3" && [ ! -s "$4" ]' _ "$here" "$work/bad.txt" "$work/warm.out" "$log"
done
new_session
expect "ecr-warm.sh refuses a list that is not there" \
  sh -c '! bash "$1/ecr-warm.sh" stg "$2/none.txt" >"$3" 2>&1 && grep -q "^FAIL  no readable list" "$3" && [ ! -s "$4" ]' _ "$here" "$work" "$work/warm.out" "$log"
clear_log
expect "ecr-warm.sh --print prd shows the pull and the check with profile and region, and calls nothing" \
  sh -c 'bash "$1/ecr-warm.sh" --print prd "$2" >"$3" 2>&1 && [ ! -s "$4" ] &&
    grep -q "^+ AWS_PROFILE=anhnv-prd aws ecr batch-get-image --repository-name docker-hub/library/alpine --image-ids imageTag=3.22 .*--region ap-southeast-1$" "$3" &&
    grep -q "^+ AWS_PROFILE=anhnv-prd aws ecr describe-images --repository-name docker-hub/library/alpine --image-ids imageDigest=$5 --output json --region ap-southeast-1$" "$3"' \
  _ "$here" "$images" "$work/warm.out" "$log" "$d1"
unset SVP_SESSION_DIR

# --- measure.sh ---------------------------------------------------------------------------------------------------
start_measure() {
  new_session
  echo "{\"name\":\"svp-$1\",\"domain\":\"$(zone_of "$1")\",\"edgeTargetGroupArn\":\"arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:targetgroup/svp-$1-envoy/2c3d\"}" >"$SVP_SESSION_DIR/cluster-values.json"
  printf '%s\t%s\t%s\n' 2026-10-31T00:00:00Z "${2:-$(date +%s)}" session-start >"$SVP_SESSION_DIR/timeline.tsv"
  rm -f "$state/node-calls" "$state/job-calls"
}
start_measure stg
FAKE_K6_FAIL_AT=2 bash "$here/measure.sh" stg >"$work/measure.out" 2>&1 || bad "measure.sh stg exits 0 with a failed level ($(tail -n 3 "$work/measure.out"))"
expect "measure.sh: smoke and seed with the domain" grep -q 'make .* eks-seed CONTEXT=svp-stg DOMAIN=stg.aws.svp.example' "$log"
expect "measure.sh: level 1 passes, level 2 fails" test "$(cut -f1,2 "$SVP_SESSION_DIR/k6-levels.tsv" | tr '\t\n' ': ')" = "1:pass 2:fail "
expect "measure.sh: no level after the failed one" test -z "$(grep -- '--pods 4' "$log")"
expect "measure.sh: eks-rl-reset before each level's start" before "$log" 'eks-rl-reset' 'run.sh .*--pods 1 .*start'
expect "measure.sh: summaries copied into the session" test -s "$SVP_SESSION_DIR/k6-1/summaries/pod-0.json"
expect "measure.sh: nodes and kubectl top sampled" test -s "$SVP_SESSION_DIR/k6-1/top-nodes.tsv"

start_measure stg
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

start_measure stg "$(($(date +%s) - 10000))"
bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 || bad "measure.sh past 3 hours exits 0"
expect "measure.sh: no level starts that would end past 3 hours" test -z "$(grep 'run.sh .* start' "$log")"

start_measure stg
FAKE_JOB_FLAKY=1 FAKE_K6_FAIL_AT=2 bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 ||
  bad "measure.sh with a failed poll of the Job exits 0 ($(tail -n 3 "$work/measure.out"))"
expect "measure.sh: a failed poll of the Job is noted" grep -q 'kubectl get job svp-load/svp-k6 failed .*waiting on' "$work/measure.out"
expect "measure.sh: after a failed poll it polls again before reading the logs" \
  test "$(awk '/get job svp-k6/ { n++ } /run\.sh .*logs/ { print n; exit }' "$log")" = 2
expect "measure.sh: the level with a failed poll still passes" test "$(head -n 1 "$SVP_SESSION_DIR/k6-levels.tsv" | cut -f1,2 | tr '\t' ':')" = 1:pass
start_measure stg
rc=0
FAKE_JOB_DOWN=1 SVP_MEASURE_LEVEL_LIMIT=1 bash "$here/measure.sh" stg --from 1 >"$work/measure.out" 2>&1 || rc=$?
expect "measure.sh: a Job no read reaches exits 1" test "$rc" = 1
expect "measure.sh: that level is a tooling error, not a failed level" test "$(cut -f1,2 "$SVP_SESSION_DIR/k6-levels.tsv" | tr '\t\n' ': ')" = "1:error "
expect "measure.sh: the error says the Job could not be read and how to go on" \
  sh -c 'grep -q "^FAIL  level 1: Job svp-load/svp-k6 could not be read" "$1" && grep -q "measure.sh stg --from 1" "$1"' _ "$work/measure.out"
expect "measure.sh: the unread Job is not deleted (one delete, before the level's start)" \
  sh -c '[ "$(grep -c "^run\.sh .* delete$" "$1")" = 1 ] && [ "$(grep -n "^run\.sh " "$1" | tail -n 1 | grep -c -- "--pods 1 .*start$")" = 1 ]' _ "$log"
expect "measure.sh: no logs read and no level after the error" test -z "$(grep -E 'run\.sh .* logs$|--pods 2 ' "$log")"
expect "measure.sh: no measure-end after the error" no_mark measure-end
clear_log
expect "measure.sh stops on another account before any other command" \
  sh -c '! FAKE_ACCOUNT=000000000000 bash "$1/measure.sh" stg >/dev/null 2>&1 && [ -s "$2" ] && ! grep -qv "^aws sts get-caller-identity " "$2"' _ "$here" "$log"

start_measure prd
expect "measure.sh prd runs the smoke alone" bash "$here/measure.sh" prd >"$work/measure.out" 2>&1
expect "measure.sh prd: smoke through its domain, no seed, no k6" \
  sh -c 'grep -q "make .* eks-smoke CONTEXT=svp-prd DOMAIN=aws.svp.example " "$1" && ! grep -qE "eks-seed|run\.sh" "$1"' _ "$log"
expect "measure.sh prd --from refuses: no ladder" sh -c '! bash "$1/measure.sh" prd --from 2 >/dev/null 2>&1' _ "$here"
start_measure prd
expect "measure.sh prd refuses while the tunnel is closed, before the smoke" \
  sh -c '! FAKE_TUNNEL=closed bash "$1/measure.sh" prd >/dev/null 2>&1 && ! grep -q "^make " "$2"' _ "$here" "$log"

# --- sweep.sh -----------------------------------------------------------------------------------------------------
unset SVP_SESSION_DIR
for e in stg prd mgmt; do
  case $e in mgmt) p=anhnv-sso a=000000000000 s=bootstrap k=bootstrap,org,security-baseline,security ;;
    stg) p=anhnv-stg a=111111111111 s=baseline k=baseline,security-baseline ;;
    prd) p=anhnv-prd a=222222222222 s=baseline k=baseline,security-baseline ;; esac
  z=$(zone_of "$e")
  clear_log
  expect "sweep.sh $e passes with what the account keeps alone" bash "$here/sweep.sh" "$e" >"$work/sweep.out" 2>&1
  expect "sweep.sh $e: profile $p alone" profiles_are "$p"
  expect "sweep.sh $e prints the state bucket and its KMS key as kept (Stack=$s)" \
    sh -c 'grep -q "^kept  bucket svp-tfstate-$2-ap-southeast-1 (Stack=$3)$" "$1" && grep -q "^kept  KMS key key-state (Stack=$3)$" "$1"' _ "$work/sweep.out" "$a" "$s"
  if [ -n "$z" ]; then
    expect "sweep.sh $e prints the zone $z as kept" grep -q "^kept  hosted zone $z " "$work/sweep.out"
  fi
  expect "sweep.sh $e prints the key of a destroyed root as pending deletion" grep -q '^pending deletion  KMS key key-eks, deleted on 2026-11-12' "$work/sweep.out"
  expect "sweep.sh $e keeps the stacks that live between sessions, aws/baseline's in every account: $k" \
    grep -q "^ok    nothing left in account $e but what it keeps (Stack=$k) and keys pending deletion$" "$work/sweep.out"
  if [ "$s" = baseline ]; then
    expect "sweep.sh $e prints what aws/accounts/$e keeps as kept: AMP and Grafana workspaces, cache rules, ECR repositories, OIDC provider, roles of CI" \
      sh -c 'grep -q "^kept  AMP workspace ws-0fake svp-$2 (Stack=baseline)$" "$1" && grep -q "^kept  Grafana workspace g-0fake svp-$2 (Stack=baseline)$" "$1" &&
        [ "$(grep -c "^kept  ECR pull-through cache rule " "$1")" = 5 ] && grep -q "^kept  ECR pull-through cache rule k8s (upstream.example)$" "$1" &&
        grep -q "^kept  ECR repository svp-backend/gateway (Stack=baseline)$" "$1" &&
        grep -q "^kept  ECR repository docker-hub/library/alpine (made by the pull-through cache)$" "$1" &&
        grep -q "^kept  IAM OIDC provider arn:aws:iam::$3:oidc-provider/token.actions.githubusercontent.com (Stack=baseline)$" "$1" &&
        grep -q "^kept  IAM role svp-ci-ecr-release-backend (Stack=baseline)$" "$1" && grep -q "^kept  IAM role svp-ci-ecr-rescan-backend (Stack=baseline)$" "$1" &&
        grep -q "^kept  secret ecr-pullthroughcache/ghcr (Stack=baseline)$" "$1" && grep -q "^kept  secret ecr-pullthroughcache/docker-hub (Stack=baseline)$" "$1" &&
        ! grep -qE "other-project|other.example|other-role|ws-other" "$1"' _ "$work/sweep.out" "$e" "$a"
  fi
  if [ -n "$z" ]; then
    expect "sweep.sh $e prints the EBS key of aws/baseline as kept (Stack=security-baseline)" \
      grep -q '^kept  KMS key key-ebs (Stack=security-baseline)$' "$work/sweep.out"
  fi
  expect "sweep.sh $e reports neither another project's Malware Protection plan nor GuardDuty's own EventBridge rule" \
    sh -c 'grep -q "^ok    GuardDuty Malware Protection plans: none$" "$1" && ! grep -q "plan-other\|DO-NOT-DELETE" "$1"' _ "$work/sweep.out"
  expect "sweep.sh $e reads WAF of CloudFront in us-east-1" grep -q '^aws wafv2 list-web-acls --scope CLOUDFRONT --output json --region us-east-1$' "$log"
  expect "sweep.sh $e reads the pricing plan subscriptions in us-east-1" \
    sh -c 'grep -q "^aws pricing-plan-manager list-subscriptions --output json --region us-east-1$" "$1"' _ "$log"
  expect "sweep.sh $e lists the pricing plan subscriptions before the CloudFront distributions" \
    before "$log" '^aws pricing-plan-manager list-subscriptions ' '^aws cloudfront list-distributions '
  expect "sweep.sh $e reads in us-east-1 the certificates, log deliveries, alarms, log groups, SNS topics and KMS keys" \
    sh -c 'for c in "acm list-certificates" "logs describe-deliveries" "logs describe-delivery-sources" "logs describe-delivery-destinations" \
      "cloudwatch describe-alarms" "logs describe-log-groups" "resourcegroupstaggingapi get-resources --resource-type-filters logs:log-group" \
      "sns list-topics" "kms list-aliases" "resourcegroupstaggingapi get-resources --resource-type-filters kms:key"; do
        grep -q "^aws $c .*--region us-east-1$" "$1" || exit 1; done' _ "$log"
  expect "sweep.sh $e reads the IAM OIDC providers and roles of CI, and their tags, in us-east-1 alone" \
    sh -c 'grep -q "^aws iam list-open-id-connect-providers --output json --region us-east-1$" "$1" &&
      grep -q "^aws iam list-roles --output json --region us-east-1$" "$1" && grep -q "^aws iam list-open-id-connect-provider-tags " "$1" &&
      [ -z "$(grep -E "^aws iam list-(open-id-connect-provider|role)" "$1" | grep -v -- "--region us-east-1$")" ]' _ "$log"
  expect "sweep.sh $e reads the certificates of every key type, in both regions" \
    test "$(grep -c '^aws acm list-certificates --includes keyTypes=[^ ]*EC_prime256v1' "$log")" = 2
  if [ "$e" = prd ]; then
    expect "sweep.sh prd prints what aws/accounts/prd keeps in us-east-1 as kept (Stack=baseline): DNSSEC alarms, query log group, topic, keys" \
      sh -c 'grep -q "^kept  alarm svp-prd-dnssec-internal-failure (Stack=baseline)$" "$1" && grep -q "^kept  alarm svp-prd-dnssec-ksk-action-needed (Stack=baseline)$" "$1" &&
        grep -q "^kept  log group /aws/route53/aws.svp.example (Stack=baseline)$" "$1" &&
        grep -q "^kept  SNS topic arn:aws:sns:us-east-1:222222222222:svp-prd-dns-alarms (Stack=baseline)$" "$1" &&
        grep -q "^kept  KMS key key-dnssec (Stack=baseline)$" "$1" && grep -q "^kept  KMS key key-dns-alarms (Stack=baseline)$" "$1" &&
        grep -q "^ok    CloudWatch alarms in us-east-1: none$" "$1" && grep -q "^ok    CloudWatch log groups in us-east-1: none$" "$1" &&
        grep -q "^ok    SNS topics in us-east-1: none$" "$1" && grep -q "^ok    KMS keys in us-east-1: none$" "$1"' _ "$work/sweep.out"
  fi
  if [ -n "$z" ]; then
    expect "sweep.sh $e: the CAA record at the apex of $z stays with the zone" \
      sh -c 'grep -q "^ok    records of $2: none$" "$1" && grep -q "^kept  hosted zone $2 .*NS, SOA and CAA at its apex" "$1"' _ "$work/sweep.out" "$z"
  fi
done
expect "sweep.sh mgmt: no hosted zone, no call to Route 53" \
  sh -c '! grep -q "hosted zone" "$1" && ! grep -q "^aws route53 " "$2"' _ "$work/sweep.out" "$log"
clear_log
expect "sweep.sh prd keeps the NS records delegating stg.aws.svp.example and the CAA at the apex, fails on the records of root env and a CAA below" \
  sh -c '! FAKE_LEFTOVER=record bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  records of aws.svp.example: 4 left$" "$2" &&
    grep -q "^        api.aws.svp.example. A$" "$2" && grep -q "^        api.aws.svp.example. AAAA$" "$2" &&
    grep -q "^        api.aws.svp.example. CAA$" "$2" && grep -q "^        _0fake.api.aws.svp.example. CNAME$" "$2" &&
    ! grep -q "^        stg.aws.svp.example. NS" "$2" && ! grep -q "^        aws.svp.example. CAA" "$2" &&
    grep -q "^kept  hosted zone aws.svp.example .*NS records below it" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh needs no Terraform state" test -z "$(grep '^terraform ' "$log")"
expect "sweep.sh only reads (describe, list, get)" \
  test -z "$(grep '^aws ' "$log" | awk '{ print $3 }' | grep -vE '^(describe|list|get)-' || true)"
expect "sweep.sh fails on a leftover EBS volume, names it and the command that deletes it" \
  sh -c '! FAKE_LEFTOVER=volume bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "vol-0fake available 10 GiB storage-loki-0" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws ec2 delete-volume --volume-id vol-0fake --region ap-southeast-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh fails on a secret scheduled for deletion, and says so" \
  sh -c '! FAKE_LEFTOVER=secret bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "svp/stg/web (scheduled for deletion since" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg keeps the pull-through cache secrets beside a leftover secret: kept, not listed, no delete command" \
  sh -c '! FAKE_LEFTOVER=secret bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  Secrets Manager secrets (scheduled for deletion included): 1 left$" "$2" &&
    grep -q "^kept  secret ecr-pullthroughcache/ghcr (Stack=baseline)$" "$2" && ! grep -q "^        ecr-pullthroughcache" "$2" &&
    ! grep -q "delete-secret --secret-id ecr-pullthroughcache" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on the final snapshot, with its delete command" \
  sh -c '! FAKE_LEFTOVER=snapshot bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  RDS snapshots: 1 left" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-prd aws rds delete-db-snapshot --db-snapshot-identifier svp-prd-final-0a1b2c3d --region ap-southeast-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on a retained automated backup" \
  sh -c '! FAKE_LEFTOVER=backup bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  RDS automated backups: 1 left" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on a KMS key of the root not pending deletion" \
  sh -c '! FAKE_LEFTOVER=kms bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  KMS keys: 1 left" "$2" && grep -q "key-eks Enabled Stack=prd" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd prints the key of MSK as pending deletion, not counted" \
  sh -c 'bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^pending deletion  KMS key key-msk, deleted on 2026-11-15" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on the key of MSK not pending deletion" \
  sh -c '! FAKE_LEFTOVER=msk-kms bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  KMS keys: 1 left" "$2" && grep -q "key-msk Enabled Stack=prd" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on the alias of MSK left on its key pending deletion, with the delete-alias command" \
  sh -c '! FAKE_LEFTOVER=msk-alias bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  KMS aliases on keys pending deletion: 1 left" "$2" &&
    grep -q "^        alias/svp-prd-msk-scram on key key-msk pending deletion$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-prd aws kms delete-alias --alias-name alias/svp-prd-msk-scram --region ap-southeast-1$" "$2" &&
    grep -q "^ok    KMS keys: none" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd counts no alias on a key not pending deletion" \
  sh -c '! FAKE_LEFTOVER=msk-kms bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^ok    KMS aliases on keys pending deletion: none" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on an MSK cluster and its configuration, the cluster first, each with its delete command" \
  sh -c '! FAKE_LEFTOVER=msk bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  MSK clusters: 1 left" "$2" && grep -q "^FAIL  MSK configurations: 1 left" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws kafka delete-cluster --cluster-arn arn:aws:kafka:ap-southeast-1:111111111111:cluster/svp-stg/c-fake --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws kafka delete-configuration --arn arn:aws:kafka:ap-southeast-1:111111111111:configuration/svp-stg-4-1-x-kraft/cfg-fake --region ap-southeast-1$" "$2" &&
    ! grep -q "arn:other" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on an ElastiCache replication group, user group, user, subnet and parameter group, leaves AWS's own" \
  sh -c '! FAKE_LEFTOVER=elasticache bash "$1/sweep.sh" stg >"$2" 2>&1 &&
    grep -q "^FAIL  ElastiCache replication groups: 1 left" "$2" && grep -q "^FAIL  ElastiCache user groups: 1 left" "$2" &&
    grep -q "^FAIL  ElastiCache users: 1 left" "$2" && grep -q "^FAIL  ElastiCache subnet groups: 1 left" "$2" &&
    grep -q "^FAIL  ElastiCache parameter groups: 1 left" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws elasticache delete-replication-group --replication-group-id svp-stg --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws elasticache delete-user --user-id svp-stg-gateway --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws elasticache delete-cache-parameter-group --cache-parameter-group-name svp-stg-valkey9 --region ap-southeast-1$" "$2" &&
    ! grep -qE "^        (default|default\.valkey9)( |$)" "$2"' _ "$here" "$work/sweep.out"
# AWS refuses to delete what is in use: the list follows the order the deletes must run in.
expect "sweep.sh --print stg runs" sh -c 'bash "$1/sweep.sh" --print stg >"$2" 2>&1' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg lists the MSK clusters before their configurations" \
  before "$work/sweep.out" ' aws kafka list-clusters-v2 ' ' aws kafka list-configurations '
expect "sweep.sh --print stg lists the replication groups before the user groups" \
  before "$work/sweep.out" ' elasticache describe-replication-groups ' ' elasticache describe-user-groups '
expect "sweep.sh --print stg lists the user groups before the users" \
  before "$work/sweep.out" ' elasticache describe-user-groups ' ' elasticache describe-users '
expect "sweep.sh stg fails on a SCRAM secret of MSK found by its name, with the delete that skips recovery" \
  sh -c '! FAKE_LEFTOVER=msk-secret bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^        AmazonMSK_svp-stg-svp-admin$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws secretsmanager delete-secret --secret-id AmazonMSK_svp-stg-svp-admin --force-delete-without-recovery --region ap-southeast-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on the broker log group of MSK" \
  sh -c '! FAKE_LEFTOVER=msk-log bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  CloudWatch log groups: 1 left" "$2" && grep -q "^        /aws/msk/svp-prd$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh prd fails on the web ACLs of web, api and media left in us-east-1" \
  sh -c '! FAKE_LEFTOVER=waf bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  WAF web ACLs of CloudFront: 3 left" "$2" &&
    grep -q "^        svp-prd-web waf-web$" "$2" && grep -q "^        svp-prd-api waf-api$" "$2" && grep -q "^        svp-prd-media waf-fake$" "$2" &&
    grep -q "^          delete: docs/runbooks/session-stg.md#lệnh-xoá-tay-theo-loại (delete-web-acl takes the lock token" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on a pricing plan subscription, with its resources and the runbook's manual deletion" \
  sh -c '! FAKE_LEFTOVER=subscription bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudFront pricing plan subscriptions: 1 left" "$2" &&
    grep -q "^        arn:aws:pricingplanmanager::111111111111:subscription/sub-fake CloudFront FREE ACTIVE arn:aws:cloudfront::111111111111:distribution/EFAKE,arn:aws:wafv2:" "$2" &&
    grep -q "^          delete: docs/runbooks/session-stg.md#lệnh-xoá-tay-theo-loại (cancel the plan first" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg does not fail on a plan whose cancellation is scheduled, and prints it as kept" \
  sh -c 'FAKE_LEFTOVER=cancellation bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^ok    CloudFront pricing plan subscriptions: none" "$2" &&
    grep -q "^kept  pricing plan arn:aws:pricingplanmanager::111111111111:subscription/sub-paid (CloudFront PRO): cancellation scheduled 2026-12-01T00:00:00Z$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg does not call a clean answer from a pricing plan API that failed: could not be read, not none" \
  sh -c '! FAKE_LEFTOVER=subscription-error bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudFront pricing plan subscriptions: could not be read" "$2" &&
    ! grep -q "CloudFront pricing plan subscriptions: none" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg shows list-subscriptions with --region us-east-1" \
  sh -c 'bash "$1/sweep.sh" --print stg >"$2" 2>&1 && grep -q "^+ AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions --output json --region us-east-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg prints list-subscriptions before list-distributions" \
  before "$work/sweep.out" '^\+ AWS_PROFILE=anhnv-stg aws pricing-plan-manager list-subscriptions ' '^\+ AWS_PROFILE=anhnv-stg aws cloudfront list-distributions '
expect "sweep.sh stg fails on what Karpenter made outside the state, each with the commands that delete it" \
  sh -c '! FAKE_LEFTOVER=karpenter bash "$1/sweep.sh" stg >"$2" 2>&1 &&
    grep -q "^        i-0karp running m7g.large$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws ec2 delete-launch-template --launch-template-id lt-0karp --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws iam remove-role-from-instance-profile --instance-profile-name svp-stg_1234567890 --role-name svp-stg-karpenter-node --region ap-southeast-1 && AWS_PROFILE=anhnv-stg aws iam delete-instance-profile --instance-profile-name svp-stg_1234567890 --region ap-southeast-1$" "$2" &&
    ! grep -q "other-profile" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws sqs delete-queue --queue-url https://sqs.ap-southeast-1.amazonaws.com/111111111111/svp-stg-karpenter --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws events remove-targets --rule KarpenterSpotInterrupt-2026 --ids KarpenterInterruptionQueueTarget --region ap-southeast-1 && AWS_PROFILE=anhnv-stg aws events delete-rule --name KarpenterSpotInterrupt-2026 --region ap-southeast-1$" "$2" &&
    grep -q "^FAIL  EC2 launch templates: 1 left$" "$2" && grep -q "^FAIL  IAM instance profiles of Karpenter: 1 left$" "$2" &&
    grep -q "^FAIL  SQS queues: 1 left$" "$2" && grep -q "^FAIL  EventBridge rules of Karpenter: 1 left$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on an alarm of the lab and the target tracking alarm of MSK, leaves another one's" \
  sh -c '! FAKE_LEFTOVER=alarm bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudWatch alarms: 2 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws cloudwatch delete-alarms --alarm-names svp-stg-rds-storage-low --region ap-southeast-1$" "$2" &&
    grep -q "^        TargetTracking-arn:aws:kafka:ap-southeast-1:111111111111:cluster/svp-stg/c-fake-AlarmHigh-0a1b$" "$2" && ! grep -q "other-alarm" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the Malware Protection plan of its uploads bucket, with the command that deletes it" \
  sh -c '! FAKE_LEFTOVER=malware bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  GuardDuty Malware Protection plans: 1 left$" "$2" &&
    grep -q "^        plan-svp svp-stg-uploads-111111111111-ap-southeast-1 ACTIVE$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws guardduty delete-malware-protection-plan --malware-protection-plan-id plan-svp --region ap-southeast-1$" "$2" &&
    ! grep -q "plan-other\|DO-NOT-DELETE" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg lists the Malware Protection plans before the buckets" \
  sh -c 'bash "$1/sweep.sh" --print stg >"$2" 2>&1' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg: list-malware-protection-plans before list-buckets" \
  before "$work/sweep.out" ' aws guardduty list-malware-protection-plans ' ' aws s3api list-buckets '
expect "sweep.sh --print stg: VPC endpoints before network interfaces and security groups" \
  sh -c 'b() { a=$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1); c=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1); [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; }
    b "$1" " ec2 describe-vpc-endpoints " " ec2 describe-network-interfaces " && b "$1" " ec2 describe-vpc-endpoints " " ec2 describe-security-groups "' _ "$work/sweep.out"
expect "sweep.sh prd fails on the interface endpoint guardduty-data, not on an endpoint already deleted" \
  sh -c '! FAKE_LEFTOVER=endpoint bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  VPC endpoints: 1 left$" "$2" &&
    grep -q "^        vpce-0fake Interface com.amazonaws.ap-southeast-1.guardduty-data available$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-prd aws ec2 delete-vpc-endpoints --vpc-endpoint-ids vpce-0fake --region ap-southeast-1$" "$2" &&
    ! grep -q "vpce-0gone" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on a record of its zone" \
  sh -c '! FAKE_LEFTOVER=record bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "api.stg.aws.svp.example. A" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the distribution of web, found by its comment (its origin is the ALB's), not on another one's" \
  sh -c '! FAKE_LEFTOVER=distribution bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudFront distributions: 1 left$" "$2" &&
    grep -q "^        EWEB Deployed enabled=false d0web.cloudfront.net svp-stg-web$" "$2" && ! grep -q EOTHER "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the VPC origin of the edge, with the runbook's deletion" \
  sh -c '! FAKE_LEFTOVER=vpc-origin bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudFront VPC origins: 1 left$" "$2" &&
    grep -q "^        vo_0fake svp-stg-edge Deployed$" "$2" && ! grep -q vo_other "$2" &&
    grep -q "^          delete: docs/runbooks/session-stg.md#lệnh-xoá-tay-theo-loại (after the distributions that use it: delete-vpc-origin takes the ETag" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the group CloudFront made in the VPC for a VPC origin, as a kind of its own" \
  sh -c '! FAKE_LEFTOVER=vpc-origin-sg bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  security groups of CloudFront VPC origins: 1 left$" "$2" &&
    grep -q "^        sg-0cf CloudFront-VPCOrigins-Service-SG-0fake vpc-0fake$" "$2" && grep -q "^ok    security groups: none$" "$2" &&
    grep -q "^          delete: docs/runbooks/session-stg.md#lệnh-xoá-tay-theo-loại (CloudFront deletes it after its VPC origin" "$2" &&
    grep -q "ec2 describe-security-groups --filters Name=vpc-id,Values=vpc-0fake " "$3"' _ "$here" "$work/sweep.out" "$log"
expect "sweep.sh stg fails on the ALB and the target group of the edge (tag Project=svp), not on another one's" \
  sh -c '! FAKE_LEFTOVER=edge bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  ELBv2 load balancers: 1 left$" "$2" && grep -q "^FAIL  ELBv2 target groups: 1 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:loadbalancer/app/svp-stg-edge/0a1b --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws elbv2 delete-target-group --target-group-arn arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:targetgroup/svp-stg-envoy/2c3d --region ap-southeast-1$" "$2" &&
    ! grep -q "app/other" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the certificates of the lab in both regions, each deleted in its own, and leaves an untagged one" \
  sh -c '! FAKE_LEFTOVER=cert bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  ACM certificates: 1 left$" "$2" && grep -q "^FAIL  ACM certificates in us-east-1: 1 left$" "$2" &&
    grep -q "^        arn:aws:acm:us-east-1:111111111111:certificate/svp-fake stg.aws.svp.example Stack=stg$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws acm delete-certificate --certificate-arn arn:aws:acm:ap-southeast-1:111111111111:certificate/svp-fake --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws acm delete-certificate --certificate-arn arn:aws:acm:us-east-1:111111111111:certificate/svp-fake --region us-east-1$" "$2" &&
    ! grep -q "certificate/other" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the delivery, delivery source and delivery destination of CloudFront logs, deleted in us-east-1" \
  sh -c '! FAKE_LEFTOVER=delivery bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudWatch Logs deliveries in us-east-1: 1 left$" "$2" &&
    grep -q "^FAIL  CloudWatch Logs delivery sources in us-east-1: 1 left$" "$2" && grep -q "^FAIL  CloudWatch Logs delivery destinations in us-east-1: 1 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws logs delete-delivery --id dlv-fake --region us-east-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws logs delete-delivery-source --name svp-stg-web --region us-east-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws logs delete-delivery-destination --name svp-cloudfront-stg --region us-east-1$" "$2" &&
    ! grep -q "other-source\|other-delivery" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg lists the deliveries before their sources" \
  sh -c 'bash "$1/sweep.sh" --print stg >"$2" 2>&1' _ "$here" "$work/sweep.out"
expect "sweep.sh --print stg: describe-deliveries before describe-delivery-sources, both in us-east-1" \
  before "$work/sweep.out" '^\+ AWS_PROFILE=anhnv-stg aws logs describe-deliveries --output json --region us-east-1$' '^\+ AWS_PROFILE=anhnv-stg aws logs describe-delivery-sources --output json --region us-east-1$'
expect "sweep.sh prd fails on an alarm and a topic of root env in us-east-1, deleted there, and still keeps the baseline's" \
  sh -c '! FAKE_LEFTOVER=us-east-1 bash "$1/sweep.sh" prd >"$2" 2>&1 && grep -q "^FAIL  CloudWatch alarms in us-east-1: 1 left$" "$2" &&
    grep -q "^FAIL  SNS topics in us-east-1: 1 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-prd aws cloudwatch delete-alarms --alarm-names svp-prd-edge-5xx --region us-east-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-prd aws sns delete-topic --topic-arn arn:aws:sns:us-east-1:222222222222:svp-prd-edge-alarms --region us-east-1$" "$2" &&
    grep -q "^kept  alarm svp-prd-dnssec-internal-failure (Stack=baseline)$" "$2" && grep -q "^ok    CloudWatch alarms: none$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the alarm topic of root env in the home region, not on another one's" \
  sh -c '! FAKE_LEFTOVER=sns bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  SNS topics: 1 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws sns delete-topic --topic-arn arn:aws:sns:ap-southeast-1:111111111111:svp-stg-alarms --region ap-southeast-1$" "$2" &&
    ! grep -q "other-topic" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on a tagged log group whose Stack is not kept" \
  sh -c '! FAKE_LEFTOVER=log-group bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  CloudWatch log groups: 1 left$" "$2" &&
    grep -q "^        /aws/rds/svp-stg/postgresql$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the interface endpoint and the endpoints group of root env found by their names" \
  sh -c '! FAKE_LEFTOVER=interface-endpoint bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  VPC endpoints: 1 left$" "$2" &&
    grep -q "^        vpce-0sts Interface com.amazonaws.ap-southeast-1.sts available$" "$2" &&
    grep -q "^FAIL  security groups: 1 left$" "$2" && grep -q "^        sg-0ep svp-stg-endpoints$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws ec2 delete-security-group --group-id sg-0ep --region ap-southeast-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on the rule groups namespaces of ACK left in the AMP workspace, with their delete commands" \
  sh -c '! FAKE_LEFTOVER=amp-rules bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  AMP rule groups namespaces: 2 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws amp delete-rule-groups-namespace --name svp-alerts --workspace-id ws-0fake --region ap-southeast-1$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws amp delete-rule-groups-namespace --name slo-generated --workspace-id ws-0fake --region ap-southeast-1$" "$2" &&
    grep -q "^kept  AMP workspace ws-0fake svp-stg (Stack=baseline)$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on a release repository of a Stack it does not keep" \
  sh -c '! FAKE_LEFTOVER=ecr bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  ECR repositories: 1 left$" "$2" &&
    grep -q "^        svp-backend/old Stack=stg$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws ecr delete-repository --repository-name svp-backend/old --force --region ap-southeast-1$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh mgmt fails on a cache rule and the repository it made: no account keeps them but the environments'" \
  sh -c '! FAKE_LEFTOVER=cache bash "$1/sweep.sh" mgmt >"$2" 2>&1 && grep -q "^FAIL  ECR pull-through cache rules: 1 left$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-sso aws ecr delete-pull-through-cache-rule --ecr-repository-prefix k8s --region ap-southeast-1$" "$2" &&
    grep -q "^FAIL  ECR repositories: 1 left$" "$2" && grep -q "^        k8s/pause$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stg fails on an OIDC provider of root env, keeps GitHub's" \
  sh -c '! FAKE_LEFTOVER=oidc bash "$1/sweep.sh" stg >"$2" 2>&1 && grep -q "^FAIL  IAM OIDC providers: 1 left$" "$2" &&
    grep -q "^        arn:aws:iam::111111111111:oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/0FAKE Stack=stg$" "$2" &&
    grep -q "delete: AWS_PROFILE=anhnv-stg aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::111111111111:oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/0FAKE --region us-east-1$" "$2" &&
    grep -q "^kept  IAM OIDC provider .*token.actions.githubusercontent.com (Stack=baseline)$" "$2"' _ "$here" "$work/sweep.out"
expect "sweep.sh stops on another account before any other command" \
  sh -c '! FAKE_ACCOUNT=000000000000 bash "$1/sweep.sh" stg >/dev/null 2>&1' _ "$here"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
