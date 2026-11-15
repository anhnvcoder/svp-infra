#!/usr/bin/env bash
# Self-test of profiles.sh: each row of the table sets the profile, the account variable and the name of its account,
# a profile outside the table stops, and check_account of lib.sh works on every row against the fake aws (and stops on
# another account); --print reaches nothing.

# Usage: aws/scripts/profiles-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"
fake_aws

# The expected table, written out here and not read from profiles.sh: profile, account variable, permission set, name of
# the account, account of the fake aws.
rows='anhnv-sso SVP_AWS_MGMT_ACCOUNT_ID - mgmt 000000000000
anhnv-stg SVP_AWS_STG_ACCOUNT_ID SvpAdmin stg 111111111111
anhnv-stg-ro SVP_AWS_STG_ACCOUNT_ID SvpReadOnly stg 111111111111
anhnv-prd SVP_AWS_PRD_ACCOUNT_ID SvpAdmin prd 222222222222
anhnv-prd-ro SVP_AWS_PRD_ACCOUNT_ID SvpReadOnly prd 222222222222
anhnv-log-ro SVP_AWS_LOG_ACCOUNT_ID SvpLogReader log 333333333333
anhnv-security-ro SVP_AWS_SECURITY_ACCOUNT_ID SvpReadOnly security 444444444444
anhnv-backup-ro SVP_AWS_BACKUP_ACCOUNT_ID SvpReadOnly backup 555555555555'

# drv CODE [--print]: CODE (bash) after lib.sh and profiles.sh were sourced as a session script does, with the options
# of the script after CODE.
cat >"$work/drv.sh" <<'EOF'
set -euo pipefail
code=$1
shift
. "$LIBDIR/lib.sh"
. "$LIBDIR/profiles.sh"
eval "$code"
EOF
export LIBDIR=$src
drv() { bash "$work/drv.sh" "$@"; }

expect "the table has the eight profiles" test "$(drv 'printf "%s\n" "$profile_table" | wc -l | tr -d " "')" = 8

while read -r p v ps n a; do
  expect "$p: row of the table" test "$(drv "printf '%s\n' \"\$profile_table\" | awk '\$1 == \"$p\"'")" = "$p $v $ps $n"
  expect "$p: profile_arg sets profile, account_var and env_name" \
    test "$(drv "profile_arg $p; echo \"\$profile \$account_var \$env_name\"")" = "$p $v $n"
  expect "$p: check_account passes against the fake aws" \
    sh -c 'env "$1=$2" bash "$3" "profile_arg $4; check_account" 2>&1 | grep -q "^ok    account $2 of $5,"' _ "$v" "$a" "$work/drv.sh" "$p" "$n"
  expect "$p: check_account FAILs when $v is another account" \
    sh -c 'out=$(env "$1=$2" bash "$3" "profile_arg $4; check_account" 2>&1) && exit 1; case $out in "FAIL  profile $4 is account"*) exit 0 ;; *) exit 1 ;; esac' \
    _ "$v" 999999999999 "$work/drv.sh" "$p"
done <<<"$rows"

expect "a profile outside the table stops and names it" \
  sh -c 'out=$(bash "$1" "profile_arg anhnv-other" 2>&1) && exit 1; case $out in "FAIL  profile '"'"'anhnv-other'"'"' is not one of anhnv-sso "*) exit 0 ;; *) exit 1 ;; esac' _ "$work/drv.sh"
expect "no profile stops" sh -c '! bash "$1" "profile_arg" >/dev/null 2>&1' _ "$work/drv.sh"

# profile_arg leaves everything else of lib.sh as env_arg set it.
snap='printf "%s|" "$region" "$global_region" "$poll" "$env_table" "$has_zone" "$kept_stacks" "$tunnel_port" "$teardown" "$ladder" "$cluster" "$context" "$env_root" "$gitops_root"'
expect "profile_arg changes none of the other variables of lib.sh" \
  test "$(drv "env_arg stg; $snap")" = "$(drv "env_arg stg; profile_arg anhnv-log-ro; $snap")"

# --print: the commands are shown, none runs, nothing is checked.
: >"$log"
drv 'profile_arg anhnv-security-ro; check_account' --print >"$work/print.out" 2>&1
expect "--print shows the sts call of the profile" grep -q '^+ AWS_PROFILE=anhnv-security-ro aws sts get-caller-identity' "$work/print.out"
expect "--print calls no aws" test ! -s "$log"
expect "--print needs no account variable" sh -c '! grep -q FAIL "$1"' _ "$work/print.out"

finish
