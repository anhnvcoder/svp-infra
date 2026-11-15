#!/usr/bin/env bash
# Self-test of accounts.sh: after check_account of the management account it prints, on stdout and nothing else, the
# export line of each member account found by name in the fake organization; any FAIL leaves stdout empty, the
# management account is never printed, and --print reaches nothing.

# Usage: aws/scripts/accounts-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"
fake_aws
here=$work/infra/aws/scripts
mkdir -p "$here"
cp "$src/lib.sh" "$src/accounts.sh" "$here/"
unset SVP_AWS_STG_ACCOUNT_ID SVP_AWS_PRD_ACCOUNT_ID SVP_AWS_LOG_ACCOUNT_ID SVP_AWS_SECURITY_ACCOUNT_ID \
  SVP_AWS_BACKUP_ACCOUNT_ID
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000
stdout=$work/stdout stderr=$work/stderr
run() { bash "$here/accounts.sh" "$@" >"$stdout" 2>"$stderr"; }
empty() { [ ! -s "$stdout" ]; }

# acct NAME ID STATE: one account of the answer of list-accounts, with Status as the API still sends it beside State.
acct() { printf '{"Id": "%s", "Name": "%s", "State": "%s", "Status": "%s", "Arn": "arn:aws:organizations::000000000000:account/o-fake/%s"}' "$2" "$1" "$3" "$3" "$2"; }
# answer [EXTRA]: the organization of the lab, the management account and a closed account of another name included;
# EXTRA is raw JSON added inside the answer (another account, a NextToken).
answer() {
  local a
  a="$(acct anhnv-mgmt 000000000000 ACTIVE), $(acct svp-stg 111111111111 ACTIVE), $(acct svp-prd 222222222222 ACTIVE)"
  a="$a, $(acct svp-log-archive 333333333333 ACTIVE), $(acct svp-security 444444444444 ACTIVE)"
  a="$a, $(acct svp-backup 555555555555 ACTIVE), $(acct old-sandbox 777777777777 CLOSED)"
  printf '{"Accounts": [%s%s]%s}\n' "$a" "${1:-}" "${2:-}" >"$answers/organizations_list-accounts"
}
want='export SVP_AWS_STG_ACCOUNT_ID=111111111111
export SVP_AWS_PRD_ACCOUNT_ID=222222222222
export SVP_AWS_LOG_ACCOUNT_ID=333333333333
export SVP_AWS_SECURITY_ACCOUNT_ID=444444444444
export SVP_AWS_BACKUP_ACCOUNT_ID=555555555555'

answer
: >"$log"
expect "accounts.sh exits 0" run
expect "stdout is the five export lines and nothing else" test "$(cat "$stdout")" = "$want"
expect "stdout never holds the management account or its variable" \
  sh -c '! grep -q -e 000000000000 -e SVP_AWS_MGMT_ACCOUNT_ID "$1"' _ "$stdout"
expect "the messages go to stderr: the account check and one ok per member account" \
  sh -c 'grep -q "^ok    account 000000000000 of mgmt," "$1" && test "$(grep -c "^ok    SVP_AWS_.*_ACCOUNT_ID: account svp-.*, ACTIVE$" "$1")" = 5' _ "$stderr"
expect "check_account runs before list-accounts, both with anhnv-sso" \
  test "$(awk '{ print $2 "_" $3 }' "$log" | tr '\n' ' ')" = "sts_get-caller-identity organizations_list-accounts "
expect "list-accounts runs in us-east-1" grep -q '^aws organizations list-accounts --output json --region us-east-1$' "$log"
expect "eval of stdout sets the five variables" \
  sh -c 'eval "$(cat "$1")"; test "$SVP_AWS_STG_ACCOUNT_ID $SVP_AWS_LOG_ACCOUNT_ID $SVP_AWS_BACKUP_ACCOUNT_ID" = "111111111111 333333333333 555555555555"' _ "$stdout"

# fails NAME GREP CMD...: CMD (accounts.sh) exits non-zero with a line matching GREP on stderr, and stdout stays empty.
fails() {
  local name=$1 pattern=$2
  shift 2
  if "$@"; then
    bad "$name: exits 0"
    return 0
  fi
  expect "$name: FAIL, stdout empty" sh -c 'grep -q "$1" "$2" && [ ! -s "$3" ]' _ "$pattern" "$stderr" "$stdout"
}
# The FAIL checks run accounts.sh by this wrapper, which writes the two files the checks read.
cat >"$work/acc" <<EOF
#!/usr/bin/env bash
exec bash "$here/accounts.sh" "\$@" >"$stdout" 2>"$stderr"
EOF
chmod +x "$work/acc"

: >"$log"
fails "SVP_AWS_MGMT_ACCOUNT_ID not exported" '^FAIL  set SVP_AWS_MGMT_ACCOUNT_ID to the 12 digits' env -u SVP_AWS_MGMT_ACCOUNT_ID "$work/acc"
expect "SVP_AWS_MGMT_ACCOUNT_ID not exported: no aws call" test ! -s "$log"
fails "SVP_AWS_MGMT_ACCOUNT_ID another account" '^FAIL  profile anhnv-sso is account .000000000000.' env SVP_AWS_MGMT_ACCOUNT_ID=999999999999 "$work/acc"
expect "SVP_AWS_MGMT_ACCOUNT_ID another account: list-accounts never runs" sh -c '! grep -q "organizations" "$1"' _ "$log"

answer ", $(acct svp-stg 888888888888 ACTIVE)"
fails "two accounts named svp-stg" '^FAIL  more than one account named svp-stg' "$work/acc"
answer ", $(acct svp-stg 888888888888 CLOSED), $(acct svp-stg 999999999999 PENDING_CLOSURE), $(acct svp-stg 666666666666 SUSPENDED)"
expect "svp-stg rebuilt beside closed, closing and suspended accounts of its name: the ACTIVE one is taken" \
  sh -c '"$1" && test "$(cat "$2")" = "$3"' _ "$work/acc" "$stdout" "$want"
printf '{"Accounts": [%s, %s, %s]}\n' "$(acct svp-stg 111111111111 CLOSED)" "$(acct svp-stg 888888888888 CLOSED)" \
  "$(acct svp-prd 222222222222 ACTIVE)" >"$answers/organizations_list-accounts"
fails "svp-stg held by closed accounts alone" '^FAIL  account svp-stg is CLOSED, not ACTIVE' "$work/acc"
printf '{"Accounts": [%s, %s]}\n' "$(acct svp-stg 111111111111 ACTIVE)" "$(acct svp-prd 222222222222 ACTIVE)" >"$answers/organizations_list-accounts"
fails "svp-log-archive missing" '^FAIL  no account svp-log-archive in the organization: apply aws/org first' "$work/acc"
answer ", $(acct svp-backup-old 666666666666 ACTIVE)"
expect "an account whose name only starts like one of the lab's is not taken" sh -c '"$1" && ! grep -q 666666666666 "$2"' _ "$work/acc" "$stdout"
sed 's/"Name": "svp-security", "State": "ACTIVE"/"Name": "svp-security", "State": "SUSPENDED"/' "$answers/organizations_list-accounts" >"$work/a"
mv "$work/a" "$answers/organizations_list-accounts"
fails "svp-security SUSPENDED" '^FAIL  account svp-security is SUSPENDED, not ACTIVE' "$work/acc"
answer '' ', "NextToken": "page-2"'
fails "an answer with a NextToken" '^FAIL  list-accounts answered one page and a NextToken' "$work/acc"
answer
sed 's/"State": "[A-Z]*", //g' "$answers/organizations_list-accounts" >"$work/a"
mv "$work/a" "$answers/organizations_list-accounts"
expect "an answer with Status alone (no State) is read" sh -c '"$1" && test "$(cat "$2")" = "$3"' _ "$work/acc" "$stdout" "$want"

# --print: the commands on stderr, nothing on stdout, nothing called.
answer
: >"$log"
expect "--print exits 0" run --print
expect "--print calls no aws" test ! -s "$log"
expect "--print leaves stdout empty" empty
expect "--print shows the account check and list-accounts on stderr" \
  sh -c 'grep -q "^+ AWS_PROFILE=anhnv-sso aws sts get-caller-identity" "$1" && grep -q "^+ AWS_PROFILE=anhnv-sso aws organizations list-accounts --output json --region us-east-1$" "$1"' _ "$stderr"
expect "an argument is refused, stdout empty" sh -c '! "$1" stg && [ ! -s "$2" ]' _ "$work/acc" "$stdout"

finish
