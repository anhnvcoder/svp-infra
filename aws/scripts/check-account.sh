#!/usr/bin/env bash
# First step of every AWS session, and before every command of the learner that writes to an account: the account
# behind the environment's profile (anhnv-sso for mgmt, anhnv-stg, anhnv-prd) must be the one the learner exported in
# its variable (SVP_AWS_MGMT_ACCOUNT_ID, SVP_AWS_STG_ACCOUNT_ID, SVP_AWS_PRD_ACCOUNT_ID; never written to a file).
# Prints the account and the ARN of the caller, for both sides to read; stops on any other account. Starts the
# session's timeline in $SVP_SESSION_DIR.
#
# Usage: aws/scripts/check-account.sh [--print] mgmt|stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] $(env_names)"
env_arg "$1" any

session_dir
step "check-account.sh: the account of profile $profile ($env_name)"
check_account
if printing || [ ! -s "$session/timeline.tsv" ]; then
  mark session-start
fi
