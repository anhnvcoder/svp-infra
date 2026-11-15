#!/usr/bin/env bash
# Read-only checks of what the one-time setup runbooks built, in place of the commands typed by hand after each apply:
# org, backup, subscriptions (SNS email confirmation), dnssec (prd zone), cost (Cost Explorer by service). Nothing is
# created, changed or tagged; every check prints one line, ok, FAIL or note, and a FAIL does not stop the next check.

# Each check runs under the profile its runbook names: the environment's own, or one of profiles.sh after check_account
# of that profile. A note is what a script cannot see (a console page) or a value to compare by eye.

# Usage: aws/scripts/verify.sh [--print] org | backup
#        aws/scripts/verify.sh [--print] subscriptions mgmt|stg|prd
#        aws/scripts/verify.sh [--print] dnssec
#        aws/scripts/verify.sh [--print] cost mgmt|stg|prd|backup [START yyyy-mm-dd]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=aws/scripts/profiles.sh
. "$(dirname "$0")/profiles.sh"
printing && shift
usage="usage: $(basename "$0") [--print] org|backup | subscriptions mgmt|stg|prd | dnssec | cost mgmt|stg|prd|backup [START]"
sub=${1:-}
[ $# -ge 1 ] || fail "$usage"
shift
case $sub:$# in
  org:0 | backup:0) env_arg mgmt any ;;
  dnssec:0) env_arg prd ;;
  subscriptions:1) env_arg "$1" any ;;
  cost:1 | cost:2) if [ "$1" = backup ]; then env_arg mgmt any; else env_arg "$1" any; fi ;;
  *) fail "$usage" ;;
esac

failures=0
# Filled by load_org and load_ou_json under anhnv-sso; empty when that profile fails: each check needing them says so.
active='' root_id='' org_id='' ou_json=''
# bad MESSAGE: a FAIL of the script itself (outside a check), counted here.
bad() {
  printf 'FAIL  %s\n' "$*" >&2
  failures=$((failures + 1))
}
# chk FUNCTION [ARG...]: runs one check in a subshell so that its FAIL (an exit 1) does not stop the next one. The
# subshell runs in an if, where errexit is off: every command of a check that can fail ends in || fail.
chk() {
  if ( "$@" ); then :; else failures=$((failures + 1)); fi
}

# use_profile PROFILE: the profile of the following commands, and its account checked against its variable; neither
# the account id nor the ARN of the caller is printed. Returns 1 (counted) when the account is wrong: skip that profile.
use_profile() {
  local line
  profile_arg "$1"
  if line=$(check_account); then
    [ -z "$line" ] || ok "profile $profile is the account of $env_name ($account_var)"
    return 0
  fi
  failures=$((failures + 1))
  return 1
}

# aws_in REGION ARGS...: aws in a region other than the two of lib.sh.
aws_in() {
  local r=$1
  shift
  run_ "AWS_PROFILE=$profile" aws "$@" --region "$r"
}

# need_id VAR: the 12 digits in the account variable VAR, a target of a command and not the account of the profile.
need_id() {
  local v=${!1:-}
  if printing; then
    printf '<%s>\n' "$1"
    return 0
  fi
  [[ $v =~ ^[0-9]{12}$ ]] || fail "set $1 to the 12 digits of the account (export $1=...; never in a committed file)"
  printf '%s\n' "$v"
}

# words: stdin with every run of white space as one space, none at either end.
words() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# missing TEXT WORD...: the WORDs that are no whitespace-separated token of TEXT, joined by spaces.
missing() {
  local w out='' t=$1
  shift
  t=" $(tr -s '[:space:]' ' ' <<<"$t") "
  for w in "$@"; do
    case $t in *" $w "*) ;; *) out="$out $w" ;; esac
  done
  printf '%s\n' "${out# }"
}

# account_key ID: the key of paid-features.json of the account with that id, from the account variables; empty if none.
account_key() {
  local p v
  for p in mgmt:MGMT stg:STG prd:PRD log-archive:LOG security:SECURITY backup:BACKUP; do
    v=SVP_AWS_${p#*:}_ACCOUNT_ID
    if [ "${!v:-}" = "$1" ]; then
      printf '%s\n' "${p%%:*}"
      return 0
    fi
  done
}

# standards REGION: Security Hub standards and the Config recorder of the profile in REGION, unless the account's cost
# flags (paid-features.json) turn the service off there.
standards() {
  local r=$1 hub cfg std rec st n
  hub=$(paid_feature "$env_name" security_hub) || return 1
  cfg=$(paid_feature "$env_name" config_recording) || return 1
  if ! std=$(aws_in "$r" securityhub get-enabled-standards \
    --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' --output text); then
    [ "$hub" = off ] || fail "securityhub get-enabled-standards in $r with profile $profile"
    std=
  fi
  rec=$(aws_in "$r" configservice describe-configuration-recorders \
    --query 'ConfigurationRecorders[].[name,recordingMode.recordingFrequency]' --output text) ||
    fail "configservice describe-configuration-recorders in $r with profile $profile"
  st=$(aws_in "$r" configservice describe-configuration-recorder-status \
    --query 'ConfigurationRecordersStatus[].[name,recording,lastStatus]' --output text) ||
    fail "configservice describe-configuration-recorder-status in $r with profile $profile"
  printing && return 0
  if [ "$hub" = off ]; then
    note "$profile $r: security_hub is off in paid-features.json, no standard expected"
  else
    n=$(grep -cE '(aws-foundational-security-best-practices/v/1\.0\.0|cis-aws-foundations-benchmark/v/5\.0\.0)[[:space:]]+READY$' \
      <<<"$std" || true)
    [ "$n" = 2 ] || fail "$profile $r: $n of the 2 standards (AWS Foundational 1.0.0, CIS 5.0.0) are READY (Security Hub can take 24 h)"
  fi
  if [ "$cfg" = off ]; then
    note "$profile $r: config_recording is off in paid-features.json, no recorder expected"
  else
    case $rec in *CONTINUOUS*) ;; *) fail "$profile $r: no Config recorder with CONTINUOUS recording" ;; esac
    case $(tr -s '[:space:]' ' ' <<<"$st") in
      *" True SUCCESS"*) ;;
      *) fail "$profile $r: the Config recorder is not recording with lastStatus SUCCESS" ;;
    esac
  fi
  ok "$profile $r: Security Hub standards and Config recorder as expected"
}

# --- org ---

# load_org: in the parent shell, as the management account: the ids of the ACTIVE accounts and the outputs of aws/org.
load_org() {
  local out
  active='' root_id='' org_id='' ou_json=''
  if out=$(aws_global_ organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text); then
    active=$(tr -s '[:space:]' ' ' <<<"$out")
  else
    bad "organizations list-accounts with profile $profile"
  fi
  root_id=$(tf_ "$infra_root/aws/org" output -raw root_id) || bad "terraform output root_id of aws/org (init it first)"
  org_id=$(tf_ "$infra_root/aws/org" output -raw organization_id) || bad "terraform output organization_id of aws/org"
  load_ou_json
  if printing; then root_id='<root_id>' org_id='<organization_id>'; fi
}

# load_ou_json: the output organizational_unit_ids of aws/org (OU name to id), in the parent shell.
load_ou_json() {
  ou_json=$(tf_ "$infra_root/aws/org" output -json organizational_unit_ids) ||
    bad "terraform output organizational_unit_ids of aws/org"
  if printing; then ou_json='{"Prod":"<Prod>","NonProd":"<NonProd>","Security":"<Security>"}'; fi
}

org_services() {
  local sec out miss
  sec=$(need_id SVP_AWS_SECURITY_ACCOUNT_ID) || return 1
  out=$(aws_global_ organizations list-delegated-services-for-account --account-id "$sec" \
    --query 'DelegatedServices[].ServicePrincipal' --output text) || fail "organizations list-delegated-services-for-account"
  printing && return 0
  miss=$(missing "$out" guardduty.amazonaws.com securityhub.amazonaws.com config.amazonaws.com \
    config-multiaccountsetup.amazonaws.com access-analyzer.amazonaws.com inspector2.amazonaws.com)
  [ -z "$miss" ] || fail "7a: svp-security is not the delegated administrator of: $miss (apply aws/org, step 4)"
  ok "7a: svp-security administers GuardDuty, Security Hub, Config, Access Analyzer and Inspector"
}

org_policies() {
  local t names miss n
  for t in SERVICE_CONTROL_POLICY RESOURCE_CONTROL_POLICY DECLARATIVE_POLICY_EC2 TAG_POLICY; do
    names=$(aws_global_ organizations list-policies-for-target --target-id "$root_id" --filter "$t" \
      --query 'Policies[].Name' --output text) || fail "organizations list-policies-for-target $t"
    printing && continue
    case $t in
      SERVICE_CONTROL_POLICY)
        miss=$(missing "$names" FullAWSAccess)
        n=$(tr -s '[:space:]' '\n' <<<"$names" | grep -c '^svp-' || true)
        [ -z "$miss" ] && [ "$n" = 5 ] || fail "7a: root SCPs are '$names': FullAWSAccess and five svp-* expected"
        ;;
      RESOURCE_CONTROL_POLICY)
        miss=$(missing "$names" RCPFullAWSAccess svp-data-perimeter svp-ec2-baseline svp-tags)
        [ -z "$miss" ] || fail "7a: root RCPs lack: $miss"
        ;;
      *) note "7a: root $t: ${names:-none}" ;;
    esac
  done
  names=$(aws_global_ organizations list-policies-for-target --target-id "$(jq -r .Prod <<<"$ou_json")" \
    --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || fail "organizations list-policies-for-target Prod"
  printing && return 0
  miss=$(missing "$names" FullAWSAccess svp-prod-guardrails)
  [ -z "$miss" ] || fail "7a: OU Prod SCPs lack: $miss"
  ok "7a: policies of the root and of OU Prod as expected"
}

org_features() {
  local out miss
  out=$(aws_global_ iam list-organizations-features --query EnabledFeatures --output text) ||
    fail "iam list-organizations-features"
  printing && return 0
  miss=$(missing "$out" RootCredentialsManagement RootSessions)
  [ -z "$miss" ] || fail "7b: organization root features lack: $miss (aws/org, centralized root access)"
  ok "7b: RootCredentialsManagement and RootSessions are on"
}

# The profile anhnv-sso reads the event rule in the region of Identity Center, which only org.auto.tfvars knows.
org_rule() {
  local f=$infra_root/aws/org/org.auto.tfvars sso_region st
  if printing; then
    sso_region='<sso_region>'
  else
    [ -f "$f" ] || fail "no $f: the file of aws/org, whose sso_region is the region of Identity Center"
    sso_region=$(sed -n 's/^[[:space:]]*sso_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)
    [[ $sso_region =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || fail "sso_region '$sso_region' of $f is not an AWS region name"
  fi
  st=$(run_ "AWS_PROFILE=$profile" aws events describe-rule --name svp-security-admin-sso --query State --output text \
    --region "$sso_region") ||
    fail "7a: rule svp-security-admin-sso not found in $sso_region: sso_region of baseline.auto.tfvars is wrong"
  printing && return 0
  [ "$st" = ENABLED ] || fail "7a: rule svp-security-admin-sso is '$st', not ENABLED"
  ok "7a: rule svp-security-admin-sso ENABLED in the region of Identity Center"
}

org_trail_mgmt() {
  local m out
  m=$(need_id SVP_AWS_MGMT_ACCOUNT_ID) || return 1
  out=$(aws_ s3api list-objects-v2 --bucket "svp-cloudtrail-$m-ap-southeast-1" \
    --query 'max_by(Contents, &LastModified).LastModified' --output text) ||
    fail "7c: cannot read the old management trail bucket"
  printing && return 0
  note "7c: last write to the old management trail bucket: $out (not later than the apply of step 4 plus minutes)"
}

org_trail_status() {
  local out
  out=$(aws_ cloudtrail get-trail-status --name svp-audit --query '[IsLogging,LatestDeliveryError,LatestDigestDeliveryError]' \
    --output json) || fail "7c: cloudtrail get-trail-status svp-audit (apply aws/org, step 4)"
  printing && return 0
  out=$(jq -c . <<<"$out" 2>/dev/null || true)
  [ "$out" = '[true,null,null]' ] ||
    fail "7c: trail svp-audit is $out, not [true,null,null]: a delivery error is the bucket or key policy of aws/log-archive"
  ok "7c: trail svp-audit is logging with no delivery error"
}

# member_ids: the ACTIVE accounts but the management account and svp-security, the members of the detection services.
member_ids() {
  local id
  for id in $active; do
    [ "$id" = "${SVP_AWS_MGMT_ACCOUNT_ID:-}" ] || [ "$id" = "${SVP_AWS_SECURITY_ACCOUNT_ID:-}" ] || printf '%s\n' "$id"
  done
}

# flag_off ID FLAG: the account with that id has FLAG off in paid-features.json.
flag_off() {
  local key
  key=$(account_key "$1")
  [ -n "$key" ] && [ "$(paid_feature "$key" "$2")" = off ]
}

# sec_guardduty REGION: organization configuration, members and publishing of GuardDuty at the delegated administrator.
sec_guardduty() {
  local r=$1 d cfg mem dest id st bad_ids=
  [ -n "$active" ] || printing || fail "7a: no list of accounts (organizations list-accounts failed above)"
  d=$(aws_in "$r" guardduty list-detectors --query 'DetectorIds[0]' --output text) || fail "guardduty list-detectors in $r"
  cfg=$(aws_in "$r" guardduty describe-organization-configuration --detector-id "$d" \
    --query '[AutoEnableOrganizationMembers, Features[].[Name, AutoEnable]]' --output json) ||
    fail "guardduty describe-organization-configuration in $r"
  mem=$(aws_in "$r" guardduty list-members --detector-id "$d" --query 'Members[].[AccountId, RelationshipStatus]' \
    --output text) || fail "guardduty list-members in $r"
  dest=$(aws_in "$r" guardduty list-publishing-destinations --detector-id "$d" --query 'Destinations[].Status' \
    --output text) || fail "guardduty list-publishing-destinations in $r"
  printing && return 0
  jq -e '.[0] == "ALL" and (.[1] | length) == 6 and all(.[1][]; .[1] == "ALL")' <<<"$cfg" >/dev/null 2>&1 ||
    fail "7a: GuardDuty in $r auto-enables $(jq -c . <<<"$cfg" 2>/dev/null), not ALL for members and the six features"
  for id in $active; do
    [ "$id" != "${SVP_AWS_SECURITY_ACCOUNT_ID:-}" ] || continue
    st=$(awk -v i="$id" '$1 == i { print $2 }' <<<"$mem")
    [ "$st" = Enabled ] || bad_ids="$bad_ids ...${id: -4}"
  done
  [ -z "$bad_ids" ] || fail "7a: GuardDuty in $r: not an Enabled member:$bad_ids (new accounts can take 24 h)"
  [ -n "$(words <<<"$dest")" ] && [ -z "$(tr -s '[:space:]' '\n' <<<"$dest" | grep . | grep -vx PUBLISHING || true)" ] ||
    fail "7a: GuardDuty in $r: publishing destinations '$dest', not all PUBLISHING"
  ok "7a: GuardDuty in $r: auto-enable ALL, every ACTIVE account but svp-security a member, findings PUBLISHING"
}

sec_analyzer() {
  local r=$1 out
  out=$(aws_in "$r" accessanalyzer list-analyzers --type ORGANIZATION --query 'analyzers[].[name, status]' --output text) ||
    fail "accessanalyzer list-analyzers in $r"
  printing && return 0
  grep -qE '^svp-org[[:space:]]+ACTIVE$' <<<"$out" || fail "7a: no ACTIVE organization analyzer svp-org in $r"
  ok "7a: Access Analyzer svp-org ACTIVE in $r"
}

# sec_hub_org: central configuration of Security Hub, and the policy association of the root and of each account
# whose security_hub flag is off (its own association wins over the root's).
sec_hub_org() {
  local cfg as id t st label targets bad_t='' pend=''
  cfg=$(aws_ securityhub describe-organization-configuration \
    --query 'OrganizationConfiguration.[ConfigurationType, Status]' --output text) ||
    fail "securityhub describe-organization-configuration"
  as=$(aws_ securityhub list-configuration-policy-associations \
    --query 'ConfigurationPolicyAssociationSummaries[].[TargetId, AssociationStatus]' --output text) ||
    fail "securityhub list-configuration-policy-associations"
  printing && return 0
  [ "$(words <<<"$cfg")" = "CENTRAL ENABLED" ] || fail "7a: Security Hub organization configuration is '$cfg', not CENTRAL ENABLED"
  [ -n "$root_id" ] || fail "7a: no root id to look for (terraform output root_id of aws/org failed above)"
  [ -n "$active" ] || fail "7a: no list of accounts (organizations list-accounts failed above)"
  targets=$root_id
  for id in $active; do
    [ "$id" = "${SVP_AWS_SECURITY_ACCOUNT_ID:-}" ] || ! flag_off "$id" security_hub || targets="$targets $id"
  done
  for t in $targets; do
    st=$(awk -v i="$t" '$1 == i { print $2 }' <<<"$as")
    if [ "$t" = "$root_id" ]; then label=root; else label="...${t: -4}"; fi
    case $st in
      SUCCESS) ;;
      PENDING) pend="$pend $label" ;;
      *) bad_t="$bad_t $label(${st:-none})" ;;
    esac
  done
  [ -z "$bad_t" ] || fail "7a: Security Hub configuration policy association not SUCCESS for:$bad_t"
  [ -z "$pend" ] || note "7a: Security Hub association PENDING for:$pend (up to 24 h is normal; read again later)"
  ok "7a: Security Hub is CENTRAL ENABLED, the root and the accounts with security_hub off have their association"
}

# sec_aggregator: every source of the Config aggregator is SUCCEEDED, but the accounts whose config_recording is off:
# they have no recorder, so the aggregator gets nothing new from them.
sec_aggregator() {
  local out id r st bad_s=''
  out=$(aws_ configservice describe-configuration-aggregator-sources-status --configuration-aggregator-name svp-org \
    --query 'AggregatedSourceStatusList[].[SourceId, AwsRegion, LastUpdateStatus]' --output text) ||
    fail "configservice describe-configuration-aggregator-sources-status svp-org"
  printing && return 0
  [ -n "$out" ] && [ "$out" != None ] || fail "7a: the Config aggregator svp-org has no source"
  while read -r id r st; do
    [ -n "$id" ] || continue
    ! flag_off "$id" config_recording || continue
    [ "$st" = SUCCEEDED ] || bad_s="$bad_s ...${id: -4}/$r(${st:-none})"
  done <<<"$out"
  [ -z "$bad_s" ] || fail "7a: Config aggregator sources not SUCCEEDED:$bad_s (aws/baseline, step 6, turns the recorders on)"
  ok "7a: every source of the Config aggregator svp-org is SUCCEEDED, but those of config_recording off"
}

# sec_inspector: Inspector scans ECR only, in svp-security and in each member whose inspector_ecr is not off.
sec_inspector() {
  local sec auto st mem id ids=() off='' bad_i=''
  sec=$(need_id SVP_AWS_SECURITY_ACCOUNT_ID) || return 1
  [ -n "$active" ] || printing || fail "7a: no list of accounts (organizations list-accounts failed above)"
  ids=("$sec")
  for id in $(member_ids); do
    if flag_off "$id" inspector_ecr; then off="$off $id"; else ids+=("$id"); fi
  done
  auto=$(aws_ inspector2 describe-organization-configuration --query autoEnable --output json) ||
    fail "inspector2 describe-organization-configuration"
  st=$(aws_ inspector2 batch-get-account-status --account-ids "${ids[@]}" --output text \
    --query 'accounts[].[accountId, resourceState.ecr.status, resourceState.ec2.status, resourceState.lambda.status]') ||
    fail "inspector2 batch-get-account-status"
  mem=$(aws_ inspector2 list-members --only-associated --query 'members[].[accountId, relationshipStatus]' --output text) ||
    fail "inspector2 list-members"
  printing && return 0
  jq -e '.ecr == true and ([to_entries[] | select(.key != "ecr") | .value == false] | all)' <<<"$auto" >/dev/null 2>&1 ||
    fail "7a: Inspector auto-enables $(jq -c . <<<"$auto" 2>/dev/null), not ecr alone"
  for id in "${ids[@]}"; do
    [ "$(awk -v i="$id" '$1 == i { print $2 " " $3 " " $4 }' <<<"$st")" = "ENABLED DISABLED DISABLED" ] ||
      bad_i="$bad_i ...${id: -4}(scans)"
    [ "$id" = "$sec" ] || [ "$(awk -v i="$id" '$1 == i { print $2 }' <<<"$mem")" = ENABLED ] || bad_i="$bad_i ...${id: -4}(member)"
  done
  for id in $off; do
    [ -z "$(awk -v i="$id" '$1 == i' <<<"$mem")" ] || bad_i="$bad_i ...${id: -4}(inspector_ecr off but a member)"
  done
  [ -z "$bad_i" ] || fail "7a: Inspector wrong for:$bad_i (scans must be ECR only: ENABLED DISABLED DISABLED)"
  ok "7a: Inspector scans only ECR in svp-security and its $((${#ids[@]} - 1)) member(s); accounts with inspector_ecr off are not members"
}

org_hub_members() {
  local out id key want st bad_ids=
  [ -n "$active" ] || printing || fail "7a: no list of accounts (organizations list-accounts failed above)"
  out=$(aws_ securityhub list-members --query 'Members[].[AccountId,MemberStatus]' --output text) ||
    fail "securityhub list-members"
  printing && return 0
  for id in $active; do
    [ "$id" != "${SVP_AWS_SECURITY_ACCOUNT_ID:-}" ] || continue
    key=$(account_key "$id")
    want=Enabled
    if [ -n "$key" ] && [ "$(paid_feature "$key" security_hub)" = off ]; then want=off; fi
    st=$(awk -v i="$id" '$1 == i { print $2 }' <<<"$out")
    if [ "$want" = Enabled ] && [ "$st" != Enabled ]; then bad_ids="$bad_ids ...${id: -4}"; fi
    if [ "$want" = off ] && [ "$st" = Enabled ]; then bad_ids="$bad_ids ...${id: -4}(security_hub off)"; fi
  done
  [ -z "$bad_ids" ] || fail "7a: Security Hub member status wrong for:$bad_ids (new accounts can take 24 h)"
  ok "7a: every ACTIVE account but svp-security is a Security Hub member as its cost flag says"
}

org_findings() {
  local out counts n c
  out=$(aws_ securityhub get-findings --output text \
    --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
    --query 'Findings[].Compliance.SecurityControlId') || fail "securityhub get-findings"
  printing && return 0
  counts=$(tr '\t' '\n' <<<"$out" | grep . | sort | uniq -c | sort -rn || true)
  while read -r n c; do
    [ -z "${c:-}" ] || note "7a: control $c FAILED in $n finding(s)"
  done <<<"$counts"
  ok "7a: $(grep -c . <<<"$counts" || true) control(s) with FAILED findings, the input of later fixes and no error here"
}

org_trail_log() {
  local l out have miss='' id
  l=$(need_id SVP_AWS_LOG_ACCOUNT_ID) || return 1
  [ -n "$org_id" ] || printing || fail "7c: no organization id (terraform output organization_id of aws/org failed above)"
  out=$(aws_ s3api list-objects-v2 --bucket "svp-cloudtrail-$l-ap-southeast-1" --prefix "AWSLogs/$org_id/" --delimiter / \
    --query 'CommonPrefixes[].Prefix' --output text) || fail "7c: cannot list the trail bucket of svp-log-archive"
  printing && return 0
  [ -n "$active" ] || fail "7c: no list of accounts (organizations list-accounts failed above)"
  have=$(tr -s '[:space:]' '\n' <<<"$out" | sed -n 's#.*/\([0-9]\{12\}\)/$#\1#p')
  for id in $active; do
    grep -qx "$id" <<<"$have" || miss="$miss ...${id: -4}"
  done
  [ -z "$miss" ] || fail "7c: no CloudTrail logs in the Log Archive bucket for:$miss (an hour after step 4 at the earliest)"
  ok "7c: the Log Archive bucket holds logs of every ACTIVE account, management included"
}

org() {
  local p r
  step "verify.sh org: checks 7a, 7b and 7c of org-security-setup.md"
  if use_profile anhnv-sso; then
    load_org
    chk org_services
    chk org_policies
    chk org_features
    chk org_rule
    chk org_trail_mgmt
    chk org_trail_status
    for r in ap-southeast-1 us-east-1; do chk standards "$r"; done
  fi
  if use_profile anhnv-security-ro; then
    chk org_hub_members
    for r in ap-southeast-1 us-east-1; do
      chk sec_guardduty "$r"
      chk sec_analyzer "$r"
    done
    chk sec_hub_org
    chk sec_aggregator
    chk sec_inspector
    for r in ap-southeast-1 us-east-1; do chk standards "$r"; done
    chk org_findings
  fi
  for p in anhnv-stg-ro anhnv-prd-ro; do
    if use_profile "$p"; then
      for r in ap-southeast-1 us-east-1; do chk standards "$r"; done
    fi
  done
  if use_profile anhnv-log-ro; then chk org_trail_log; fi
  note "7a: Security score: console of svp-security, Security Hub, Summary (profile anhnv-security-ro)"
  note "7b: the root credential audit (sts assume-root) of each account changes sessions, so it stays manual (7b)"
}

# --- backup ---

backup_account() {
  local bk parent sec na c
  bk=$(need_id SVP_AWS_BACKUP_ACCOUNT_ID) || return 1
  parent=$(aws_global_ organizations list-parents --child-id "$bk" --query 'Parents[0].Id' --output text) ||
    fail "organizations list-parents"
  na=$(aws_global_ organizations describe-account --account-id "$bk" --query 'Account.[Name,Status]' --output text) ||
    fail "organizations describe-account"
  c=$(aws_global_ account get-alternate-contact --account-id "$bk" --alternate-contact-type SECURITY \
    --query 'AlternateContact.[AlternateContactType,Title]' --output text) ||
    fail "7a: no SECURITY alternate contact on svp-backup (security_contact of org.auto.tfvars, apply aws/org)"
  printing && return 0
  sec=$(jq -r '.Security // empty' <<<"$ou_json")
  [ -n "$sec" ] && [ "$parent" = "$sec" ] || fail "7a: svp-backup is not in the OU Security"
  [ "$(words <<<"$na")" = "svp-backup ACTIVE" ] || fail "7a: svp-backup is '$na', not ACTIVE"
  case $(tr -s '[:space:]' ' ' <<<"$c") in
    "SECURITY "?*) ;;
    *) fail "7a: the SECURITY contact of svp-backup has no title" ;;
  esac
  ok "7a: svp-backup is ACTIVE in the OU Security with a SECURITY contact"
}

backup_detect() {
  local r=$1 bk d st
  bk=$(need_id SVP_AWS_BACKUP_ACCOUNT_ID) || return 1
  d=$(aws_in "$r" guardduty list-detectors --query 'DetectorIds[0]' --output text) || fail "guardduty list-detectors in $r"
  st=$(aws_in "$r" guardduty list-members --detector-id "$d" --output text \
    --query "Members[?AccountId=='$bk'].RelationshipStatus") || fail "guardduty list-members in $r"
  printing && return 0
  [ "$st" = Enabled ] || fail "7a: GuardDuty member status of svp-backup in $r is '${st:-none}' (a new account takes up to 24 h)"
  ok "7a: svp-backup is a GuardDuty member in $r"
}

backup_hub_inspector() {
  local bk st ins
  bk=$(need_id SVP_AWS_BACKUP_ACCOUNT_ID) || return 1
  st=$(aws_ securityhub list-members --output text --query "Members[?AccountId=='$bk'].MemberStatus") ||
    fail "securityhub list-members"
  ins=$(aws_ inspector2 batch-get-account-status --account-ids "$bk" \
    --query 'accounts[].[resourceState.ecr.status, resourceState.ec2.status, resourceState.lambda.status]' --output text) ||
    fail "inspector2 batch-get-account-status"
  printing && return 0
  [ "$st" = Enabled ] || fail "7a: Security Hub member status of svp-backup is '${st:-none}' (a new account takes up to 24 h)"
  [ "$(words <<<"$ins")" = "ENABLED DISABLED DISABLED" ] ||
    fail "7a: Inspector of svp-backup is '$ins', not ENABLED DISABLED DISABLED (ecr, ec2, lambda)"
  ok "7a: svp-backup is a Security Hub member and Inspector scans only ECR"
}

backup_global() {
  local out
  out=$(aws_ backup describe-global-settings --query GlobalSettings --output json) || fail "backup describe-global-settings"
  printing && return 0
  jq -e '.isCrossAccountBackupEnabled == "true" and
    ([to_entries[] | select(.key != "isCrossAccountBackupEnabled") | .value == "false"] | all)' <<<"$out" >/dev/null ||
    fail "7b: AWS Backup global settings: isCrossAccountBackupEnabled must be true and every other key false"
  ok "7b: cross-account backup is on, the other global settings off"
}

backup_optin() {
  local out
  out=$(aws_ backup describe-region-settings --query 'ResourceTypeOptInPreference.[RDS,S3]' --output text) ||
    fail "backup describe-region-settings with profile $profile"
  printing && return 0
  [ "$(words <<<"$out")" = "True True" ] || fail "7b: $profile: opt-in of RDS and S3 is '$out', not True True"
  ok "7b: $profile: RDS and S3 are opted in to AWS Backup"
}

# backup_policy ENV OU: the Backup policy of the OU, and the effective policy of the account of ENV (as management).
backup_policy() {
  local e=$1 ou=$2 names v a eff keys
  names=$(aws_global_ organizations list-policies-for-target --target-id "$(jq -r ".$ou" <<<"$ou_json")" \
    --filter BACKUP_POLICY --query 'Policies[].Name' --output text) || fail "organizations list-policies-for-target $ou"
  v=$(awk -v p="anhnv-$e-ro" '$1 == p { print $2 }' <<<"$profile_table")
  a=$(need_id "$v") || return 1
  eff=$(aws_global_ organizations describe-effective-policy --policy-type BACKUP_POLICY --target-id "$a" \
    --query 'EffectivePolicy.PolicyContent' --output text) || fail "organizations describe-effective-policy of $e"
  printing && return 0
  [ "$names" = "svp-backup-$e" ] || fail "7c: OU $ou has Backup policies '$names', not svp-backup-$e"
  keys=$(jq -c '.plans | keys' <<<"$eff" 2>/dev/null || true)
  [ "$keys" = "[\"svp-$e\"]" ] || fail "7c: the effective Backup policy of $e has plans $keys, not [\"svp-$e\"]"
  ok "7c: OU $ou carries svp-backup-$e and the effective policy of $e has the plan svp-$e only"
}

# backup_plan ENV: the plan AWS generated in the account of ENV (its read-only profile is the current one).
backup_plan() {
  local e=$1 id rules sel
  id=$(aws_ backup list-backup-plans --output text --query "BackupPlansList[?BackupPlanName=='svp-$e'].BackupPlanId") ||
    fail "backup list-backup-plans in $e"
  printing || { [ -n "$id" ] && [ "$id" != None ] ||
    fail "7c: AWS has not generated the plan svp-$e in the account yet (a newly attached policy takes a while); read again later"; }
  rules=$(aws_ backup get-backup-plan --backup-plan-id "$id" --output text \
    --query 'BackupPlan.Rules[].[RuleName,TargetBackupVaultName,ScheduleExpression,Lifecycle.DeleteAfterDays,CopyActions[0].Lifecycle.DeleteAfterDays]') ||
    fail "backup get-backup-plan svp-$e"
  sel=$(aws_ backup list-backup-selections --backup-plan-id "$id" --query 'BackupSelectionsList[].SelectionName' --output text) ||
    fail "backup list-backup-selections svp-$e"
  printing && return 0
  [ "$(grep -c . <<<"$rules")" = 1 ] && [ "$(awk '{ print $1 " " $2 }' <<<"$rules")" = "daily svp-$e" ] ||
    fail "7c: the plan svp-$e must have one rule daily into the vault svp-$e, got: $(oneline <<<"$rules")"
  [ -z "$(missing "$sel" "svp-$e-tagged")" ] || fail "7c: the plan svp-$e has no selection svp-$e-tagged"
  note "7c: $e rule schedule and retention (vault days, copy days) for the eye: $(awk '{ $1 = $2 = ""; print }' <<<"$rules")"
  ok "7c: the plan svp-$e has the rule daily into svp-$e and the selection svp-$e-tagged"
}

backup_vault() {
  local e=$1 v n locked count pol
  v=$(aws_ backup describe-backup-vault --backup-vault-name "svp-$e" --query '[BackupVaultName,Locked,NumberOfRecoveryPoints]' \
    --output text) || fail "backup describe-backup-vault svp-$e"
  pol=$(aws_global_ iam list-attached-role-policies --role-name "svp-$e-backup" --query 'AttachedPolicies[].PolicyName' \
    --output text) || fail "iam list-attached-role-policies svp-$e-backup"
  printing && return 0
  read -r n locked count <<<"$v"
  [ "$locked" = False ] || fail "7c: the vault svp-$e is Locked '$locked', not False"
  [ "$(tr -s '[:space:]' '\n' <<<"$pol" | grep -c .)" = 4 ] ||
    fail "7c: the role svp-$e-backup must have the 4 managed policies of AWS Backup, got: $(oneline <<<"$pol")"
  ok "7c: the vault svp-$e is not locked ($count recovery points) and its role has the 4 policies"
}

backup_copy() {
  local e=$1 v a out pol got n locked min max
  v=$(awk -v p="anhnv-$e-ro" '$1 == p { print $2 }' <<<"$profile_table")
  a=$(need_id "$v") || return 1
  out=$(aws_ backup describe-backup-vault --backup-vault-name "svp-$e-copy" \
    --query '[BackupVaultName,Locked,MinRetentionDays,MaxRetentionDays]' --output text) ||
    fail "backup describe-backup-vault svp-$e-copy"
  pol=$(aws_ backup get-backup-vault-access-policy --backup-vault-name "svp-$e-copy" --query Policy --output text) ||
    fail "backup get-backup-vault-access-policy svp-$e-copy"
  printing && return 0
  read -r n locked min max <<<"$out"
  [ "$locked" = True ] || fail "7d: the vault svp-$e-copy is Locked '$locked', not True"
  got=$(jq -c --arg p "arn:aws:iam::$a:root" '[.Statement[] | {Effect, Action, env_root: (.Principal.AWS == $p)}]' <<<"$pol" \
    2>/dev/null || true)
  [ "$got" = '[{"Effect":"Allow","Action":"backup:CopyIntoBackupVault","env_root":true}]' ] ||
    fail "7d: the access policy of svp-$e-copy must be one Allow of backup:CopyIntoBackupVault from the account of $e only: $got"
  note "7d: svp-$e-copy lock min $min days, max $max days (compare with the table of Tài nguyên of aws/backup)"
  ok "7d: the vault svp-$e-copy is locked and accepts copies from the account of $e only"
}

backup() {
  local e r ou
  step "verify.sh backup: checks 7a to 7d of backup-setup.md"
  if use_profile anhnv-sso; then
    load_ou_json
    chk backup_account
    chk backup_global
    chk backup_optin
    for e in stg:NonProd prd:Prod; do
      ou=${e#*:}
      chk backup_policy "${e%%:*}" "$ou"
    done
  fi
  if use_profile anhnv-backup-ro; then
    for r in ap-southeast-1 us-east-1; do chk standards "$r"; done
    for e in stg prd; do chk backup_copy "$e"; done
  fi
  if use_profile anhnv-security-ro; then
    for r in ap-southeast-1 us-east-1; do chk backup_detect "$r"; done
    chk backup_hub_inspector
  fi
  for e in stg prd; do
    if use_profile "anhnv-$e-ro"; then
      chk backup_optin
      chk backup_plan "$e"
      chk backup_vault "$e"
    fi
  done
  note "7d: the copy of a recovery point across accounts is tested by the first session: restore-drill.sh <env> backup"
}

# --- subscriptions ---

# The topics whose email subscription the runbooks ask to confirm: environment, profile that reads it, topic, region,
# variable with the account that owns it, 1 for a topic of the session roots (only there during a session) or -.
sub_topics='mgmt anhnv-security-ro svp-security-alarms ap-southeast-1 SVP_AWS_SECURITY_ACCOUNT_ID -
stg anhnv-stg svp-stg-alarms ap-southeast-1 SVP_AWS_STG_ACCOUNT_ID 1
prd anhnv-prd svp-prd-dns-alarms us-east-1 SVP_AWS_PRD_ACCOUNT_ID -
prd anhnv-prd svp-prd-alarms ap-southeast-1 SVP_AWS_PRD_ACCOUNT_ID 1'

# confirmed TOPIC REGION VAR SESSION: no subscription of the topic waits for its email link. A topic of the session
# roots that does not exist is skipped: between sessions there is nothing to confirm.
confirmed() {
  local topic=$1 r=$2 id out n
  id=$(need_id "$3") || return 1
  if [ "$4" = 1 ]; then
    n=$(aws_in "$r" sns list-topics --query "length(Topics[?ends_with(TopicArn, ':$topic')])" --output text) ||
      fail "sns list-topics in $r"
    if ! printing && [ "$n" = 0 ]; then
      skip "topic $topic does not exist: its session root is not applied (read again after the apply of the session)"
      return 0
    fi
  fi
  out=$(aws_in "$r" sns list-subscriptions-by-topic --topic-arn "arn:aws:sns:$r:$id:$topic" \
    --query 'Subscriptions[].SubscriptionArn' --output text) ||
    fail "topic $topic cannot be read in $r (is the root that creates it applied?)"
  printing && return 0
  [ -n "$out" ] && [ "$out" != None ] || fail "topic $topic has no subscription: the apply of its root creates the email one"
  case " $(tr -s '[:space:]' ' ' <<<"$out") " in
    *" PendingConfirmation "*)
      fail "topic $topic: a subscription is still PendingConfirmation: open the Confirm subscription link of the mail (spam too)"
      ;;
  esac
  ok "topic $topic: every subscription is confirmed"
}

subscriptions() {
  local p t r v s
  step "verify.sh subscriptions $1: the email subscriptions of its SNS topics"
  for p in $(awk -v e="$1" '$1 == e { print $2 }' <<<"$sub_topics" | sort -u | tr '\n' ' '); do
    use_profile "$p" || continue
    while read -r _ _ t r v s; do
      chk confirmed "$t" "$r" "$v" "$s" </dev/null
    done < <(awk -v e="$1" -v p="$p" '$1 == e && $2 == p' <<<"$sub_topics")
  done
}

# --- dnssec ---

# fields RECORD: the four fields of a DS record, as the Cloudflare form asks them.
ds_fields() {
  local tag alg typ digest
  read -r tag alg typ digest <<<"$1"
  printf 'key tag %s, algorithm %s, digest type %s, digest %s' "$tag" "$alg" "$typ" "$digest"
}

# ds_norm: DS records on stdin, one per line, upper case, the digest in one word: dig splits a long one in two.
ds_norm() { awk 'NF { d = ""; for (i = 4; i <= NF; i++) d = d $i; print toupper($1 " " $2 " " $3 " " d) }' | sort; }

dnssec_signing() {
  local st ksk
  printing && return 0
  st=$(jq -r '.Status.ServeSignature // empty' <<<"$sig")
  [ "$st" = SIGNING ] ||
    fail "zone $zone is not signed (status '${st:-none}'): apply aws/accounts/prd, step (2) of edge-setup.md"
  ksk=$(jq -r '.KeySigningKeys[]? | select(.Name == "svp_prd_ksk") | .Status' <<<"$sig")
  [ "$ksk" = ACTIVE ] || fail "KSK svp_prd_ksk is '${ksk:-missing}', not ACTIVE: section Alarm DNSSEC of edge-setup.md"
  ok "zone $zone is SIGNING and its KSK svp_prd_ksk is ACTIVE"
}

dnssec_parent() {
  local ds flags
  ds=$(run_ dig +short DS "$domain" @1.1.1.1) || fail "dig DS $domain"
  flags=$(run_ dig +dnssec SOA "$domain" @1.1.1.1 | sed -n 's/^;; flags: \([^;]*\);.*/\1/p' || true)
  printing && return 0
  [ -n "$ds" ] ||
    fail "no DS for $domain at 1.1.1.1: turn DNSSEC of $domain on at Cloudflare and put its DS at the registrar (3a of edge-setup.md)"
  case " $flags " in
    *" ad "*) ;;
    *) fail "$domain does not validate at 1.1.1.1 (no ad flag): the DS at the registrar is missing or not published yet (3a)" ;;
  esac
  note "registrar: DS of $domain is $(ds_fields "$(head -n 1 <<<"$ds" | ds_norm)") (given by Cloudflare, DNS, Settings, DNSSEC)"
  ok "$domain has a DS at 1.1.1.1 and validates"
}

dnssec_ds_at_parent() {
  local pns got zns pttl zttl
  [ -n "$ds_record" ] || printing || fail "no DSRecord of svp_prd_ksk to compare with (the signing check above failed)"
  pns=$(run_ dig +short NS "$domain" | head -n 1) || fail "dig NS $domain"
  got=$(run_ dig +norec +short DS "$zone" "@$pns") || fail "dig DS $zone at the name server of $domain"
  pttl=$(run_ dig +norec +noall +authority NS "$zone" "@$pns" | awk 'NR == 1 { print $2 }' || true)
  zns=$(run_ dig +short NS "$zone" | head -n 1 || true)
  zttl=$(run_ dig +noall +answer NS "$zone" "@$zns" | awk 'NR == 1 { print $2 }' || true)
  printing && return 0
  note "3e: NS TTL ${pttl:-?} s at the parent, ${zttl:-?} s at the zone (3600 after 2a): wait 10 minutes plus the larger before 3f"
  [ -n "$got" ] || fail "no DS $zone at the parent's name server: add it at Cloudflare (3d of edge-setup.md)"
  [ "$(ds_norm <<<"$got")" = "$(ds_norm <<<"$ds_record")" ] ||
    fail "the DS of $zone at Cloudflare differs from the KSK's DSRecord: fix it (3d of edge-setup.md)"
  ok "the DS of $zone at the parent is the DSRecord of the KSK"
}

# resolves ZONE RESOLVER ad|noad: the zone answers NOERROR at the resolver, validated (ad) or not.
resolves() {
  local z=$1 r=$2 want=$3 out status flags
  out=$(run_ dig +dnssec SOA "$z" "@$r") || fail "dig SOA $z at $r"
  printing && return 0
  status=$(sed -n 's/.*->>HEADER<<-.*status: \([A-Z]*\).*/\1/p' <<<"$out")
  flags=$(sed -n 's/^;; flags: \([^;]*\);.*/\1/p' <<<"$out")
  [ "$status" = NOERROR ] ||
    fail "$z at $r answers '${status:-nothing}': if SERVFAIL, do the rollback (Đường lui) of edge-setup.md now"
  case $want:" $flags " in
    ad:*" ad "*) ;;
    noad:*" ad "*) fail "$z at $r is validated (ad flag), but its delegation has no DS" ;;
    noad:*) ;;
    *) fail "$z at $r answers without the ad flag: the chain of trust is not complete (3d, 3e of edge-setup.md)" ;;
  esac
  ok "$z at $r: NOERROR, $want"
}

dnssec_delv() {
  local out
  out=$(run_ delv @1.1.1.1 "$zone" SOA 2>&1 || true)
  printing && return 0
  case $out in
    *"fully validated"*) ok "delv: $zone is fully validated" ;;
    *[Aa]lgorithm*) note "delv lacks an algorithm of $zone: the dig checks above are enough" ;;
    *) fail "delv does not report $zone fully validated" ;;
  esac
}

dnssec() {
  local r ns
  step "verify.sh dnssec: delegation and signature of the prd zone (edge-setup.md)"
  printing || command -v dig >/dev/null 2>&1 ||
    fail "dig is not installed (macOS has it; Linux: the package dnsutils or bind-utils): the checks of propagation need it"
  env_zone
  domain=${zone#*.}
  sig='' ds_record='' ns=''
  use_profile anhnv-prd || return 0
  zone_id=$(tf_ "$infra_root/aws/accounts/prd" output -raw zone_id) || bad "terraform output zone_id of aws/accounts/prd"
  if printing; then zone_id='<zone_id>'; fi
  if sig=$(aws_global_ route53 get-dnssec --hosted-zone-id "$zone_id" --output json); then
    ds_record=$(jq -r '.KeySigningKeys[]? | select(.Name == "svp_prd_ksk") | .DSRecord' <<<"$sig" 2>/dev/null || true)
  else
    bad "route53 get-dnssec of the prd zone"
  fi
  ns=$(tf_ "$infra_root/aws/accounts/prd" output -json name_servers | jq -r '.[]' || true)
  if ! printing; then
    [ -n "$ns" ] || bad "terraform output name_servers of aws/accounts/prd is empty"
    for r in $ns; do note "Cloudflare: NS record, name ${zone%."$domain"}, value $r"; done
    [ -z "$ds_record" ] || note "Cloudflare: DS record, name ${zone%."$domain"}, $(ds_fields "$ds_record")"
  fi
  chk dnssec_signing
  chk dnssec_parent
  chk dnssec_ds_at_parent
  for r in 1.1.1.1 8.8.8.8; do
    chk resolves "$zone" "$r" ad
    chk resolves "stg.$zone" "$r" noad
  done
  if printing || command -v delv >/dev/null 2>&1; then
    chk dnssec_delv
  else
    note "delv is not installed: the dig checks above are enough"
  fi
}

# --- cost ---

cost() {
  local kind=$1 start=${2:-} end filter='' id out rows
  step "verify.sh cost $kind: Cost Explorer by service"
  end=$(date -u +%Y-%m-%d)
  [ -n "$start" ] || start=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)
  [[ $start =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "START '$start' is not yyyy-mm-dd"
  [[ $start < $end ]] || fail "START $start is not before today ($end): Cost Explorer takes End exclusive"
  use_profile "$profile" || exit 1
  case $kind in
    mgmt)
      filter='{"Dimensions":{"Key":"SERVICE","Values":["Amazon GuardDuty","AWS Security Hub","AWS Config",'
      filter="$filter\"AWS Key Management Service\",\"Amazon Simple Storage Service\",\"AWS CloudTrail\"]}}"
      ;;
    backup)
      id=$(need_id SVP_AWS_BACKUP_ACCOUNT_ID)
      filter=$(jq -nc --arg a "$id" '{Dimensions: {Key: "LINKED_ACCOUNT", Values: [$a]}}')
      ;;
  esac
  set -- ce get-cost-and-usage --granularity DAILY --metrics UnblendedCost --time-period "Start=$start,End=$end" \
    --group-by Type=DIMENSION,Key=SERVICE
  [ -z "$filter" ] || set -- "$@" --filter "$filter"
  out=$(aws_global_ "$@" --output json) ||
    fail "ce get-cost-and-usage (first use: turn Cost Explorer on once in the console, Billing, Cost Explorer; data comes ~24 h later)"
  printing && return 0
  rows=$(jq -r '.ResultsByTime[] | .TimePeriod.Start as $d | .Groups[] | "\($d)\t\(.Keys[0])\t\(.Metrics.UnblendedCost.Amount)"' \
    <<<"$out") || fail "the answer of ce get-cost-and-usage is not the expected JSON"
  if [ -z "$rows" ]; then
    note "no cost data from $start to $end yet (Cost Explorer lags about 24 hours)"
  else
    while IFS=$'\t' read -r d s a; do note "$d  $s  $a USD"; done <<<"$rows"
    ok "$(grep -c . <<<"$rows") row(s) from $start to $end, $(awk -F'\t' '{ t += $3 } END { printf "%.4f", t }' <<<"$rows") USD"
  fi
  case $kind in
    mgmt)
      note "GuardDuty and Security Hub estimated cost after the trial: console of svp-security, page Usage of each"
      note "cost monitor, anomaly subscription and allocation tags: README of aws/bootstrap, section 5"
      ;;
    backup) note "compare with the estimate of the backup runbook for the account svp-backup (±50 %)" ;;
    *) note "the whole organization: verify.sh cost mgmt" ;;
  esac
}

case $sub in
  org | backup) "$sub" ;;
  subscriptions) subscriptions "$1" ;;
  dnssec) dnssec ;;
  cost) cost "$@" ;;
esac
if [ "$failures" -gt 0 ]; then
  printf 'FAIL  %s check(s) failed, each named above\n' "$failures" >&2
  exit 1
fi
