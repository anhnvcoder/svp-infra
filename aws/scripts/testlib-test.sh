#!/usr/bin/env bash
# Self-test of testlib.sh, the harness of the other *-test.sh files: the fake aws refuses a call without profile or
# region, answers from files and as the account of each profile of the table, and the real aws and the learner's
# ~/.aws are out of reach.

# Usage: aws/scripts/testlib-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
real_home=$HOME
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"

# rc CODE CMD...: CMD exits with CODE, silently.
rc() {
  local want=$1 got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ]
}

# --- the tree and the environment ---------------------------------------------------------------------------------
expect "HOME is in the temporary tree, not the learner's" sh -c '[ "$1" = "$2/home" ] && [ "$1" != "$3" ]' _ "$HOME" "$work" "$real_home"
expect "AWS_CONFIG_FILE is in the temporary tree" sh -c '[ "$AWS_CONFIG_FILE" = "$1/home/.aws/config" ]' _ "$work"
expect "AWS_SHARED_CREDENTIALS_FILE is in the temporary tree" sh -c '[ "$AWS_SHARED_CREDENTIALS_FILE" = "$1/home/.aws/credentials" ]' _ "$work"
expect "the fake commands directory is first on PATH" sh -c '[ "${PATH%%:*}" = "$1" ]' _ "$bin"
expect "AWS_PROFILE and AWS_REGION of the caller are cleared" sh -c 'AWS_PROFILE=x AWS_REGION=x bash -c ". \"$1/testlib.sh\"; [ -z \"\${AWS_PROFILE:-}\" ] && [ -z \"\${AWS_REGION:-}\" ]"' _ "$src"

# --- the real aws is out of reach ---------------------------------------------------------------------------------
expect "before fake_aws, aws is the guard of the tree" sh -c '[ "$(command -v aws)" = "$1/aws" ]' _ "$bin"
expect "before fake_aws, the guard exits 99" rc 99 aws sts get-caller-identity --region ap-southeast-1
expect "before fake_aws, the guard logs the call" grep -q '^aws sts get-caller-identity --region ap-southeast-1 (guard' "$log"
fake_aws
expect "after fake_aws, the first aws on PATH is the fake of the tree" sh -c '[ "$(command -v aws)" = "$1/aws" ]' _ "$bin"
shadowed() {
  mkdir "$work/other" && printf '#!/bin/sh\n' >"$work/other/aws" && chmod +x "$work/other/aws"
  bash -c '. "$1/testlib.sh"; PATH=$2/other:$PATH; fake_aws' _ "$src" "$work"
}
expect "fake_aws stops when something else comes first on PATH" rc 1 shadowed

# --- the refusals --------------------------------------------------------------------------------------------------
expect "aws without AWS_PROFILE exits 97" rc 97 aws sts get-caller-identity --region ap-southeast-1
expect "aws without --region exits 97" rc 97 env AWS_PROFILE=anhnv-stg aws sts get-caller-identity
expect "aws with --region and no value exits 97" rc 97 env AWS_PROFILE=anhnv-stg aws sts get-caller-identity --region
expect "aws under a profile outside the table exits 97" rc 97 env AWS_PROFILE=anhnv-other aws sts get-caller-identity --region ap-southeast-1
expect "a refused call is in the log" grep -qx 'aws sts get-caller-identity' "$log"

# --- the answers ---------------------------------------------------------------------------------------------------
printf '{"Accounts": []}\n' >"$answers/organizations_list-accounts"
expect "a command answers with the file of its key, options after the words left out of the key" \
  sh -c '[ "$(AWS_PROFILE=anhnv-sso aws organizations list-accounts --output json --region us-east-1)" = "{\"Accounts\": []}" ]'
expect "the answered call is in the log" grep -qx 'aws organizations list-accounts --output json --region us-east-1' "$log"
expect "a command without an answer file exits 96" rc 96 env AWS_PROFILE=anhnv-sso aws iam list-users --region us-east-1
expect "a command without an answer file logs its key" grep -qx 'no answer: iam_list-users' "$log"

# --- the accounts of the profiles ----------------------------------------------------------------------------------
who() { jq -r .Account < <(AWS_PROFILE=$1 aws sts get-caller-identity --region ap-southeast-1); }
while read -r p a; do
  expect "sts get-caller-identity of $p is account $a" sh -c '[ "$1" = "$2" ]' _ "$(who "$p")" "$a"
done <<'ROWS'
anhnv-sso 000000000000
anhnv-stg 111111111111
anhnv-stg-ro 111111111111
anhnv-prd 222222222222
anhnv-prd-ro 222222222222
anhnv-log-ro 333333333333
anhnv-security-ro 444444444444
anhnv-backup-ro 555555555555
ROWS

# --- fake_cmd ------------------------------------------------------------------------------------------------------
fake_cmd gh 'echo "gh says $1"'
expect "fake_cmd runs its script with the arguments" sh -c '[ "$(gh api)" = "gh says api" ]'
expect "fake_cmd logs the call" grep -qx 'gh api' "$log"

# --- no_leak -------------------------------------------------------------------------------------------------------
printf 'line one\nthe secret-value-123 is here\n' >"$work/leaky"
printf 'nothing\n' >"$work/clean"
expect "no_leak passes when no file holds the value" no_leak secret-value-123 "$work/clean" "$work/missing"
leaks() { ! no_leak secret-value-123 "$work/clean" "$work/leaky"; }
expect "no_leak fails when a file holds the value" leaks
expect "no_leak reads the value as text, not as a pattern" no_leak 'secret.*123' "$work/leaky"
expect "no_leak of an empty value is an error" rc 2 no_leak '' "$work/clean"

# --- finish --------------------------------------------------------------------------------------------------------
sub() { bash -c ". \"$src/testlib.sh\"; $1" _; }
expect "finish exits 0 and prints ok when every check passed" sh -c '[ "$(bash -c ". \"$1/testlib.sh\"; expect a true; finish" | tail -n 1)" = "ok    every check passed" ]' _ "$src"
expect "finish exits 1 when a check failed" rc 1 sub 'expect a false; expect b true; finish'
expect "a failed check prints FAIL and its name on stderr" sh -c '[ "$(bash -c ". \"$1/testlib.sh\"; expect named-check false; finish" 2>&1 >/dev/null | head -n 1)" = "FAIL  named-check" ]' _ "$src"
expect "the temporary tree is removed at exit" sh -c 'w=$(bash -c ". \"$1/testlib.sh\"; echo \"\$work\""); [ -n "$w" ] && [ ! -e "$w" ]' _ "$src"
expect "the tree of this test still exists" test -d "$work/bin"

finish
