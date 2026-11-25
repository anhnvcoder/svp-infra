#!/usr/bin/env bash
# Self-test of platform-member.sh against the fake aws and terraform: add, remove and count on the groups of aws/org in
# the region of sso_region, the account checked first, a member added once, ids never printed; a missing user, group
# output or sso_region stops it; --print reaches nothing.

# Usage: aws/scripts/tests/platform-member-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=aws/scripts/tests/testlib.sh
. "$src/tests/testlib.sh"
fake_aws
here=$work/infra/aws/scripts
mkdir -p "$here" "$work/infra/aws/org"
cp "$src/lib.sh" "$src/platform-member.sh" "$here/"
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000
tfvars=$work/infra/aws/org/org.auto.tfvars
out=$work/out
pm() { bash "$here/platform-member.sh" "$@" >"$out" 2>&1; }
# calls: the fake calls of the last run in order, aws as <service>_<command>, terraform as the output it read.
calls() { awk '$1 == "aws" { print "aws_" $2 "_" $3; next } { print $1 " " $NF }' "$log" | tr '\n' '|'; }

# The personal file of aws/org: an email beside sso_region, which nothing may print.
write_tfvars() {
  printf '%s\n' 'account_emails = {' '  stg = "stg@svp.example"' '}' 'sso_user_name = "learner"' \
    "sso_region = \"${1:-us-west-2}\"" >"$tfvars"
}
write_tfvars
# terraform: the two group outputs of aws/org, or none at all once $answers/no-outputs exists.
fake_cmd terraform '[ ! -e "$FAKE_ANSWERS/no-outputs" ] || { echo "Error: Output \"$4\" not found" >&2; exit 1; }
case "$2 $3 $4" in
  "output -raw platform_admin_group_id") printf g-admins ;;
  "output -raw platform_viewer_group_id") printf g-viewers ;;
  *) exit 1 ;;
esac'
printf '{"Instances": [{"InstanceArn": "arn:aws:sso:::instance/ssoins-fake", "IdentityStoreId": "d-0000000000"}]}\n' \
  >"$answers/sso-admin_list-instances"
printf '{"IdentityStoreId": "d-0000000000", "UserId": "u-fake-learner"}\n' >"$answers/identitystore_get-user-id"
# member true|false: the answer of is-member-in-groups.
member() {
  printf '{"Results": [{"GroupId": "g-admins", "MemberId": {"UserId": "u-fake-learner"}, "MembershipExists": %s}]}\n' "$1" \
    >"$answers/identitystore_is-member-in-groups"
}
printf '{"IdentityStoreId": "d-0000000000", "MembershipId": "m-fake-new"}\n' >"$answers/identitystore_create-group-membership"
printf '{"IdentityStoreId": "d-0000000000", "MembershipId": "m-fake-old"}\n' >"$answers/identitystore_get-group-membership-id"
: >"$answers/identitystore_delete-group-membership"
printf '{"GroupMemberships": [{"MembershipId": "m-fake-1", "MemberId": {"UserId": "u-fake-1"}}, {"MembershipId": "m-fake-2", "MemberId": {"UserId": "u-fake-2"}}]}\n' \
  >"$answers/identitystore_list-group-memberships"
ids='u-fake-learner g-admins g-viewers d-0000000000 m-fake-new m-fake-old m-fake-1 stg@svp.example'
no_ids() {
  local i
  for i in $ids; do no_leak "$i" "$out" || return 1; done
}

# --- arguments ---------------------------------------------------------------------------------------------------
: >"$log"
for args in '' 'add' 'add admins' 'count' 'count admins learner' 'list admins' 'add owners learner' 'add admins a/b' 'add admins a b'; do
  # shellcheck disable=SC2086 # the words of args are the arguments
  expect "arguments '$args' are refused with a FAIL" sh -c '! bash "$@" >"$0" 2>&1 && grep -q "^FAIL  " "$0"' "$out" "$here/platform-member.sh" $args
done
expect "refused arguments call nothing" test ! -s "$log"

# --- add ---------------------------------------------------------------------------------------------------------
member false
: >"$log"
expect "add admins learner exits 0" pm add admins learner
expect "add says the user was added" grep -qx 'ok    learner added to svp-platform-admins' "$out"
expect "add: account check, group output, instance, user, membership, then the write" \
  test "$(calls)" = "aws_sts_get-caller-identity|terraform platform_admin_group_id|aws_sso-admin_list-instances|aws_identitystore_get-user-id|aws_identitystore_is-member-in-groups|aws_identitystore_create-group-membership|"
expect "the account check runs in the home region" grep -q '^aws sts get-caller-identity --output json --region ap-southeast-1$' "$log"
expect "every Identity Center call runs in sso_region of org.auto.tfvars" \
  sh -c 'test "$(grep -Ec "^aws (sso-admin|identitystore) .* --region us-west-2$" "$1")" = 4 && test "$(grep -Ec "^aws (sso-admin|identitystore) " "$1")" = 4' _ "$log"
expect "the user is looked up by userName" \
  grep -qF -- '--alternate-identifier {"UniqueAttribute":{"AttributePath":"userName","AttributeValue":"learner"}}' "$log"
expect "the membership is made for that user in the admins group" \
  grep -q '^aws identitystore create-group-membership --identity-store-id d-0000000000 --group-id g-admins --member-id UserId=u-fake-learner ' "$log"
expect "add prints no id and nothing else of org.auto.tfvars" no_ids

member true
: >"$log"
expect "add of a member exits 0" pm add admins learner
expect "add of a member skips" grep -qx 'skip  learner is already a member of svp-platform-admins' "$out"
expect "add of a member writes nothing" sh -c '! grep -q create-group-membership "$1"' _ "$log"

# --- remove ------------------------------------------------------------------------------------------------------
: >"$log"
expect "remove admins learner exits 0" pm remove admins learner
expect "remove says the user was removed" grep -qx 'ok    learner removed from svp-platform-admins' "$out"
expect "remove deletes the membership get-group-membership-id names" \
  sh -c 'grep -q "^aws identitystore get-group-membership-id --identity-store-id d-0000000000 --group-id g-admins --member-id UserId=u-fake-learner " "$1" && grep -q "^aws identitystore delete-group-membership --identity-store-id d-0000000000 --membership-id m-fake-old " "$1"' _ "$log"
expect "remove prints no id" no_ids
member false
: >"$log"
expect "remove of a non-member exits 0" pm remove admins learner
expect "remove of a non-member skips and deletes nothing" \
  sh -c 'grep -qx "skip  learner is not a member of svp-platform-admins" "$1" && ! grep -q -e delete-group-membership -e get-group-membership-id "$2"' _ "$out" "$log"

# --- count -------------------------------------------------------------------------------------------------------
: >"$log"
expect "count viewers exits 0" pm count viewers
expect "count prints the number of members" grep -qx 'ok    svp-platform-viewers has 2 member(s)' "$out"
expect "count reads the viewers group and writes nothing" \
  test "$(calls)" = "aws_sts_get-caller-identity|terraform platform_viewer_group_id|aws_sso-admin_list-instances|aws_identitystore_list-group-memberships|"
expect "count prints no id" no_ids

# --- what stops it -------------------------------------------------------------------------------------------------
member false
rm "$answers/identitystore_get-user-id"
: >"$log"
expect "a user Identity Center does not have: FAIL naming the user" \
  sh -c '! bash "$1" add admins nobody >"$2" 2>&1 && grep -q "^FAIL  no user nobody in Identity Center" "$2"' _ "$here/platform-member.sh" "$out"
expect "a user Identity Center does not have: no membership is made" sh -c '! grep -q create-group-membership "$1"' _ "$log"
printf '{"IdentityStoreId": "d-0000000000", "UserId": "u-fake-learner"}\n' >"$answers/identitystore_get-user-id"

touch "$answers/no-outputs"
: >"$log"
expect "no group output (aws/org not applied): FAIL naming the step" \
  sh -c '! bash "$1" add admins learner >"$2" 2>&1 && grep -q "^FAIL  terraform output platform_admin_group_id of aws/org: apply aws/org first" "$2"' _ "$here/platform-member.sh" "$out"
expect "no group output: no Identity Center call" sh -c '! grep -q -e sso-admin -e identitystore "$1"' _ "$log"
rm "$answers/no-outputs"

printf 'sso_user_name = "learner"\n' >"$tfvars"
: >"$log"
expect "org.auto.tfvars without sso_region: FAIL before any call" \
  sh -c '! bash "$1" count admins >"$2" 2>&1 && grep -q "^FAIL  no sso_region = \"<region>\" line in " "$2" && [ ! -s "$3" ]' _ "$here/platform-member.sh" "$out" "$log"
rm "$tfvars"
expect "no org.auto.tfvars: FAIL naming the example file, before any call" \
  sh -c '! bash "$1" count admins >"$2" 2>&1 && grep -q "^FAIL  no .*/aws/org/org.auto.tfvars: copy org.auto.tfvars.example" "$2" && [ ! -s "$3" ]' _ "$here/platform-member.sh" "$out" "$log"
write_tfvars

expect "SVP_AWS_MGMT_ACCOUNT_ID of another account: FAIL before terraform and Identity Center" \
  sh -c '! env SVP_AWS_MGMT_ACCOUNT_ID=999999999999 bash "$1" count admins >"$2" 2>&1 && grep -q "^FAIL  profile anhnv-sso is account" "$2" && ! grep -q -e terraform -e identitystore "$3"' \
  _ "$here/platform-member.sh" "$out" "$log"

cp "$answers/sso-admin_list-instances" "$work/instances"
printf '{"Instances": [{"IdentityStoreId": "d-0000000000"}, {"IdentityStoreId": "d-1111111111"}]}\n' >"$answers/sso-admin_list-instances"
expect "two Identity Center instances: FAIL" \
  sh -c '! bash "$1" count admins >"$2" 2>&1 && grep -q "^FAIL  not exactly one Identity Center instance in us-west-2" "$2"' _ "$here/platform-member.sh" "$out"
mv "$work/instances" "$answers/sso-admin_list-instances"

# --- --print -----------------------------------------------------------------------------------------------------
# shows ARGS GREP: --print ARGS exits 0, calls nothing and shows a line matching GREP.
shows() {
  : >"$log"
  # shellcheck disable=SC2086 # the words of $1 are the arguments
  expect "--print $1 exits 0" pm --print $1
  expect "--print $1 calls nothing" test ! -s "$log"
  expect "--print $1 shows its write or read, in sso_region" grep -q "$2" "$out"
}
shows 'add admins learner' '^+ AWS_PROFILE=anhnv-sso aws identitystore create-group-membership .* --region us-west-2$'
shows 'remove viewers learner' "^+ AWS_PROFILE=anhnv-sso aws identitystore delete-group-membership --identity-store-id '<IdentityStoreId>' --membership-id '<MembershipId>' --region us-west-2$"
shows 'count admins' '^+ AWS_PROFILE=anhnv-sso aws identitystore list-group-memberships .* --region us-west-2$'
rm "$tfvars"
expect "--print works without org.auto.tfvars and calls nothing" \
  sh -c 'bash "$1" --print count admins >"$2" 2>&1 && grep -q "<sso_region of aws/org/org.auto.tfvars>" "$2" && [ ! -s "$3" ]' _ "$here/platform-member.sh" "$out" "$log"

finish
