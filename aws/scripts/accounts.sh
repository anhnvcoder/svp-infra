#!/usr/bin/env bash
# The account variables of the member accounts, read from the organization with profile anhnv-sso once
# SVP_AWS_MGMT_ACCOUNT_ID (typed by the learner) matches that profile's account. stdout holds only the export lines,
# for eval in the terminal of a session; every message goes to stderr.

# On any FAIL stdout stays empty, so the eval sets nothing. SVP_AWS_MGMT_ACCOUNT_ID is never printed: it is the
# reference check_account compares with.

# Usage: eval "$(aws/scripts/accounts.sh)"
#        aws/scripts/accounts.sh --print
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 0 ] || fail "usage: eval \"\$($(basename "$0"))\""
# fd 4 is the stdout eval reads; everything else, --print included, goes to stderr.
exec 4>&1 1>&2 3>&2
env_arg mgmt any

# The member accounts by their name in aws/org, and the variable of each (the table of profiles.sh).
members='svp-stg SVP_AWS_STG_ACCOUNT_ID
svp-prd SVP_AWS_PRD_ACCOUNT_ID
svp-log-archive SVP_AWS_LOG_ACCOUNT_ID
svp-security SVP_AWS_SECURITY_ACCOUNT_ID
svp-backup SVP_AWS_BACKUP_ACCOUNT_ID'

step "accounts.sh: the member accounts of the organization"
check_account
out=$(aws_global_ organizations list-accounts --output json) ||
  fail "aws organizations list-accounts with profile $profile"
printing && exit 0
[ "$(jq -r '.NextToken // empty' <<<"$out")" = "" ] ||
  fail "list-accounts answered one page and a NextToken: not every account was read"

lines=
while read -r name var; do
  # State replaced Status in the answer of list-accounts; Status is read only when State is absent.
  rows=$(jq -r --arg n "$name" '.Accounts[] | select(.Name == $n) | "\(.Id) \(.State // .Status // "-")"' <<<"$out")
  # list-accounts keeps a closed account for 90 days, so one rebuilt under the same name is no duplicate of it; a name
  # held by closed accounts alone still fails below, as not ACTIVE.
  case $(grep -c . <<<"$rows" || true) in
    0) fail "no account $name in the organization: apply aws/org first (README.md of aws/org)" ;;
    1) ;;
    *)
      live=$(grep -vE ' (CLOSED|SUSPENDED|PENDING_CLOSURE)$' <<<"$rows" || true)
      case $(grep -c . <<<"$live" || true) in
        0) rows=$(head -n 1 <<<"$rows") ;;
        1) rows=$live ;;
        *) fail "more than one account named $name in the organization: rename the extra one" ;;
      esac
      ;;
  esac
  read -r id state <<<"$rows"
  [ "$state" = ACTIVE ] || fail "account $name is $state, not ACTIVE"
  [[ $id =~ ^[0-9]{12}$ ]] || fail "account $name has id '$id', not 12 digits"
  ok "$var: account $name, ACTIVE"
  lines="${lines}export $var=$id
"
done <<<"$members"
printf '%s' "$lines" >&4
