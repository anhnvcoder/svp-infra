#!/usr/bin/env bash
# Members of the IAM Identity Center groups of the platform tools (svp-platform-admins, svp-platform-viewers), made by
# aws/org. Who belongs is picked when this runs and is never configuration: add or remove one user by user name, or
# count the members of a group (the count alone, no id).

# The groups come from the outputs of aws/org, the region of Identity Center from the line sso_region of
# aws/org/org.auto.tfvars; profile anhnv-sso, its account checked first.

# Usage: aws/scripts/platform-member.sh [--print] add|remove admins|viewers <user-name>
#        aws/scripts/platform-member.sh [--print] count admins|viewers
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] add|remove admins|viewers <user-name>, or count admins|viewers"
case ${1:-}:$# in
  add:3 | remove:3 | count:2) ;;
  *) fail "$usage" ;;
esac
action=$1
case $2 in
  admins) output=platform_admin_group_id ;;
  viewers) output=platform_viewer_group_id ;;
  *) fail "$usage" ;;
esac
group=svp-platform-$2
user=${3:-}
# The characters Identity Center allows in a user name; none needs quoting inside the JSON below.
[ "$action" = count ] || [[ $user =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] ||
  fail "user name '$user' has a character Identity Center does not allow in one"
env_arg mgmt any

# sso_region: read from its own line of the file, nothing else of it (the file holds personal data).
tfvars=$infra_root/aws/org/org.auto.tfvars
if [ ! -f "$tfvars" ] && printing; then
  sso_region='<sso_region of aws/org/org.auto.tfvars>'
else
  [ -f "$tfvars" ] || fail "no $tfvars: copy org.auto.tfvars.example of aws/org and fill it in (README.md of aws/org)"
  sso_region=$(sed -n 's/^[[:space:]]*sso_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tfvars" | head -n 1)
  [[ $sso_region =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] ||
    fail "no sso_region = \"<region>\" line in $tfvars: set it to the region of Identity Center, sso_region of the [sso-session] of anhnv-sso"
fi
# aws_sso_ ARGS...: aws in the region of the Identity Center instance (sso-admin, identitystore answer only there).
aws_sso_() { run_ "AWS_PROFILE=$profile" aws "$@" --region "$sso_region"; }
# value JQ-FILTER JSON: the string the filter picks, empty with --print.
value() {
  printing && return 0
  jq -r "$1 // empty" <<<"$2"
}

step "platform-member.sh $action: group $group"
check_account
gid=$(tf_ "$infra_root/aws/org" output -raw "$output") ||
  fail "terraform output $output of aws/org: apply aws/org first (docs/runbooks/platform-setup.md, step (1)), or init it once: AWS_PROFILE=$profile terraform -chdir=aws/org init -backend-config=../backend.hcl"
printing && gid="<$output>"
[ -n "$gid" ] || fail "output $output of aws/org is empty: apply aws/org first (docs/runbooks/platform-setup.md, step (1))"

out=$(aws_sso_ sso-admin list-instances --output json) || fail "aws sso-admin list-instances in $sso_region"
store=$(value '.Instances | if length == 1 then .[0].IdentityStoreId else empty end' "$out")
printing && store='<IdentityStoreId>'
[ -n "$store" ] || fail "not exactly one Identity Center instance in $sso_region: check sso_region of $tfvars"

if [ "$action" = count ]; then
  out=$(aws_sso_ identitystore list-group-memberships --identity-store-id "$store" --group-id "$gid" --output json) ||
    fail "aws identitystore list-group-memberships of $group"
  printing && exit 0
  ok "$group has $(jq '.GroupMemberships | length' <<<"$out") member(s)"
  exit 0
fi

out=$(aws_sso_ identitystore get-user-id --identity-store-id "$store" \
  --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"userName\",\"AttributeValue\":\"$user\"}}" --output json) ||
  fail "no user $user in Identity Center (user name as at the top right of the AWS access portal): create the user first"
uid=$(value .UserId "$out")
printing && uid='<UserId>'
[ -n "$uid" ] || fail "get-user-id of $user answered no UserId"

out=$(aws_sso_ identitystore is-member-in-groups --identity-store-id "$store" --member-id "UserId=$uid" \
  --group-ids "$gid" --output json) || fail "aws identitystore is-member-in-groups for $user in $group"
member=$(value '.Results[0].MembershipExists | tostring' "$out")
printing && member='<MembershipExists>'
case $action:$member in
  add:true)
    skip "$user is already a member of $group"
    ;;
  add:false | add:'<MembershipExists>')
    aws_sso_ identitystore create-group-membership --identity-store-id "$store" --group-id "$gid" \
      --member-id "UserId=$uid" --output json >/dev/null || fail "add $user to $group"
    ok "$user added to $group"
    ;;
  remove:false)
    skip "$user is not a member of $group"
    ;;
  remove:true | remove:'<MembershipExists>')
    out=$(aws_sso_ identitystore get-group-membership-id --identity-store-id "$store" --group-id "$gid" \
      --member-id "UserId=$uid" --output json) || fail "aws identitystore get-group-membership-id for $user in $group"
    mid=$(value .MembershipId "$out")
    printing && mid='<MembershipId>'
    [ -n "$mid" ] || fail "get-group-membership-id answered no MembershipId"
    aws_sso_ identitystore delete-group-membership --identity-store-id "$store" --membership-id "$mid" ||
      fail "remove $user from $group"
    ok "$user removed from $group"
    ;;
  *)
    fail "is-member-in-groups answered '$member' for $user in $group, not true or false"
    ;;
esac
